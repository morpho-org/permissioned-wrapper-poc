# Permissioned ERC20 Wrapper - Proof of Concept

## ⚠️ WARNING: PROOF OF CONCEPT ONLY

**This repository is a Proof of Concept (PoC) and must NEVER be used in production as-is.**

This code has not been audited, lacks proper access controls, and is intended solely for demonstration purposes. Use at your own risk.

---

## Purpose

This repository demonstrates how to use an ERC20 wrapper token to implement permissioned access control for collateral supply in Morpho.


---

## 1. Allow List Mechanism

This PoC uses a simple allow list stored directly in the ERC20 wrapper contract. In production, you should use a separate contract with proper access controls to manage the allow list.

### Allow List Management

**Location**: [`src/PermissionedERC20.sol`](src/PermissionedERC20.sol#L20-L34)

```solidity
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
```


---

## 2. Transfer Restrictions

All token operations (transfers, mints, and burns) are restricted by the allow list. The `_beforeTokenTransfer` hook checks if addresses are allowed before allowing any operation.

**Location**: [`src/PermissionedERC20.sol`](src/PermissionedERC20.sol#L36-L51)

```solidity
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
```


## 3. Interacting with Morpho

When using the permissioned wrapper with Morpho, you must add the Morpho protocol contract to the allow list (and the Morpho Bundler if used). This is required because Morpho needs to receive or send the permissioned tokens when users supply or withdraw collateral.

**Location**: [`test/SupplyCollateralInMorpho.sol`](test/SupplyCollateralInMorpho.sol#L72-L73)

```solidity
// Add Morpho to allow list so it can handle the permissioned token
permissionedERC20.addToAllowList(address(morpho));
```


---

## License

MIT

---

## Disclaimer

This software is provided "as is", without warranty of any kind. The authors and contributors are not liable for any damages arising from the use of this software.

