// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {PermissionedERC20} from "../src/PermissionedERC20.sol";
import {ERC20Mock} from "morpho-blue/src/mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PermissionedERC20Test is Test {
    ERC20Mock public underlyingERC20;
    PermissionedERC20 public permissionedERC20;

    address public allowedUser1 = address(0x1001);
    address public allowedUser2 = address(0x1002);
    address public notAllowedUser1 = address(0x2001);
    address public notAllowedUser2 = address(0x2002);

    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant TEST_AMOUNT = 100 ether;

    function setUp() public {
        // Deploy underlying ERC20
        underlyingERC20 = new ERC20Mock();

        // Deploy PermissionedERC20
        permissionedERC20 = new PermissionedERC20(IERC20(address(underlyingERC20)));

        // Add users to allow list
        permissionedERC20.addToAllowList(allowedUser1);
        permissionedERC20.addToAllowList(allowedUser2);

        // Mint underlying tokens to users
        underlyingERC20.setBalance(allowedUser1, INITIAL_BALANCE);
        underlyingERC20.setBalance(allowedUser2, INITIAL_BALANCE);
        underlyingERC20.setBalance(notAllowedUser1, INITIAL_BALANCE);
        underlyingERC20.setBalance(notAllowedUser2, INITIAL_BALANCE);
    }

    /**
     * @notice Test: mint to an allowed address => ok
     */
    function test_MintToAllowedAddress_Ok() public {
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        permissionedERC20.depositFor(allowedUser1, TEST_AMOUNT);
        vm.stopPrank();

        assertEq(permissionedERC20.balanceOf(allowedUser1), TEST_AMOUNT);
        assertEq(underlyingERC20.balanceOf(address(permissionedERC20)), TEST_AMOUNT);
    }

    /**
     * @notice Test: burn from an allowed address => ok
     */
    function test_BurnFromAllowedAddress_Ok() public {
        // First, set up: mint some tokens
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        permissionedERC20.depositFor(allowedUser1, TEST_AMOUNT);
        vm.stopPrank();

        // Now test burning
        vm.startPrank(allowedUser1);
        uint256 balanceBefore = underlyingERC20.balanceOf(allowedUser1);
        permissionedERC20.withdrawTo(allowedUser1, TEST_AMOUNT);
        vm.stopPrank();

        assertEq(permissionedERC20.balanceOf(allowedUser1), 0);
        assertEq(underlyingERC20.balanceOf(allowedUser1), balanceBefore + TEST_AMOUNT);
    }

    /**
     * @notice Test: mint to a not allowed address => ko
     */
    function test_MintToNotAllowedAddress_Ko() public {
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);

        // Try to mint to notAllowedUser1 (not in allow list)
        vm.expectRevert(abi.encodeWithSelector(PermissionedERC20.ToAddressNotAllowed.selector, notAllowedUser1));
        permissionedERC20.depositFor(notAllowedUser1, TEST_AMOUNT);
        vm.stopPrank();
    }

    /**
     * @notice Test: burn from a not allowed address => ko
     */
    function test_BurnFromNotAllowedAddress_Ko() public {
        // First, set up: mint some tokens to allowedUser1
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        permissionedERC20.depositFor(allowedUser1, TEST_AMOUNT);
        vm.stopPrank();

        // Transfer tokens to notAllowedUser1 (temporarily add to allow list to receive)
        permissionedERC20.addToAllowList(notAllowedUser1);
        vm.startPrank(allowedUser1);
        permissionedERC20.transfer(notAllowedUser1, TEST_AMOUNT);
        vm.stopPrank();
        permissionedERC20.removeFromAllowList(notAllowedUser1);

        // Now try to burn from notAllowedUser1 (not allowed)
        vm.startPrank(notAllowedUser1);
        vm.expectRevert(abi.encodeWithSelector(PermissionedERC20.FromAddressNotAllowed.selector, notAllowedUser1));
        permissionedERC20.withdrawTo(notAllowedUser1, TEST_AMOUNT);
        vm.stopPrank();
    }

    /**
     * @notice Test: transfer from an allowed address to an allowed address => ok
     */
    function test_TransferFromAllowedToAllowed_Ok() public {
        // Set up: mint tokens to allowedUser1
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        permissionedERC20.depositFor(allowedUser1, TEST_AMOUNT);
        vm.stopPrank();

        // Transfer from allowedUser1 to allowedUser2
        vm.startPrank(allowedUser1);
        permissionedERC20.transfer(allowedUser2, TEST_AMOUNT);
        vm.stopPrank();

        assertEq(permissionedERC20.balanceOf(allowedUser1), 0);
        assertEq(permissionedERC20.balanceOf(allowedUser2), TEST_AMOUNT);
    }

    /**
     * @notice Test: transfer from an allowed address to a not allowed address => ko
     */
    function test_TransferFromAllowedToNotAllowed_Ko() public {
        // Set up: mint tokens to allowedUser1
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        permissionedERC20.depositFor(allowedUser1, TEST_AMOUNT);
        vm.stopPrank();

        // Try to transfer to notAllowedUser1
        vm.startPrank(allowedUser1);
        vm.expectRevert(abi.encodeWithSelector(PermissionedERC20.ToAddressNotAllowed.selector, notAllowedUser1));
        permissionedERC20.transfer(notAllowedUser1, TEST_AMOUNT);
        vm.stopPrank();
    }

    /**
     * @notice Test: transfer from a not allowed address to a not allowed address => ko
     */
    function test_TransferFromNotAllowedToNotAllowed_Ko() public {
        // Set up: mint tokens to allowedUser1, then transfer to notAllowedUser1 (temporarily allow)
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        permissionedERC20.depositFor(allowedUser1, TEST_AMOUNT);
        vm.stopPrank();

        // Temporarily add notAllowedUser1 to allow list to receive tokens
        permissionedERC20.addToAllowList(notAllowedUser1);
        vm.startPrank(allowedUser1);
        permissionedERC20.transfer(notAllowedUser1, TEST_AMOUNT);
        vm.stopPrank();
        permissionedERC20.removeFromAllowList(notAllowedUser1);

        // Now try to transfer from notAllowedUser1 to notAllowedUser2
        vm.startPrank(notAllowedUser1);
        vm.expectRevert(abi.encodeWithSelector(PermissionedERC20.FromAddressNotAllowed.selector, notAllowedUser1));
        permissionedERC20.transfer(notAllowedUser2, TEST_AMOUNT);
        vm.stopPrank();
    }

    /**
     * @notice Test: transfer from a not allowed address to an allowed address => ko
     */
    function test_TransferFromNotAllowedToAllowed_Ko() public {
        // Set up: mint tokens to allowedUser1, then transfer to notAllowedUser1 (temporarily allow)
        vm.startPrank(allowedUser1);
        underlyingERC20.approve(address(permissionedERC20), TEST_AMOUNT);
        permissionedERC20.depositFor(allowedUser1, TEST_AMOUNT);
        vm.stopPrank();

        // Temporarily add notAllowedUser1 to allow list to receive tokens
        permissionedERC20.addToAllowList(notAllowedUser1);
        vm.startPrank(allowedUser1);
        permissionedERC20.transfer(notAllowedUser1, TEST_AMOUNT);
        vm.stopPrank();
        permissionedERC20.removeFromAllowList(notAllowedUser1);

        // Now try to transfer from notAllowedUser1 to allowedUser2
        vm.startPrank(notAllowedUser1);
        vm.expectRevert(abi.encodeWithSelector(PermissionedERC20.FromAddressNotAllowed.selector, notAllowedUser1));
        permissionedERC20.transfer(allowedUser2, TEST_AMOUNT);
        vm.stopPrank();
    }
}
