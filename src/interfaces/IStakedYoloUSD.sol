// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title   IStakedYoloUSD
 * @notice  Interface for sUSY (Staked Yolo USD) receipt token
 */
interface IStakedYoloUSD {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}
