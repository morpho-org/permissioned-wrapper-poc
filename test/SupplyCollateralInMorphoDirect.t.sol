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
import {Constants} from "./utils/Constants.sol";
import {MorphoMarketSetup} from "./utils/MorphoMarketSetup.sol";
import {TokenSetup} from "./utils/TokenSetup.sol";

contract SupplyCollateralInMorphoDirect is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;

    ERC20Mock public underlyingERC20;
    PermissionedERC20 public permissionedERC20;
    IMorpho public morpho;
    OracleMock public oracle;
    IrmMock public irm;
    MarketParams public marketParams;
    Id public marketId;

    address public constant allowedUser1 = Constants.ALLOWED_USER_1;
    address public constant allowedUser2 = Constants.ALLOWED_USER_2;
    address public constant notAllowedUser1 = Constants.NOT_ALLOWED_USER_1;
    address public constant owner = Constants.OWNER;

    uint256 public constant INITIAL_BALANCE = Constants.INITIAL_BALANCE;
    uint256 public constant TEST_AMOUNT = Constants.TEST_AMOUNT;

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

        // Add contracts and users to allow list
        // NOTE: Morpho needs to be whitelisted because it receives permissioned tokens as collateral
        address[] memory allowListAddresses = new address[](3);
        allowListAddresses[0] = address(morpho);
        allowListAddresses[1] = allowedUser1;
        allowListAddresses[2] = allowedUser2;
        TokenSetup.addToAllowList(permissionedERC20, allowListAddresses);

        // Mint underlying tokens to users and wrap them to get permissioned tokens
        address[] memory users = new address[](2);
        users[0] = allowedUser1;
        users[1] = allowedUser2;
        TokenSetup.mintToUsers(underlyingERC20, users, INITIAL_BALANCE);

        // Only whitelisted users can wrap tokens
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            underlyingERC20.approve(address(permissionedERC20), INITIAL_BALANCE);
            permissionedERC20.depositFor(users[i], INITIAL_BALANCE);
            permissionedERC20.approve(address(morpho), type(uint256).max);
            vm.stopPrank();
        }
    }

    /**
     * @notice Test: supplyCollateral from an allowed user => ok
     */
    function test_SupplyCollateralFromAllowedUser_Ok() public {
        uint256 collateralBefore = morpho.collateral(marketId, allowedUser1);
        uint256 balanceBefore = permissionedERC20.balanceOf(allowedUser1);

        vm.prank(allowedUser1);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, allowedUser1, hex"");

        assertEq(morpho.collateral(marketId, allowedUser1), collateralBefore + TEST_AMOUNT);
        assertEq(permissionedERC20.balanceOf(allowedUser1), balanceBefore - TEST_AMOUNT);
        assertEq(permissionedERC20.balanceOf(address(morpho)), TEST_AMOUNT);
    }

    /**
     * @notice Test: supplyCollateral from a not allowed user => ko (user cannot get permissioned tokens)
     */
    function test_SupplyCollateralFromNotAllowedUser_Ko() public {
        // Note: notAllowedUser1 cannot wrap underlying tokens because they're not whitelisted
        // So they cannot get permissioned tokens to supply as collateral
        uint256 collateralBefore = morpho.collateral(marketId, notAllowedUser1);

        // Give notAllowedUser1 underlying tokens
        underlyingERC20.setBalance(notAllowedUser1, TEST_AMOUNT);

        vm.startPrank(notAllowedUser1);
        // Try to wrap tokens - should fail because notAllowedUser1 is not whitelisted
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(PermissionedERC20.ToAddressNotAllowed.selector, notAllowedUser1));
        permissionedERC20.depositFor(notAllowedUser1, TEST_AMOUNT);
        vm.stopPrank();

        // Verify no collateral was supplied
        assertEq(morpho.collateral(marketId, notAllowedUser1), collateralBefore);
    }

    /**
     * @notice Test: supplyCollateral on behalf of another allowed user => ok
     */
    function test_SupplyCollateralOnBehalfOfAllowedUser_Ok() public {
        uint256 collateralBefore = morpho.collateral(marketId, allowedUser2);
        uint256 balanceBefore = permissionedERC20.balanceOf(allowedUser1);

        vm.prank(allowedUser1);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, allowedUser2, hex"");

        assertEq(morpho.collateral(marketId, allowedUser2), collateralBefore + TEST_AMOUNT);
        assertEq(permissionedERC20.balanceOf(allowedUser1), balanceBefore - TEST_AMOUNT);
        assertEq(permissionedERC20.balanceOf(address(morpho)), TEST_AMOUNT);
    }

    /**
     * @notice Test: supplyCollateral with zero amount => ko
     */
    function test_SupplyCollateralZeroAmount_Ko() public {
        vm.prank(allowedUser1);
        vm.expectRevert();
        morpho.supplyCollateral(marketParams, 0, allowedUser1, hex"");
    }

    /**
     * @notice Test: supplyCollateral on behalf of zero address => ko
     */
    function test_SupplyCollateralOnBehalfOfZeroAddress_Ko() public {
        vm.prank(allowedUser1);
        vm.expectRevert();
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, address(0), hex"");
    }

    /**
     * @notice Test: supplyCollateral multiple times accumulates collateral
     */
    function test_SupplyCollateralMultipleTimes_Accumulates() public {
        vm.startPrank(allowedUser1);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, allowedUser1, hex"");
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, allowedUser1, hex"");
        vm.stopPrank();

        assertEq(morpho.collateral(marketId, allowedUser1), TEST_AMOUNT * 2);
        assertEq(permissionedERC20.balanceOf(address(morpho)), TEST_AMOUNT * 2);
    }

    /**
     * @notice Test: supplyCollateral from different users to same onBehalf
     */
    function test_SupplyCollateralFromDifferentUsers_SameOnBehalf() public {
        vm.startPrank(allowedUser1);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, allowedUser2, hex"");
        vm.stopPrank();

        vm.startPrank(allowedUser2);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, allowedUser2, hex"");
        vm.stopPrank();

        assertEq(morpho.collateral(marketId, allowedUser2), TEST_AMOUNT * 2);
    }
}

