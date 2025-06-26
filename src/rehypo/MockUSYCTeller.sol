// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title   MockUSYCTeller
 * @author  0xyolodev.eth
 * @notice  This mock contract simulates how the USYC Teller worrks, allowing users to buy an sell USYC tokens.
 * @dev     Based on USYC documentation: https://usyc.docs.hashnote.com/
 * @dev     Actual contract: https://etherscan.io/address/0x5c73e1cfdd85b7f1d608f7f7736fc8c653513b7a#code
 *
 */
contract MockUSYCTeller {
    using SafeERC20 for IERC20;

    IERC20 public immutable stable;
    IERC20 public immutable ytoken;

    uint256 public buyFee = 0.001e18; // 0.1%
    uint256 public sellFee = 0.001e18; // 0.1%
    uint256 public constant PRICE = 109163886; // Use Fixed Price for Demo Purpose

    event Bought(
        address indexed from, address indexed recipient, uint256 amount, uint256 paid, uint256 price, uint256 fee
    );
    event Sold(
        address indexed from, address indexed recipient, uint256 amount, uint256 received, uint256 price, uint256 fee
    );

    constructor(address _stable, address _ytoken) {
        stable = IERC20(_stable);
        ytoken = IERC20(_ytoken);
    }

    function buy(uint256 amount) external returns (uint256) {
        return buyFor(amount, msg.sender);
    }

    function buyFor(uint256 amount, address recipient) public returns (uint256 payout) {
        uint256 fee = (amount * buyFee) / 1e18;
        uint256 netAmount = amount - fee;

        // Simple 1:1 conversion for mock
        payout = netAmount;

        stable.safeTransferFrom(msg.sender, address(this), amount);
        ytoken.transfer(recipient, payout);

        emit Bought(msg.sender, recipient, payout, amount, PRICE, fee);
    }

    function sell(uint256 amount) external returns (uint256) {
        return sellFor(amount, msg.sender);
    }

    function sellFor(uint256 amount, address recipient) public returns (uint256 payout) {
        // Simple 1:1 conversion for mock
        payout = amount;
        uint256 fee = (payout * sellFee) / 1e18;
        payout = payout - fee;

        ytoken.transferFrom(msg.sender, address(this), amount);
        stable.safeTransfer(recipient, payout);

        emit Sold(msg.sender, recipient, amount, payout, PRICE, fee);
    }

    function buyPreview(uint256 amount) external view returns (uint256 payout, uint256 fee, int256 price) {
        fee = (amount * buyFee) / 1e18;
        payout = amount - fee;
        price = int256(PRICE);
    }

    function sellPreview(uint256 amount) external view returns (uint256 payout, uint256 fee, int256 price) {
        payout = amount;
        fee = (payout * sellFee) / 1e18;
        payout = payout - fee;
        price = int256(PRICE);
    }

    // Simplified admin functions
    function setFees(uint256 _buyFee, uint256 _sellFee) external {
        buyFee = _buyFee;
        sellFee = _sellFee;
    }

    // Add initial liquidity for testing
    function addLiquidity(uint256 stableAmount, uint256 ytokenAmount) external {
        stable.safeTransferFrom(msg.sender, address(this), stableAmount);
        ytoken.transferFrom(msg.sender, address(this), ytokenAmount);
    }
}
