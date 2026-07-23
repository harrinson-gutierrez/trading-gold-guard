# ORACLE engine

ORACLE replicates the Oracle 2.0 black-box bot — measured live, side by side, not guessed —
**plus the account-level net that bot did not have**. The entry logic was worth copying, the
absence of a stop was not.

## Signal — it FADES the market

Two exponential indicators on M1 (`Signal_TF = 1`):

- **Gann HiLo(3, EMA)** (`HiLo_Period`, `HiLo_Method = 1`) — the trend/breakout side. Close
  above the EMA of the last N highs → up; below the EMA of the last N lows → down; in
  between it keeps the previous side.
- **MA(34, EMA on the Open)** (`MA_Period`, `MA_Method = 1`, `MA_AppliedPrice = 1`) — the
  tie-breaker used only before the HiLo has a side (start-up).

**The entry is the OPPOSITE of the HiLo side.** Oracle fades the market: it buys a falling
market and sells a rising one. This was confirmed live on 2026-07-23 — Oracle bought the dip
(@4042.6 → 4042.2) and sold the rebound (@4044.0), while the old trend-following Cerberus was
BUY at the very same instant. They were exact opposites; inverting the entry aligned them.
Oracle does this with `InpHILOFilterInverter=false`, so Cerberus fades at `HiLo_Invert` off
too.

> The indicator is not miscalculated — the error was conceptual. The HiLo computes the trend
> side correctly; Oracle simply *fades* it instead of following it.

## Two engines, one ladder per side

| Magic | Side (both engines on) |
|---|---|
| `7799` (A) | **SELL** |
| `9977` (B) | **BUY** |

As measured on Oracle (the reverse of its own cosmetic "Engine A [BUY]" labels). With the
fade, a falling market makes the fade side BUY, so the BUY engine (9977) arms; a rising
market arms the SELL engine (7799). `Engine_A_Sell` / `Engine_B_Buy` toggle them.

## Cadence — one new basket per HiLo flip

A closed basket does **not** re-arm every tick the side is still valid. It waits for the raw
HiLo to **flip** (a fresh signal edge): each contiguous stretch of one HiLo side is an
"epoch", and an engine may arm at most one new basket per epoch.

This is Oracle's real cadence governor. Before it, the HiLo persisting a side forever made
Cerberus re-arm the second it closed a basket — measured ~22 baskets/10 min. With the flip
gate, that dropped to ~3, against Oracle's ~5 in the same window. (Oracle's own
`InpOpenOneCandle` was turned off during the test, confirming the flip — not a per-candle cap
— is what governs its rhythm.)

## The grid

On an adverse move of `GridStep_Pips`, the engine adds a level at **constant lot**
(`Lot_Factor = 1.0`). Additive, **not** martingale — confirmed by Oracle opening every level
at 0.01 (17 BUY + 20 SELL observed, zero 0.02/0.04).

### The anchor

The next level must open a full `GridStep` **beyond the deepest level reached** — the
basket's low for a BUY ladder, its high for a SELL ladder — not the newest level by time.
With second-resolution timestamps and rebounds, the newest level is often not the extreme,
which let adds stack pips apart and bypass the gate (measured 2026-07-20: 17 of 20 adds
violated it, 21 levels instead of ~4).

### Add throttle

`MinSecs_BetweenAdds = 2`. Both `OnTick` and `OnTimer` run the grid, so a tick burst could
add several levels in one second before the fresh order appears. The throttle keeps the
spacing honest.

## Exit

One **shared, server-side take profit** on every order of the basket, `TakeProfit_Pips` from
the volume-weighted average, re-anchored to the new average on every add. The whole ladder
closes at once. Because the TP lives on the broker, it survives a terminal crash, and it is
re-anchored live when you change `TP` with a `SET` command.

## Risk net

| Input | Default | What it bounds |
|---|---|---|
| `MaxGrid_Levels` | 0 | Hard cap on levels (0 = use the proportional cap) |
| `Capital_Base` | 1000 | **Declared** capital for the proportional cap |
| `Capital_PerLevel` | 180 | One level per N dollars of declared capital |
| `BasketStop_USD` | 0 (off) | Cut the basket at −N USD floating (see [Guardian](Guardian)) |
| `MaxLot_Total` | 99.0 | Hard total-lot cap |
| `MaxSpread_Points` | 240 | Skip entries/adds above N points of spread |

**Why declared capital, not live balance.** Reading the live balance would make the depth
cap drift as P/L moves. A declared number keeps it predictable: $1 000 → ~5 levels.

## Pip scale

For the strategy, **1 pip = `Point*10`**, which on XAUUSDm is **$0.01**. So `TP=15 / GRID=100`
is a 15-cent target and a $1.00 step.

## What was deliberately not copied

- **`InpCloseAllTrades=true`** — Oracle flattens its basket when the EA is turned off.
  Cerberus does not, on purpose: a basket should survive a restart. (The trade-off is real —
  a terminal left off with a live basket is unguarded until it comes back.)
- **No net at all.** Oracle 2.0 runs with no basket stop and a 40 % drawdown tolerance. A
  faithful replica of that half lost **−99.99 %** in a 2.4-year backtest *despite 97 %
  winning cycles*. Cerberus keeps rule E (and the optional basket stop). See
  [Safety model](Safety-Model) for why a win rate is the wrong metric.
