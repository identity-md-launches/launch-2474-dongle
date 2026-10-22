# Dongle (DONGLE)

A fixed-supply ERC-20 token for a custom token launch on Ethereum (chain id 1).

| Field | Value |
|-------|-------|
| Solidity contract | `DongleToken` (`src/DongleToken.sol`) |
| `name()` | `Dongle` |
| `symbol()` | `DONGLE` |
| `decimals()` | `18` |
| `totalSupply()` | `1_000_000_000 * 10^18` = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Owner / admin | none |

The whole supply is minted exactly once, in the constructor, to `msg.sender`. At launch
`msg.sender` is the launch factory, which then pays every allocation out of that balance.
Nothing in the contract reserves, redirects, taxes, burns or mints anything.

## Design

`DongleToken` inherits OpenZeppelin `ERC20` (v5.1.0, vendored under `lib/`) and adds only
constants and a constructor. It has:

- no owner, no `Ownable`, no roles;
- no `mint`, `burn`, `burnFrom`, `pause`, blacklist, freeze, lock, seize or transfer toggle;
- no fee or burn on transfer, so every flow arrives exactly as sent;
- no external calls in the constructor, no `receive`/`fallback`, no proxy, no `delegatecall`,
  no `selfdestruct`;
- no library with public or external functions, so the bytecode has no link placeholders.

Every value the token needs is a named constant in the contract:

| Constant | Value |
|----------|-------|
| `TOKEN_NAME` | `"Dongle"` |
| `TOKEN_SYMBOL` | `"DONGLE"` |
| `DECIMALS` | `18` |
| `SUPPLY_WHOLE_TOKENS` | `1_000_000_000` |
| `TOTAL_SUPPLY` | `SUPPLY_WHOLE_TOKENS * 10 ** DECIMALS` |

The brief left nothing open: name, symbol, supply and decimals are all given, and the token
has no other parameters.

## Deployment parameters

- **Constructor arguments:** none. The deployer receives the full supply.
- **Deployer:** the launch factory (`ProjectFactory.launchCustom`), which deploys the token via
  CREATE2 and holds the supply until it distributes it. The factory is not a parameter and
  nothing identifies it inside the contract; any address that deploys the code receives the
  supply.
- **Compiler:** `solc = "0.8.26"`, optimizer on with 200 runs, `evm_version = "cancun"`,
  `bytecode_hash = "none"` and `cbor_metadata = false` so the built bytecode is reproducible
  without a metadata hash (see `foundry.toml`).
- **Launch values decided by the launch, not by this token:** pool pair IMD
  (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), pool fee 12500 (1.25%), tick spacing 60,
  the opening price derived from the requester's economics, 10% of the supply to the swarm's
  MerkleDistributor, 88% seeding the pool and 2% to the requester's remainder address. The
  manifest step writes `launch.json`; this repository intentionally does not contain one.

## Operational responsibilities

- **After launch there is nothing to operate.** There is no owner-settable value, no setter
  and no privileged function. Nobody, including the deployer, can mint, burn, pause, freeze
  or move another holder's balance.
- **Supply is final.** `totalSupply()` can never grow. Holders may discard tokens only by
  sending them to an address nobody controls; the contract itself refuses transfers to the
  zero address.
- **Holders manage their own allowances.** Standard ERC-20 approvals apply. Granting
  `type(uint256).max` is a permanent allowance that is never decremented; approve exact
  amounts to contracts you do not fully trust.
- **Explorer verification** of the deployed source is the launch deployer's step
  (`forge verify-contract` with the pinned compiler settings), not this repository's.

## Assumptions

- The deployer is the launch factory and is the right recipient of the full supply, as the
  custom token launch requires.
- The vendored OpenZeppelin `ERC20` v5.1.0 is correct as shipped. Only the five files the
  token imports are vendored, unmodified, with the upstream MIT licence.
- `forge-std` v1.9.7 is vendored for tests only; it is not part of the deployed bytecode.

## Security notes

Checked against the `eth-security` checklist:

- No admin functions, so no access-control surface. No pausability, so no censorship vector.
- No external calls and no ETH handling, so no reentrancy path.
- Decimals are 18 and fixed; no cross-token math exists.
- No oracles, no swaps, no proxies, no signatures, no `delegatecall`.
- Tests cover zero amounts, maximum balance, unauthorized callers, every common privileged
  selector, the launch flows and fuzzed transfers (run with the verifier's fuzz seed).

Tools run in this task: `forge build`, `forge test` (unit and fuzz, 256 runs) and
`forge fmt --check`. Slither and Mythril were not available here and did not run. Passing
tests are not an audit; the launch's independent review remains a separate step.

## Layout

```
foundry.toml          compiler pins and build settings
remappings.txt        forge-std and @openzeppelin/contracts remappings
src/DongleToken.sol   the token
test/DongleToken.t.sol unit and fuzz tests
lib/forge-std         vendored test library (v1.9.7, src only)
lib/openzeppelin-contracts  vendored ERC20 and its four imports (v5.1.0)
```

## Build and test

```
forge build
FOUNDRY_FUZZ_SEED=0x924598b0c08576dd30305e380f363a1522cd11b4b27b275571f64e923f38a9ae forge test
forge fmt --check
```

All three run offline with solc 0.8.26 installed.
