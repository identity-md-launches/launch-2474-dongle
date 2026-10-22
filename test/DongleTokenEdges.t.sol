// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DongleToken} from "../src/DongleToken.sol";

/// @notice Edge cases the main suite does not pin: callers the code may not have assumed, the same
/// call twice, and the zero / one / maximum values of amounts and allowances.
contract DongleTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    DongleToken internal token;
    address internal deployer;
    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        vm.prank(deployer);
        token = new DongleToken();
    }

    function test_ownerCannotTransferFromSelfWithoutAllowance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferFromZeroAmountWithoutAllowanceSucceeds() public {
        vm.prank(carol);
        assertTrue(token.transferFrom(deployer, alice, 0));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferFromZeroAddressReverts() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, 1));
        token.transferFrom(address(0), alice, 1);
    }

    function test_transferFromToZeroAddressReverts() public {
        vm.prank(deployer);
        token.approve(carol, 10);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 10);
        assertEq(token.allowance(deployer, carol), 10);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_approveOverwritesRatherThanAdds() public {
        vm.startPrank(deployer);
        token.approve(alice, 100);
        token.approve(alice, 30);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 30);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 30, 31));
        token.transferFrom(deployer, bob, 31);
    }

    function test_approveToZeroRevokes() public {
        vm.startPrank(deployer);
        token.approve(alice, 100);
        token.approve(alice, 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_allowanceSpentExactlyThenExhausted() public {
        vm.prank(deployer);
        token.approve(alice, 50);
        vm.startPrank(alice);
        token.transferFrom(deployer, bob, 20);
        token.transferFrom(deployer, bob, 30);
        assertEq(token.allowance(deployer, alice), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 50);
    }

    function test_allowanceIsPerOwnerAndSpender() public {
        vm.prank(deployer);
        token.approve(alice, 100);
        // bob has no allowance of his own, and alice's allowance is not usable against another owner.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, bob, 1);

        vm.prank(deployer);
        token.transfer(carol, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(carol, alice, 1);
    }

    function test_transferFromDoesNotEmitApproval() public {
        vm.prank(deployer);
        token.approve(alice, 100);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 40);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(deployer))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(abi.decode(logs[0].data, (uint256)), 40);
    }

    function test_transferEmitsTransferEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(deployer, alice, 1);
        vm.prank(deployer);
        token.transfer(alice, 1);
    }

    function test_oneWeiTransfers() public {
        vm.prank(deployer);
        token.transfer(alice, 1);
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_maxUintTransferReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_transferToTokenContractIsAcceptedAndStuck() public {
        // Plain ERC-20: tokens sent to the token's own address are accepted and nobody can move them.
        vm.prank(deployer);
        token.transfer(address(token), 5);
        assertEq(token.balanceOf(address(token)), 5);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_unknownSelectorReverts() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(ok);
        (ok,) = address(token).call(hex"");
        assertFalse(ok);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_thirdPartyCannotMoveFunds(address attacker, address to, uint256 amount) public {
        vm.assume(attacker != deployer);
        to = to == address(0) ? alice : to;
        amount = bound(amount, 1, SUPPLY);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, attacker, 0, amount));
        token.transferFrom(deployer, to, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferChangesOnlySenderAndRecipient(uint256 amount, uint256 seed) public {
        address[3] memory others = [alice, bob, carol];
        address to = others[seed % 3];
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(to), amount);
        for (uint256 i; i < 3; ++i) {
            if (others[i] != to) assertEq(token.balanceOf(others[i]), 0);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }
}
