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

When using the permissioned wrapper with Morpho, you must add Morpho and ERC20WrapperAdapter to the allow list. **Bundler3 typically does NOT need to be whitelisted** for wrapping operations, but **Bundler3 MUST be whitelisted for atomic wrap+supply operations** because:
- **Morpho** receives permissioned tokens as collateral (must be whitelisted)
- **ERC20WrapperAdapter** handles wrapping operations with permissioned tokens (must be whitelisted)
- **Bundler3** must be whitelisted for atomic wrap+supply because Morpho's `supplyCollateral` pulls tokens from `msg.sender` (Bundler3)

### Direct Supply (ie without the Bundler)

For direct supply operations, you need to add Morpho and users to the allow list. **Morpho must be whitelisted** because it receives permissioned tokens as collateral.

**Location**: [`test/SupplyCollateralInMorphoDirect.t.sol`](test/SupplyCollateralInMorphoDirect.t.sol#L60-L66)

```solidity
// Add contracts and users to allow list
// NOTE: Morpho needs to be whitelisted because it receives permissioned tokens as collateral
permissionedERC20.addToAllowList(address(morpho));
permissionedERC20.addToAllowList(allowedUser1);
permissionedERC20.addToAllowList(allowedUser2);
```

Users can then directly call Morpho's `supplyCollateral` function:

```solidity
morpho.supplyCollateral(marketParams, amount, onBehalf, hex"");
```

### Supply with Bundler

When using Morpho Bundler3, you need to add Morpho, ERC20WrapperAdapter, and users to the allow list. **For atomic wrap+supply operations, Bundler3 must also be whitelisted**:
- **Morpho must be whitelisted** because it receives permissioned tokens as collateral
- **ERC20WrapperAdapter must be whitelisted** because it handles wrapping operations with permissioned tokens
- **Bundler3 must be whitelisted for atomic wrap+supply** because Morpho's `supplyCollateral` pulls tokens from `msg.sender` (Bundler3)

**Location**: [`test/SupplyCollateralInMorphoBundler.t.sol`](test/SupplyCollateralInMorphoBundler.t.sol#L85-L96)

```solidity
// Add contracts and users to allow list
// NOTE: Morpho and ERC20WrapperAdapter need to be whitelisted
// - Morpho receives permissioned tokens as collateral
// - ERC20WrapperAdapter handles wrapping operations with permissioned tokens
// Bundler3 will be whitelisted in atomic wrap+supply operations
permissionedERC20.addToAllowList(address(morpho));
permissionedERC20.addToAllowList(address(erc20WrapperAdapter));

// Add users to allow list
permissionedERC20.addToAllowList(allowedUser1);
permissionedERC20.addToAllowList(allowedUser2);
```

**Pattern: Wrap tokens and supply collateral atomically through Bundler3**

This is the main use case - wrapping underlying tokens and supplying them as collateral in one atomic transaction:

**Location**: [`test/SupplyCollateralInMorphoBundler.t.sol`](test/SupplyCollateralInMorphoBundler.t.sol#L125-L189)

```solidity
// Whitelist Bundler3 for atomic operation (needed because Morpho pulls from msg.sender)
permissionedERC20.addToAllowList(address(bundler3));

// Approve Bundler3 and Morpho (users must do this before calling multicall)
underlyingERC20.approve(address(bundler3), amount);
permissionedERC20.approve(address(bundler3), amount);
permissionedERC20.approve(address(morpho), amount);

Call[] memory bundle = new Call[](6);
// Step 1: Transfer underlying tokens from user to ERC20WrapperAdapter
bundle.push(
    BundlerHelpers.createERC20TransferFromCall(
        address(underlyingERC20), user, address(erc20WrapperAdapter), amount
    )
);
// Step 2: Wrap underlying tokens to permissioned tokens (sent to initiator)
bundle.push(
    BundlerHelpers.createERC20WrapperDepositForCall(
        address(erc20WrapperAdapter), address(permissionedERC20), amount
    )
);
// Step 3: Transfer permissioned tokens from initiator to ERC20WrapperAdapter
bundle.push(
    BundlerHelpers.createERC20TransferFromCall(
        address(permissionedERC20), user, address(erc20WrapperAdapter), amount
    )
);
// Step 4: Use adapter to transfer permissioned tokens from adapter to Bundler3
bundle.push(
    BundlerHelpers.createERC20TransferCall(
        address(erc20WrapperAdapter), address(permissionedERC20), address(bundler3), amount
    )
);
// Step 5: Approve Morpho to spend permissioned tokens from Bundler3
bundle.push(
    BundlerHelpers.createApproveCall(address(permissionedERC20), address(morpho), amount)
);
// Step 6: Supply collateral to Morpho (Morpho pulls from Bundler3)
bundle.push(
    BundlerHelpers.createMorphoSupplyCollateralCall(
        address(morpho), marketParams, amount, user, hex""
    )
);

bundler3.multicall(bundle);
```

**Note**: The wrapped tokens go through the adapter (steps 3-4) before reaching Bundler3. This ensures all token transfers go through whitelisted contracts (adapter), and Bundler3 only holds tokens temporarily for Morpho's `supplyCollateral` call.

#### Security Considerations

**Important**: The [Bundler3 audit by Spearbit (February 2025)](https://github.com/morpho-org/bundler3/blob/main/audits/2025-02-17-bundler3-update-spearbit.pdf) identified that permissioned wrappers that only check the recipient address could allow non-permissioned users to use the wrapper if they can get tokens through other means.

This implementation mitigates this risk in two ways:

1. **Use of ERC20WrapperAdapter**: We use `ERC20WrapperAdapter` for wrapping operations (instead of using `GeneralAdapter1` for all operations). The `ERC20WrapperAdapter` is specifically designed for ERC20Wrapper operations and sends wrapped tokens directly to the initiator, ensuring proper access control. This adapter is used when wrapping underlying tokens into permissioned tokens.

2. **Both sender and recipient checks**: Our `_beforeTokenTransfer` hook checks **both** the `from` address (sender) and `to` address (recipient). This means:
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

