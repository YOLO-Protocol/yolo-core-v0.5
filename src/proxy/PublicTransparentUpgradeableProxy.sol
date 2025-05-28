// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IVersionized} from "@yolo/contracts/interfaces/Iversionized.sol";

/**
 * @title   PublicTransparentUpgradeableProxy
 * @author  0xyolodev.eth
 * @dev     Extends OpenZeppelin's TransparentUpgradeableProxy to allow public reading of
 *          the implementation address, admin address and the implementation version.
 */
contract PublicTransparentUpgradeableProxy is TransparentUpgradeableProxy {
    /**
     * @dev     Constructor that initializes the proxy with the implementation address, admin address, and initialization data.
     * @param   _logic                      The address of the initial implementation contract.
     * @param   _initialProxyAdminOwner     The address of the initial proxy admin owner. This address will be the owner of the ProxyAdmin contract.
     * @param   _data                       Initialization data to be passed to the implementation contract.
     */
    constructor(address _logic, address _initialProxyAdminOwner, bytes memory _data)
        TransparentUpgradeableProxy(_logic, _initialProxyAdminOwner, _data)
    {}

    function implementation() public view returns (address) {
        return _implementation();
    }

    function proxyAdmin() public view returns (address) {
        return _proxyAdmin();
    }

    function version() public view returns (string memory) {
        return IVersionized(_implementation()).version();
    }
}
