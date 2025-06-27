// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title   MockUSYC
 * @notice  Mock USYC token that accumulates value over time like sDAI
 */
contract MockUSYC is ERC20, Ownable {
    uint256 public lastUpdateTime;
    uint256 public exchangeRate; // USYC to USDC exchange rate (scaled by 1e18)
    uint256 public constant ANNUAL_YIELD = 500; // 5% annual yield in basis points

    constructor() ERC20("Mock USYC", "mUSYC") Ownable(msg.sender) {
        lastUpdateTime = block.timestamp;
        exchangeRate = 1e18; // Start at 1:1
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    function updateExchangeRate() public {
        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        if (timeElapsed > 0) {
            // Compound the exchange rate: rate = rate * (1 + yield * time / year)
            uint256 yieldRate = (ANNUAL_YIELD * timeElapsed * 1e18) / (365 days * 10000);
            exchangeRate = exchangeRate + (exchangeRate * yieldRate / 1e18);
            lastUpdateTime = block.timestamp;
        }
    }

    function getExchangeRate() external view returns (uint256) {
        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        if (timeElapsed == 0) return exchangeRate;

        uint256 yieldRate = (ANNUAL_YIELD * timeElapsed * 1e18) / (365 days * 10000);
        return exchangeRate + (exchangeRate * yieldRate / 1e18);
    }
}

/**
 * @title   MockUSYCTeller
 * @author  0xyolodev.eth
 * @notice  This mock contract simulates how the USYC Teller works, with an internal USYC token that mints/burns
 * @dev     Based on USYC documentation: https://usyc.docs.hashnote.com/
 * @dev     Actual contract: https://etherscan.io/address/0x5c73e1cfdd85b7f1d608f7f7736fc8c653513b7a#code
 *
 */
contract MockUSYCTeller {
    using SafeERC20 for IERC20;

    IERC20 public immutable stable;
    MockUSYC public immutable usyc;

    uint256 public buyFee = 0.001e18; // 0.1%
    uint256 public sellFee = 0.001e18; // 0.1%
    uint256 public constant PRICE = 109163886; // Use Fixed Price for Demo Purpose

    event Bought(
        address indexed from, address indexed recipient, uint256 amount, uint256 paid, uint256 price, uint256 fee
    );
    event Sold(
        address indexed from, address indexed recipient, uint256 amount, uint256 received, uint256 price, uint256 fee
    );

    constructor(address _stable) {
        stable = IERC20(_stable);
        usyc = new MockUSYC();
    }

    function buy(uint256 amount) external returns (uint256) {
        return buyFor(amount, msg.sender);
    }

    function buyFor(uint256 amount, address recipient) public returns (uint256 payout) {
        uint256 fee = (amount * buyFee) / 1e18;
        uint256 netAmount = amount - fee;

        // Update exchange rate first
        usyc.updateExchangeRate();

        // Calculate USYC amount based on current exchange rate
        uint256 exchangeRate = usyc.getExchangeRate();
        payout = (netAmount * 1e18) / exchangeRate;

        stable.safeTransferFrom(msg.sender, address(this), amount);
        usyc.mint(recipient, payout);

        emit Bought(msg.sender, recipient, payout, amount, PRICE, fee);
    }

    function sell(uint256 amount) external returns (uint256) {
        return sellFor(amount, msg.sender);
    }

    function sellFor(uint256 amount, address recipient) public returns (uint256 payout) {
        // Update exchange rate first
        usyc.updateExchangeRate();

        // Calculate USDC amount based on current exchange rate
        uint256 exchangeRate = usyc.getExchangeRate();
        payout = (amount * exchangeRate) / 1e18;
        uint256 fee = (payout * sellFee) / 1e18;
        payout = payout - fee;

        usyc.burn(msg.sender, amount);
        stable.safeTransfer(recipient, payout);

        emit Sold(msg.sender, recipient, amount, payout, PRICE, fee);
    }

    function buyPreview(uint256 amount) external view returns (uint256 payout, uint256 fee, int256 price) {
        fee = (amount * buyFee) / 1e18;
        uint256 netAmount = amount - fee;
        uint256 exchangeRate = usyc.getExchangeRate();
        payout = (netAmount * 1e18) / exchangeRate;
        price = int256(PRICE);
    }

    function sellPreview(uint256 amount) external view returns (uint256 payout, uint256 fee, int256 price) {
        uint256 exchangeRate = usyc.getExchangeRate();
        payout = (amount * exchangeRate) / 1e18;
        fee = (payout * sellFee) / 1e18;
        payout = payout - fee;
        price = int256(PRICE);
    }

    // Simplified admin functions
    function setFees(uint256 _buyFee, uint256 _sellFee) external {
        buyFee = _buyFee;
        sellFee = _sellFee;
    }

    // Add initial USDC liquidity for testing
    function addLiquidity(uint256 stableAmount) external {
        stable.safeTransferFrom(msg.sender, address(this), stableAmount);
    }

    // Get the USYC token address for external reference
    function getUSYCToken() external view returns (address) {
        return address(usyc);
    }

    // Force exchange rate update (for testing)
    function forceUpdateExchangeRate() external {
        usyc.updateExchangeRate();
    }
}
