# Morpho Midnight Levered Looping

Atomic leverage open and close callbacks for Morpho Midnight.

`MidnightLeverageCallback` lets a borrower, or their authorized keeper, open a leveraged position by taking a resting
lender buy offer, then close or reduce that position through `Midnight.repay()`. Swap calldata is supplied live in the
same transaction, so the contract never relies on stale resting-order swap parameters.

> [!WARNING]
> These contracts are unaudited and provided as-is. Review carefully before use.

## Design Choices

- One callback contract handles both opening and closing leveraged positions.
- Each callback invocation targets one collateral index.
- Multi-collateral positions are wound and unwound through Midnight `multicall` by building the individual `take` or
  `repay` calldata beforehand.
- Swap routers must be explicitly allowlisted by the owner.
- Swap output is measured by token balance delta, not router return data.
- Permit2 witness signatures bind token pulls to the market, collateral, router, swap calldata, and slippage limits.
- Empty signatures fall back to plain ERC-20 `transferFrom` for simpler self-submitted flows.
- The callback refunds residual token balances so it should not hold borrower funds between calls.

## Repo Structure

```text
src/                         Production contracts
src/interfaces/              ABI-facing structs, events, errors, and interfaces
script/                      Deployment scripts
test/                        Foundry tests
test/mocks/                  Test mocks
dependencies/                Soldeer-managed dependencies
```

## Getting Started

Clone the repo:

```bash
git clone https://github.com/mgnfy-view/morpho-midnight-levered-looping.git
cd morpho-midnight-levered-looping
```

Install dependencies:

```bash
make install
```

Build:

```bash
make fbuild
```

Run tests:

```bash
make ftest
```

Run formatting:

```bash
make format
```

## Deployment

Copy the environment file and fill in the values:

```bash
cp .env.example .env
```

Simulate deployment:

```bash
make deploy-callback-simulate
```

Broadcast and verify:

```bash
make deploy-callback-broadcast
```

## Contact

- Linktree: [mgnfy.view](https://linktr.ee/mgnfy.view)
