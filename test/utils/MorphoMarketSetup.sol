// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/src/interfaces/IMorpho.sol";
import {Morpho} from "morpho-blue/src/Morpho.sol";
import {OracleMock} from "morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "morpho-blue/src/mocks/IrmMock.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
import {Constants} from "./Constants.sol";

/**
 * @title MorphoMarketSetup
 * @notice Utility functions for setting up Morpho markets in tests
 */
library MorphoMarketSetup {
    using MarketParamsLib for MarketParams;

    struct MorphoMarket {
        IMorpho morpho;
        OracleMock oracle;
        IrmMock irm;
        MarketParams marketParams;
        Id marketId;
    }

    /**
     * @notice Deploys Morpho, Oracle, and IRM contracts
     * @param owner The owner address for the Morpho contract
     * @return market Partially configured MorphoMarket struct (needs setupMarketConfig to complete)
     */
    function deployMarketContracts(address owner) internal returns (MorphoMarket memory market) {
        // Deploy Morpho
        market.morpho = IMorpho(address(new Morpho(owner)));

        // Deploy Oracle and IRM mocks
        market.oracle = new OracleMock();
        market.oracle.setPrice(Constants.ORACLE_PRICE_SCALE); // 1:1 price ratio

        market.irm = new IrmMock();
    }

    /**
     * @notice Configures Morpho (enable IRM and LLTV)
     * @param market The MorphoMarket struct with deployed contracts
     * @dev The caller must be pranked as the owner before calling this function
     */
    function configureMorpho(
        MorphoMarket memory market,
        address /* owner */
    )
        internal
    {
        market.morpho.enableIrm(address(0));
        market.morpho.enableIrm(address(market.irm));
        market.morpho.enableLltv(0);
        market.morpho.enableLltv(Constants.LLTV);
    }

    /**
     * @notice Creates the market with given tokens
     * @param market The MorphoMarket struct with configured contracts
     * @param loanToken The loan token address
     * @param collateralToken The collateral token address
     */
    function createMarket(MorphoMarket memory market, address loanToken, address collateralToken) internal {
        // Create market params
        market.marketParams = MarketParams({
            loanToken: loanToken,
            collateralToken: collateralToken,
            oracle: address(market.oracle),
            irm: address(market.irm),
            lltv: Constants.LLTV
        });

        // Create market
        market.morpho.createMarket(market.marketParams);
        market.marketId = market.marketParams.id();
    }
}

