// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {PermissionedERC20} from "../src/PermissionedERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/src/interfaces/IMorpho.sol";
import {Morpho} from "morpho-blue/src/Morpho.sol";
import {OracleMock} from "morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "morpho-blue/src/mocks/IrmMock.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "morpho-blue/src/libraries/periphery/MorphoLib.sol";

contract SupplyCollateralInMorphoTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;

    ERC20Mock public underlyingERC20;
    PermissionedERC20 public permissionedERC20;
    IMorpho public morpho;
    OracleMock public oracle;
    IrmMock public irm;
    MarketParams public marketParams;
    Id public marketId;

    address public allowedUser1 = address(0x1001);
    address public allowedUser2 = address(0x1002);
    address public notAllowedUser1 = address(0x2001);
    address public owner = address(0x9999);

    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant TEST_AMOUNT = 100 ether;
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;

    function setUp() public {
        // Deploy underlying ERC20 (collateral token)
        underlyingERC20 = new ERC20Mock();

        // Deploy PermissionedERC20 (loan token)
        permissionedERC20 = new PermissionedERC20(underlyingERC20);

        // Deploy Morpho
        morpho = IMorpho(address(new Morpho(owner)));

        // Deploy Oracle and IRM mocks
        oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE); // 1:1 price ratio

        irm = new IrmMock();

        // Setup Morpho (enable IRM and LLTV)
        vm.startPrank(owner);
        morpho.enableIrm(address(0));
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0);
        morpho.enableLltv(8600); // 86% LLTV
        vm.stopPrank();

        // Create market params
        marketParams = MarketParams({
            loanToken: address(permissionedERC20),
            collateralToken: address(underlyingERC20),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 8600 // 86% in basis points
        });

        // Create market
        morpho.createMarket(marketParams);
        marketId = marketParams.id();

        // Add Morpho to allow list so it can handle the permissioned token
        permissionedERC20.addToAllowList(address(morpho));

        // Add users to allow list
        permissionedERC20.addToAllowList(allowedUser1);
        permissionedERC20.addToAllowList(allowedUser2);

        // Mint underlying tokens (collateral) to users
        underlyingERC20.mint(allowedUser1, INITIAL_BALANCE);
        underlyingERC20.mint(allowedUser2, INITIAL_BALANCE);
        underlyingERC20.mint(notAllowedUser1, INITIAL_BALANCE);

        // Approve Morpho to spend collateral tokens
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(morpho), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(allowedUser2);
        underlyingERC20.approve(address(morpho), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(notAllowedUser1);
        underlyingERC20.approve(address(morpho), type(uint256).max);
        vm.stopPrank();
    }

    /**
     * @notice Test: supplyCollateral from an allowed user => ok
     */
    function test_SupplyCollateralFromAllowedUser_Ok() public {
        uint256 collateralBefore = morpho.collateral(marketId, allowedUser1);
        uint256 balanceBefore = underlyingERC20.balanceOf(allowedUser1);

        vm.prank(allowedUser1);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, allowedUser1, hex"");

        assertEq(morpho.collateral(marketId, allowedUser1), collateralBefore + TEST_AMOUNT);
        assertEq(underlyingERC20.balanceOf(allowedUser1), balanceBefore - TEST_AMOUNT);
        assertEq(underlyingERC20.balanceOf(address(morpho)), TEST_AMOUNT);
    }

    /**
     * @notice Test: supplyCollateral from a not allowed user => ok (collateral is not permissioned)
     */
    function test_SupplyCollateralFromNotAllowedUser_Ok() public {
        // Note: supplyCollateral uses the collateral token (underlyingERC20), not the permissioned token
        // So it should work even if the user is not in the allow list
        uint256 collateralBefore = morpho.collateral(marketId, notAllowedUser1);
        uint256 balanceBefore = underlyingERC20.balanceOf(notAllowedUser1);

        vm.prank(notAllowedUser1);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, notAllowedUser1, hex"");

        assertEq(morpho.collateral(marketId, notAllowedUser1), collateralBefore + TEST_AMOUNT);
        assertEq(underlyingERC20.balanceOf(notAllowedUser1), balanceBefore - TEST_AMOUNT);
        assertEq(underlyingERC20.balanceOf(address(morpho)), TEST_AMOUNT);
    }

    /**
     * @notice Test: supplyCollateral on behalf of another allowed user => ok
     */
    function test_SupplyCollateralOnBehalfOfAllowedUser_Ok() public {
        uint256 collateralBefore = morpho.collateral(marketId, allowedUser2);
        uint256 balanceBefore = underlyingERC20.balanceOf(allowedUser1);

        vm.prank(allowedUser1);
        morpho.supplyCollateral(marketParams, TEST_AMOUNT, allowedUser2, hex"");

        assertEq(morpho.collateral(marketId, allowedUser2), collateralBefore + TEST_AMOUNT);
        assertEq(underlyingERC20.balanceOf(allowedUser1), balanceBefore - TEST_AMOUNT);
        assertEq(underlyingERC20.balanceOf(address(morpho)), TEST_AMOUNT);
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
        assertEq(underlyingERC20.balanceOf(address(morpho)), TEST_AMOUNT * 2);
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
