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
import {Morpho} from "morpho-blue/src/Morpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SupplyCollateralInMorpho is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;

    // Constants
    address public constant OWNER = address(0x9999);
    address public constant ALLOWED_USER_1 = address(0x1001);
    address public constant ALLOWED_USER_2 = address(0x1002);
    address public constant NOT_ALLOWED_USER_1 = address(0x2001);
    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant TEST_AMOUNT = 100 ether;
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;
    uint256 public constant LLTV = 8600; // 86% in basis points

    ERC20Mock public underlyingERC20;
    PermissionedERC20 public permissionedERC20;
    IMorpho public morpho;
    OracleMock public oracle;
    IrmMock public irm;
    MarketParams public marketParams;
    Id public marketId;

    function setUp() public {
        // Deploy tokens
        underlyingERC20 = new ERC20Mock();
        permissionedERC20 = new PermissionedERC20(IERC20(address(underlyingERC20)));

        // Setup Morpho market
        morpho = IMorpho(address(new Morpho(OWNER)));
        oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE); // 1:1 price ratio
        irm = new IrmMock();

        // Configure Morpho (enable IRM and LLTV)
        vm.startPrank(OWNER);
        morpho.enableIrm(address(0));
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0);
        morpho.enableLltv(LLTV);
        vm.stopPrank();

        // Create market with permissioned token as collateral
        address loanToken = makeAddr("LoanToken");
        marketParams = MarketParams({
            loanToken: loanToken,
            collateralToken: address(permissionedERC20),
            oracle: address(oracle),
            irm: address(irm),
            lltv: LLTV
        });
        morpho.createMarket(marketParams);
        marketId = marketParams.id();

        // Add contracts and users to allow list
        // NOTE: Morpho needs to be whitelisted because it receives permissioned tokens as collateral
        address[] memory allowListAddresses = new address[](3);
        allowListAddresses[0] = address(morpho);
        allowListAddresses[1] = ALLOWED_USER_1;
        allowListAddresses[2] = ALLOWED_USER_2;
        for (uint256 i = 0; i < allowListAddresses.length; i++) {
            permissionedERC20.addToAllowList(allowListAddresses[i]);
        }

        // Mint underlying tokens to users and wrap them to get permissioned tokens
        address[] memory users = new address[](2);
        users[0] = ALLOWED_USER_1;
        users[1] = ALLOWED_USER_2;
        for (uint256 i = 0; i < users.length; i++) {
            underlyingERC20.setBalance(users[i], INITIAL_BALANCE);
        }

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
        uint256 collateralBefore = morpho.collateral(marketId, ALLOWED_USER_1);
        uint256 balanceBefore = permissionedERC20.balanceOf(ALLOWED_USER_1);

        vm.prank(ALLOWED_USER_1);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, ALLOWED_USER_1, hex"");

        assertEq(morpho.collateral(marketId, ALLOWED_USER_1), collateralBefore + TEST_AMOUNT);
        assertEq(permissionedERC20.balanceOf(ALLOWED_USER_1), balanceBefore - TEST_AMOUNT);
        assertEq(permissionedERC20.balanceOf(address(morpho)), TEST_AMOUNT);
    }

    /**
     * @notice Test: supplyCollateral from a not allowed user => ko (user cannot get permissioned tokens)
     */
    function test_SupplyCollateralFromNotAllowedUser_Ko() public {
        // Note: notAllowedUser1 cannot wrap underlying tokens because they're not whitelisted
        // So they cannot get permissioned tokens to supply as collateral
        uint256 collateralBefore = morpho.collateral(marketId, NOT_ALLOWED_USER_1);

        // Give notAllowedUser1 underlying tokens
        underlyingERC20.setBalance(NOT_ALLOWED_USER_1, TEST_AMOUNT);

        vm.startPrank(NOT_ALLOWED_USER_1);
        // Try to wrap tokens - should fail because notAllowedUser1 is not whitelisted
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(PermissionedERC20.ToAddressNotAllowed.selector, NOT_ALLOWED_USER_1));
        permissionedERC20.depositFor(NOT_ALLOWED_USER_1, TEST_AMOUNT);
        vm.stopPrank();

        // Verify no collateral was supplied
        assertEq(morpho.collateral(marketId, NOT_ALLOWED_USER_1), collateralBefore);
    }

    /**
     * @notice Test: supplyCollateral on behalf of another allowed user => ok
     */
    function test_SupplyCollateralOnBehalfOfAllowedUser_Ok() public {
        uint256 collateralBefore = morpho.collateral(marketId, ALLOWED_USER_2);
        uint256 balanceBefore = permissionedERC20.balanceOf(ALLOWED_USER_1);

        vm.prank(ALLOWED_USER_1);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, ALLOWED_USER_2, hex"");

        assertEq(morpho.collateral(marketId, ALLOWED_USER_2), collateralBefore + TEST_AMOUNT);
        assertEq(permissionedERC20.balanceOf(ALLOWED_USER_1), balanceBefore - TEST_AMOUNT);
        assertEq(permissionedERC20.balanceOf(address(morpho)), TEST_AMOUNT);
    }

    /**
     * @notice Test: supplyCollateral with zero amount => ko
     */
    function test_SupplyCollateralZeroAmount_Ko() public {
        vm.prank(ALLOWED_USER_1);
        vm.expectRevert();
        morpho.supplyCollateral(marketParams, 0, ALLOWED_USER_1, hex"");
    }

    /**
     * @notice Test: supplyCollateral on behalf of zero address => ko
     */
    function test_SupplyCollateralOnBehalfOfZeroAddress_Ko() public {
        vm.prank(ALLOWED_USER_1);
        vm.expectRevert();
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, address(0), hex"");
    }

    /**
     * @notice Test: supplyCollateral multiple times accumulates collateral
     */
    function test_SupplyCollateralMultipleTimes_Accumulates() public {
        vm.startPrank(ALLOWED_USER_1);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, ALLOWED_USER_1, hex"");
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, ALLOWED_USER_1, hex"");
        vm.stopPrank();

        assertEq(morpho.collateral(marketId, ALLOWED_USER_1), TEST_AMOUNT * 2);
        assertEq(permissionedERC20.balanceOf(address(morpho)), TEST_AMOUNT * 2);
    }

    /**
     * @notice Test: supplyCollateral from different users to same onBehalf
     */
    function test_SupplyCollateralFromDifferentUsers_SameOnBehalf() public {
        vm.startPrank(ALLOWED_USER_1);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, ALLOWED_USER_2, hex"");
        vm.stopPrank();

        vm.startPrank(ALLOWED_USER_2);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, ALLOWED_USER_2, hex"");
        vm.stopPrank();

        assertEq(morpho.collateral(marketId, ALLOWED_USER_2), TEST_AMOUNT * 2);
    }
}

