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
import {ERC20WrapperAdapter} from "bundler3/src/adapters/ERC20WrapperAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Constants} from "./utils/Constants.sol";
import {MorphoMarketSetup} from "./utils/MorphoMarketSetup.sol";
import {TokenSetup} from "./utils/TokenSetup.sol";
import {BundlerSetup} from "./utils/BundlerSetup.sol";
import {BundlerHelpers} from "./utils/BundlerHelpers.sol";

/**
 * @title SupplyCollateralInMorphoBundler
 * @notice Test suite for wrapping tokens using Bundler3 with ERC20WrapperAdapter
 * @dev Tests wrapping operations through Bundler3 using only ERC20WrapperAdapter
 * @dev Note: Supply collateral operations should be done directly (not through Bundler3) after wrapping
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
    ERC20WrapperAdapter public erc20WrapperAdapter;

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

        // Create market with permissioned token as collateral
        address loanToken = makeAddr("LoanToken");
        MorphoMarketSetup.createMarket(market, loanToken, address(permissionedERC20));

        morpho = market.morpho;
        oracle = market.oracle;
        irm = market.irm;
        marketParams = market.marketParams;
        marketId = market.marketId;

        // Deploy Bundler3 and ERC20WrapperAdapter
        BundlerSetup.BundlerContracts memory bundlerContracts = BundlerSetup.setupBundler();
        bundler3 = bundlerContracts.bundler3;
        erc20WrapperAdapter = bundlerContracts.erc20WrapperAdapter;

        // Add contracts and users to allow list
        // NOTE: Morpho and ERC20WrapperAdapter need to be whitelisted
        // - Morpho receives permissioned tokens as collateral
        // - ERC20WrapperAdapter handles wrapping operations with permissioned tokens
        // Bundler3 is NOT whitelisted because it never directly interacts with tokens
        address[] memory allowListAddresses = new address[](3);
        allowListAddresses[0] = address(morpho);
        allowListAddresses[1] = address(erc20WrapperAdapter);
        allowListAddresses[2] = allowedUser1;
        // Note: allowedUser2 will be added separately if needed
        TokenSetup.addToAllowList(permissionedERC20, allowListAddresses);
        permissionedERC20.addToAllowList(allowedUser2);

        // Mint underlying tokens to users and wrap them to get permissioned tokens
        address[] memory users = new address[](2);
        users[0] = allowedUser1;
        users[1] = allowedUser2;
        TokenSetup.mintToUsers(underlyingERC20, users, INITIAL_BALANCE);

        // Users wrap underlying tokens to get permissioned tokens
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            underlyingERC20.approve(address(permissionedERC20), INITIAL_BALANCE);
            permissionedERC20.depositFor(users[i], INITIAL_BALANCE);
            // Approve Morpho and ERC20WrapperAdapter to spend permissioned tokens
            permissionedERC20.approve(address(morpho), type(uint256).max);
            permissionedERC20.approve(address(erc20WrapperAdapter), type(uint256).max);
            vm.stopPrank();
        }
    }

    /* ========== WRAPPING TESTS ========== */

    /**
     * @notice Test: Wrap tokens and supply collateral to Morpho - all atomically through Bundler3
     * @dev This is the main use case: wrap underlying tokens and supply as collateral in one atomic transaction
     * @dev Flow: 1) Transfer underlying to adapter, 2) Wrap (tokens go to initiator), 3) Transfer wrapped tokens
     * @dev from initiator to adapter, 4) Use adapter to transfer to Bundler3, 5) Approve Morpho, 6) Call supplyCollateral
     * @dev Note: Morpho pulls from msg.sender (Bundler3), so we use adapter to transfer tokens to Bundler3
     */
    function test_WrapTokensAndSupplyCollateral_Atomic_Ok() public {
        // Whitelist Bundler3 for this atomic operation (needed because Morpho pulls from msg.sender)
        permissionedERC20.addToAllowList(address(bundler3));

        // First, ensure user has underlying tokens and approves Bundler3 for transferFrom
        underlyingERC20.setBalance(allowedUser1, TEST_AMOUNT);
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(bundler3), TEST_AMOUNT);
        permissionedERC20.approve(address(bundler3), TEST_AMOUNT); // Approve for transfer to adapter
        permissionedERC20.approve(address(morpho), TEST_AMOUNT); // Approve for Morpho to pull from Bundler3
        vm.stopPrank();

        uint256 collateralBefore = morpho.collateral(marketId, allowedUser1);
        uint256 wrappedBalanceBefore = permissionedERC20.balanceOf(allowedUser1);

        // Step 1: Transfer underlying tokens from user to ERC20WrapperAdapter
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(underlyingERC20), allowedUser1, address(erc20WrapperAdapter), TEST_AMOUNT
            )
        );
        // Step 2: Wrap underlying tokens to permissioned tokens (sent to initiator)
        bundle.push(
            BundlerHelpers.createERC20WrapperDepositForCall(
                address(erc20WrapperAdapter), address(permissionedERC20), TEST_AMOUNT
            )
        );
        // Step 3: Transfer permissioned tokens from initiator to ERC20WrapperAdapter (through adapter)
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(permissionedERC20), allowedUser1, address(erc20WrapperAdapter), TEST_AMOUNT
            )
        );
        // Step 4: Use adapter to transfer permissioned tokens from adapter to Bundler3
        bundle.push(
            BundlerHelpers.createERC20TransferCall(
                address(erc20WrapperAdapter), address(permissionedERC20), address(bundler3), TEST_AMOUNT
            )
        );
        // Step 5: Approve Morpho to spend permissioned tokens from Bundler3
        bundle.push(BundlerHelpers.createApproveCall(address(permissionedERC20), address(morpho), TEST_AMOUNT));
        // Step 6: Supply collateral to Morpho (Morpho will pull from Bundler3, which now has tokens via adapter)
        bundle.push(
            BundlerHelpers.createMorphoSupplyCollateralCall(
                address(morpho), marketParams, TEST_AMOUNT, allowedUser1, hex""
            )
        );

        vm.prank(allowedUser1);
        bundler3.multicall(bundle);

        // Verify wrapped tokens were received and then supplied
        assertEq(
            permissionedERC20.balanceOf(allowedUser1),
            wrappedBalanceBefore,
            "Permissioned tokens should be supplied to Morpho"
        );
        assertEq(
            morpho.collateral(marketId, allowedUser1), collateralBefore + TEST_AMOUNT, "Collateral should increase"
        );
    }

    /**
     * @notice Test: Use ERC20WrapperAdapter to wrap tokens
     */
    function test_UseERC20WrapperAdapter_WrapTokens_Ok() public {
        // First, ensure user has underlying tokens and approves Bundler3 for transferFrom
        underlyingERC20.setBalance(allowedUser1, TEST_AMOUNT);
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(bundler3), TEST_AMOUNT);
        vm.stopPrank();

        // Step 1: Transfer underlying tokens from user to ERC20WrapperAdapter (direct call to token)
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(underlyingERC20), allowedUser1, address(erc20WrapperAdapter), TEST_AMOUNT
            )
        );
        // Step 2: Wrap underlying tokens to permissioned tokens (sent to initiator)
        bundle.push(
            BundlerHelpers.createERC20WrapperDepositForCall(
                address(erc20WrapperAdapter), address(permissionedERC20), TEST_AMOUNT
            )
        );

        uint256 wrappedBalanceBefore = permissionedERC20.balanceOf(allowedUser1);

        vm.prank(allowedUser1);
        bundler3.multicall(bundle);

        // Verify wrapped tokens were sent to initiator
        assertEq(
            permissionedERC20.balanceOf(allowedUser1),
            wrappedBalanceBefore + TEST_AMOUNT,
            "Initiator should receive wrapped tokens"
        );
    }

    /**
     * @notice Test: Wrap tokens and then supply collateral directly (not through Bundler3)
     * @dev This demonstrates the complete flow: wrap through Bundler3, then supply directly to Morpho
     */
    function test_WrapTokensThenSupplyCollateralDirectly_Ok() public {
        // First, ensure user has underlying tokens and approves Bundler3 for transferFrom
        underlyingERC20.setBalance(allowedUser1, TEST_AMOUNT);
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(bundler3), TEST_AMOUNT);
        vm.stopPrank();

        uint256 collateralBefore = morpho.collateral(marketId, allowedUser1);
        uint256 wrappedBalanceBefore = permissionedERC20.balanceOf(allowedUser1);

        // Step 1: Wrap tokens through Bundler3
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(underlyingERC20), allowedUser1, address(erc20WrapperAdapter), TEST_AMOUNT
            )
        );
        bundle.push(
            BundlerHelpers.createERC20WrapperDepositForCall(
                address(erc20WrapperAdapter), address(permissionedERC20), TEST_AMOUNT
            )
        );

        vm.prank(allowedUser1);
        bundler3.multicall(bundle);

        // Verify wrapped tokens were received
        assertEq(
            permissionedERC20.balanceOf(allowedUser1),
            wrappedBalanceBefore + TEST_AMOUNT,
            "Initiator should receive wrapped tokens"
        );

        // Step 2: Supply collateral directly to Morpho (not through Bundler3)
        vm.prank(allowedUser1);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, allowedUser1, hex"");

        // Verify collateral was supplied
        assertEq(
            morpho.collateral(marketId, allowedUser1), collateralBefore + TEST_AMOUNT, "Collateral should increase"
        );
        assertEq(
            permissionedERC20.balanceOf(allowedUser1),
            wrappedBalanceBefore,
            "Permissioned tokens should be supplied to Morpho"
        );
    }

    /**
     * @notice Test: Multiple wrapping operations
     */
    function test_MultipleWrappingOperations_Ok() public {
        uint256 amount1 = 50 ether;
        uint256 amount2 = 75 ether;

        // Ensure user has underlying tokens and approves Bundler3 for transferFrom
        underlyingERC20.setBalance(allowedUser1, amount1 + amount2);
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(bundler3), amount1 + amount2);
        vm.stopPrank();

        uint256 wrappedBalanceBefore = permissionedERC20.balanceOf(allowedUser1);

        // First wrapping operation
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(underlyingERC20), allowedUser1, address(erc20WrapperAdapter), amount1
            )
        );
        bundle.push(
            BundlerHelpers.createERC20WrapperDepositForCall(
                address(erc20WrapperAdapter), address(permissionedERC20), amount1
            )
        );

        // Second wrapping operation
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(underlyingERC20), allowedUser1, address(erc20WrapperAdapter), amount2
            )
        );
        bundle.push(
            BundlerHelpers.createERC20WrapperDepositForCall(
                address(erc20WrapperAdapter), address(permissionedERC20), amount2
            )
        );

        vm.prank(allowedUser1);
        bundler3.multicall(bundle);

        // Verify total wrapped tokens
        assertEq(
            permissionedERC20.balanceOf(allowedUser1),
            wrappedBalanceBefore + amount1 + amount2,
            "Should have wrapped both amounts"
        );
    }

    /**
     * @notice Test: Verify that Bundler3 does NOT need to be whitelisted
     * @dev This test demonstrates that only ERC20WrapperAdapter needs whitelisting, not Bundler3
     */
    function test_Bundler3NotWhitelisted_StillWorks() public {
        // Ensure user has underlying tokens and approves Bundler3 for transferFrom
        underlyingERC20.setBalance(allowedUser1, TEST_AMOUNT);
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(bundler3), TEST_AMOUNT);
        vm.stopPrank();

        // Verify Bundler3 is NOT whitelisted
        assertFalse(permissionedERC20.isAllowed(address(bundler3)), "Bundler3 should NOT be whitelisted");

        // Verify ERC20WrapperAdapter IS whitelisted (for wrapping operations)
        assertTrue(
            permissionedERC20.isAllowed(address(erc20WrapperAdapter)), "ERC20WrapperAdapter should be whitelisted"
        );

        // Wrapping should still work using direct calls (requires approving Bundler3)
        bundle.push(
            BundlerHelpers.createERC20TransferFromCall(
                address(underlyingERC20), allowedUser1, address(erc20WrapperAdapter), TEST_AMOUNT
            )
        );
        bundle.push(
            BundlerHelpers.createERC20WrapperDepositForCall(
                address(erc20WrapperAdapter), address(permissionedERC20), TEST_AMOUNT
            )
        );

        uint256 wrappedBalanceBefore = permissionedERC20.balanceOf(allowedUser1);

        vm.prank(allowedUser1);
        bundler3.multicall(bundle);

        assertEq(
            permissionedERC20.balanceOf(allowedUser1),
            wrappedBalanceBefore + TEST_AMOUNT,
            "Wrapping should work even without Bundler3 whitelisted"
        );
    }
}
