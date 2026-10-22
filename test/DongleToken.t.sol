// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DongleToken} from "../src/DongleToken.sol";

/// @notice Stands in for the launch factory: deploys the token through CREATE2 so the whole supply
/// lands on this contract, exactly as `ProjectFactory.launchCustom` deploys it. Nothing is
/// pre-funded and nothing else exists on the chain when the constructor runs.
contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function call(address target, bytes memory data) external returns (bool ok) {
        (ok,) = target.call(data);
    }
}

contract DongleTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SWARM_BPS = 1_000;

    FactoryProbe internal factory;
    DongleToken internal token;

    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant HOLDER = address(0x401D);
    address internal constant OTHER = address(0x07E5);
    address internal constant ATTACKER = address(0xBEEF);

    function setUp() public {
        factory = new FactoryProbe();
        address deployed = factory.deploy(type(DongleToken).creationCode, bytes32(uint256(1)));
        token = DongleToken(deployed);
    }

    // ---------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Dongle");
        assertEq(token.symbol(), "DONGLE");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Dongle");
        assertEq(token.TOKEN_SYMBOL(), "DONGLE");
        assertEq(token.DECIMALS(), 18);
    }

    function test_supplyConstantsAgree() public view {
        assertEq(token.SUPPLY_WHOLE_TOKENS(), 1_000_000_000);
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
    }

    /// @dev The constructor mints the whole supply, once, to whoever deploys it: here the factory probe.
    function test_mintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(factory)), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    /// @dev Deployed directly by an EOA-like test address, the supply lands on that address instead.
    function test_mintsToWhoeverDeploys() public {
        address deployer = makeAddr("deployer");
        vm.prank(deployer);
        DongleToken fresh = new DongleToken();
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
        assertEq(fresh.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_constructorEmitsSingleTransferFromZero() public {
        address deployer = makeAddr("deployer");
        vm.recordLogs();
        vm.prank(deployer);
        new DongleToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event");
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(0));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), deployer);
        assertEq(abi.decode(logs[0].data, (uint256)), EXPECTED_SUPPLY);
    }

    /// @dev The constructor takes no arguments and talks to no other contract, so it deploys on an
    /// empty chain at any CREATE2 address the launch picks.
    function test_deploysOnEmptyChainAtAnySalt() public {
        FactoryProbe lonely = new FactoryProbe();
        bytes32 salt = keccak256("another launch");
        bytes32 codeHash = keccak256(type(DongleToken).creationCode);
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(lonely), salt, codeHash)))));
        assertEq(predicted.code.length, 0);
        address deployed = lonely.deploy(type(DongleToken).creationCode, salt);
        assertEq(deployed, predicted);
        assertEq(DongleToken(deployed).balanceOf(address(lonely)), EXPECTED_SUPPLY);
    }

    function test_runtimeFitsEip170() public view {
        assertGt(address(token).code.length, 0);
        assertLe(address(token).code.length, 24_576);
    }

    // ---------------------------------------------------------------------------------------
    // Transfers: success
    // ---------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        uint256 amount = 123_456 ether;
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(factory), HOLDER, amount);
        assertTrue(factory.move(token, HOLDER, amount));
        assertEq(token.balanceOf(HOLDER), amount);
        assertEq(token.balanceOf(address(factory)), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferWholeBalance() public {
        assertTrue(factory.move(token, HOLDER, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(HOLDER), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(factory)), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        assertTrue(factory.move(token, HOLDER, 0));
        assertEq(token.balanceOf(HOLDER), 0);
        vm.prank(HOLDER);
        assertTrue(token.transfer(OTHER, 0));
    }

    function test_transferToSelfKeepsBalance() public {
        factory.move(token, HOLDER, 10 ether);
        vm.prank(HOLDER);
        assertTrue(token.transfer(HOLDER, 10 ether));
        assertEq(token.balanceOf(HOLDER), 10 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev The launch flow: ten percent to the distributor whole, then claimed whole. No fee, no burn.
    function test_swarmShareArrivesWholeAndIsClaimableWhole() public {
        uint256 swarm = (EXPECTED_SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------
    // Transfers: failure
    // ---------------------------------------------------------------------------------------

    function test_transferRevertsOnInsufficientBalance() public {
        factory.move(token, HOLDER, 5 ether);
        vm.prank(HOLDER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, HOLDER, 5 ether, 5 ether + 1)
        );
        token.transfer(OTHER, 5 ether + 1);
        assertEq(token.balanceOf(HOLDER), 5 ether);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ATTACKER, 0, 1));
        token.transfer(OTHER, 1);
    }

    function test_transferToZeroAddressReverts() public {
        factory.move(token, HOLDER, 1 ether);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------

    function test_approveAndTransferFrom() public {
        factory.move(token, HOLDER, 100 ether);
        vm.prank(HOLDER);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(HOLDER, OTHER, 40 ether);
        assertTrue(token.approve(OTHER, 40 ether));
        assertEq(token.allowance(HOLDER, OTHER), 40 ether);

        vm.prank(OTHER);
        assertTrue(token.transferFrom(HOLDER, CLAIMANT, 30 ether));
        assertEq(token.balanceOf(HOLDER), 70 ether);
        assertEq(token.balanceOf(CLAIMANT), 30 ether);
        assertEq(token.allowance(HOLDER, OTHER), 10 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        factory.move(token, HOLDER, 100 ether);
        vm.prank(HOLDER);
        token.approve(OTHER, type(uint256).max);
        vm.prank(OTHER);
        token.transferFrom(HOLDER, CLAIMANT, 60 ether);
        assertEq(token.allowance(HOLDER, OTHER), type(uint256).max);
        assertEq(token.balanceOf(CLAIMANT), 60 ether);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        factory.move(token, HOLDER, 100 ether);
        vm.prank(HOLDER);
        token.approve(OTHER, 10 ether);
        vm.prank(OTHER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, OTHER, 10 ether, 10 ether + 1)
        );
        token.transferFrom(HOLDER, CLAIMANT, 10 ether + 1);
        assertEq(token.balanceOf(HOLDER), 100 ether);
    }

    function test_transferFromWithoutApprovalReverts() public {
        factory.move(token, HOLDER, 100 ether);
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ATTACKER, 0, 1));
        token.transferFrom(HOLDER, ATTACKER, 1);
        assertEq(token.balanceOf(HOLDER), 100 ether);
    }

    function test_transferFromRevertsBeyondBalanceEvenWithAllowance() public {
        factory.move(token, HOLDER, 5 ether);
        vm.prank(HOLDER);
        token.approve(OTHER, 10 ether);
        vm.prank(OTHER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, HOLDER, 5 ether, 6 ether)
        );
        token.transferFrom(HOLDER, CLAIMANT, 6 ether);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------
    // No privileged surface
    // ---------------------------------------------------------------------------------------

    /// @dev Neither a stranger nor the deployer can reach anything that grows the supply.
    function test_noCommonAdminCallIncreasesSupply() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "owner()",
            "renounceOwnership()"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ATTACKER, type(uint128).max);
            vm.prank(ATTACKER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
            assertEq(token.balanceOf(ATTACKER), 0, signatures[i]);
            assertFalse(factory.call(address(token), data), signatures[i]);
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
        }
    }

    /// @dev Nobody moves or freezes a holder's balance but the holder, not even the deployer.
    function test_noPrivilegedHandMovesOrFreezesAHolder() public {
        factory.move(token, HOLDER, EXPECTED_SUPPLY / 1_000);
        uint256 held = token.balanceOf(HOLDER);
        assertGt(held, 0);
        string[14] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "burn(uint256)",
            "seize(address)",
            "clawback(address,uint256)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], HOLDER, true);
            assertFalse(factory.call(address(token), data), signatures[i]);
        }
        assertFalse(
            factory.call(
                address(token), abi.encodeWithSelector(IERC20.transferFrom.selector, HOLDER, address(factory), 1)
            )
        );
        assertEq(token.balanceOf(HOLDER), held, "a privileged call moved the holder's balance");
        vm.prank(HOLDER);
        assertTrue(token.transfer(OTHER, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(OTHER), held / 2);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_noPayableSurface() public {
        vm.deal(ATTACKER, 1 ether);
        vm.prank(ATTACKER);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "plain value transfer accepted");
        vm.prank(ATTACKER);
        (ok,) = address(token).call{value: 1}(abi.encodeWithSignature("nothing()"));
        assertFalse(ok, "unknown selector accepted");
        assertEq(address(token).balance, 0);
    }

    /// @dev Reachable runtime code contains no DELEGATECALL, CALLCODE or SELFDESTRUCT, scanning the
    /// way the launch floor does: PUSH data is skipped and bytes after a terminating opcode are
    /// data until the next JUMPDEST.
    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        bool reachable = true;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "runtime code contains DELEGATECALL");
                assertTrue(op != 0xF2, "runtime code contains CALLCODE");
                assertTrue(op != 0xFF, "runtime code contains SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ---------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        uint256 beforeTo = token.balanceOf(to);
        assertTrue(factory.move(token, to, amount));
        if (to == address(factory)) {
            assertEq(token.balanceOf(address(factory)), EXPECTED_SUPPLY);
        } else {
            assertEq(token.balanceOf(to), beforeTo + amount);
            assertEq(token.balanceOf(address(factory)), EXPECTED_SUPPLY - amount);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferBeyondBalanceReverts(uint256 held, uint256 excess) public {
        held = bound(held, 0, EXPECTED_SUPPLY - 1);
        excess = bound(excess, 1, EXPECTED_SUPPLY - held);
        factory.move(token, HOLDER, held);
        vm.prank(HOLDER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, HOLDER, held, held + excess)
        );
        token.transfer(OTHER, held + excess);
        assertEq(token.balanceOf(HOLDER), held);
    }

    function testFuzz_transferFromWithinAllowance(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        spent = bound(spent, 0, allowed);
        factory.move(token, HOLDER, EXPECTED_SUPPLY);
        vm.prank(HOLDER);
        token.approve(OTHER, allowed);
        vm.prank(OTHER);
        assertTrue(token.transferFrom(HOLDER, CLAIMANT, spent));
        assertEq(token.balanceOf(CLAIMANT), spent);
        assertEq(token.balanceOf(HOLDER), EXPECTED_SUPPLY - spent);
        assertEq(token.allowance(HOLDER, OTHER), allowed - spent);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_roundTripLeavesBalancesUnchanged(address a, address b, uint256 amount) public {
        vm.assume(a != address(0) && b != address(0) && a != b);
        vm.assume(a != address(factory) && b != address(factory));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        factory.move(token, a, amount);
        vm.prank(a);
        token.transfer(b, amount);
        vm.prank(b);
        token.transfer(a, amount);
        assertEq(token.balanceOf(a), amount);
        assertEq(token.balanceOf(b), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev Any address deploying the token receives the whole supply; the deployer is never baked in.
    function testFuzz_anyDeployerReceivesWholeSupply(address deployer) public {
        vm.assume(deployer != address(0));
        vm.assume(deployer.code.length == 0);
        vm.assume(uint160(deployer) > 0xff); // keep clear of precompiles and the zero page
        vm.prank(deployer);
        DongleToken fresh = new DongleToken();
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
        assertEq(fresh.balanceOf(deployer), EXPECTED_SUPPLY);
    }
}
