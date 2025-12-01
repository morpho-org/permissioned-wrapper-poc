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

---

## 3. Interacting with Morpho

When using the permissioned wrapper with Morpho, you must add Morpho and users to the allow list. **Morpho must be whitelisted** because it receives permissioned tokens as collateral.

**Location**: [`test/SupplyCollateralInMorpho.t.sol`](test/SupplyCollateralInMorpho.t.sol#L60-L66)

```solidity
// Add contracts and users to allow list
// NOTE: Morpho needs to be whitelisted because it receives permissioned tokens as collateral
address[] memory allowListAddresses = new address[](3);
allowListAddresses[0] = address(morpho);
allowListAddresses[1] = allowedUser1;
allowListAddresses[2] = allowedUser2;
for (uint256 i = 0; i < allowListAddresses.length; i++) {
    permissionedERC20.addToAllowList(allowListAddresses[i]);
}
```

Users can then directly call Morpho's `supplyCollateral` function:

```solidity
morpho.supplyCollateral(marketParams, amount, onBehalf, hex"");
```

### Security Considerations

**Important**: Permissioned wrappers that only check the recipient address could allow non-permissioned users to use the wrapper if they can get tokens through other means.

This implementation mitigates this risk by checking **both** the `from` address (sender) and `to` address (recipient) in the `_beforeTokenTransfer` hook. This means:
- Non-whitelisted users cannot receive tokens (mint/transfer blocked)
- Non-whitelisted users cannot send tokens (transfer blocked)
- Even if tokens were somehow obtained, supplying collateral would fail because Morpho's `transferFrom` would check the `from` address

This dual-check approach ensures that only whitelisted addresses can participate in token transfers, providing defense-in-depth against potential bypasses.

---

## License

MIT

---

## Disclaimer

This software is provided "as is", without warranty of any kind. The authors and contributors are not liable for any damages arising from the use of this software.
