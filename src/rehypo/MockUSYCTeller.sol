// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title   MockUSYC
 * @notice  Simple mock USYC token for testing
 */
contract MockUSYC is ERC20, Ownable {
    constructor() ERC20("Mock USYC", "mUSYC") Ownable(msg.sender) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
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
    uint256 public price = 109163886; // Current USYC price (starts at ~1.09 USDC)
    uint256 public lastUpdateTime;
    uint256 public constant ANNUAL_YIELD = 500; // 5% annual yield in basis points

    event Bought(
        address indexed from, address indexed recipient, uint256 amount, uint256 paid, uint256 price, uint256 fee
    );
    event Sold(
        address indexed from, address indexed recipient, uint256 amount, uint256 received, uint256 price, uint256 fee
    );

    constructor(address _stable) {
        stable = IERC20(_stable);
        usyc = new MockUSYC();
        lastUpdateTime = block.timestamp;
    }

    function buy(uint256 amount) external returns (uint256) {
        return buyFor(amount, msg.sender);
    }

    function buyFor(uint256 amount, address recipient) public returns (uint256 payout) {
        uint256 fee = (amount * buyFee) / 1e18;
        uint256 netAmount = amount - fee;

        // Update price first
        updatePrice();

        // Calculate USYC amount based on current price
        // price is in 8 decimals (e.g., 109163886 = 1.09163886)
        // netAmount is in USDC decimals (6 or 18)
        // We need to return USYC in 18 decimals
        uint8 usdcDecimals = IERC20Metadata(address(stable)).decimals();
        if (usdcDecimals == 6) {
            // Convert: USDC(6) -> USYC(18) using price(8)
            payout = (netAmount * 1e20) / price; // 6 + 20 - 8 = 18
        } else {
            // Convert: USDC(18) -> USYC(18) using price(8)
            payout = (netAmount * 1e8) / price; // 18 + 8 - 8 = 18
        }

        stable.safeTransferFrom(msg.sender, address(this), amount);
        usyc.mint(recipient, payout);

        emit Bought(msg.sender, recipient, payout, amount, price, fee);
    }

    function sell(uint256 amount) external returns (uint256) {
        return sellFor(amount, msg.sender);
    }

    function sellFor(uint256 amount, address recipient) public returns (uint256 payout) {
        // Update price first
        updatePrice();

        // Calculate USDC amount based on current price
        // amount is USYC in 18 decimals
        // price is in 8 decimals (e.g., 109163886 = 1.09163886)
        // We need to return USDC in its native decimals
        uint8 usdcDecimals = IERC20Metadata(address(stable)).decimals();
        if (usdcDecimals == 6) {
            // Convert: USYC(18) -> USDC(6) using price(8)
            payout = (amount * price) / 1e20; // 18 + 8 - 20 = 6
        } else {
            // Convert: USYC(18) -> USDC(18) using price(8)
            payout = (amount * price) / 1e8; // 18 + 8 - 8 = 18
        }

        uint256 fee = (payout * sellFee) / 1e18;
        payout = payout - fee;

        usyc.burn(msg.sender, amount);
        stable.safeTransfer(recipient, payout);

        emit Sold(msg.sender, recipient, amount, payout, price, fee);
    }

    function buyPreview(uint256 amount) external view returns (uint256 payout, uint256 fee, int256 priceOut) {
        fee = (amount * buyFee) / 1e18;
        uint256 netAmount = amount - fee;

        // Get current price with yield accrual
        uint256 currentPrice = price;
        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        if (timeElapsed > 0) {
            uint256 yieldRate = (ANNUAL_YIELD * timeElapsed) / (365 days * 10000);
            currentPrice = currentPrice + (currentPrice * yieldRate / 1e8);
        }

        // Calculate payout
        uint8 usdcDecimals = IERC20Metadata(address(stable)).decimals();
        if (usdcDecimals == 6) {
            payout = (netAmount * 1e20) / currentPrice;
        } else {
            payout = (netAmount * 1e8) / currentPrice;
        }

        priceOut = int256(currentPrice);
    }

    function sellPreview(uint256 amount) external view returns (uint256 payout, uint256 fee, int256 priceOut) {
        // Get current price with yield accrual
        uint256 currentPrice = price;
        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        if (timeElapsed > 0) {
            uint256 yieldRate = (ANNUAL_YIELD * timeElapsed) / (365 days * 10000);
            currentPrice = currentPrice + (currentPrice * yieldRate / 1e8);
        }

        // Calculate payout
        uint8 usdcDecimals = IERC20Metadata(address(stable)).decimals();
        if (usdcDecimals == 6) {
            payout = (amount * currentPrice) / 1e20;
        } else {
            payout = (amount * currentPrice) / 1e8;
        }

        fee = (payout * sellFee) / 1e18;
        payout = payout - fee;
        priceOut = int256(currentPrice);
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

    // Update price based on elapsed time and yield
    function updatePrice() public {
        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        if (timeElapsed > 0) {
            // Compound the price: price = price * (1 + yield * time / year)
            uint256 yieldRate = (ANNUAL_YIELD * timeElapsed) / (365 days * 10000);
            price = price + (price * yieldRate / 1e8); // Divide by 1e8 since price is in 8 decimals
            lastUpdateTime = block.timestamp;
        }
    }

    // Force price update (for testing)
    function forceUpdatePrice() external {
        updatePrice();
    }
}
