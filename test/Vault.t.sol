// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { YieldSweeperVault } from "../src/Vault.sol";
import { IERC20Minimal } from "../src/interfaces/IERC20Minimal.sol";
import { IPayable } from "reactive-lib/interfaces/IPayable.sol";

/// @dev A minimal mintable ERC20 for testing.
contract MockToken is IERC20Minimal {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract VaultTest is Test {
    YieldSweeperVault vault;
    MockToken token;

    address callbackProxy = address(0xA11CE);
    address reactive = address(0xB0B);
    address coldWallet = address(0xC0ffee);
    address farmer = address(0xF00);

    function setUp() public {
        vault = new YieldSweeperVault(
            IPayable(payable(callbackProxy)),
            reactive,
            coldWallet
        );
        // The Vault now uses a mutable `callbackSender`; set it in setUp.
        vm.prank(coldWallet);
        vault.setCallbackSender(reactive);
        token = new MockToken();
    }

    function test_DepositERC20() public {
        token.mint(farmer, 100e18);
        vm.startPrank(farmer);
        token.approve(address(vault), 100e18);
        vault.depositToken(address(token), 50e18);
        vm.stopPrank();

        assertEq(vault.sweepableBalance(address(token)), 50e18);
    }

    function test_DepositNative() public {
        vm.deal(farmer, 10 ether);
        vm.prank(farmer);
        vault.deposit{ value: 1 ether }();

        assertEq(vault.sweepableBalance(address(0)), 1 ether);
    }

    function test_SweepToken_Unauthorized_Reverts() public {
        token.mint(address(vault), 10e18);
        // Wrong callback sender (not the reactive contract) -> revert.
        vm.prank(callbackProxy);
        vm.expectRevert();
        vault.sweep(address(0xBAD), address(token), 0);
    }

    function test_SweepToken_ViaCallbackProxy() public {
        token.mint(address(vault), 10e18);

        // The callback proxy always injects the reactive contract address as
        // the first argument of the callback. In our test, we call `sweep`
        // from the proxy and pass `reactive` as the first arg.
        vm.prank(callbackProxy);
        vault.sweep(reactive, address(token), 0);

        assertEq(token.balanceOf(coldWallet), 10e18);
        assertEq(vault.sweepableBalance(address(token)), 0);
    }

    function test_SweepNative_ViaCallbackProxy() public {
        vm.deal(address(vault), 2 ether);

        vm.prank(callbackProxy);
        vault.sweep(reactive, address(0), 0);

        assertEq(coldWallet.balance, 2 ether);
        assertEq(vault.sweepableBalance(address(0)), 0);
    }

    function test_Sweep_Partial() public {
        token.mint(address(vault), 10e18);

        vm.prank(callbackProxy);
        vault.sweep(reactive, address(token), 4e18);

        assertEq(token.balanceOf(coldWallet), 4e18);
        assertEq(vault.sweepableBalance(address(token)), 6e18);
    }

    function test_ManualSweep_OnlyOwner() public {
        token.mint(address(vault), 5e18);

        // Owner (coldWallet) can manually sweep.
        vm.prank(coldWallet);
        vault.manualSweep(address(token), 0);
        assertEq(token.balanceOf(coldWallet), 5e18);

        // Non-owner cannot.
        token.mint(address(vault), 1e18);
        vm.prank(farmer);
        vm.expectRevert();
        vault.manualSweep(address(token), 0);
    }

    function test_OnlyReactiveCallbackSenderCanSweep() public {
        token.mint(address(vault), 1e18);

        // A different reactive contract is not allowed.
        vm.prank(callbackProxy);
        // We simulate by deploying a new vault with a different sender.
        YieldSweeperVault vault2 = new YieldSweeperVault(
            IPayable(payable(callbackProxy)),
            address(0xAAA), // different reactive
            coldWallet
        );
        vm.prank(coldWallet);
        vault2.setCallbackSender(address(0xAAA));
        MockToken t = new MockToken();
        t.mint(address(vault2), 1e18);

        // The proxy injects 0xAAA, which matches vault2's sender -> allowed.
        vm.prank(callbackProxy);
        vault2.sweep(address(0xAAA), address(t), 0);
        assertEq(t.balanceOf(coldWallet), 1e18);
    }
}
