// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {YoloStorage} from "./YoloStorage.sol";

/**
 * @title   AnchorPoolLogic
 * @author  0xyolodev.eth
 * @notice  Delegated logic contract for anchor pool operations (addLiquidity/removeLiquidity)
 * @dev     IMPORTANT: This contract MUST NOT have constructor or additional storage
 *          It inherits storage layout from YoloStorage and is called via delegatecall
 */
contract AnchorPoolLogic is YoloStorage {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // ========================
    // DATA STRUCTURES (callback data)
    // ========================

    struct CallbackData {
        uint8 action; // 0 = Add Liquidity, 1 = Remove Liquidity
        bytes data;
    }

    struct AddLiquidityCallbackData {
        address sender;
        address receiver;
        uint256 usdcUsed;
        uint256 usyUsed;
        uint256 liquidity;
    }

    struct RemoveLiquidityCallbackData {
        address initiator;
        address receiver;
        uint256 usdcAmount;
        uint256 usyAmount;
        uint256 liquidity;
    }

    // ========================
    // EXTERNAL FUNCTIONS (called via delegatecall)
    // ========================

    /**
     * @notice  Add liquidity to the anchor pool pair (USDC/USY) with ratio enforcement
     * @param   _maxUsdcAmount Maximum USDC amount user wants to add
     * @param   _maxUsyAmount Maximum USY amount user wants to add
     * @param   _minLiquidityReceive Minimum LP tokens to receive
     * @param   _receiver Address to receive sUSY tokens
     */
    function addLiquidity(
        uint256 _maxUsdcAmount,
        uint256 _maxUsyAmount,
        uint256 _minLiquidityReceive,
        address _receiver
    )
        external
        returns (uint256 actualUsdcUsed, uint256 actualUsyUsed, uint256 actualLiquidityMinted, address actualReceiver)
    {
        // Validation
        if (_maxUsdcAmount == 0 || _maxUsyAmount == 0 || _receiver == address(0)) {
            revert YoloHook__InvalidAddLiquidityParams();
        }
        require(address(sUSY) != address(0), "sUSY not initialized");

        uint256 maxUsdcAmountInWad = _toWadUSDC(_maxUsdcAmount);
        uint256 maxUsyAmountInWad = _maxUsyAmount;

        uint256 usdcUsed;
        uint256 usyUsed;
        uint256 liquidity;

        uint256 currentTotalSupply = sUSY.totalSupply();

        if (currentTotalSupply == 0) {
            // First liquidity - use the smaller side to enforce 1:1 ratio and mint sUSY 1:1 vs USD value
            uint256 minInWad = maxUsdcAmountInWad < maxUsyAmountInWad ? maxUsdcAmountInWad : maxUsyAmountInWad;
            usdcUsed = _fromWadUSDC(minInWad);
            usyUsed = minInWad;

            // Mint amount equals total USD value (USDC+USY) minus MINIMUM_LIQUIDITY
            uint256 valueAdded = minInWad + minInWad; // both sides equal in WAD
            if (valueAdded <= MINIMUM_LIQUIDITY) revert YoloHook__InsufficientAmount();
            liquidity = valueAdded - MINIMUM_LIQUIDITY;
            if (liquidity < _minLiquidityReceive) revert YoloHook__InsufficientLiquidityMinted();
            // Lock MINIMUM_LIQUIDITY permanently (non-zero burn address)
            sUSY.mint(address(1), MINIMUM_LIQUIDITY);
        } else {
            // Proportional liquidity to maintain pool ratio; mint sUSY based on USD value share
            uint256 totalReserveUsdcInWad = _toWadUSDC(totalAnchorReserveUSDC);
            uint256 totalReserveUsyInWad = totalAnchorReserveUSY;

            // Calculate optimal amounts maintaining current ratio
            uint256 optimalUsyInWad = (maxUsdcAmountInWad * totalReserveUsyInWad) / totalReserveUsdcInWad;
            if (optimalUsyInWad <= maxUsyAmountInWad) {
                usdcUsed = _fromWadUSDC(maxUsdcAmountInWad);
                usyUsed = optimalUsyInWad;
            } else {
                uint256 optimalUsdcInWad = (maxUsyAmountInWad * totalReserveUsdcInWad) / totalReserveUsyInWad;
                usdcUsed = _fromWadUSDC(optimalUsdcInWad);
                usyUsed = maxUsyAmountInWad;
            }

            // Mint sUSY in proportion to value share
            uint256 valueAdded = _toWadUSDC(usdcUsed) + usyUsed;
            uint256 totalValueBefore = totalReserveUsdcInWad + totalReserveUsyInWad;
            liquidity = (valueAdded * currentTotalSupply) / totalValueBefore;
            if (liquidity < _minLiquidityReceive) revert YoloHook__InsufficientLiquidityMinted();
        }

        // Execute transfers - hook receives the tokens
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcUsed);
        IERC20(address(anchor)).safeTransferFrom(msg.sender, address(this), usyUsed);

        // Convert real tokens to PM claim-tokens and update reserves via unlock callback
        IPoolManager poolManager = _getPoolManager();
        poolManager.unlock(
            abi.encode(
                CallbackData({
                    action: 0,
                    data: abi.encode(
                        AddLiquidityCallbackData({
                            sender: msg.sender,
                            receiver: _receiver,
                            usdcUsed: usdcUsed,
                            usyUsed: usyUsed,
                            liquidity: liquidity
                        })
                    )
                })
            )
        );

        // Mint sUSY receipt tokens after successful settlement
        sUSY.mint(_receiver, liquidity);

        return (usdcUsed, usyUsed, liquidity, _receiver);
    }

    /**
     * @notice  Remove liquidity from the anchor pool
     * @param   _minUSDC    Minimum USDC to receive
     * @param   _minUSY     Minimum USY to receive
     * @param   _liquidity  Amount of sUSY tokens to burn
     * @param   _receiver   Address to receive the USDC and USY
     */
    function removeLiquidity(uint256 _minUSDC, uint256 _minUSY, uint256 _liquidity, address _receiver)
        external
        returns (uint256 usdcAmount, uint256 usyAmount, uint256 liquidity, address receiver)
    {
        // Validation
        require(_liquidity > 0, "Invalid liquidity amount");
        require(_receiver != address(0), "Invalid receiver");
        require(address(sUSY) != address(0), "sUSY not initialized");

        uint256 totalSupply = sUSY.totalSupply();
        require(totalSupply > 0, "No liquidity in pool");
        if (sUSY.balanceOf(msg.sender) < _liquidity) revert YoloHook__InsufficientLiquidityBalance();

        // Calculate proportional amounts (rounding down to benefit pool)
        usdcAmount = (_liquidity * totalAnchorReserveUSDC) / totalSupply;
        usyAmount = (_liquidity * totalAnchorReserveUSY) / totalSupply;

        if (usdcAmount < _minUSDC) revert YoloHook__InsufficientAmount();
        if (usyAmount < _minUSY) revert YoloHook__InsufficientAmount();

        // Handle rehypothecation if needed
        _handleDehypothecation(usdcAmount);

        // Burn sUSY tokens from user
        sUSY.burn(msg.sender, _liquidity);

        // Settle transfers via PoolManager unlock callback (action 1)
        IPoolManager poolManager = _getPoolManager();
        poolManager.unlock(
            abi.encode(
                CallbackData({
                    action: 1,
                    data: abi.encode(
                        RemoveLiquidityCallbackData({
                            initiator: msg.sender,
                            receiver: _receiver,
                            usdcAmount: usdcAmount,
                            usyAmount: usyAmount,
                            liquidity: _liquidity
                        })
                    )
                })
            )
        );

        // Emit liquidity event for compatibility
        if (anchorPoolToken0 == usdc) {
            emit HookModifyLiquidity(anchorPoolId, _receiver, -int128(int256(usdcAmount)), -int128(int256(usyAmount)));
        } else {
            emit HookModifyLiquidity(anchorPoolId, _receiver, -int128(int256(usyAmount)), -int128(int256(usdcAmount)));
        }

        return (usdcAmount, usyAmount, _liquidity, _receiver);
    }

    /**
     * @notice Handle unlock callback for liquidity operations
     * @param _callbackData Encoded callback data
     */
    function handleLiquidityUnlockCallback(bytes calldata _callbackData) external returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(_callbackData, (CallbackData));
        uint8 action = callbackData.action;

        if (action == 0) {
            // CASE A: Add Liquidity
            AddLiquidityCallbackData memory data = abi.decode(callbackData.data, (AddLiquidityCallbackData));
            uint256 usdcUsed = data.usdcUsed;
            uint256 usyUsed = data.usyUsed;

            // Handle claim tokens properly
            Currency cUSDC = Currency.wrap(usdc);
            Currency cUSY = Currency.wrap(address(anchor));

            IPoolManager poolManager = _getPoolManager();

            // Settle = hook pays real tokens to PoolManager
            cUSDC.settle(poolManager, address(this), usdcUsed, false);
            cUSY.settle(poolManager, address(this), usyUsed, false);

            // Take = hook receives claim tokens from PoolManager
            cUSDC.take(poolManager, address(this), usdcUsed, true);
            cUSY.take(poolManager, address(this), usyUsed, true);

            // Update state
            totalAnchorReserveUSDC += usdcUsed;
            totalAnchorReserveUSY += usyUsed;

            return abi.encode(address(this), data.receiver, usdcUsed, usyUsed, data.liquidity);
        } else if (action == 1) {
            // CASE B: Remove Liquidity
            RemoveLiquidityCallbackData memory data = abi.decode(callbackData.data, (RemoveLiquidityCallbackData));
            uint256 usdcAmount = data.usdcAmount;
            uint256 usyAmount = data.usyAmount;

            // Update reserves
            totalAnchorReserveUSDC -= usdcAmount;
            totalAnchorReserveUSY -= usyAmount;

            // Transfer tokens back to user using PoolManager's accounting systems
            Currency usdcCurrency = Currency.wrap(usdc);
            Currency usyCurrency = Currency.wrap(address(anchor));

            IPoolManager poolManager = _getPoolManager();

            usdcCurrency.settle(poolManager, address(this), usdcAmount, true);
            usyCurrency.settle(poolManager, address(this), usyAmount, true);

            // For USDC: Burn our claim tokens and give real USDC to user
            usdcCurrency.take(poolManager, data.receiver, usdcAmount, false);
            // For USY: Burn our claim tokens and give real USY to user
            usyCurrency.take(poolManager, data.receiver, usyAmount, false);

            return abi.encode(data.initiator, data.receiver, usdcAmount, usyAmount, data.liquidity);
        } else {
            revert YoloHook__UnknownUnlockActionError();
        }
    }

    /**
     * @notice Get total USD value of anchor pool reserves (for sUSY exchange rate)
     * @return totalValue Combined USD value of USDC + USY reserves (18 decimals)
     */
    function getTotalAnchorPoolValue() external view returns (uint256 totalValue) {
        // Convert USDC (6 decimals) to 18 decimals (treat as $1)
        uint256 usdcValue18 = _toWadUSDC(totalAnchorReserveUSDC);
        // USY is 18 decimals and treated as $1 in the stable anchor pool
        uint256 usyValue18 = totalAnchorReserveUSY;
        return usdcValue18 + usyValue18;
    }

    // ========================
    // INTERNAL HELPER FUNCTIONS
    // ========================

    /**
     * @notice Convert raw USDC amount to WAD (18 decimals)
     */
    function _toWadUSDC(uint256 _raw) internal view returns (uint256) {
        return _raw * USDC_SCALE_UP;
    }

    /**
     * @notice Convert WAD (18 decimals) to raw USDC's native decimals (usually 6 decimals)
     */
    function _fromWadUSDC(uint256 _wad) internal view returns (uint256) {
        return _wad / USDC_SCALE_UP;
    }

    /**
     * @notice Get the PoolManager instance
     * @dev Calls back to YoloHook to get the immutable poolManager
     */
    function _getPoolManager() internal view returns (IPoolManager) {
        // poolManager is immutable in BaseHook, so we need to call YoloHook to get it
        // Use low-level call to avoid interface dependency
        (bool success, bytes memory data) = address(this).staticcall(abi.encodeWithSignature("getPoolManager()"));
        require(success, "Failed to get poolManager");
        return abi.decode(data, (IPoolManager));
    }

    /**
     * @notice Handle dehypothecation - delegatecall to RehypothecationLogic
     * @param _usdcNeeded Amount of USDC needed
     */
    function _handleDehypothecation(uint256 _usdcNeeded) internal {
        if (rehypothecationLogic == address(0)) return; // No rehypo logic set

        (bool success, bytes memory ret) =
            rehypothecationLogic.delegatecall(abi.encodeWithSignature("handleDehypothecation(uint256)", _usdcNeeded));
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
