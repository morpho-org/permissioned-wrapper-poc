// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PermissionedERC20 is ERC20, ERC20Wrapper {
    constructor(IERC20 _underlying) ERC20Wrapper(_underlying) ERC20("PermissionedERC20", "PERC20") {}

    function decimals() public view override(ERC20, ERC20Wrapper) returns (uint8) {
        return ERC20Wrapper.decimals();
    }

    ///-------------CUSTOM ERRORS-------------
    error FromAddressNotAllowed(address from);
    error ToAddressNotAllowed(address to);
    ///---------------END OF CUSTOM ERRORS---------------

    ///-------------ALLOW LIST MANAGEMENT-------------
    mapping(address => bool) public allowed;

    function addToAllowList(address _address) public {
        allowed[_address] = true;
    }

    function removeFromAllowList(address _address) public {
        allowed[_address] = false;
    }

    function isAllowed(address _address) public view returns (bool) {
        return allowed[_address];
    }

    ///---------------END OF ALLOW LIST MANAGEMENT---------------

    ///-------------GATING FUNCTIONS-------------
    /**
     * @dev Override the _beforeTokenTransfer function to check mint, burn and transfer permissions
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
        // Check from address (skip for minting where from is address(0))
        if (from != address(0) && !isAllowed(from)) {
            revert FromAddressNotAllowed(from);
        }
        // Check to address (skip for burning where to is address(0))
        if (to != address(0) && !isAllowed(to)) {
            revert ToAddressNotAllowed(to);
        }
        super._beforeTokenTransfer(from, to, amount);
    }
    ///---------------END OF GATING FUNCTIONS---------------
}
