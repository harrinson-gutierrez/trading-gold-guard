# ORACLE engine

ORACLE is a faithful replica of the Oracle 2.0 black-box bot, **plus the risk net that bot
did not have**. The split is deliberate: the entry logic was worth copying, the absence of
a stop was not.

## Signal

Two indicators on M1 (`Oracle_TF`):

- **Gann HiLo(3)** (`Oracle_HILOPeriod`) — the direction source. It compares the last close against the SMA of the previous N highs (down-flip) and the SMA of the previous N lows (up-flip); in between it *keeps the previous side*. This is a trend indicator, so it always carries a side. It is not a breakout that rarely fires.
- **EMA(34)** (`Oracle_MaPeriod`, `Oracle_MaMethod=1`) — a confirming filter. Only the HiLo side that agrees with price-vs-EMA is taken.

The result is a continuous direction, which is why the bot trades often.

## Two engines, one ladder per side

| Magic | Both engines on | Single engine on |
|---|---|---|
| `7799` (A) | BUY signals only | Both sides, one basket at a time |
| `9977` (B) | SELL signals only | Both sides, one basket at a time |

Running both gives one ladder per side simultaneously, exactly like the original Oracle
2.0. `Oracle_EngineA` / `Oracle_EngineB` toggle them.

## The grid

On an adverse move of `GRID` pips, the engine adds a level at **constant lot**
(`FACTOR = 1.0`). This is an **additive** grid, not a martingale: no ×2 lot doubling.

### The anchor (a fixed bug worth knowing)

The next level must open a full `GridSize` **beyond the deepest level reached** — the
basket's low for a BUY ladder, its high for a SELL ladder:

```cpp
if (loPrice == 0 || op < loPrice) loPrice = op;
if (hiPrice == 0 || op > hiPrice) hiPrice = op;
...
lastPrice = (dir > 0) ? loPrice : hiPrice;   // extreme, NOT newest-by-time
```

The original code anchored to the level opened last **in time** (`POSITION_TIME`). With
second-resolution timestamps and price rebounds, the newest level is frequently not the
extreme — so adds stacked a few pips apart and silently bypassed the `GridSize` gate.
Measured 2026-07-20: **17 of 20 adds** violated the gate, inflating a basket that should
have held ~4 levels to **21**. Both builds now anchor on the extreme.

### Add throttle

`Oracle_MinSecsBetweenAdds = 2`. Both `OnTick` and `OnTimer` run the grid, so a tick burst
could add several levels in the same second, before the fresh order appears in
`PositionsTotal`. The throttle is what keeps the spacing honest.

## Exit

One **shared, server-side take profit** on every order of the basket, placed `TP` pips
from the volume-weighted average open price, and **re-anchored to the new average on every
add**. The whole ladder therefore closes at once.

Because the TP lives on the broker, it survives a terminal crash — and it is re-anchored
live when you change `TP` with a `SET` command, not only on the next add.

## Risk net (what Oracle 2.0 lacked)

| Input | Default | What it bounds |
|---|---|---|
| `Oracle_MaxGridLevels` | 0 | Hard cap on levels per engine (0 = use the proportional cap) |
| `Oracle_BaseCapital` | 1000 | **Declared** capital for the proportional cap |
| `Oracle_DollarsPerLevel` | 180 | One level per N dollars of declared capital |
| `Oracle_BasketStopUSD` | 0 (off) | Cut the basket at −N USD floating |
| `Oracle_BasketStopCooldownMin` | 30 | Minutes before re-arming on that engine |
| `Oracle_UseServerSL` | true | Mirror the basket stop as a broker-side SL per position |
| `Oracle_MaxLot` | 99.0 | Hard total-lot cap |
| `Oracle_MaxSpread` | 240 | Skip entries above N points of spread |

**Why declared capital, not live balance.** Reading the live balance would make the depth
cap drift as P/L moves, so the allowed grid depth would change mid-basket. A declared
number keeps it predictable: $1 000 → 5 levels, $4 000 → 22 (Oracle itself ran ~22 levels
on a $4 000 cushion, hence ~$180/level).

**Why a server-side SL too.** On 2026-07-20 the basket stop fired correctly, and then the
broker refused every close retry for about two hours while the basket kept moving — about
$50 worse than the stop intended. A broker-side SL executes even when our close orders are
being rejected. It is sized so the whole basket losing at once approximates
`Oracle_BasketStopUSD`, and it is a no-op when the basket stop is off.

**Sizing the basket stop.** Roughly **2.5× the average basket win**. At a 72 % win rate,
break-even sits at 2.57×, so a tighter stop turns a winning cadence into a losing one.
First real trigger cut a basket at −$44.87 and avoided roughly −$98.

## The cadence gate

`Oracle_NewBasketNeedsEMA` requires the EMA to agree with the HiLo side before arming a
**new** basket. Adds are never gated.

Because the HiLo persists a side forever, without this gate Cerberus re-arms a basket the
same second it closes one. Measured 2026-07-21: **98.9 % of the time in market, 26 baskets
per 21 minutes**, against Oracle 2.0's 72.2 % and 11. With the gate on, entries dropped to
0.27/min. Hot-switchable with `EMAGATE ON|OFF` so it can be A/B'd without a restart.

## Regime filter (optional, off)

`Oracle_UseRegimeFilter` vetoes entries and adds that fade a strong H1 trend — a soft
block, twin of the hour filter, that never closes anything.

- `Oracle_RegimeADX = 27` — ADX(14) H1 above this counts as a strong trend; the side fading it (DI+ vs DI−) is blocked.
- `Oracle_RegimeATRDist = 3.0` — price further than N × ATR(14) H1 from the EMA200 H1, on the side the signal would fade, also blocks. Set 0 for ADX only.

## Pip scale

For the strategy, **1 pip = `Point*10`**, which on XAUUSDm is **$0.01**. So the production
preset's `TP=15 / GRID=30` means a 15-cent target and a 30-cent step. The guardian's rule
A uses a different scale (`PipSizeOverride = 0.1`, i.e. $0.10) — the two are intentionally
independent.

> Crypto does not inherit these numbers. On BTCUSDm "300 pips" is a $30 move, and the ~$10
> spread eats targets that work on gold. Per-position rules calibrated for gold do not
> transfer.

## What was deliberately not copied

Oracle 2.0 runs with **no basket stop and a 40 % drawdown tolerance**. A faithful replica
of that half lost **−99.99 %** in a 2.4-year backtest *despite 97 % winning cycles*. The
entry logic was kept; the missing net was not. See [Safety model](Safety-Model) for why a
win rate is the wrong metric here.
