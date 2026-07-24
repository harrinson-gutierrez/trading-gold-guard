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

## Two engines, one side at a time

| Magic | Side (both engines on) |
|---|---|
| `7799` (A) | **SELL** |
| `9977` (B) | **BUY** |

As measured on Oracle (the reverse of its own cosmetic "Engine A [BUY]" labels). With the
fade, a falling market makes the fade side BUY, so the BUY engine (9977) arms; a rising
market arms the SELL engine (7799).

**Never both sides at once.** Before an engine arms a fresh basket, any basket the *other*
engine still holds is closed (`FLIP_CLOSE`). A fade flip leaves the book on one side only.
Without this, Cerberus carried a hedged SELL+BUY dead weight — measured 2026-07-24: a 3-level
SELL and a 2-level BUY open at the same time, floating −$5 that never cleared, while Oracle
held a single 1-level basket.

## Cadence — re-arm immediately

A closed basket opens the next one on the following tick, as long as the fade side is valid —
exactly like Oracle, which books its many small wins by re-arming at once. A HiLo-flip gate
was tried and removed: it waited for a fresh signal edge before re-arming, which starved the
win-booking to ~28 basket cycles against Oracle's ~72 in a comparable window.

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

## Exit — hybrid, like Oracle

Two exits run together; whichever hits first wins.

1. **Individual TP per order.** Each order carries its own server-side TP at `TakeProfit_Pips`
   from *its own* open price. Shallow orders scalp their +15 pips and close independently.
2. **Basket-average close at avg + TP / n.** The whole basket closes when its **total**
   floating equals one TP unit — i.e. the volume-weighted average is `TakeProfit_Pips ÷ n`
   pips in profit, **not** the full `TakeProfit_Pips`. A deep 5-level ladder therefore clears
   on a 3-pip bounce, not an unreachable 15.

The second point is the one that keeps the book lean. Measured 2026-07-24: Oracle cleared a
6-level basket at avg + 3.3 pips and a 3-level one at avg + 13.7 — both about one TP unit of
*total* profit, regardless of depth. Before this fix Cerberus closed the basket at avg + full
TP, so a deep ladder never reached its own target and floating piled to −$16.54; with `TP / n`
it fell to −$1.70, matching Oracle's lean book.

The individual TPs live on the broker, so they survive a terminal crash; the basket-average
close is evaluated by the EA each tick.

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
