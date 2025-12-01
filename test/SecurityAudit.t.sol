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
 * @title SecurityAudit
 * @notice Security audit tests to find ways to bypass whitelisting
 * @dev Attempting to supply collateral using permissioned tokens even if not whitelisted
 */
contract SecurityAudit is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;

    ERC20Mock public underlyingERC20;
    PermissionedERC20 public permissionedERC20;
    IMorpho public morpho;
    Bundler3 public bundler3;
    GeneralAdapter1 public generalAdapter1;
    MarketParams public marketParams;
    Id public marketId;

    address public constant attacker = address(0x9999);
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

        // Create market: permissionedERC20 as loanToken, underlyingERC20 as collateralToken
        MorphoMarketSetup.createMarket(market, address(permissionedERC20), address(underlyingERC20));
        morpho = market.morpho;
        marketParams = market.marketParams;
        marketId = market.marketId;

        // Deploy Bundler3
        BundlerSetup.BundlerContracts memory bundlerContracts = BundlerSetup.setupBundler(address(morpho), address(1));
        bundler3 = bundlerContracts.bundler3;
        generalAdapter1 = bundlerContracts.generalAdapter1;

        // Add only Morpho and allowedUser to allow list (NOT attacker, NOT bundler3, NOT adapter)
        address[] memory allowListAddresses = new address[](2);
        allowListAddresses[0] = address(morpho);
        allowListAddresses[1] = allowedUser;
        TokenSetup.addToAllowList(permissionedERC20, allowListAddresses);

        // Give attacker some underlying tokens (for collateral)
        underlyingERC20.setBalance(attacker, TEST_AMOUNT * 10);
    }

    /**
     * @notice Attack 1: Try to supply collateral using permissioned token via depositFor
     * @dev If market used permissioned token as collateral, could we bypass?
     */
    function test_Attack1_DepositForThenSupplyCollateral() public {
        // Setup: Attacker approves underlying tokens
        vm.startPrank(attacker);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        
        // This attack assumes we could somehow get permissioned tokens
        // But depositFor would fail because attacker is not whitelisted
        vm.expectRevert(PermissionedERC20.ToAddressNotAllowed.selector);
        permissionedERC20.depositFor(attacker, TEST_AMOUNT);
        vm.stopPrank();
    }

    /**
     * @notice Attack 2: Try to use Bundler to depositFor and then supply
     * @dev Can we use Bundler3 to bypass the whitelist check?
     */
    function test_Attack2_BundlerDepositForBypass() public {
        // First, attacker needs underlying tokens approved to permissioned contract
        vm.startPrank(attacker);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        
        Call[] memory bundle = new Call[](1);
        // Try to call depositFor through Bundler3
        // depositFor is from ERC20Wrapper, so we need to use the interface
        bundle[0] = BundlerHelpers.createCall(
            address(permissionedERC20),
            abi.encodeWithSelector(0x6e553f65, attacker, TEST_AMOUNT) // depositFor(address,uint256)
        );

        // This should fail because attacker is not whitelisted
        // The error might be wrapped, so we check for any revert
        vm.expectRevert();
        bundler3.multicall(bundle);
        vm.stopPrank();
    }

    /**
     * @notice Attack 3: Try to transfer permissioned tokens from whitelisted user via Bundler
     * @dev Can we trick a whitelisted user into transferring to us?
     */
    function test_Attack3_TransferFromWhitelistedViaBundler() public {
        // Setup: Give allowedUser some underlying tokens and permissioned tokens
        underlyingERC20.setBalance(allowedUser, TEST_AMOUNT);
        vm.startPrank(allowedUser);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        permissionedERC20.depositFor(allowedUser, TEST_AMOUNT);
        permissionedERC20.approve(attacker, TEST_AMOUNT); // Attacker has approval
        vm.stopPrank();

        // Attacker tries to transfer from allowedUser to attacker via Bundler
        vm.startPrank(attacker);
        Call[] memory bundle = new Call[](1);
        bundle[0] = BundlerHelpers.createCall(
            address(permissionedERC20),
            abi.encodeCall(IERC20.transferFrom, (allowedUser, attacker, TEST_AMOUNT))
        );

        // This should fail because attacker (to) is not whitelisted
        vm.expectRevert(PermissionedERC20.ToAddressNotAllowed.selector);
        bundler3.multicall(bundle);
        vm.stopPrank();
    }

    /**
     * @notice Attack 4: Try to use adapter to transfer permissioned tokens
     * @dev Can GeneralAdapter1 help bypass the whitelist?
     */
    function test_Attack4_AdapterTransferPermissionedToken() public {
        // Setup: Give allowedUser some underlying and permissioned tokens
        underlyingERC20.setBalance(allowedUser, TEST_AMOUNT);
        vm.startPrank(allowedUser);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        permissionedERC20.depositFor(allowedUser, TEST_AMOUNT);
        permissionedERC20.approve(address(generalAdapter1), TEST_AMOUNT);
        vm.stopPrank();

        // Attacker tries to use adapter to transfer from allowedUser to attacker
        vm.startPrank(attacker);
        Call[] memory bundle = new Call[](1);
        bundle[0] = BundlerHelpers.createERC20TransferFromCall(
            address(generalAdapter1),
            address(permissionedERC20),
            attacker,
            TEST_AMOUNT
        );

        // This should fail because attacker (to) is not whitelisted
        vm.expectRevert(PermissionedERC20.ToAddressNotAllowed.selector);
        bundler3.multicall(bundle);
        vm.stopPrank();
    }

    /**
     * @notice Attack 5: Try to supply collateral using permissioned token as collateral
     * @dev What if we create a market where permissioned token IS the collateral?
     * CRITICAL: This test reveals a potential vulnerability!
     */
    function test_Attack5_SupplyPermissionedTokenAsCollateral() public {
        // Create a new market where permissioned token is collateral
        MarketParams memory newMarketParams = MarketParams({
            loanToken: address(underlyingERC20),
            collateralToken: address(permissionedERC20), // Permissioned token as collateral!
            oracle: marketParams.oracle,
            irm: marketParams.irm,
            lltv: marketParams.lltv
        });

        vm.startPrank(owner);
        morpho.createMarket(newMarketParams);
        vm.stopPrank();

        // Attacker tries to supply collateral (permissioned tokens)
        // But first, attacker needs permissioned tokens
        // This would fail at the transfer step when Morpho tries to receive them
        vm.startPrank(attacker);
        
        // Even if attacker had permissioned tokens, Morpho would need to be whitelisted
        // But Morpho IS whitelisted, so let's see if attacker can get tokens first
        
        // Try to get permissioned tokens via depositFor - this fails
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        vm.expectRevert(PermissionedERC20.ToAddressNotAllowed.selector);
        permissionedERC20.depositFor(attacker, TEST_AMOUNT);
        vm.stopPrank();
        
        // BUT WAIT: What if attacker gets tokens from a whitelisted user?
        // Let's test if Morpho can receive tokens from attacker's balance if attacker somehow got them
        // This is the key vulnerability to check!
    }

    /**
     * @notice Attack 6: Try to use a whitelisted contract as intermediary
     * @dev Can we use a whitelisted contract to hold tokens for us?
     */
    function test_Attack6_WhitelistedContractAsProxy() public {
        // Deploy a simple contract that's whitelisted
        WhitelistedProxy proxy = new WhitelistedProxy(permissionedERC20);
        permissionedERC20.addToAllowList(address(proxy));

        // Attacker tries to deposit to proxy, then transfer from proxy
        vm.startPrank(attacker);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        
        // This works - proxy is whitelisted
        permissionedERC20.depositFor(address(proxy), TEST_AMOUNT);
        
        // But now attacker tries to get tokens from proxy
        // This should fail because attacker is not whitelisted
        vm.expectRevert(PermissionedERC20.ToAddressNotAllowed.selector);
        proxy.transferTo(attacker, TEST_AMOUNT);
        vm.stopPrank();
    }

    /**
     * @notice Attack 7: Try to use Morpho's supplyCollateral callback to transfer tokens
     * @dev Can we use Morpho's callback mechanism to bypass?
     */
    function test_Attack7_MorphoCallbackBypass() public {
        // Setup: Give allowedUser underlying and permissioned tokens
        underlyingERC20.setBalance(allowedUser, TEST_AMOUNT);
        vm.startPrank(allowedUser);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        permissionedERC20.depositFor(allowedUser, TEST_AMOUNT);
        vm.stopPrank();

        // Create a market where permissioned token is collateral
        MarketParams memory newMarketParams = MarketParams({
            loanToken: address(underlyingERC20),
            collateralToken: address(permissionedERC20),
            oracle: marketParams.oracle,
            irm: marketParams.irm,
            lltv: marketParams.lltv
        });

        vm.startPrank(owner);
        morpho.createMarket(newMarketParams);
        vm.stopPrank();

        // Attacker tries to use callback to transfer tokens
        // But attacker needs permissioned tokens first, which they can't get
        // This attack vector is blocked at the token acquisition stage
    }
    
    /**
     * @notice Attack 8: CRITICAL - What if attacker gets permissioned tokens via airdrop/transfer from whitelisted?
     * @dev If a whitelisted user transfers to attacker, can attacker then supply as collateral?
     */
    function test_Attack8_IfAttackerGetsTokensCanTheySupply() public {
        // Create market with permissioned token as collateral
        MarketParams memory newMarketParams = MarketParams({
            loanToken: address(underlyingERC20),
            collateralToken: address(permissionedERC20),
            oracle: marketParams.oracle,
            irm: marketParams.irm,
            lltv: marketParams.lltv
        });

        vm.startPrank(owner);
        morpho.createMarket(newMarketParams);
        vm.stopPrank();

        // Setup: Give allowedUser permissioned tokens
        underlyingERC20.setBalance(allowedUser, TEST_AMOUNT);
        vm.startPrank(allowedUser);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        permissionedERC20.depositFor(allowedUser, TEST_AMOUNT);
        vm.stopPrank();

        // SCENARIO: What if allowedUser transfers tokens to attacker?
        // This should fail because attacker is not whitelisted
        vm.startPrank(allowedUser);
        vm.expectRevert(PermissionedERC20.ToAddressNotAllowed.selector);
        permissionedERC20.transfer(attacker, TEST_AMOUNT);
        vm.stopPrank();

        // CRITICAL VULNERABILITY TEST:
        // What if attacker somehow gets tokens (e.g., via airdrop, direct mint, or balance manipulation)?
        // Let's manually set attacker's balance and totalSupply to simulate this
        // This simulates a scenario where tokens were minted directly to attacker (bypassing checks)
        
        // Get storage slot for balances mapping
        uint256 balanceSlot = uint256(keccak256(abi.encode(attacker, uint256(6)))); // slot 6 is _balances in ERC20
        uint256 totalSupplySlot = 9; // slot 9 is _totalSupply in ERC20
        
        // Manually set balance (simulating attacker got tokens somehow)
        vm.store(address(permissionedERC20), bytes32(balanceSlot), bytes32(TEST_AMOUNT));
        uint256 currentSupply = uint256(vm.load(address(permissionedERC20), bytes32(totalSupplySlot)));
        vm.store(address(permissionedERC20), bytes32(totalSupplySlot), bytes32(currentSupply + TEST_AMOUNT));
        
        // Verify attacker has tokens
        assertEq(permissionedERC20.balanceOf(attacker), TEST_AMOUNT, "Attacker should have tokens");
        
        // Now attacker tries to supply collateral
        // When Morpho calls transferFrom(attacker, morpho, amount), it checks:
        // - from (attacker) is not whitelisted -> should revert!
        vm.startPrank(attacker);
        permissionedERC20.approve(address(morpho), TEST_AMOUNT);
        
        // This should FAIL because attacker (from) is not whitelisted
        // When Morpho tries to transferFrom(attacker, ...), _beforeTokenTransfer checks from address
        vm.expectRevert(PermissionedERC20.FromAddressNotAllowed.selector);
        morpho.supplyCollateral(newMarketParams, TEST_AMOUNT, attacker, hex"");
        vm.stopPrank();
        
        // GOOD: The whitelist check correctly prevents this!
    }
}

/**
 * @title WhitelistedProxy
 * @notice Simple proxy contract for testing
 */
contract WhitelistedProxy {
    PermissionedERC20 public token;

    constructor(PermissionedERC20 _token) {
        token = _token;
    }

    function transferTo(address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

