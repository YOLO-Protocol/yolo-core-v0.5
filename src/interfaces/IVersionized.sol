//SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IVersionized {
    function version() external view returns (string memory);
}
