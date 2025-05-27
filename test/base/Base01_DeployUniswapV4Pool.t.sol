// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/**
 * @title   Base01_DeployUniswapV4Pool
 * @author  0xyolodev.eth
 * @dev     This contract is a base test contract for deploying Uniswap V4 pools, and also
 *          ensures that it is functioning correctly by includes basic swap tests for two
 *          currencies.
 */
contract Base01_DeployUniswapV4Pool is Test, Deployers {
    PoolKey internal mockPoolKey; // Pull key to keep tract of the mock pool
    PoolId internal mockPoolId; // Pool ID to keep track of the mock pool

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Initialize the pool with a fee of 3000 and a starting price
        (mockPoolKey, mockPoolId) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        emit log_named_address("Deployed Pool Manager", address(manager));
        emit log_named_address("Currency 0", Currency.unwrap(currency0));
        emit log_named_address("Currency 1", Currency.unwrap(currency1));
    }

    function test_Base01_Case01_SwapCurrency0ToCurrency1() public {
        int256 amountIn = 1000 * 1e18;
        bytes memory hookData = bytes("");

        BalanceDelta delta = swap(mockPoolKey, true, amountIn, hookData);

        emit log_named_int("Currency0 Change", delta.amount0());
        emit log_named_int("Currency1 Change", delta.amount1());

        assert(delta.amount0() < 0);
        assert(delta.amount1() > 0);
    }

    function test_Base02_Case02_SwapCurrency1ToCurrency0() public {
        int256 amountIn = 1000 * 1e18;
        bytes memory hookData = bytes("");

        BalanceDelta delta = swap(mockPoolKey, false, amountIn, hookData);

        emit log_named_int("Currency0 Change", delta.amount0());
        emit log_named_int("Currency1 Change", delta.amount1());

        assert(delta.amount1() < 0);
        assert(delta.amount0() > 0);
    }
}
