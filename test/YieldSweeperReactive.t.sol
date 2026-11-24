// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { YieldSweeperReactive } from "../src/YieldSweeperReactive.sol";
import { IReactive } from "reactive-lib/interfaces/IReactive.sol";
import { ISystemContract } from "reactive-lib/interfaces/ISystemContract.sol";

/// @dev Mock of the Reactive system contract. Records callback requests so we
///      can assert the reactive contract posts the correct callback.
contract MockSystem is ISystemContract {
    event CallbackRequested(uint256 chainId, address recipient, uint64 gasLimit, bytes payload);

    function subscribe(
        uint256,
        address,
        uint256,
        uint256,
        uint256,
        uint256
    ) external {}

    function unsubscribe(
        uint256,
        address,
        uint256,
        uint256,
        uint256,
        uint256
    ) external {}

    function requestCallback(CallbackVersion, bytes memory) external {}

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external {
        emit CallbackRequested(config_.chainId, config_.recipient, config_.gasLimit, config_.payload);
    }

    function pay() external payable {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract YieldSweeperReactiveTest is Test {
    YieldSweeperReactive rc;

    // The Reactive Network system contract address (constant in AbstractReactive).
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;

    address vault = address(0x1a11);
    address coldWallet = address(0xC0ffee);
    address token = address(0x70e9);
    uint256 constant DEST_CHAIN = 84532; // Base Sepolia

    // keccak256("Deposited(address,address,uint256)")
    uint256 constant DEPOSITED_TOPIC = 0x8752a472e571a816aea92eec8dae9baf628e840f4929fbcc2d155e6233ff68a7;

    function setUp() public {
        // Place a mock system contract at the fixed system address so that
        // subscribe()/requestCallback*() calls in the reactive contract work.
        vm.etch(SYSTEM, type(MockSystem).runtimeCode);
        rc = new YieldSweeperReactive(DEST_CHAIN, vault, coldWallet);
    }

    function _logRecord(address contractAddr, uint256 topic1, uint256 amount)
        internal view returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: DEST_CHAIN,
            contractAddress: contractAddr,
            topic0: DEPOSITED_TOPIC,
            topic1: topic1,
            topic2: uint256(uint160(coldWallet)),
            topic3: 0,
            data: abi.encode(amount),
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function test_ConstructorSubscribes() public {
        // If we got here without reverting, the subscribe call in the
        // constructor executed. Verify state is set.
        assertEq(rc.destinationChainId(), DEST_CHAIN);
        assertEq(rc.vault(), vault);
        assertEq(rc.coldWallet(), coldWallet);
    }

    function test_React_OnlySystem() public {
        // react() must revert when called by a non-system address.
        vm.prank(address(0xBAD));
        IReactive.LogRecord memory log = _logRecord(vault, uint256(uint160(token)), 1e18);
        vm.expectRevert();
        rc.react(log);
    }

    function test_React_NotVaultReverts() public {
        // react() must revert if the log is not from our vault.
        vm.prank(SYSTEM);
        IReactive.LogRecord memory log = _logRecord(address(0xBEEF), uint256(uint160(token)), 1e18);
        vm.expectRevert();
        rc.react(log);
    }

    function test_React_AccumulatesBelowThreshold() public {
        // Set threshold to 100e18.
        vm.prank(coldWallet);
        rc.setMinSweep(token, 100e18);

        // Deposit 10e18 (below threshold) -> accumulates, no callback.
        vm.prank(SYSTEM);
        rc.react(_logRecord(vault, uint256(uint160(token)), 10e18));

        assertEq(rc.accumulated(token), 10e18);
    }

    function test_React_ThresholdTriggersCallback() public {
        // Set threshold to 50e18.
        vm.prank(coldWallet);
        rc.setMinSweep(token, 50e18);

        // Deposit 60e18 (above threshold) -> triggers callback and resets.
        vm.recordLogs();
        vm.prank(SYSTEM);
        rc.react(_logRecord(vault, uint256(uint160(token)), 60e18));

        assertEq(rc.accumulated(token), 0);

        // The MockSystem should have emitted CallbackRequested with our vault
        // as recipient and the correct chain id.
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundRequest = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == SYSTEM) {
                foundRequest = true;
            }
        }
        assertTrue(foundRequest, "expected a callback request on the system contract");
    }

    function test_React_CumulativeReachesThreshold() public {
        // Set threshold to 100e18.
        vm.prank(coldWallet);
        rc.setMinSweep(token, 100e18);

        // Deposit 40e18 then 60e18 -> cumulative 100e18 triggers callback.
        vm.prank(SYSTEM);
        rc.react(_logRecord(vault, uint256(uint160(token)), 40e18));
        assertEq(rc.accumulated(token), 40e18);

        vm.prank(SYSTEM);
        rc.react(_logRecord(vault, uint256(uint160(token)), 60e18));
        assertEq(rc.accumulated(token), 0); // swept
    }

    function test_React_NonWhitelistedTokenReverts() public {
        // No threshold set for token -> revert.
        vm.prank(SYSTEM);
        vm.expectRevert();
        rc.react(_logRecord(vault, uint256(uint160(token)), 1e18));
    }

    function test_SetMinSweep_OnlyColdWallet() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        rc.setMinSweep(token, 1e18);
    }
}
