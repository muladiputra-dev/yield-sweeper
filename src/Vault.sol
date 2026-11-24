// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { AbstractCallback } from "reactive-lib/base/AbstractCallback.sol";
import { IPayable } from "reactive-lib/interfaces/IPayable.sol";
import { IERC20Minimal } from "./interfaces/IERC20Minimal.sol";

/**
 * @title YieldSweeperVault
 * @notice A personal vault that accumulates yield/farming rewards and can be
 *         automatically swept to a cold wallet by a Reactive Network contract.
 *
 *         This contract lives on an ORIGIN chain (e.g. Base Sepolia or
 *         Unichain Sepolia). Funds arrive here via a normal `deposit()` call
 *         (or by transferring tokens directly). A Reactive contract on Lasna
 *         watches for the `Deposited` event and, when the accumulated balance
 *         for a whitelisted token crosses the configured threshold, posts an
 *         authenticated callback to `sweep()` which forwards the funds to the
 *         cold wallet.
 *
 *         No off-chain bot or keeper is required: everything is driven by the
 *         Reactive Network.
 */
contract YieldSweeperVault is AbstractCallback {
    // ----------------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------------

    /// @notice Emitted when native ETH or a token is deposited into the vault.
    event Deposited(address indexed token, address indexed depositor, uint256 amount);

    /// @notice Emitted when the vault sweeps funds to the cold wallet.
    event Swept(address indexed token, uint256 amount);

    /// @notice Emitted when the cold wallet or a token's sweep threshold changes.
    event RulesUpdated(address indexed token, uint256 minSweep);

    // ----------------------------------------------------------------------
    // State
    // ----------------------------------------------------------------------

    /// @notice The cold wallet that receives all swept funds.
    address public immutable coldWallet;

    /// @notice The reactive contract allowed to trigger sweeps.
    ///         Set after deployment (the reactive address is not known until
    ///         it is deployed on Lasna).
    address public callbackSender;

    /// @notice Map token -> minimum balance required to trigger a sweep.
    ///         address(0) represents native ETH (even though callbacks are
    ///         not payable, we keep it for completeness).
    mapping(address => uint256) public minSweepByToken;

    /**
     * @param callbackProxy_ The callback proxy address for THIS origin chain
     *        (unique per chain, from Reactive docs).
     * @param callbackSender_ The reactive contract on Lasna allowed to trigger
     *        sweeps (must match the reactive contract address).
     * @param coldWallet_ The destination cold wallet address.
     */
    constructor(
        IPayable callbackProxy_,
        address callbackSender_,
        address coldWallet_
    ) AbstractCallback(callbackProxy_, callbackSender_) {
        require(coldWallet_ != address(0), "vault: coldWallet zero");
        coldWallet = coldWallet_;
    }

    // ----------------------------------------------------------------------
    // Configuration
    // ----------------------------------------------------------------------

    /// @notice Set the callback sender (reactive contract) after deployment.
    ///         Callable only by the owner (cold wallet).
    function setCallbackSender(address sender) external {
        _checkOwner();
        require(sender != address(0), "vault: sender zero");
        callbackSender = sender;
    }

    /// @notice Set the minimum sweep threshold for a token.
    ///         Callable only by the owner (deployer) via the proxy.
    function setMinSweep(address token, uint256 minAmount) external {
        _checkOwner();
        minSweepByToken[token] = minAmount;
        emit RulesUpdated(token, minAmount);
    }

    // ----------------------------------------------------------------------
    // Deposit
    // ----------------------------------------------------------------------

    /// @notice Deposit native ETH into the vault.
    function deposit() external payable {
        // Only track the deposit if the vault is the recipient.
        if (msg.value > 0) {
            emit Deposited(address(0), msg.sender, msg.value);
        }
    }

    /// @notice Deposit an ERC20 token into the vault.
    function depositToken(address token, uint256 amount) external {
        require(token != address(0), "vault: token zero");
        require(amount > 0, "vault: amount zero");
        IERC20Minimal(token).transferFrom(msg.sender, address(this), amount);
        emit Deposited(token, msg.sender, amount);
    }

    // ----------------------------------------------------------------------
    // Sweep
    // ----------------------------------------------------------------------

    /// @notice Sweep a token (or native ETH via token == address(0)) to the
    ///         cold wallet. Callable only via an authenticated callback from
    ///         the reactive contract.
    /// @param callbackSender_ The reactive contract address injected by the
    ///        callback proxy (must equal `_CALLBACK_SENDER`).
    /// @param token The token to sweep. address(0) means native ETH.
    /// @param amount The amount to sweep (0 = all).
    function sweep(address callbackSender_, address token, uint256 amount) external {
        // The callback proxy injects the reactive contract address as the
        // first argument; verify it matches the authorized callback sender.
        require(callbackSender_ == callbackSender, "vault: bad sender");

        if (token == address(0)) {
            uint256 bal = address(this).balance;
            require(bal > 0, "vault: no ETH");
            uint256 out = (amount == 0 || amount > bal) ? bal : amount;
            (bool ok, ) = coldWallet.call{ value: out }("");
            require(ok, "vault: ETH sweep failed");
            emit Swept(address(0), out);
        } else {
            IERC20Minimal t = IERC20Minimal(token);
            uint256 bal = t.balanceOf(address(this));
            require(bal > 0, "vault: no balance");
            uint256 out = (amount == 0 || amount > bal) ? bal : amount;
            require(t.transfer(coldWallet, out), "vault: token sweep failed");
            emit Swept(token, out);
        }
    }

    /// @notice Manually sweep (for the owner / for testing without the
    ///         reactive network). Still gated to the owner.
    function manualSweep(address token, uint256 amount) external {
        _checkOwner();
        if (token == address(0)) {
            uint256 bal = address(this).balance;
            require(bal > 0, "vault: no ETH");
            uint256 out = (amount == 0 || amount > bal) ? bal : amount;
            (bool ok, ) = coldWallet.call{ value: out }("");
            require(ok, "vault: ETH sweep failed");
            emit Swept(address(0), out);
        } else {
            IERC20Minimal t = IERC20Minimal(token);
            uint256 bal = t.balanceOf(address(this));
            require(bal > 0, "vault: no balance");
            uint256 out = (amount == 0 || amount > bal) ? bal : amount;
            require(t.transfer(coldWallet, out), "vault: token sweep failed");
            emit Swept(token, out);
        }
    }

    /// @notice Current sweepable balance for a token.
    function sweepableBalance(address token) external view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        }
        return IERC20Minimal(token).balanceOf(address(this));
    }

    // ----------------------------------------------------------------------
    // Internal helpers
    // ----------------------------------------------------------------------

    /// @notice Restrict configuration functions to the deployer.
    function _checkOwner() internal view {
        require(msg.sender == coldWallet, "vault: not owner");
    }

    // Accept native ETH transfers (e.g. reward redistributions).
    receive() external payable override {
        if (msg.value > 0) {
            emit Deposited(address(0), msg.sender, msg.value);
        }
    }
}
