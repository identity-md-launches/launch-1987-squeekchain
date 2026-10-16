# Squeekchain (SQK)

A fixed-supply ERC-20 token for an IdentityMD custom-token launch on Ethereum mainnet.

| Parameter | Value |
|---|---|
| Solidity contract | `SqueekchainToken` (`src/SqueekchainToken.sol`) |
| Token name | `Squeekchain` |
| Token symbol | `SQK` |
| Decimals | `18` |
| Total supply | 1,000,000,000 SQK = `1000000000000000000000000000` minor units (1e27) |
| Constructor arguments | none |
| Minted to | `msg.sender` of the constructor, once, in the constructor |
| Owner / admin | none |

## Behaviour

- The constructor credits the whole supply to `msg.sender` and emits `Transfer(address(0), msg.sender, 1e27)`.
  That is the only mint; there is no `mint`, `burn`, `burnFrom`, owner, minter role, pause, blocklist,
  fee, tax, reflection or upgrade path. `totalSupply()` is a constant for the life of the contract.
- `transfer` and `transferFrom` move exactly the amount asked, from every caller, to every non-zero
  address. Transfers to the zero address revert, so the supply cannot shrink by "burning to zero".
- `approve` sets the allowance outright (no increase/decrease helpers). Approving the zero address
  reverts. An allowance of `type(uint256).max` is unlimited and is not decremented by `transferFrom`.
- Failures revert with typed errors (`ERC20InsufficientBalance`, `ERC20InsufficientAllowance`,
  `ERC20InvalidReceiver`, `ERC20InvalidSpender`); the functions never return `false`.
- The contract has no `receive` or `fallback`: plain ETH transfers and unknown selectors revert.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and no library is linked.

## Launch and deployment parameters

The token is deployed by the IdentityMD ProjectFactory (`launchCustom`), never by a script in this
repository. The factory is `msg.sender` of the constructor and therefore receives the entire supply;
it then pays the swarm's share to the launch's MerkleDistributor, seeds the pool and forwards the
remainder. The token exempts nobody and taxes nothing, so every launch flow moves exactly what it says.

Values the manifest step needs (it writes `launch.json`; this repository does not):

| Manifest field | Value |
|---|---|
| `token.contract` | `SqueekchainToken` |
| `token.name` | `Squeekchain` |
| `token.symbol` | `SQK` |
| `token.decimals` | `18` |
| `token.constructorArgs` | `[]` |
| `token.totalSupply` | `1000000000000000000000000000` |
| `contracts` | `[]` (no application contracts) |

Launch terms, decided by the launch and recorded here for reference only:

| Launch term | Value |
|---|---|
| Chain | Ethereum mainnet (chain id 1) |
| Paired currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals) |
| Pool fee | `12500` (1.25%, the launch policy's fee) |
| Tick spacing | `60` |
| `pool.initialPrice` | `79228162514264337593543950336` (provenance only; the deployer derives the opening price) |
| `economics.poolBps` | `8000` (80% of the supply seeds the pool) |
| `economics.initialMarketCapWei` | `2500000000000000000000` (2,500 IMD for the whole supply) |
| `economics.remainderTo` | `0xce34a5ae98f51b499b92063a7a83d49b26ee5b14` (receives the remaining 10%) |
| Swarm share | 10% of the supply, taken by the factory before the pool is seeded |

Build settings that the launch depends on live in `foundry.toml`: `solc = "0.8.26"`,
`evm_version = "cancun"`, optimizer on with 200 runs, and `bytecode_hash = "none"` so the deployed
bytes are reproducible without a metadata hash.

## After launch

Nothing to configure. The token has no owner, no settable addresses and no parameters. Once deployed
it cannot be changed, paused or extended by anyone.

## Assumptions

- The brief asks for a plain token: name, symbol and a fixed supply minted once to the deployer. No
  transfer rules, fees, vesting, governance or permit were requested, so none are implemented.
- "The deployer" is whoever calls the constructor. In the IdentityMD launch that is the factory,
  which is what the launch requires (the whole supply must land at the factory). Anyone else who
  deploys this bytecode simply receives the supply themselves.
- Ethereum mainnet is post-Cancun, so `cancun` bytecode (which uses `MCOPY`) runs there.
- The IMD pair, the pool fee and the economics above are the launch's values; the token does not
  reference any of them and needs no addresses at construction.

## Operational responsibilities

- **Nobody holds admin powers.** There is no key to rotate, no multisig to set up and no upgrade to
  plan. This is deliberate: a fixed-supply, immutable token is the simplest thing to trust.
- **The holder of the supply is responsible for it.** After the launch the factory distributes it;
  afterwards the requester's remainder address and every other holder manage their own balances and
  allowances. Unlimited approvals (`type(uint256).max`) should be granted only to audited contracts.
- **Source verification on the explorer** is the deployer's step after launch (`forge
  verify-contract` with the same `foundry.toml`), so that holders can read the code they hold.
- **No recovery of mistaken transfers.** Tokens sent to a wrong address or to a contract that cannot
  move them are lost; the contract cannot seize or restore anything.
- **Independent review.** Tests are not an audit. The launch policy's separate adversarial review
  step should still run before the launch is admitted.

## Security checklist (eth-security reference)

Run through the pinned checklist for this contract:

- Access control: no privileged function exists, so nothing needs restricting.
- Reentrancy: the contract makes no external calls and holds no ETH.
- Decimals and integer math: 18 decimals, no division, balances always sum to the constant supply;
  the only `unchecked` blocks are guarded by the preceding comparisons.
- Input validation: zero receiver and zero spender revert; zero amounts are allowed (ERC-20 requires
  it); amounts above the balance or allowance revert with the shortfall in the error.
- Events: every balance and allowance change emits `Transfer` or `Approval`.
- No proxies, delegatecall, selfdestruct, signatures, oracles, swaps or external tokens.
- Pausable/blocklist trade-off: none, by design.

## Tests

`test/SqueekchainToken.t.sol` covers metadata, the one-time mint and its event, every success and
failure path of `transfer`, `approve` and `transferFrom`, the absence of mint/admin/freeze entry
points (the same selector lists the launch floor probes), the runtime opcode scan, and fuzzed
conservation of the supply and allowance accounting.

The tests depend on nothing outside this repository: `test/support/Vm.sol` declares the subset of
Foundry's cheatcode interface they use, so no `lib/` is needed and the project builds offline.

```sh
forge build
forge test
forge fmt --check
FOUNDRY_FUZZ_SEED=0xc1edd000e2fa9be0798039cef6acb2d3159f7452ee2a25a06dedea39e40194df forge test
```

Tests read no environment variables, do not depend on the calling address and are independent of
each other, so they pass in any order and in parallel.

## Layout

```
foundry.toml                 compiler pins and build settings
src/IERC20.sol               the ERC-20 interface the token implements
src/SqueekchainToken.sol     the token
test/support/Vm.sol          cheatcode interface subset
test/support/TestBase.sol    shared test scaffolding
test/SqueekchainToken.t.sol  tests
```
