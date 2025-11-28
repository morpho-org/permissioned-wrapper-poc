// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Constants
 * @notice Common constants used across test files
 */
library Constants {
    // Test addresses
    address public constant OWNER = address(0x9999);
    address public constant ALLOWED_USER_1 = address(0x1001);
    address public constant ALLOWED_USER_2 = address(0x1002);
    address public constant NOT_ALLOWED_USER_1 = address(0x2001);
    address public constant NOT_ALLOWED_USER_2 = address(0x2002);

    // Amounts
    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant TEST_AMOUNT = 100 ether;

    // Market parameters
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;
    uint256 public constant LLTV = 8600; // 86% in basis points
}

