// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import {Bundler3} from "bundler3/src/Bundler3.sol";
import {GeneralAdapter1} from "bundler3/src/adapters/GeneralAdapter1.sol";
import {IMorpho} from "morpho-blue/src/interfaces/IMorpho.sol";

/**
 * @title BundlerSetup
 * @notice Utility functions for setting up Bundler3 and adapters in tests
 */
library BundlerSetup {
    struct BundlerContracts {
        Bundler3 bundler3;
        GeneralAdapter1 generalAdapter1;
    }

    /**
     * @notice Deploys Bundler3 and GeneralAdapter1
     * @param morpho The Morpho protocol address
     * @param wNative The wrapped native token address (use address(1) if not needed)
     * @return contracts The deployed BundlerContracts struct
     */
    function setupBundler(address morpho, address wNative) internal returns (BundlerContracts memory contracts) {
        contracts.bundler3 = new Bundler3();
        contracts.generalAdapter1 = new GeneralAdapter1(address(contracts.bundler3), morpho, wNative);
    }
}

