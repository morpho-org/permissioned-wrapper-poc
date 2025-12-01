// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "morpho-blue/src/mocks/ERC20Mock.sol";
import {PermissionedERC20} from "../src/PermissionedERC20.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/src/interfaces/IMorpho.sol";
import {OracleMock} from "morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "morpho-blue/src/mocks/IrmMock.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {Bundler3, Call} from "bundler3/src/Bundler3.sol";
import {GeneralAdapter1} from "bundler3/src/adapters/GeneralAdapter1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Constants} from "./utils/Constants.sol";
import {MorphoMarketSetup} from "./utils/MorphoMarketSetup.sol";
import {TokenSetup} from "./utils/TokenSetup.sol";
import {BundlerSetup} from "./utils/BundlerSetup.sol";
import {BundlerHelpers} from "./utils/BundlerHelpers.sol";

/**
 * @title WhitelistRequirementTest
 * @notice Test to determine if both Bundler3 and GeneralAdapter1 need to be whitelisted
 */
contract WhitelistRequirementTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;

    ERC20Mock public underlyingERC20;
    PermissionedERC20 public permissionedERC20;
    IMorpho public morpho;
    Bundler3 public bundler3;
    GeneralAdapter1 public generalAdapter1;
    MarketParams public marketParams;
    Id public marketId;

    address public constant allowedUser = Constants.ALLOWED_USER_1;
    address public constant owner = Constants.OWNER;
    uint256 public constant TEST_AMOUNT = Constants.TEST_AMOUNT;

    function setUp() public {
        // Deploy tokens
        TokenSetup.Tokens memory tokens = TokenSetup.deployTokens();
        underlyingERC20 = tokens.underlying;
        permissionedERC20 = tokens.permissioned;

        // Setup Morpho market
        MorphoMarketSetup.MorphoMarket memory market = MorphoMarketSetup.deployMarketContracts(owner);
        vm.startPrank(owner);
        MorphoMarketSetup.configureMorpho(market, owner);
        vm.stopPrank();

        // Create market with permissioned token as collateral to test whitelist requirements
        MorphoMarketSetup.createMarket(market, address(underlyingERC20), address(permissionedERC20));
        morpho = market.morpho;
        marketParams = market.marketParams;
        marketId = market.marketId;

        // Deploy Bundler3
        BundlerSetup.BundlerContracts memory bundlerContracts = BundlerSetup.setupBundler(address(morpho), address(1));
        bundler3 = bundlerContracts.bundler3;
        generalAdapter1 = bundlerContracts.generalAdapter1;

        // Setup user
        underlyingERC20.setBalance(allowedUser, TEST_AMOUNT * 10);
        vm.startPrank(allowedUser);
        underlyingERC20.approve(address(permissionedERC20), type(uint256).max);
        underlyingERC20.approve(address(generalAdapter1), type(uint256).max);
        permissionedERC20.approve(address(generalAdapter1), type(uint256).max);
        morpho.setAuthorization(address(generalAdapter1), true);
        vm.stopPrank();
    }

    /**
     * @notice Test 1: Only Morpho whitelisted - should this work?
     */
    function test_OnlyMorphoWhitelisted() public {
        // Only whitelist Morpho
        permissionedERC20.addToAllowList(address(morpho));
        permissionedERC20.addToAllowList(allowedUser);

        // User deposits to get permissioned tokens
        vm.startPrank(allowedUser);
        permissionedERC20.depositFor(allowedUser, TEST_AMOUNT);
        vm.stopPrank();

        // Try to supply collateral through Bundler
        Call[] memory bundle = new Call[](2);
        bundle[0] = BundlerHelpers.createERC20TransferFromCall(
            address(generalAdapter1),
            address(permissionedERC20),
            address(generalAdapter1),
            TEST_AMOUNT
        );
        bundle[1] = BundlerHelpers.createMorphoSupplyCollateralCall(
            address(generalAdapter1),
            marketParams,
            TEST_AMOUNT,
            allowedUser,
            hex""
        );

        vm.startPrank(allowedUser);
        // This should fail if GeneralAdapter1 needs to be whitelisted
        // When GeneralAdapter1 transfers tokens to itself, it's the 'from' address
        vm.expectRevert(PermissionedERC20.FromAddressNotAllowed.selector);
        bundler3.multicall(bundle);
        vm.stopPrank();
    }

    /**
     * @notice Test 2: Only GeneralAdapter1 whitelisted (not Bundler3)
     */
    function test_OnlyAdapterWhitelisted() public {
        // Whitelist Morpho and GeneralAdapter1, but NOT Bundler3
        permissionedERC20.addToAllowList(address(morpho));
        permissionedERC20.addToAllowList(allowedUser);
        permissionedERC20.addToAllowList(address(generalAdapter1));

        // User deposits to get permissioned tokens
        vm.startPrank(allowedUser);
        permissionedERC20.depositFor(allowedUser, TEST_AMOUNT);
        vm.stopPrank();

        // Try to supply collateral through Bundler
        Call[] memory bundle = new Call[](2);
        bundle[0] = BundlerHelpers.createERC20TransferFromCall(
            address(generalAdapter1),
            address(permissionedERC20),
            address(generalAdapter1),
            TEST_AMOUNT
        );
        bundle[1] = BundlerHelpers.createMorphoSupplyCollateralCall(
            address(generalAdapter1),
            marketParams,
            TEST_AMOUNT,
            allowedUser,
            hex""
        );

        vm.startPrank(allowedUser);
        // This should work if only GeneralAdapter1 needs to be whitelisted
        bundler3.multicall(bundle);
        vm.stopPrank();

        // Verify collateral was supplied
        assertGt(morpho.collateral(marketId, allowedUser), 0, "Collateral should be supplied");
    }

    /**
     * @notice Test 3: Only Bundler3 whitelisted (not GeneralAdapter1)
     */
    function test_OnlyBundlerWhitelisted() public {
        // Whitelist Morpho and Bundler3, but NOT GeneralAdapter1
        permissionedERC20.addToAllowList(address(morpho));
        permissionedERC20.addToAllowList(allowedUser);
        permissionedERC20.addToAllowList(address(bundler3));

        // User deposits to get permissioned tokens
        vm.startPrank(allowedUser);
        permissionedERC20.depositFor(allowedUser, TEST_AMOUNT);
        vm.stopPrank();

        // Try to supply collateral through Bundler
        Call[] memory bundle = new Call[](2);
        bundle[0] = BundlerHelpers.createERC20TransferFromCall(
            address(generalAdapter1),
            address(permissionedERC20),
            address(generalAdapter1),
            TEST_AMOUNT
        );
        bundle[1] = BundlerHelpers.createMorphoSupplyCollateralCall(
            address(generalAdapter1),
            marketParams,
            TEST_AMOUNT,
            allowedUser,
            hex""
        );

        vm.startPrank(allowedUser);
        // This should fail if GeneralAdapter1 needs to be whitelisted
        // When GeneralAdapter1 calls transferFrom, it's the 'from' address
        vm.expectRevert(PermissionedERC20.FromAddressNotAllowed.selector);
        bundler3.multicall(bundle);
        vm.stopPrank();
    }

    /**
     * @notice Test 4: Both Bundler3 and GeneralAdapter1 whitelisted
     */
    function test_BothWhitelisted() public {
        // Whitelist Morpho, Bundler3, and GeneralAdapter1
        permissionedERC20.addToAllowList(address(morpho));
        permissionedERC20.addToAllowList(allowedUser);
        permissionedERC20.addToAllowList(address(bundler3));
        permissionedERC20.addToAllowList(address(generalAdapter1));

        // User deposits to get permissioned tokens
        vm.startPrank(allowedUser);
        permissionedERC20.depositFor(allowedUser, TEST_AMOUNT);
        vm.stopPrank();

        // Try to supply collateral through Bundler
        Call[] memory bundle = new Call[](2);
        bundle[0] = BundlerHelpers.createERC20TransferFromCall(
            address(generalAdapter1),
            address(permissionedERC20),
            address(generalAdapter1),
            TEST_AMOUNT
        );
        bundle[1] = BundlerHelpers.createMorphoSupplyCollateralCall(
            address(generalAdapter1),
            marketParams,
            TEST_AMOUNT,
            allowedUser,
            hex""
        );

        vm.startPrank(allowedUser);
        // This should work
        bundler3.multicall(bundle);
        vm.stopPrank();

        // Verify collateral was supplied
        assertGt(morpho.collateral(marketId, allowedUser), 0, "Collateral should be supplied");
    }

    /**
     * @notice Test 5: Check who is the actual 'from' address in token transfers
     * @dev This test helps understand the flow
     */
    function test_WhoIsTheFromAddress() public {
        // Whitelist everything to see the flow
        permissionedERC20.addToAllowList(address(morpho));
        permissionedERC20.addToAllowList(allowedUser);
        permissionedERC20.addToAllowList(address(bundler3));
        permissionedERC20.addToAllowList(address(generalAdapter1));

        // User deposits to get permissioned tokens
        vm.startPrank(allowedUser);
        permissionedERC20.depositFor(allowedUser, TEST_AMOUNT);
        vm.stopPrank();

        // Check balances before
        uint256 adapterBalanceBefore = permissionedERC20.balanceOf(address(generalAdapter1));
        uint256 userBalanceBefore = permissionedERC20.balanceOf(allowedUser);

        // Try to supply collateral through Bundler
        Call[] memory bundle = new Call[](2);
        bundle[0] = BundlerHelpers.createERC20TransferFromCall(
            address(generalAdapter1),
            address(permissionedERC20),
            address(generalAdapter1),
            TEST_AMOUNT
        );
        bundle[1] = BundlerHelpers.createMorphoSupplyCollateralCall(
            address(generalAdapter1),
            marketParams,
            TEST_AMOUNT,
            allowedUser,
            hex""
        );

        vm.startPrank(allowedUser);
        bundler3.multicall(bundle);
        vm.stopPrank();

        // Check balances after
        uint256 adapterBalanceAfter = permissionedERC20.balanceOf(address(generalAdapter1));
        uint256 userBalanceAfter = permissionedERC20.balanceOf(allowedUser);

        // The transferFrom call moves tokens from allowedUser to generalAdapter1
        // So 'from' = allowedUser (whitelisted), 'to' = generalAdapter1 (needs to be whitelisted)
        assertEq(userBalanceAfter, userBalanceBefore - TEST_AMOUNT, "User balance should decrease");
        assertEq(adapterBalanceAfter, adapterBalanceBefore + TEST_AMOUNT, "Adapter balance should increase");
    }
}

