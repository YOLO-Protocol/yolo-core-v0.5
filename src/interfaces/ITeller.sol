// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title   ITeller
 * @notice  Interface for USYC Teller contract integration
 * @dev     Based on USYC documentation: https://usyc.docs.hashnote.com/
 */
interface ITeller {
    /**
     * @notice Buy USYC tokens with USDC
     * @param _amount Amount of USDC to spend
     * @return Amount of USYC tokens received
     */
    function buy(uint256 _amount) external returns (uint256);

    /**
     * @notice Sell USYC tokens for USDC
     * @param _amount Amount of USYC tokens to sell
     * @return Amount of USDC received
     */
    function sell(uint256 _amount) external returns (uint256);

    /**
     * @notice Preview the output of a USYC token purchase
     * @param _amount Amount of USDC to spend
     * @return payout Amount of USYC to be received
     * @return fee Fee deducted from the purchase
     * @return price Price used for the conversion
     */
    function buyPreview(uint256 _amount) external view returns (uint256 payout, uint256 fee, int256 price);

    /**
     * @notice Preview the output of a USYC token sale
     * @param _amount Amount of USYC to sell
     * @return payout Amount of USDC to be received
     * @return fee Fee deducted from the sale
     * @return price Price used for the conversion
     */
    function sellPreview(uint256 _amount) external view returns (uint256 payout, uint256 fee, int256 price);
}
