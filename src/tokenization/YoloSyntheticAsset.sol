// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title   YoloSyntheticAsset
 * @author  0xyolodev.eth
 * @notice  YoloAsset is a synthetic asset managed by the YoloProtocolHook.
 *          Only the owner (YoloProtocolHook) can mint and burn tokens, under circumstances
 *          of borrowing, redemption, flash loaning, swapping on UniswapV4, and cross-chaining.
 */
contract YoloSyntheticAsset is ERC20, Ownable {
    uint8 private _customDecimals;

    /**
     * @dev     Constructor to initialize the YoloAsset with a name, symbol, and decimals.
     * @param   _name        The name of the token.
     * @param   _symbol      The symbol of the token.
     * @param   _decimals    The number of decimals for the token.
     */
    constructor(string memory _name, string memory _symbol, uint8 _decimals)
        ERC20(_name, _symbol)
        Ownable(msg.sender)
    {
        _customDecimals = _decimals;
    }

    /**
     * @dev Override the decimals function to return the custom value.
     */
    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    /**
     * @dev     Mints `amount` tokens to the specified `account`.
     *          Only the owner (YoloProtocolHook) can call this function.
     * @param   _account The address to mint the tokens to.
     * @param   _amount  The number of tokens to mint.
     */
    function mint(address _account, uint256 _amount) external onlyOwner {
        _mint(_account, _amount);
    }

    /**
     * @dev     Burns `amount` tokens from the specified `account`.
     *          Only the owner (YoloProtocolHook) can call this function.
     * @param   _account The address to burn the tokens from.
     * @param   _amount  The number of tokens to burn.
     */
    function burn(address _account, uint256 _amount) external onlyOwner {
        _burn(_account, _amount);
    }
}
