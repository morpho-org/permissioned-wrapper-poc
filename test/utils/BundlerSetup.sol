// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import {Bundler3} from "bundler3/src/Bundler3.sol";
import {ERC20WrapperAdapter} from "bundler3/src/adapters/ERC20WrapperAdapter.sol";

/**
 * @title BundlerSetup
 * @notice Utility functions for setting up Bundler3 and adapters in tests
 */
library BundlerSetup {
    struct BundlerContracts {
        Bundler3 bundler3;
        ERC20WrapperAdapter erc20WrapperAdapter;
    }

    /**
     * @notice Deploys Bundler3 and ERC20WrapperAdapter
     * @return contracts The deployed BundlerContracts struct
     */
    function setupBundler() internal returns (BundlerContracts memory contracts) {
        contracts.bundler3 = new Bundler3();
        contracts.erc20WrapperAdapter = new ERC20WrapperAdapter(address(contracts.bundler3));
    }
}
