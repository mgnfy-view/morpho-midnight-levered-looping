# AGENTS.md

Solidity and Foundry operating guide for this repository.

## Priorities

1. Correctness and security over speed.
2. Small, reviewable changes over broad refactors.
3. Tests that cement behavior, especially accounting and external integration assumptions.
4. No hidden uncertainty in asset accounting, oracle pricing, permissions, or deployment safety.

## Project Layout

- `src/`: production Solidity contracts.
- `test/`: Foundry tests.
- `script/`: deployment and operations scripts.
- `dependencies/`: Soldeer-managed dependency code. Do not edit directly.
- `out/`, `cache/`, `broadcast/`, `snapshots/`: generated artifacts.

Run Foundry commands from the repository root.

```bash
make install
make fbuild
make ftest
make format
```

## Formatting

Follow `foundry.toml`.

- Use `pragma solidity ^0.8.20;` unless there is a concrete reason to differ.
- Put SPDX first, then pragma, then imports.
- Use double quotes for strings and imports.
- Use four-space indentation.
- Keep lines within the 120-character target.
- Run `forge fmt` to sort imports and apply configured formatting.
- Use explicit integer types: `uint256`, `uint16`, `int256`. Do not use `uint` or `int`.
- Use explicit import lists.

```solidity
import { SafeERC20 } from "@openzeppelin-contracts-5.4.0/token/ERC20/utils/SafeERC20.sol";
import { IManager } from "src/interfaces/IManager.sol";
```

Group imports in this order when practical:

1. External interfaces.
2. External libraries and contracts.
3. Internal interfaces.
4. Internal libraries and contracts.
5. Test-only or script-only imports.

## Naming

- Contracts and libraries: `PascalCase`, for example `PositionManager` or `MathLib`.
- Interfaces: `I` prefix, for example `IPositionManager`.
- Test contracts: descriptive names ending in `Test`, for example `RequestGuardsTest`.
- Test files: `.t.sol`.
- Script files: `.s.sol`.
- Function parameters: leading underscore, for example `_amount` or `_recipient`.
- Internal and private helpers: leading underscore, for example `_requireNonZeroAddress`.
- Storage variables: `s_` prefix, for example `s_totalDebt`.
- Immutable variables: `i_` prefix, for example `i_asset`.
- Constants: `UPPER_SNAKE_CASE`.
- Custom errors: `ContractName__Reason`, for example `PositionManager__AddressZero`. Errors declared in an interface
  for a specific implementation must still use the implementation contract name prefix, not the interface name.
- Events: past-tense or state-change names, for example `PositionOpened` or `FeeRecipientSet`.

## Interfaces

Always put ABI declarations in interfaces:

- Structs.
- Enums.
- Errors.
- Events.
- External and public function signatures.

Implementation contracts should import and implement interfaces instead of redeclaring ABI declarations locally. Local
implementation-only structs are allowed only for internal execution caches that are not part of the ABI, event/error
surface, or integration contract.

Callback contracts are not exempt from this rule. Put callback calldata structs, callback/admin events, custom errors,
and external/public function signatures in a dedicated interface under `src/interfaces/`.

## Contract Structure

Prefer this order in implementation contracts:

1. SPDX and pragma.
2. Imports.
3. Contract-level NatSpec.
4. Constants and immutables.
5. Storage.
6. Constructor or initializer.
7. External and public state-changing functions.
8. External and public view functions.
9. Internal and private functions.

Callback entry points that perform transfers, approvals, swaps, or protocol calls are state-changing functions and
belong before public view getters.

For upgradeable or storage-split contracts, keep shared storage in a dedicated abstract storage contract. Preserve
storage layout carefully and document any layout change.

## NatSpec

Use NatSpec on contracts, interfaces, events, errors with non-obvious parameters, and every external or public function.

- Use `@title`, `@author`, `@notice`, and `@dev` on contracts when useful.
- Use `@notice` for user-facing behavior.
- Use `@dev` for security assumptions, call ordering, and integration constraints.
- Use `@param` and `@return` for external and public functions.

Keep NatSpec factual. Do not describe implementation details that can drift unless they are part of the external
contract.

## Validation

- Prefer custom errors over revert strings.
- Validate zero addresses at boundaries, using a small helper when repeated.
- Emit events for admin configuration changes and user-visible state transitions.
- Put checks before state changes unless a deliberate checks-effects-interactions pattern requires state first.
- Put state updates before external calls unless there is documented rationale, mitigation, and test coverage.

## Security Baseline

Always consider:

- ERC20 non-compliance, including missing return values.
- Fee-on-transfer, rebasing, and non-standard decimal tokens.
- Reentrancy through token hooks, callbacks, and integrated protocols.
- Approval races and stale allowances.
- Oracle staleness, manipulation, unit mismatch, and decimal mismatch.
- Rounding drift in shares, assets, and debt conversions.
- Access control misconfiguration.
- Direct `msg.sender` checks versus delegated or meta-transaction caller semantics.
- Paused state, emergency paths, and privileged role abuse.

Use `SafeERC20` for token transfers unless a dependency forces a different pattern. Avoid infinite approvals unless they
are justified and bounded by trusted integration assumptions.

## Tests

Write or update tests for behavior changes. For bug fixes, reproduce the failure first when practical.

- Use `setUp()` for shared fixtures.
- Use descriptive test names, for example `testRequestRevertsWhenAmountZero` or `testRequestWithMaxDebtCreatesRequest`.
- Assert exact custom errors with `abi.encodeWithSelector`.
- Check emitted state, balances, ownership, role effects, and nonce/id changes.
- Cover failure paths for auth, zero values, unsupported assets, stale or missing oracle data, and edge rounding.
- Use fuzz or invariant tests when behavior is arithmetic-heavy or state-machine-like.

## Scripts

- Use a `Config` struct and `_loadConfig()` helper for environment-driven scripts.
- Read environment variables explicitly with `vm.envAddress`, `vm.envUint`, and related helpers.
- Use `vm.startBroadcast()` and `vm.stopBroadcast()`.
- Do not use named return parameters in scripts.
- Separate deployment scripts from post-deploy admin/configuration scripts when the flow grows.

## Dependencies

- Use Soldeer through `forge soldeer` and `make install`.
- Do not edit files under `dependencies/`.
- Do not add dependencies unless the change needs them and the reason is explicit.
- Prefer existing OpenZeppelin, Foundry, and local helpers over new abstractions.

## Required Checks

After Solidity or config changes, run:

```bash
forge fmt --check
forge build
forge test
forge lint
```

For dependency changes, also run:

```bash
make install
forge remappings
```

Report exact commands and pass/fail outcomes. If a check cannot be run, state why.

## Change Discipline

- Keep changes surgical.
- Do not refactor adjacent code unless required for the requested change.
- Match existing style even if another style is personally preferred.
- Do not remove unrelated dead code; mention it separately.
- Never expose private keys, RPC secrets, API tokens, or deployment credentials.
- Stop and ask before deploying to a live network or using mainnet private keys.
