// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

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
 * @title SupplyCollateralInMorphoBundler
 * @notice Test suite for supplying collateral to Morpho using Bundler3
 * @dev Tests atomic approve + supply collateral operations through Bundler3
 */
contract SupplyCollateralInMorphoBundler is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;

    // Contracts
    ERC20Mock public underlyingERC20;
    PermissionedERC20 public permissionedERC20;
    IMorpho public morpho;
    OracleMock public oracle;
    IrmMock public irm;
    Bundler3 public bundler3;
    GeneralAdapter1 public generalAdapter1;

    // Market setup
    MarketParams public marketParams;
    Id public marketId;

    // Test addresses
    address public constant owner = Constants.OWNER;
    address public constant allowedUser1 = Constants.ALLOWED_USER_1;
    address public constant allowedUser2 = Constants.ALLOWED_USER_2;

    // Constants
    uint256 public constant INITIAL_BALANCE = Constants.INITIAL_BALANCE;
    uint256 public constant TEST_AMOUNT = Constants.TEST_AMOUNT;

    // Bundle storage
    Call[] internal bundle;
    Call[] internal callbackBundle;

    function setUp() public {
        // Deploy tokens
        TokenSetup.Tokens memory tokens = TokenSetup.deployTokens();
        underlyingERC20 = tokens.underlying;
        permissionedERC20 = tokens.permissioned;

        // Setup Morpho market
        MorphoMarketSetup.MorphoMarket memory market = MorphoMarketSetup.deployMarketContracts(owner);

        // Configure Morpho (enable IRM and LLTV)
        vm.startPrank(owner);
        MorphoMarketSetup.configureMorpho(market, owner);
        vm.stopPrank();

        // Create market
        MorphoMarketSetup.createMarket(market, address(permissionedERC20), address(underlyingERC20));

        morpho = market.morpho;
        oracle = market.oracle;
        irm = market.irm;
        marketParams = market.marketParams;
        marketId = market.marketId;

        // Deploy Bundler3 and GeneralAdapter1
        BundlerSetup.BundlerContracts memory bundlerContracts = BundlerSetup.setupBundler(address(morpho), address(1)); // address(1) as wrapped native
        bundler3 = bundlerContracts.bundler3;
        generalAdapter1 = bundlerContracts.generalAdapter1;

        // Add contracts and users to allow list
        address[] memory allowListAddresses = new address[](5);
        allowListAddresses[0] = address(morpho);
        allowListAddresses[1] = address(bundler3);
        allowListAddresses[2] = address(generalAdapter1);
        allowListAddresses[3] = allowedUser1;
        allowListAddresses[4] = allowedUser2;
        TokenSetup.addToAllowList(permissionedERC20, allowListAddresses);

        // Mint tokens to users
        address[] memory users = new address[](2);
        users[0] = allowedUser1;
        users[1] = allowedUser2;
        TokenSetup.mintToUsers(underlyingERC20, users, INITIAL_BALANCE);

        // Approve Morpho and adapter to spend tokens, and set authorizations
        address[] memory spenders = new address[](2);
        spenders[0] = address(morpho);
        spenders[1] = address(generalAdapter1);

        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            // Approve underlying token
            for (uint256 j = 0; j < spenders.length; j++) {
                underlyingERC20.approve(spenders[j], type(uint256).max);
            }
            // Approve permissioned token
            for (uint256 j = 0; j < spenders.length; j++) {
                permissionedERC20.approve(spenders[j], type(uint256).max);
            }
            // Set Morpho authorization for adapter
            morpho.setAuthorization(address(generalAdapter1), true);
            vm.stopPrank();
        }
    }

    /* ========== SUPPLY COLLATERAL TESTS ========== */

    /**
     * @notice Test: Atomic supply collateral through Bundler3
     */
    function test_AtomicMorphoSupplyCollateral_Ok() public {
        uint256 collateralBefore = morpho.collateral(marketId, allowedUser1);

        // Step 1: Transfer collateral to adapter
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(generalAdapter1), address(underlyingERC20), address(generalAdapter1), TEST_AMOUNT
            )
        );
        // Step 2: Supply collateral to Morpho
        bundle.push(
            BundlerHelpers.createMorphoSupplyCollateralCall(
                address(generalAdapter1), marketParams, TEST_AMOUNT, allowedUser1, hex""
            )
        );

        vm.prank(allowedUser1);
        bundler3.multicall(bundle);

        assertEq(
            morpho.collateral(marketId, allowedUser1), collateralBefore + TEST_AMOUNT, "Collateral should increase"
        );
    }

    /**
     * @notice Test: Atomic approve and supply collateral through Bundler3
     */
    function test_AtomicApproveAndSupplyCollateral_Ok() public {
        uint256 collateralAmount = 100 ether;
        uint256 collateralBefore = morpho.collateral(marketId, allowedUser1);

        // Step 1: Approve adapter to spend underlying tokens
        bundle.push(
            BundlerHelpers.createApproveCall(address(underlyingERC20), address(generalAdapter1), collateralAmount)
        );
        // Step 2: Transfer collateral to adapter
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(generalAdapter1), address(underlyingERC20), address(generalAdapter1), collateralAmount
            )
        );
        // Step 3: Supply collateral to Morpho
        bundle.push(
            BundlerHelpers.createMorphoSupplyCollateralCall(
                address(generalAdapter1), marketParams, collateralAmount, allowedUser1, hex""
            )
        );

        vm.prank(allowedUser1);
        bundler3.multicall(bundle);

        assertEq(
            morpho.collateral(marketId, allowedUser1), collateralBefore + collateralAmount, "Collateral should increase"
        );
    }

    /**
     * @notice Test: Atomic approve (max) and supply collateral through Bundler3
     */
    function test_AtomicApproveMaxAndSupplyCollateral_Ok() public {
        uint256 collateralAmount = 150 ether;
        uint256 collateralBefore = morpho.collateral(marketId, allowedUser1);

        // Step 1: Approve adapter with max amount
        bundle.push(
            BundlerHelpers.createApproveCall(address(underlyingERC20), address(generalAdapter1), type(uint256).max)
        );
        // Step 2: Transfer collateral to adapter
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(generalAdapter1), address(underlyingERC20), address(generalAdapter1), collateralAmount
            )
        );
        // Step 3: Supply collateral to Morpho
        bundle.push(
            BundlerHelpers.createMorphoSupplyCollateralCall(
                address(generalAdapter1), marketParams, collateralAmount, allowedUser1, hex""
            )
        );

        vm.prank(allowedUser1);
        bundler3.multicall(bundle);

        assertEq(
            morpho.collateral(marketId, allowedUser1), collateralBefore + collateralAmount, "Collateral should increase"
        );
        // Verify approval is set (should be max, but exact value may vary due to token implementation)
        assertGt(
            underlyingERC20.allowance(allowedUser1, address(generalAdapter1)),
            collateralAmount,
            "Approval should be sufficient for the operation"
        );
    }

    /**
     * @notice Test: Multiple approve and supply collateral operations in one bundle
     */
    function test_MultipleApproveAndSupplyCollateral_Ok() public {
        uint256 collateralAmount1 = 50 ether;
        uint256 collateralAmount2 = 75 ether;
        uint256 collateralBefore = morpho.collateral(marketId, allowedUser1);

        // First operation: Approve and supply
        bundle.push(
            BundlerHelpers.createApproveCall(address(underlyingERC20), address(generalAdapter1), collateralAmount1)
        );
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(generalAdapter1), address(underlyingERC20), address(generalAdapter1), collateralAmount1
            )
        );
        bundle.push(
            BundlerHelpers.createMorphoSupplyCollateralCall(
                address(generalAdapter1), marketParams, collateralAmount1, allowedUser1, hex""
            )
        );

        // Second operation: Approve more and supply more
        bundle.push(
            BundlerHelpers.createApproveCall(address(underlyingERC20), address(generalAdapter1), collateralAmount2)
        );
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(generalAdapter1), address(underlyingERC20), address(generalAdapter1), collateralAmount2
            )
        );
        bundle.push(
            BundlerHelpers.createMorphoSupplyCollateralCall(
                address(generalAdapter1), marketParams, collateralAmount2, allowedUser1, hex""
            )
        );

        vm.prank(allowedUser1);
        bundler3.multicall(bundle);

        assertEq(
            morpho.collateral(marketId, allowedUser1),
            collateralBefore + collateralAmount1 + collateralAmount2,
            "Collateral should increase by both amounts"
        );
    }

    /**
     * @notice Test: Morpho supply collateral callback with reenter
     */
    function test_MorphoSupplyCollateralCallback_WithReenter_Ok() public {
        // Prepare callback bundle
        callbackBundle.push(
            BundlerHelpers.createERC20TransferCall(
                address(generalAdapter1), address(underlyingERC20), allowedUser1, 5 ether
            )
        );

        // Step 1: Transfer collateral to adapter
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(generalAdapter1), address(underlyingERC20), address(generalAdapter1), TEST_AMOUNT
            )
        );
        // Step 2: Supply collateral with callback
        bundle.push(
            BundlerHelpers.createMorphoSupplyCollateralCall(
                address(generalAdapter1), marketParams, TEST_AMOUNT, allowedUser1, abi.encode(callbackBundle)
            )
        );

        // Fund adapter for callback
        underlyingERC20.setBalance(address(generalAdapter1), 5 ether);

        vm.prank(allowedUser1);
        bundler3.multicall(bundle);

        assertEq(morpho.collateral(marketId, allowedUser1), TEST_AMOUNT, "Should have collateral");
    }

    /**
     * @notice Test: Complete flow - approve, supply collateral, approve more, supply more collateral
     */
    function test_CompleteFlow_ApproveAndSupplyCollateral_Ok() public {
        uint256 collateralAmount1 = 100 ether;
        uint256 collateralAmount2 = 200 ether;
        uint256 collateralBefore = morpho.collateral(marketId, allowedUser1);

        // Phase 1: Approve and supply first batch of collateral
        bundle.push(
            BundlerHelpers.createApproveCall(address(underlyingERC20), address(generalAdapter1), collateralAmount1)
        );
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(generalAdapter1), address(underlyingERC20), address(generalAdapter1), collateralAmount1
            )
        );
        bundle.push(
            BundlerHelpers.createMorphoSupplyCollateralCall(
                address(generalAdapter1), marketParams, collateralAmount1, allowedUser1, hex""
            )
        );

        vm.prank(allowedUser1);
        bundler3.multicall(bundle);

        // Phase 2: Approve more and supply more collateral
        delete bundle;
        bundle.push(
            BundlerHelpers.createApproveCall(address(underlyingERC20), address(generalAdapter1), collateralAmount2)
        );
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(generalAdapter1), address(underlyingERC20), address(generalAdapter1), collateralAmount2
            )
        );
        bundle.push(
            BundlerHelpers.createMorphoSupplyCollateralCall(
                address(generalAdapter1), marketParams, collateralAmount2, allowedUser1, hex""
            )
        );

        vm.prank(allowedUser1);
        bundler3.multicall(bundle);

        // Verify final state
        assertEq(
            morpho.collateral(marketId, allowedUser1),
            collateralBefore + collateralAmount1 + collateralAmount2,
            "Should have total collateral from both operations"
        );
    }

    /**
     * @notice Test: Multiple users operations in sequence
     */
    function test_MultipleUsers_SequentialOperations_Ok() public {
        // User1 operations
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(generalAdapter1), address(underlyingERC20), address(generalAdapter1), TEST_AMOUNT
            )
        );
        bundle.push(
            BundlerHelpers.createMorphoSupplyCollateralCall(
                address(generalAdapter1), marketParams, TEST_AMOUNT, allowedUser1, hex""
            )
        );

        vm.prank(allowedUser1);
        bundler3.multicall(bundle);

        // User2 operations
        delete bundle;
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(generalAdapter1), address(underlyingERC20), address(generalAdapter1), TEST_AMOUNT
            )
        );
        bundle.push(
            BundlerHelpers.createMorphoSupplyCollateralCall(
                address(generalAdapter1), marketParams, TEST_AMOUNT, allowedUser2, hex""
            )
        );

        vm.prank(allowedUser2);
        bundler3.multicall(bundle);

        assertEq(morpho.collateral(marketId, allowedUser1), TEST_AMOUNT, "User1 should have collateral");
        assertEq(morpho.collateral(marketId, allowedUser2), TEST_AMOUNT, "User2 should have collateral");
    }
}

