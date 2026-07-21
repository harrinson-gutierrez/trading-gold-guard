# Guardian rules

The guardian is the always-on head. It evaluates on **every tick and every 5-second
timer**, and it acts on **every position in the terminal**, not just the ones ORACLE
opened — that is how it polices other EAs running on the same account.

Every rule below exists because a specific loss happened. None of them are theoretical.

## Connection guard (before anything else)

```
if (!TERMINAL_CONNECTED || equity <= 0 || balance <= 0) return;
```

After a restart or a broker disconnect, account values arrive as `0`. Without this guard,
rule E would read a "loss" the size of its own baseline and pause the system on a false
positive — measured, then fixed.

## Rule A — adverse pips per position

`MaxAdversePips = 300`, floored by `RuleA_xATR = 15 × ATR(M1)`.

Closes any position that has moved N pips against its entry. The ATR floor makes the rule
**per symbol and volatility-relative**: 300 pips on gold is a real $30 move, but on
BTCUSDm it is a $30 wiggle. The effective limit is
`max(MaxAdversePips, RuleA_xATR × ATR ÷ pip)`, so a fixed number calibrated for gold never
misfires on a different instrument.

> Pip scale trap: XAUUSDm quotes with **3 decimals**, so `_Point*10` makes a "pip" $0.01 —
> ten times tighter than intended. `PipSizeOverride = 0.1` keeps the guardian's pip at
> $0.10.

## Rule B — margin protection

`MinMarginLevelPct = 200`.

While the margin level is below the threshold, close the **worst** position (P/L + swap),
recompute, and repeat — capped at 10 iterations per pass so a broken close cannot spin.
It stops as soon as the level recovers or a close fails.

## Rule C — volatility circuit breaker (per symbol)

| Input | Default | Trigger |
|---|---|---|
| `VolSpikeATRmult` | 5 | One M1 candle larger than 5 × ATR(20) |
| `VolWindowATRmult` | 8 | A 5-candle (`VolWindowM1Bars`) range larger than 8 × ATR |
| `VolSpikePips` | 0 (off) | Absolute variant, in fixed pips |
| `VolPauseMinutes` | 3 | Renewable cooldown after the **last** violent candle |
| `CloseOnVolSpike` | false | Also close that symbol's basket |

Rule C became **per symbol** in v2.7 after three measured cases where a rollover spike on
one quiet pair wiped the positions of all six symbols at once. A spike on EURUSD now
pauses EURUSD and nothing else.

`CloseOnVolSpike` decides the philosophy: `true` cuts at the start of the move, `false`
only stops adding to it. It currently runs `false`, so the volatility breaker is a brake,
not a scissor.

## Rule D — USD loss per position

`MaxLossPerTradeUSD = 60`. Closes any single position losing more than N USD, counting
swap. This is the backstop for the case rule A misses because price gapped rather than
travelled.

## Rule E — daily loss

`MaxDailyLossUSD = 200`. Closes **everything** and pauses until an explicit `RESUME`.

The baseline is stored in `NG_DayDate` / `NG_DayStartBal`, so it survives restarts. After
a demo top-up the baseline is stale — send `RESETDAY` to re-anchor it, otherwise the
deposit reads as a gain and the day's real loss budget is wrong.

## News windows

The guardian fetches the ForexFactory weekly calendar
(`nfs.faireconomy.media/ff_calendar_thisweek.json`) every `FeedRefreshMinutes` = 60 and
pauses trading from `MinutesBefore` = 30 to `MinutesAfter` = 30 around every **High**
impact event touching a watched currency. `ClosePendingOrders` also deletes pendings.

Two operational facts:

- The URL must be whitelisted **by hand** in Tools → Options → Expert Advisors. MetaTrader stores that list encrypted, so it cannot be deployed from a file. Without it the fetch fails with error 4014.
- The feed answers **HTTP 429** after a burst of terminal restarts. The guardian falls back to `ff_cache.json` and recovers on its own — do not restart in bursts to "fix" it. `"feed":"disk cache"` in the status JSON is the expected state after a restart, not an alarm.

Currencies are derived from `PairsToWatch`. Keep it in sync with what ORACLE actually
trades: they drifted apart once, watching five FX pairs while trading ETH.

## Soft entry gates

These block **new entries** and never close anything.

### Hour filter

`UseHourFilter` + `HourBlockRisk = 3` blocks entries in the VERY HIGH bands of the gold
risk table (08:00–09:30 and 12:00–15:30 UTC). `HourBlockRisk = 2` also blocks MEDIUM.

### Scheduler

`UseSchedule` (off by default) adds up to four user-defined UTC `HH:MM` windows plus
per-weekday flags. Two modes:

| `SchedKillAT` | Behaviour |
|---|---|
| `false` (soft, default) | Only Cerberus stops opening. Other EAs untouched. |
| `true` (hard) | On entering a window: close all orders and turn the **global** AutoTrading button off, affecting every EA. Re-enabled on exit. |

Hard mode uses its own `CB_DisabledBySched` flag so it can never be confused with a news
pause or a manual one.

### Session filter

`UseSessionFilter` asks the broker (`SymbolInfoSessionTrade`) whether the symbol is
tradable right now, instead of assuming. This matters because FX and metals pause on
Exness during the **21:00–22:00 GMT rollover**: every order returns retcode 10018, and the
thin quotes in that window produce spikes that are not real moves.

`PreCloseCloseMin = 5` flattens baskets before a session close.
`PreCloseWeekendOnly = true` restricts that to the **weekend** close only: research said
flatten for the weekend gap (a grid hanging 49 hours across it is pure gap risk), while
the nightly rollover only needs entries blocked. `WeekendGapHours = 6` is what
distinguishes them, so BTC's daily midnight close is not mistaken for a weekend.

`Oracle_OpenWarmupMin = 15` vetoes entries in the first minutes after a session reopens,
because thin opening quotes spike the ATR that rule C measures against.

## Rejection backoff

| Input | Rejection | Reaction |
|---|---|---|
| `SrvBlockBackoffMin = 10` | **Server** says 10026 (AutoTrading disabled by server) | Pause that symbol 10 minutes |
| `LocalBlockBackoffSec = 10` | **Terminal** says 10027 (this EA not armed yet) | Pause that symbol 10 seconds |

The split matters: the local rejection clears by itself seconds after an init, so spending
the full server backoff on it would idle the EA for no reason. Before this split, a broker
block produced thousands of retry attempts per minute.

> On MT4 the local-rejection error is **4109**. If it persists through restarts and
> `AT_ON`, it is not a backoff problem: the EA's own "Allow live trading" checkbox
> (F7 → Common) is off, and the journal says *trade operations not allowed by settings*.

## Commands that touch the guardian

`PAUSE`, `RESUME`, `CLOSEALL`, `RESETDAY`, `AT_ON`, `AT_OFF`, `TEST=N` — see
[Command channel](Commands).

> **Order of operations:** always close orders **before** turning AutoTrading off. With
> AT off, close and delete both fail.
