# MinimumPerps: Invariant Fuzzing Suite

Submission keyword: **clear screen**

A Foundry invariant testing suite for the minimal perpetual futures exchange in `src/`
(original: https://github.com/owenThurm/PerpsFuzzingChallenge).

## Setup

```bash
git submodule update --init --recursive   # forge-std v1.17.0, OpenZeppelin v4.9.6
forge build
```

> OpenZeppelin is pinned to **v4.9.6**. The contracts do not compile against OZ v5
> (`Ownable2Step` constructor). If you received this as a zip without `lib/`, run
> `forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v4.9.6 --no-git`.

## Run

```bash
forge test --mc MinimumPerpsInvariants   # invariant campaign (failing invariants = bugs)
forge test --mc BugPoCs -vv              # deterministic PoC per bug (pass = bug present)
forge test --mc MinimumPerpsTest         # original unit tests
```

## Layout

| File | Purpose |
|---|---|
| `test/invariant/Handler.sol` | Bug report (top-of-file comment), fuzz actions and ghost variables |
| `test/invariant/Invariants.t.sol` | Deployment and the 10 invariants |
| `test/invariant/BugPoCs.t.sol` | Minimal reproduction for every bug found |

The handler drives LP `deposit`/`withdraw`, trader `increasePosition`/`decreasePosition`,
keeper `liquidate`, BTC price moves (±20% per step), time warps (with feed refresh) and
borrowing-rate changes. It uses 2 LPs, 3 traders and a separate liquidator.

## Invariants

| # | Invariant | Result |
|---|---|---|
| 1 | `netOI <= depositedLiquidity * collateralPrice / 2` | **Broken**: Bug 1, Bug 7 |
| 2 | `collateralWithdrawn <= collateralDeposited` (profit excluded, per trader) | Holds (1000 runs × 200 calls) |
| 3 | `totalCollateral == Σ position collateral` | **Broken**: Bug 5 |
| 4 | `openInterest* == Σ positions` | **Broken**: Bug 6 |
| 5 | A freshly opened position respects max leverage | **Broken**: Bug 2 |
| 6 | Solvency: `balance >= totalDeposits + Σ collateral` | Holds |
| 7 | Traders always receive their full realized profit | Holds |
| 8 | `totalAssets()` never reverts | Holds |
| 9 | Every position can be exited (closed or liquidated) | **Broken**: Bug 3 |
| 10 | Fees ≥ collateral ⇒ position is liquidatable | **Broken**: Bug 4 |

## Bugs found

| # | Severity | Summary |
|---|---|---|
| 1 | High | Utilization check reserves longs at current value, so OI can exceed 50% after a price drop |
| 2 | High | `increasePosition` never enforces `maxLeverage`; positions are liquidatable on open |
| 3 | Critical | Insolvent liquidation underflows (`collateralAmount = 0; collateralAmount -= loss`), so bad debt can never be liquidated |
| 4 | High | `isPositionLiquidatable` subtracts token-denominated fees from a USD value, so fees are ignored and positions get stuck |
| 5 | Medium | `totalCollateral` is never decremented |
| 6 | Low | Rounding up long tokens on partial close deletes the position but leaves orphaned OI |
| 7 | Medium | Profit payouts drain liquidity with no utilization check or ADL |

Root cause, impact and suggested fix for each are in the comment at the top of
`test/invariant/Handler.sol`.
