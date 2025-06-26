// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "./YoloStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITeller} from "@yolo/contracts/interfaces/ITeller.sol";

/**
 * @title   RehypothecationLogic
 * @notice  Logic contract for rehypothecation operations
 * @dev     This contract is called via delegatecall from YoloHook, sharing its storage
 */
contract RehypothecationLogic is YoloStorage {
    /**
     * @notice  Internal function to buy USYC and track cost basis
     * @param   _usdcAmount  Amount of USDC to spend
     * @return  usycOut      Amount of USYC received
     */
    function buyUSYC(uint256 _usdcAmount) public returns (uint256 usycOut) {
        usycOut = usycTeller.buy(_usdcAmount);

        // Update cost basis with weighted average
        usycCostBasisUSDC += _usdcAmount;
        usycQuantity += usycOut;
        usycBalance = usycQuantity; // Keep usycBalance in sync

        emit RehypothecationExecuted(true, _usdcAmount, usycOut);
        return usycOut;
    }

    /**
     * @notice  Internal function to sell USYC and realize P&L
     * @param   _usycAmount  Amount of USYC to sell
     * @return  usdcOut      Amount of USDC received
     */
    function sellUSYC(uint256 _usycAmount) public returns (uint256 usdcOut) {
        require(_usycAmount <= usycQuantity, "Insufficient USYC");

        // Calculate proportional cost basis being closed
        uint256 costPortion = (usycCostBasisUSDC * _usycAmount) / usycQuantity;

        // Execute the sale
        usdcOut = usycTeller.sell(_usycAmount);

        // Update tracking
        usycCostBasisUSDC -= costPortion;
        usycQuantity -= _usycAmount;
        usycBalance = usycQuantity;

        // Realize P&L to the anchor pool reserves
        if (usdcOut > costPortion) {
            uint256 profit = usdcOut - costPortion;
            totalAnchorReserveUSDC += profit; // LPs get the yield!
            emit RehypothecationGain(profit);
        } else if (usdcOut < costPortion) {
            uint256 loss = costPortion - usdcOut;
            totalAnchorReserveUSDC = totalAnchorReserveUSDC > loss ? totalAnchorReserveUSDC - loss : 0;
            emit RehypothecationLoss(loss);
        }

        // Clear cost basis if fully unwound
        if (usycQuantity == 0) {
            usycCostBasisUSDC = 0;
        }

        emit RehypothecationExecuted(false, _usycAmount, usdcOut);
        return usdcOut;
    }

    /**
     * @notice  Handle rehypothecation during swaps
     * @param   _usdcAmount  Amount of USDC being added to reserves
     */
    function handleRehypothecation(uint256 _usdcAmount) external {
        if (!rehypothecationEnabled || rehypothecationRatio == 0) return;

        // Calculate target USDC value to rehypothecate
        uint256 targetUSDCValue = (totalAnchorReserveUSDC * rehypothecationRatio) / PRECISION_DIVISOR;

        // Get current USYC value in USDC terms
        uint256 currentUSYCValueInUSDC = 0;
        if (usycBalance > 0) {
            // Preview how much USDC we'd get if we sold all our USYC
            (uint256 usdcOut,,) = usycTeller.sellPreview(usycBalance);
            currentUSYCValueInUSDC = usdcOut;
        }

        if (targetUSDCValue > currentUSYCValueInUSDC) {
            // Need to buy more USYC
            uint256 usdcToBuy = targetUSDCValue - currentUSYCValueInUSDC;

            // Ensure we have enough USDC available
            uint256 availableUSDC = IERC20(usdc).balanceOf(address(this));
            if (usdcToBuy > availableUSDC) {
                usdcToBuy = availableUSDC;
            }

            if (usdcToBuy > 0) {
                // Preview the buy to see how much USYC we'll get
                (uint256 usycOut,,) = usycTeller.buyPreview(usdcToBuy);

                if (usycOut > 0) {
                    // Execute the buy via delegatecall to self
                    buyUSYC(usdcToBuy);
                }
            }
        }
        // Note: We don't sell excess USYC here, only in rebalance function
    }

    /**
     * @notice  Handle de-hypothecation when USDC is needed
     * @param   _usdcNeeded  Amount of USDC needed
     */
    function handleDehypothecation(uint256 _usdcNeeded) external {
        if (usycBalance == 0) return;

        uint256 currentUSDC = IERC20(usdc).balanceOf(address(this));

        if (currentUSDC < _usdcNeeded) {
            uint256 shortfall = _usdcNeeded - currentUSDC;

            // We need to figure out how much USYC to sell to get the shortfall
            uint256 usycToSell = usycBalance; // Start with all our balance

            // Binary search or use preview to find right amount
            // For simplicity, try to sell enough to cover shortfall with buffer
            if (usycBalance > 0) {
                (uint256 maxUsdcOut,,) = usycTeller.sellPreview(usycBalance);

                if (maxUsdcOut >= shortfall) {
                    // We have enough USYC to cover the shortfall
                    // Estimate how much USYC we need to sell (with 1% buffer for fees)
                    usycToSell = (usycBalance * ((shortfall * 101) / 100)) / maxUsdcOut;

                    if (usycToSell > usycBalance) {
                        usycToSell = usycBalance;
                    }
                }

                // Execute via delegatecall to self
                sellUSYC(usycToSell);

                // Check if we still need more USDC
                currentUSDC = IERC20(usdc).balanceOf(address(this));
                if (currentUSDC < _usdcNeeded && usycQuantity > 0) {
                    // Sell all remaining USYC
                    sellUSYC(usycQuantity);
                }
            }
        }
    }

    /**
     * @notice  Manually rebalance rehypothecation to target ratio
     */
    function rebalanceRehypothecation() external {
        if (!rehypothecationEnabled) revert YoloHook__RehypothecationDisabled();

        // Calculate target USDC value to rehypothecate
        uint256 targetUSDCValue = (totalAnchorReserveUSDC * rehypothecationRatio) / PRECISION_DIVISOR;

        // Get current USYC value in USDC terms
        uint256 currentUSYCValueInUSDC = 0;
        if (usycBalance > 0) {
            (uint256 usdcOut,,) = usycTeller.sellPreview(usycBalance);
            currentUSYCValueInUSDC = usdcOut;
        }

        if (targetUSDCValue > currentUSYCValueInUSDC) {
            // Buy USYC
            uint256 usdcToBuy = targetUSDCValue - currentUSYCValueInUSDC;
            uint256 availableUSDC = IERC20(usdc).balanceOf(address(this));

            if (usdcToBuy > availableUSDC) {
                usdcToBuy = availableUSDC;
            }

            if (usdcToBuy > 0) {
                uint256 usycReceived = usycTeller.buy(usdcToBuy);
                // Update storage directly since we're already in the logic contract
                usycCostBasisUSDC += usdcToBuy;
                usycQuantity += usycReceived;
                usycBalance = usycQuantity;

                emit RehypothecationRebalanced(true, usdcToBuy, usycReceived);
            }
        } else if (targetUSDCValue < currentUSYCValueInUSDC) {
            // Sell USYC
            uint256 excessUSDCValue = currentUSYCValueInUSDC - targetUSDCValue;

            // Estimate how much USYC to sell
            uint256 usycToSell = (usycBalance * excessUSDCValue) / currentUSYCValueInUSDC;

            if (usycToSell > 0 && usycToSell <= usycBalance) {
                // Execute via delegatecall to self
                uint256 usdcReceived = sellUSYC(usycToSell);
                emit RehypothecationRebalanced(false, usycToSell, usdcReceived);
            }
        }
    }

    /**
     * @notice  Emergency withdrawal of all USYC
     */
    function emergencyWithdrawUSYC() external returns (uint256 usdcReceived, uint256 withdrawnAmount) {
        if (usycBalance == 0) return (0, 0);

        withdrawnAmount = usycBalance;
        usdcReceived = sellUSYC(usycBalance);

        // Ensure everything is cleared
        usycBalance = 0;
        usycQuantity = 0;
        usycCostBasisUSDC = 0;

        emit EmergencyUSYCWithdrawal(withdrawnAmount, usdcReceived);
        return (usdcReceived, withdrawnAmount);
    }
}
