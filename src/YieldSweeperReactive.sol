// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { AbstractReactive } from "reactive-lib/base/AbstractReactive.sol";
import { ISystemContract } from "reactive-lib/interfaces/ISystemContract.sol";
import { IReactive } from "reactive-lib/interfaces/IReactive.sol";
import { IERC20Minimal } from "./interfaces/IERC20Minimal.sol";

/**
 * @title YieldSweeperReactive
 * @notice The Reactive Network (Lasna) contract that watches the
 *         YieldSweeperVault on an origin chain and triggers a sweep whenever
 *         the accumulated deposits for a whitelisted token cross the
 *         configured threshold.
 *
 *         The hot path:
 *           1. `Deposited` event is emitted by the vault on the origin chain.
 *           2. The Reactive system contract delivers it to `react()`.
 *           3. `react()` accumulates the amount in `accumulated[token]`.
 *           4. If `accumulated[token] >= minSweepByToken[token]`, this
 *              contract requests a callback to `Vault.sweep(token, 0)`
 *              on the destination chain (via the callback proxy).
 *           5. The vault forwards the swept amount to the cold wallet.
 *
 *         The accumulated counter is reset on sweep so the cycle repeats.
 *         This contract keeps its own running tally (deterministic) rather
 *         than reading cross-chain balances.
 */
contract YieldSweeperReactive is AbstractReactive {
    // ----------------------------------------------------------------------
    // Constants
    // ----------------------------------------------------------------------

    /// @notice ke0 of the vault's `Deposited(address,address,uint256)` event.
    /// keccak256("Deposited(address,address,uint256)")
    uint256 private constant DEPOSITED_TOPIC =
        0x8752a472e571a816aea92eec8dae9baf628e840f4929fbcc2d155e6233ff68a7;

    uint64 private constant CALLBACK_GAS_LIMIT = 1_000_000;

    // ----------------------------------------------------------------------
    // State
    // ----------------------------------------------------------------------

    /// @notice The destination chain ID where the vault lives.
    uint256 public immutable destinationChainId;

    /// @notice The vault address on the destination chain.
    address public immutable vault;

    /// @notice The cold wallet that receives swept funds (informational;
    ///         the vault enforces it).
    address public immutable coldWallet;

    /// @notice Whitelisted tokens and their required sweep threshold
    ///         (address(0) = native ETH).
    mapping(address => uint256) public minSweepByToken;

    /// @notice Running tally of accumulated (un-swept) deposits per token.
    mapping(address => uint256) public accumulated;

    /**
     * @param destinationChainId_ Chain ID of the chain where the vault lives.
     * @param vault_ The YieldSweeperVault address on the destination chain.
     * @param coldWallet_ The cold wallet (used for the `owner` guard).
     */
    constructor(
        uint256 destinationChainId_,
        address vault_,
        address coldWallet_
    ) payable AbstractReactive() {
        destinationChainId = destinationChainId_;
        vault = vault_;
        coldWallet = coldWallet_;

        // Subscribe to the Deposited event from the vault.
        SYSTEM.subscribe(
            destinationChainId_,
            vault_,
            DEPOSITED_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    // ----------------------------------------------------------------------
    // Owner configuration
    // ----------------------------------------------------------------------

    /// @notice Set the sweep threshold for a token. Only the cold wallet
    ///         (owner) can configure.
    function setMinSweep(address token, uint256 minAmount) external {
        require(msg.sender == coldWallet, "r: not owner");
        minSweepByToken[token] = minAmount;
    }

    // ----------------------------------------------------------------------
    // Reactive entry point
    // ----------------------------------------------------------------------

    /// @notice Handle the Deposited event from the vault.
    /// @param log_ The log record delivered by the system contract.
    function react(LogRecord calldata log_) external onlySystem {
        require(log_.contractAddress == vault, "r: not vault");

        // Deposited(address indexed token, address indexed depositor, uint256 amount)
        address token = address(uint160(log_.topic1));
        uint256 amount = abi.decode(log_.data, (uint256));
        require(amount > 0, "r: zero amount");

        uint256 threshold = minSweepByToken[token];
        require(threshold > 0, "r: token not whitelisted");

        uint256 newAcc = accumulated[token] + amount;
        if (newAcc >= threshold) {
            // Sweep everything currently accumulated.
            _requestSweep(token);
            accumulated[token] = 0;
        } else {
            accumulated[token] = newAcc;
        }
    }

    // ----------------------------------------------------------------------
    // Internal
    // ----------------------------------------------------------------------

    /// @notice Request an authenticated callback to `Vault.sweep(token, 0)`.
    function _requestSweep(address token) internal {
        bytes memory payload = abi.encodeWithSignature(
            "sweep(address,address,uint256)",
            address(0), // placeholder: proxy injects the reactive contract address
            token,
            uint256(0)
        );

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: vault,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
    }
}
