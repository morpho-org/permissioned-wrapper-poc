// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import {Call, IBundler3} from "bundler3/src/Bundler3.sol";
import {ERC20WrapperAdapter} from "bundler3/src/adapters/ERC20WrapperAdapter.sol";
import {CoreAdapter} from "bundler3/src/adapters/CoreAdapter.sol";
import {IMorpho, MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BundlerHelpers
 * @notice Helper functions for creating Bundler3 Call structs
 */
library BundlerHelpers {
    /**
     * @notice Creates a basic Call struct
     * @param to Target address
     * @param data Calldata
     * @return call The Call struct
     */
    function createCall(address to, bytes memory data) internal pure returns (Call memory call) {
        return Call({to: to, data: data, value: 0, skipRevert: false, callbackHash: bytes32(0)});
    }

    /**
     * @notice Creates a Call struct with callback hash
     * @param to Target address
     * @param data Calldata
     * @param callbackHash Hash of the callback bundle
     * @return call The Call struct
     */
    function createCallWithCallback(address to, bytes memory data, bytes32 callbackHash)
        internal
        pure
        returns (Call memory call)
    {
        return Call({to: to, data: data, value: 0, skipRevert: false, callbackHash: callbackHash});
    }

    /**
     * @notice Creates a Call struct for ERC20 transfer
     * @param adapter The CoreAdapter contract address
     * @param token The token address
     * @param recipient The recipient address
     * @param amount The amount to transfer
     * @return call The Call struct
     */
    function createERC20TransferCall(address adapter, address token, address recipient, uint256 amount)
        internal
        pure
        returns (Call memory call)
    {
        return createCall(adapter, abi.encodeCall(CoreAdapter.erc20Transfer, (token, recipient, amount)));
    }

    /**
     * @notice Creates a Call struct for Morpho supply collateral (direct call to Morpho)
     * @param morpho The Morpho protocol address
     * @param marketParams The market parameters
     * @param assets The amount of assets to supply
     * @param onBehalf The address to supply on behalf of
     * @param data Callback data (empty bytes if no callback)
     * @return call The Call struct
     */
    function createMorphoSupplyCollateralCall(
        address morpho,
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes memory data
    ) internal pure returns (Call memory call) {
        bytes32 callbackHash = data.length == 0 ? bytes32(0) : keccak256(data);
        // Use function selector 0x238d6579 for supplyCollateral(MarketParams,uint256,address,bytes)
        return createCallWithCallback(
            morpho, abi.encodeWithSelector(bytes4(0x238d6579), marketParams, assets, onBehalf, data), callbackHash
        );
    }

    /**
     * @notice Creates a Call struct for ERC20 transferFrom (direct call to token)
     * @dev Note: This requires users to approve Bundler3 directly
     * @param token The token address
     * @param from The address to transfer from
     * @param to The address to transfer to
     * @param amount The amount to transfer
     * @return call The Call struct
     */
    function createERC20TransferFromCall(address token, address from, address to, uint256 amount)
        internal
        pure
        returns (Call memory call)
    {
        return createCall(token, abi.encodeCall(IERC20(token).transferFrom, (from, to, amount)));
    }

    /**
     * @notice Creates a Call struct for ERC20 approve
     * @param token The token address
     * @param spender The spender address
     * @param amount The approval amount
     * @return call The Call struct
     */
    function createApproveCall(address token, address spender, uint256 amount)
        internal
        pure
        returns (Call memory call)
    {
        return createCall(token, abi.encodeCall(IERC20(token).approve, (spender, amount)));
    }

    /**
     * @notice Creates a Call struct for ERC20Wrapper depositFor
     * @param adapter The ERC20WrapperAdapter contract address
     * @param wrapper The wrapper token address
     * @param amount The amount of underlying tokens to deposit
     * @return call The Call struct
     */
    function createERC20WrapperDepositForCall(address adapter, address wrapper, uint256 amount)
        internal
        pure
        returns (Call memory call)
    {
        return createCall(adapter, abi.encodeCall(ERC20WrapperAdapter.erc20WrapperDepositFor, (wrapper, amount)));
    }

    /**
     * @notice Creates a Call struct for ERC20Wrapper withdrawTo
     * @param adapter The ERC20WrapperAdapter contract address
     * @param wrapper The wrapper token address
     * @param receiver The address receiving the underlying tokens
     * @param amount The amount of wrapped tokens to burn
     * @return call The Call struct
     */
    function createERC20WrapperWithdrawToCall(address adapter, address wrapper, address receiver, uint256 amount)
        internal
        pure
        returns (Call memory call)
    {
        return
            createCall(adapter, abi.encodeCall(ERC20WrapperAdapter.erc20WrapperWithdrawTo, (wrapper, receiver, amount)));
    }
}

