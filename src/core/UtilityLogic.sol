// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";
import {IFlashBorrower} from "@yolo/contracts/interfaces/IFlashBorrower.sol";
import {YoloStorage} from "./YoloStorage.sol";

/**
 * @title   UtilityLogic
 * @author  0xyolodev.eth
 * @notice  Delegated logic contract for utility functions (flash loans, cross-chain, helper functions)
 * @dev     IMPORTANT: This contract MUST NOT have constructor or additional storage
 *          It inherits storage layout from YoloStorage and is called via delegatecall
 */
contract UtilityLogic is YoloStorage {
    using CurrencySettler for Currency;

    // ========================
    // EXTERNAL FUNCTIONS (called via delegatecall)
    // ========================

    /**
     * @notice Execute a batch flash loan for multiple YoloAssets
     * @param _yoloAssets Array of YoloAsset addresses to borrow
     * @param _amounts Array of amounts to borrow per asset
     * @param _data Arbitrary call data passed to the borrower
     */
    function flashLoan(address[] calldata _yoloAssets, uint256[] calldata _amounts, bytes calldata _data) external {
        if (_yoloAssets.length != _amounts.length) revert YoloHook__ParamsLengthMismatched();

        uint256[] memory fees = new uint256[](_yoloAssets.length);
        uint256[] memory totalRepayments = new uint256[](_yoloAssets.length);

        // Mint flash loans to the borrower
        for (uint256 i = 0; i < _yoloAssets.length;) {
            if (!isYoloAsset[_yoloAssets[i]]) revert YoloHook__NotYoloAsset();

            YoloAssetConfiguration storage assetConfig = yoloAssetConfigs[_yoloAssets[i]];
            if (assetConfig.maxMintableCap <= 0) revert YoloHook__YoloAssetPaused();

            // Check if flash loan amount exceeds the cap
            if (assetConfig.maxFlashLoanableAmount > 0 && _amounts[i] > assetConfig.maxFlashLoanableAmount) {
                revert YoloHook__ExceedsFlashLoanCap();
            }

            // Calculate the fee and total repayment
            uint256 fee = (_amounts[i] * flashLoanFee) / PRECISION_DIVISOR;
            fees[i] = fee;
            totalRepayments[i] = _amounts[i] + fee;

            // Mint the YoloAsset to the borrower
            IYoloSyntheticAsset(_yoloAssets[i]).mint(msg.sender, _amounts[i]);

            unchecked {
                ++i;
            }
        }

        // Call the borrower's callback function
        IFlashBorrower(msg.sender).onBatchFlashLoan(msg.sender, _yoloAssets, _amounts, fees, _data);

        // Burn the amount + fee from the borrower and mint fee to the treasury
        for (uint256 i = 0; i < _yoloAssets.length;) {
            // Ensure repayment
            IYoloSyntheticAsset(_yoloAssets[i]).burn(msg.sender, totalRepayments[i]);

            // Mint the fee to the protocol treasury
            IYoloSyntheticAsset(_yoloAssets[i]).mint(treasury, fees[i]);
            unchecked {
                ++i;
            }
        }

        emit FlashLoanExecuted(msg.sender, _yoloAssets, _amounts, fees);
    }

    /**
     * @notice Burn YoloAssets for cross-chain transfer (called by registered bridge)
     * @param _yoloAsset YoloAsset to burn
     * @param _amount Amount to burn
     * @param _sender Original sender of the tokens
     */
    function crossChainBurn(address _yoloAsset, uint256 _amount, address _sender) external {
        if (msg.sender != registeredBridge) revert YoloHook__NotBridge();
        if (!isYoloAsset[_yoloAsset]) revert YoloHook__NotYoloAsset();
        if (_amount == 0) revert YoloHook__InsufficientAmount();

        // Burn the tokens from the sender
        IYoloSyntheticAsset(_yoloAsset).burn(_sender, _amount);

        emit CrossChainBurn(msg.sender, _yoloAsset, _amount, _sender);
    }

    /**
     * @notice Mint YoloAssets for cross-chain transfer (called by registered bridge)
     * @param _yoloAsset YoloAsset to mint
     * @param _amount Amount to mint
     * @param _receiver Receiver of the minted tokens
     */
    function crossChainMint(address _yoloAsset, uint256 _amount, address _receiver) external {
        if (msg.sender != registeredBridge) revert YoloHook__NotBridge();
        if (!isYoloAsset[_yoloAsset]) revert YoloHook__NotYoloAsset();
        if (_amount == 0) revert YoloHook__InsufficientAmount();
        if (_receiver == address(0)) revert YoloHook__ZeroAddress();

        // Check if minting would exceed the cap
        YoloAssetConfiguration storage config = yoloAssetConfigs[_yoloAsset];
        if (config.maxMintableCap > 0) {
            // Note: We can't call totalSupply() directly on interfaces, need to cast
            uint256 currentSupply = IYoloSyntheticAsset(_yoloAsset).totalSupply();
            if (currentSupply + _amount > config.maxMintableCap) {
                revert YoloHook__ExceedsYoloAssetMintCap();
            }
        }

        // Mint the tokens to the receiver
        IYoloSyntheticAsset(_yoloAsset).mint(_receiver, _amount);

        emit CrossChainMint(msg.sender, _yoloAsset, _amount, _receiver);
    }

    /**
     * @notice Handle burning of pending tokens (called from unlock callback)
     * @param poolManager The PoolManager instance (passed from YoloHook since it's immutable)
     */
    function handleBurnPending(address poolManager) external {
        if (assetToBurn == address(0) || amountToBurn == 0) return; // Nothing to burn

        Currency c = Currency.wrap(assetToBurn);
        IPoolManager pm = IPoolManager(poolManager);

        // We're in an unlock callback, so we can do the settle/take operations
        c.settle(pm, address(this), amountToBurn, true); // burn the claim-tokens
        c.take(pm, address(this), amountToBurn, false); // pull the real tokens
        IYoloSyntheticAsset(assetToBurn).burn(address(this), amountToBurn); // burn the real tokens

        assetToBurn = address(0);
        amountToBurn = 0;
    }

    /**
     * @notice Handle USDC pull operations for rehypothecation (unlock callback helper)
     * @param _amount Amount of USDC to pull
     * @param poolManager The PoolManager instance (passed from YoloHook since it's immutable)
     */
    function handlePullRealUSDC(uint256 _amount, address poolManager) external {
        Currency cUSDC = Currency.wrap(usdc);
        IPoolManager pm = IPoolManager(poolManager);

        // burn claim-tokens we currently hold
        cUSDC.settle(pm, address(this), _amount, true);
        // receive the underlying ERC-20
        cUSDC.take(pm, address(this), _amount, false);
    }

    /**
     * @notice Handle USDC push operations for rehypothecation (unlock callback helper)
     * @param _amount Amount of USDC to push
     * @param poolManager The PoolManager instance (passed from YoloHook since it's immutable)
     */
    function handlePushRealUSDC(uint256 _amount, address poolManager) external {
        Currency cUSDC = Currency.wrap(usdc);
        IPoolManager pm = IPoolManager(poolManager);

        // hand ERC-20 back to PM and get fresh claim-tokens
        cUSDC.settle(pm, address(this), _amount, false);
    }

    // ========================
    // INTERNAL HELPER FUNCTIONS
    // ========================

    /**
     * @notice Remove a position key from a user's positions array
     * @param _user User address
     * @param _collateral Collateral asset address
     * @param _yoloAsset YoloAsset address
     */
    function removeUserPositionKey(address _user, address _collateral, address _yoloAsset) external {
        UserPositionKey[] storage keys = userPositionKeys[_user];
        for (uint256 i = 0; i < keys.length;) {
            if (keys[i].collateral == _collateral && keys[i].yoloAsset == _yoloAsset) {
                // Swap with last element and pop
                keys[i] = keys[keys.length - 1];
                keys.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Add a position key to a user's positions array
     * @param _user User address
     * @param _collateral Collateral asset address
     * @param _yoloAsset YoloAsset address
     */
    function addUserPositionKey(address _user, address _collateral, address _yoloAsset) external {
        // Check if already exists
        UserPositionKey[] storage keys = userPositionKeys[_user];
        for (uint256 i = 0; i < keys.length;) {
            if (keys[i].collateral == _collateral && keys[i].yoloAsset == _yoloAsset) {
                return; // Already exists
            }
            unchecked {
                ++i;
            }
        }

        // Add new key
        keys.push(UserPositionKey({collateral: _collateral, yoloAsset: _yoloAsset}));
    }
}
