// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DongleToken} from "../src/DongleToken.sol";

/// @notice Drives the token with random transfers, approvals and transferFroms among a fixed set of
/// actors, and keeps an independent model of every balance and allowance. Calls that must fail are
/// driven too, and the handler checks they revert with the expected error and change nothing.
contract DongleHandler is Test {
    DongleToken public immutable token;
    address[] public actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostTransfers;
    uint256 public ghostTransferFroms;
    uint256 public ghostRejected;

    constructor(DongleToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            ghostBalance[actors_[i]] = token_.balanceOf(actors_[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, ghostBalance[from]);

        vm.prank(from);
        assertTrue(token.transfer(to, amount));

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ++ghostTransfers;
    }

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        excess = bound(excess, 1, type(uint256).max - held);

        vm.prank(from);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, held + excess)
        );
        token.transfer(to, held + excess);
        ++ghostRejected;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Exercise the unlimited allowance often, not once in 2^256.
        if (amount % 5 == 0) amount = type(uint256).max;

        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[from][spender];
        uint256 cap = allowed < ghostBalance[from] ? allowed : ghostBalance[from];
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));

        if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ++ghostTransferFroms;
    }

    function transferFromBeyondAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[from][spender];
        if (allowed == type(uint256).max) return;
        excess = bound(excess, 1, type(uint256).max - allowed);

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, allowed + excess)
        );
        token.transferFrom(from, to, allowed + excess);
        ++ghostRejected;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        ++ghostRejected;
    }
}

contract DongleTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    DongleToken internal token;
    DongleHandler internal handler;
    address[] internal actors;

    function setUp() public {
        address deployer = makeAddr("factory");
        vm.prank(deployer);
        token = new DongleToken();

        actors.push(deployer);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));

        // Spread the supply unevenly so balances near zero and near the whole supply are both reachable.
        vm.startPrank(deployer);
        token.transfer(actors[1], SUPPLY / 10);
        token.transfer(actors[2], 1);
        token.transfer(actors[3], SUPPLY / 2);
        vm.stopPrank();

        handler = new DongleHandler(token, actors);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_actorsHoldTheWholeSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply());
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesMatchModel() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.ghostBalance(actors[i]));
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allowancesMatchModel() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), handler.ghostAllowance(actors[i], actors[j]));
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_metadataFixed() public view {
        assertEq(token.name(), "Dongle");
        assertEq(token.symbol(), "DONGLE");
        assertEq(token.decimals(), 18);
    }
}
