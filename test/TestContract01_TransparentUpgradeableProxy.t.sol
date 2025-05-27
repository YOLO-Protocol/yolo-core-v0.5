// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PublicTransparentUpgradeableProxy} from "@yolo/contracts/proxy/PublicTransparentUpgradeableProxy.sol";

/**
 * @dev     Mock contract to test the TransparentUpgradeableProxy contract, functions as
 *          the "original" implementation of a counter.
 */
contract CounterV1 {
    uint256 public count;

    function increment() public {
        count += 1;
    }

    function version() public pure returns (string memory) {
        return "v1";
    }
}

/**
 * @dev     Mock contract to test the TransparentUpgradeableProxy contract, functions as
 *          the "upgraded v2 version" implementation of a counter.
 */
contract CounterV2 {
    uint256 public count;

    function increment() public {
        count += 10;
    }

    function decrement() public {
        count -= 5;
    }

    function version() public pure returns (string memory) {
        return "v2";
    }
}

/**
 * @dev Mock contract without version function to test error handling
 */
contract CounterNoVersion {
    uint256 public count;

    function increment() public {
        count += 100;
    }
}

/**
 * @title   TestContract01_TransparentUpgradeableProxy
 * @author  0xyolodev.eth
 * @dev     This contract is used to test the TransparentUpgradeableProxy contract to
 *          ensure that it behaves as expected in a transparent upgradeable proxy pattern.
 */
contract TestContract01_TransparentUpgradeableProxy is Test {
    address public owner;
    address public nonOwner;

    PublicTransparentUpgradeableProxy public proxy;
    ProxyAdmin public proxyAdmin;

    CounterV1 public v1;
    CounterV2 public v2;
    CounterNoVersion public noVersion;

    function setUp() public {
        owner = address(this);
        nonOwner = address(0x1234);

        // Deploy implementation v1
        v1 = new CounterV1();
        v2 = new CounterV2();
        noVersion = new CounterNoVersion();

        // Encode initialization data (none in this case)
        bytes memory data;
        proxy = new PublicTransparentUpgradeableProxy(address(v1), owner, data);

        // Fetch ProxyAdmin
        proxyAdmin = ProxyAdmin(proxy.proxyAdmin());

        console.log("Implementation Address:", proxy.implementation());
        emit log_named_address("Proxy Admin Address", address(proxyAdmin));
    }

    /**
     * @dev     Make sure proxy is initialized and delegates calls to the initial implementation,
     *          which is CounterV1, and store the sate successfully.
     */
    function test_Contract01_Case01_initialLogicWorks() public {
        CounterV1 proxyAsV1 = CounterV1(address(proxy));
        assertEq(proxyAsV1.count(), 0);
        proxyAsV1.increment();
        assertEq(proxyAsV1.count(), 1);
        assertEq(proxyAsV1.version(), "v1");
    }

    /**
     * @dev Test that public getter functions work correctly
     */
    function test_Contract01_Case02_publicGettersWork() public view {
        assertEq(proxy.implementation(), address(v1));
        assertEq(proxy.proxyAdmin(), address(proxyAdmin));
        assertEq(proxy.version(), "v1");
    }

    /**
     * @dev Test upgrading the proxy to v2 implementation
     */
    function test_Contract01_Case03_upgradeToV2() public {
        // Initial state with v1
        CounterV1 proxyAsV1 = CounterV1(address(proxy));
        proxyAsV1.increment();
        assertEq(proxyAsV1.count(), 1);

        // Upgrade to v2
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(v2), "");

        // Verify upgrade
        assertEq(proxy.implementation(), address(v2));
        assertEq(proxy.version(), "v2");

        // Test v2 functionality
        CounterV2 proxyAsV2 = CounterV2(address(proxy));
        assertEq(proxyAsV2.count(), 1); // State should persist
        proxyAsV2.increment(); // Should add 10 in v2
        assertEq(proxyAsV2.count(), 11);

        // Test new function in v2
        proxyAsV2.decrement(); // Should subtract 5
        assertEq(proxyAsV2.count(), 6);
    }

    /**
     * @dev Test that only the admin can upgrade the proxy
     */
    function test_Contract01_Case04_onlyAdminCanUpgrade() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(v2), "");

        // Verify implementation hasn't changed
        assertEq(proxy.implementation(), address(v1));
    }

    /**
     * @dev Test proxy admin transfer functionality
     */
    function test_Contract01_Case05_adminTransfer() public {
        assertEq(proxy.proxyAdmin(), address(proxyAdmin));

        // Transfer ownership of ProxyAdmin
        proxyAdmin.transferOwnership(nonOwner);

        // Old owner should no longer be able to upgrade
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(v2), "");

        // New owner should be able to upgrade
        vm.prank(nonOwner);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(v2), "");

        assertEq(proxy.implementation(), address(v2));
    }

    /**
     * @dev Test proxy with initialization data
     */
    function test_Contract01_Case06_proxyWithInitData() public {
        // Create a new proxy with initialization data
        bytes memory initData = abi.encodeWithSelector(CounterV1.increment.selector);
        PublicTransparentUpgradeableProxy newProxy = new PublicTransparentUpgradeableProxy(address(v1), owner, initData);

        CounterV1 newProxyAsV1 = CounterV1(address(newProxy));
        assertEq(newProxyAsV1.count(), 1); // Should be 1 due to initialization
    }

    /**
     * @dev Test behavior when implementation doesn't have version function
     */
    function test_Contract01_Case07_noVersionFunction() public {
        // Upgrade to implementation without version function
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(noVersion), "");

        // version() call should revert
        vm.expectRevert();
        proxy.version();

        // But other functionality should work
        CounterNoVersion proxyAsNoVersion = CounterNoVersion(address(proxy));
        proxyAsNoVersion.increment();
        assertEq(proxyAsNoVersion.count(), 100);
    }

    /**
     * @dev Test that direct calls to implementation work correctly
     */
    function test_Contract01_Case08_directImplementationCalls() public {
        // Direct call to v1 should work independently
        v1.increment();
        assertEq(v1.count(), 1);

        // Proxy should have separate state
        CounterV1 proxyAsV1 = CounterV1(address(proxy));
        assertEq(proxyAsV1.count(), 0);
        proxyAsV1.increment();
        assertEq(proxyAsV1.count(), 1);

        // v1 direct state should be unchanged by proxy calls
        assertEq(v1.count(), 1);
    }

    /**
     * @dev Test proxy behavior with zero address scenarios
     */
    function test_Contract01_Case09_invalidUpgrade() public {
        // Try to upgrade to zero address - should revert
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(0), "");
    }

    /**
     * @dev Test state persistence across multiple upgrades
     */
    function test_Contract01_Case10_multipleUpgrades() public {
        CounterV1 proxyAsV1 = CounterV1(address(proxy));

        // Set initial state
        proxyAsV1.increment();
        proxyAsV1.increment();
        assertEq(proxyAsV1.count(), 2);

        // Upgrade to v2
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(v2), "");
        CounterV2 proxyAsV2 = CounterV2(address(proxy));
        assertEq(proxyAsV2.count(), 2); // State persists

        // Modify state with v2
        proxyAsV2.increment(); // +10
        assertEq(proxyAsV2.count(), 12);

        // Upgrade back to v1
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(v1), "");
        proxyAsV1 = CounterV1(address(proxy));
        assertEq(proxyAsV1.count(), 12); // State still persists

        // v1 increment behavior should work
        proxyAsV1.increment(); // +1
        assertEq(proxyAsV1.count(), 13);
    }

    /**
     * @dev Test function selector collision protection
     */
    function test_Contract01_Case11_transparentProxyBehavior() public {
        // Admin should not be able to call implementation functions
        // This tests the transparent proxy pattern

        // From admin (owner), calls should go to proxy admin functions
        assertEq(proxy.implementation(), address(v1));
        assertEq(proxy.proxyAdmin(), address(proxyAdmin));

        // From non-admin, calls should go to implementation
        vm.prank(nonOwner);
        CounterV1 proxyAsV1 = CounterV1(address(proxy));
        proxyAsV1.increment();

        vm.prank(nonOwner);
        assertEq(proxyAsV1.count(), 1);
    }

    /**
     * @dev Test proxy with complex initialization data
     */
    function test_Contract01_Case12_complexInitialization() public {
        // Create initialization data that calls increment multiple times
        bytes memory initData = abi.encodeWithSelector(CounterV1.increment.selector);

        PublicTransparentUpgradeableProxy complexProxy =
            new PublicTransparentUpgradeableProxy(address(v1), owner, initData);

        CounterV1 complexProxyAsV1 = CounterV1(address(complexProxy));
        assertEq(complexProxyAsV1.count(), 1);
        assertEq(complexProxy.version(), "v1");
    }

    /**
     * @dev Make sure admin cannot call implementation functions directly
     */
    function test_Contract01_Case13_adminBlockedFromImplementation() public {
        vm.prank(address(proxyAdmin));
        vm.expectRevert(); // should fail due to TransparentProxy restriction
        CounterV1(address(proxy)).increment();
    }
}
