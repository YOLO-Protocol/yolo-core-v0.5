// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Base02_DeployMockAssetsAndOracles} from "./Base02_DeployMockAssetsAndOracles.t.sol";
import {Config02_AssetAndCollateralInitialization} from "../config/Config02_AssetAndCollateralInitialization.sol";
import {MockPriceOracle} from "@yolo/contracts/mocks/MockPriceOracle.sol";

/**
 * @title   Base03_DeployYoloAssetSettingsAndCollaterals
 * @author  0xyolodev.eth
 * @dev     This contracts does all the things in Base02 and setup Yolo Asset and
 *          supported colleterals environment
 */
contract Base03_DeployYoloAssetSettingsAndCollaterals is
    Base02_DeployMockAssetsAndOracles,
    Config02_AssetAndCollateralInitialization
{
    function setUp() public virtual override(Base02_DeployMockAssetsAndOracles) {
        // 1. Call Base02 to setup environment
        Base02_DeployMockAssetsAndOracles.setUp();

        // 2. Deploy Yolo Assets' oracles from Config03
        for (uint256 i = 0; i < yoloAssetsArray.length; i++) {
            // 2A. Deploy MockOracles
            MockOracleConfig memory oracleConfig = yoloAssetsArray[i].oracleConfig;
            MockPriceOracle oracle = new MockPriceOracle(oracleConfig.initialPrice, oracleConfig.description);
            yoloAssetsArray[i].oracle = address(oracle);
        }
    }
}
