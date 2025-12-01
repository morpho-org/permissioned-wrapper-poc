// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20Mock} from "morpho-blue/src/mocks/ERC20Mock.sol";
import {PermissionedERC20} from "../../src/PermissionedERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Constants} from "./Constants.sol";

/**
 * @title TokenSetup
 * @notice Utility functions for setting up tokens in tests
 */
library TokenSetup {
    struct Tokens {
        ERC20Mock underlying;
        PermissionedERC20 permissioned;
    }

    /**
     * @notice Deploys underlying and permissioned tokens
     * @return tokens The deployed tokens
     */
    function deployTokens() internal returns (Tokens memory tokens) {
        tokens.underlying = new ERC20Mock();
        tokens.permissioned = new PermissionedERC20(IERC20(address(tokens.underlying)));
    }

    /**
     * @notice Adds addresses to the permissioned token allow list
     * @param permissioned The permissioned token contract
     * @param addresses Array of addresses to add to allow list
     */
    function addToAllowList(PermissionedERC20 permissioned, address[] memory addresses) internal {
        for (uint256 i = 0; i < addresses.length; i++) {
            permissioned.addToAllowList(addresses[i]);
        }
    }

    /**
     * @notice Mints tokens to users
     * @param underlying The underlying token contract
     * @param users Array of user addresses
     * @param amount Amount to mint to each user
     */
    function mintToUsers(ERC20Mock underlying, address[] memory users, uint256 amount) internal {
        for (uint256 i = 0; i < users.length; i++) {
            underlying.setBalance(users[i], amount);
        }
    }

    /**
     * @notice Approves token spending for a single user
     * @param token The token contract to approve
     * @param spender The spender address
     * @param amount The approval amount (use type(uint256).max for unlimited)
     * @dev The caller must be pranked as the user before calling this function
     */
    function approveForUser(address token, address spender, uint256 amount) internal {
        IERC20(token).approve(spender, amount);
    }
}

