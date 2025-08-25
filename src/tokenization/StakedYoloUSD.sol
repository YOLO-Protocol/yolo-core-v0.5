// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title StakedYoloUSD (sUSY)
 * @notice Receipt token representing LP shares in USDC/USY anchor pool
 * @dev Value accrues automatically via reserves growth from swap fees
 *      Simple 1:1 minting with liquidity, no complex yield distribution needed
 */
contract StakedYoloUSD is ERC20, ERC20Permit, Ownable {
    // ========================
    // STATE VARIABLES
    // ========================

    address public immutable yoloHook;

    // ========================
    // EVENTS
    // ========================

    event sUSYDeployed(address indexed yoloHook);

    // ========================
    // CONSTRUCTOR
    // ========================

    constructor(address _yoloHook)
        ERC20("Staked YOLO USD", "sUSY")
        ERC20Permit("Staked YOLO USD")
        Ownable(msg.sender)
    {
        yoloHook = _yoloHook;
        emit sUSYDeployed(_yoloHook);
    }

    // ========================
    // MODIFIERS
    // ========================

    modifier onlyYoloHook() {
        require(msg.sender == yoloHook, "Only YoloHook");
        _;
    }

    // ========================
    // MINTING & BURNING (ONLY YOLO HOOK)
    // ========================

    /**
     * @notice Mint sUSY tokens (only YoloHook can call)
     * @param to Recipient address
     * @param amount Amount to mint (equal to liquidity amount)
     */
    function mint(address to, uint256 amount) external onlyYoloHook {
        _mint(to, amount);
    }

    /**
     * @notice Burn sUSY tokens (only YoloHook can call)
     * @param from Address to burn from
     * @param amount Amount to burn (equal to liquidity amount)
     */
    function burn(address from, uint256 amount) external onlyYoloHook {
        _burn(from, amount);
    }

    // ========================
    // VIEW FUNCTIONS
    // ========================

    /**
     * @notice Get total anchor pool value backing sUSY tokens
     * @return totalValue USD value of USDC + USY reserves
     */
    function getTotalPoolValue() external view returns (uint256 totalValue) {
        return IYoloHook(yoloHook).getTotalAnchorPoolValue();
    }

    /**
     * @notice Get sUSY exchange rate (value per token)
     * @return exchangeRate USD value per sUSY token (18 decimals)
     */
    function getExchangeRate() external view returns (uint256 exchangeRate) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18; // 1:1 initially

        uint256 totalValue = this.getTotalPoolValue();
        return (totalValue * 1e18) / supply;
    }
}

// Interface for YoloHook integration
interface IYoloHook {
    function getTotalAnchorPoolValue() external view returns (uint256);
}
