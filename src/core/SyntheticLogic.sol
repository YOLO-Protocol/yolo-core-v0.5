// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IYoloOracle} from "@yolo/contracts/interfaces/IYoloOracle.sol";
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";
import {IFlashBorrower} from "@yolo/contracts/interfaces/IFlashBorrower.sol";

contract SyntheticLogic {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // Constants
    uint256 private constant PRECISION_DIVISOR = 10000;

    // Storage variables accessed via delegatecall context from YoloHook
    IPoolManager public poolManager;
    address public treasury;
    IYoloOracle public yoloOracle;
    uint256 public syntheticSwapFee;
    uint256 public flashLoanFee;

    mapping(address => bool) public isYoloAsset;
    mapping(address => YoloAssetConfiguration) public yoloAssetConfigs;

    address public assetToBurn;
    uint256 public amountToBurn;

    struct YoloAssetConfiguration {
        address yoloAssetAddress;
        uint256 maxMintableCap;
        uint256 maxFlashLoanableAmount;
    }

    // Errors
    error YoloHook__ParamsLengthMismatched();
    error YoloHook__NotYoloAsset();
    error YoloHook__YoloAssetPaused();
    error YoloHook__ExceedsFlashLoanCap();
    error YoloHook__NoPendingBurns();

    // Events
    event SyntheticSwapExecuted(
        bytes32 indexed poolId,
        address indexed sender,
        address indexed receiver,
        bool zeroForOne,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
        uint256 feeAmount
    );

    event FlashLoanExecuted(address flashBorrower, address yoloAsset, uint256 amount, uint256 fee);

    event BatchFlashLoanExecuted(
        address indexed flashBorrower, address[] yoloAssets, uint256[] amounts, uint256[] fees
    );

    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

    function executeSyntheticSwap(bytes32 poolId, address sender, SwapParams calldata params, PoolKey calldata key)
        external
        returns (BeforeSwapDelta beforeSwapDelta)
    {
        // Pick input/output currencies
        (Currency cIn, Currency cOut) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        address tokenIn = Currency.unwrap(cIn);
        address tokenOut = Currency.unwrap(cOut);

        // Determine exact-input or exact-output
        bool isExactInput = params.amountSpecified < 0;

        uint256 grossInputAmount;
        uint256 netInputAmount;
        uint256 netOutputAmount;
        uint256 fee;

        if (isExactInput) {
            // Exact-input: Calculate output
            grossInputAmount = uint256(-int256(params.amountSpecified));
            fee = grossInputAmount * syntheticSwapFee / PRECISION_DIVISOR;
            netInputAmount = grossInputAmount - fee;
            netOutputAmount = yoloOracle.getAssetPrice(tokenIn) * netInputAmount / yoloOracle.getAssetPrice(tokenOut);
        } else {
            // Exact-output: Calculate input
            netOutputAmount = uint256(int256(params.amountSpecified));
            netInputAmount = yoloOracle.getAssetPrice(tokenOut) * netOutputAmount / yoloOracle.getAssetPrice(tokenIn);

            uint256 numerator = netInputAmount * syntheticSwapFee;
            uint256 denominator = PRECISION_DIVISOR - syntheticSwapFee;

            fee = (numerator + denominator - 1) / denominator;
            grossInputAmount = netInputAmount + fee;
        }

        // Pull amount from user into PoolManager
        cIn.take(poolManager, address(this), netInputAmount, true);

        // Pull fee to treasury if non-zero
        if (fee > 0) {
            cIn.take(poolManager, treasury, fee, true);
        }

        // Mint assets to be sent to user and settle with PoolManager
        IYoloSyntheticAsset(tokenOut).mint(address(this), netOutputAmount);
        cOut.settle(poolManager, address(this), netOutputAmount, false);

        // Set assets to burn in afterSwap
        assetToBurn = tokenIn;
        amountToBurn = netInputAmount;

        emit SyntheticSwapExecuted(
            poolId, sender, sender, params.zeroForOne, tokenIn, grossInputAmount, tokenOut, netOutputAmount, fee
        );

        // Construct BeforeSwapDelta
        int128 dSpecified;
        int128 dUnspecified;

        if (params.amountSpecified < 0) {
            dSpecified = int128(uint128(grossInputAmount));
            dUnspecified = -int128(uint128(netOutputAmount));
        } else {
            dSpecified = -int128(uint128(netOutputAmount));
            dUnspecified = int128(uint128(grossInputAmount));
        }
        beforeSwapDelta = toBeforeSwapDelta(dSpecified, dUnspecified);

        // Emit HookSwap event
        uint128 in128 = uint128(grossInputAmount);
        uint128 out128 = uint128(netOutputAmount);
        uint128 fee128 = uint128(fee);

        int128 amount0;
        int128 amount1;
        uint128 fee0;
        uint128 fee1;

        if (params.zeroForOne) {
            amount0 = int128(in128);
            amount1 = -int128(out128);
            fee0 = fee128;
            fee1 = 0;
        } else {
            amount0 = -int128(out128);
            amount1 = int128(in128);
            fee0 = 0;
            fee1 = fee128;
        }

        emit HookSwap(poolId, sender, amount0, amount1, fee0, fee1);
    }

    function simpleFlashLoan(address _yoloAsset, uint256 _amount, bytes calldata _data) external {
        if (!isYoloAsset[_yoloAsset]) revert YoloHook__NotYoloAsset();

        // Check if yolo asset is paused
        YoloAssetConfiguration storage assetConfig = yoloAssetConfigs[_yoloAsset];
        if (assetConfig.maxMintableCap <= 0) revert YoloHook__YoloAssetPaused();

        // Check flash loan cap
        if (assetConfig.maxFlashLoanableAmount > 0 && _amount > assetConfig.maxFlashLoanableAmount) {
            revert YoloHook__ExceedsFlashLoanCap();
        }

        uint256 fee = (_amount * flashLoanFee) / PRECISION_DIVISOR;
        uint256 totalRepayment = _amount + fee;

        // Transfer flash loan to borrower
        IYoloSyntheticAsset(_yoloAsset).mint(msg.sender, _amount);

        // Call borrower's callback
        IFlashBorrower(msg.sender).onFlashLoan(msg.sender, _yoloAsset, _amount, fee, _data);

        // Ensure repayment
        IYoloSyntheticAsset(_yoloAsset).burn(msg.sender, totalRepayment);

        // Mint fee to treasury
        IYoloSyntheticAsset(_yoloAsset).mint(treasury, fee);

        emit FlashLoanExecuted(msg.sender, _yoloAsset, _amount, fee);
    }

    function flashLoan(address[] calldata _yoloAssets, uint256[] calldata _amounts, bytes calldata _data) external {
        if (_yoloAssets.length != _amounts.length) revert YoloHook__ParamsLengthMismatched();

        uint256[] memory fees = new uint256[](_yoloAssets.length);
        uint256[] memory totalRepayments = new uint256[](_yoloAssets.length);

        // Mint flash loans to borrower
        for (uint256 i = 0; i < _yoloAssets.length; i++) {
            if (!isYoloAsset[_yoloAssets[i]]) revert YoloHook__NotYoloAsset();

            // Check if yolo asset is paused
            YoloAssetConfiguration storage assetConfig = yoloAssetConfigs[_yoloAssets[i]];
            if (assetConfig.maxMintableCap <= 0) revert YoloHook__YoloAssetPaused();

            // Check flash loan cap
            if (assetConfig.maxFlashLoanableAmount > 0 && _amounts[i] > assetConfig.maxFlashLoanableAmount) {
                revert YoloHook__ExceedsFlashLoanCap();
            }

            fees[i] = (_amounts[i] * flashLoanFee) / PRECISION_DIVISOR;
            totalRepayments[i] = _amounts[i] + fees[i];

            // Mint the flash loan amount
            IYoloSyntheticAsset(_yoloAssets[i]).mint(msg.sender, _amounts[i]);
        }

        // Call the borrower's batch callback
        IFlashBorrower(msg.sender).onBatchFlashLoan(msg.sender, _yoloAssets, _amounts, fees, _data);

        // Ensure repayment for all assets
        for (uint256 i = 0; i < _yoloAssets.length; i++) {
            // Ensure repayment
            IYoloSyntheticAsset(_yoloAssets[i]).burn(msg.sender, totalRepayments[i]);

            // Mint fee to treasury
            IYoloSyntheticAsset(_yoloAssets[i]).mint(treasury, fees[i]);
        }

        emit BatchFlashLoanExecuted(msg.sender, _yoloAssets, _amounts, fees);
    }

    function burnPendings() external {
        if (assetToBurn == address(0)) revert YoloHook__NoPendingBurns();

        Currency c = Currency.wrap(assetToBurn);
        c.settle(poolManager, address(this), amountToBurn, true);
        c.take(poolManager, address(this), amountToBurn, false);
        IYoloSyntheticAsset(assetToBurn).burn(address(this), amountToBurn);
        assetToBurn = address(0);
        amountToBurn = 0;
    }
}
