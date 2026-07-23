# Guardian rules

The guardian is the always-on head. It evaluates on **every tick and every 5-second
timer**, and it acts on **every position in the terminal**, not just the ones ORACLE opened
— that is how it polices other EAs on the same account.

v2.0 stripped the guardian to the two nets the owner kept on purpose. Everything that closed
a position *early* was removed, because realising a loss breaks the average the shared
basket TP depends on — the mechanism that pushed the average loss to −$3.58 against Oracle's
−$1.78 while winning *more* often.

## Connection guard (before anything else)

```
if (!IsConnected() || balance <= 0) return;
```

After a restart or a broker disconnect, account values arrive as `0`. Without this guard,
rule E would read a "loss" the size of its own baseline and pause on a false positive.

## Rule E — daily loss (kept)

`DailyLoss_USD = 200`. When equity is down that much from the day's baseline, close
**everything** and pause until an explicit `RESUME`.

The baseline lives in `NG_DayDate` / `NG_DayStartBal`, so it survives restarts. After a demo
top-up the baseline is stale — send `RESETDAY` to re-anchor it, otherwise the deposit reads
as a gain and the day's loss budget is wrong.

This is the **account-level** net. With the basket stop off (default), it is the *only*
automatic net, and it only runs while the EA runs.

## Basket stop — optional (kept, default off)

`BasketStop_USD = 0`. When a basket's floating P/L falls below −N USD, cut it, then hold off
re-arming that engine for `BasketStop_CooldownMin = 30` minutes.

`BasketStop_ServerSL = true` mirrors the stop as a **broker-side SL** on every position of
the basket, sized so the whole basket losing at once approximates `BasketStop_USD`. It
executes even when our own close orders are being rejected (measured 2026-07-20: the broker
refused every close retry for ~2 h while the basket kept moving).

> ⚠️ **At `BasketStop_USD = 0` the broker-side SL is off too** — it is attached only when
> the stop is armed. Running with the stop off leaves rule E as the sole net, and rule E
> does not run if the terminal is off. For any unattended run, set it above zero.

## News windows — block new entries only

The guardian fetches the ForexFactory weekly calendar
(`nfs.faireconomy.media/ff_calendar_thisweek.json`) every `News_RefreshMinutes = 60` and,
from `News_MinutesBefore = 30` to `News_MinutesAfter = 45` around every **High**-impact
event, **stops opening new baskets**. Open baskets are left alone — this matches Oracle's
`NewsAction=0` (block, do not close).

**All currencies, not just USD.** Oracle's feed has no country filter; it pauses on any
High-impact event. Measured 2026-07-23: this week had **0** USD-High events but **11** High
across CAD/GBP/AUD/EUR (including the ECB), which Oracle respected and the old USD-only
Cerberus ignored. Gold reacts to every major central bank, so v2.0 watches them all.

Two operational facts:

- The URL must be whitelisted **by hand** in Tools → Options → Expert Advisors. MetaTrader
  stores that list encrypted, so it cannot be deployed from a file. Without it the fetch
  fails with error 4014.
- The feed answers **HTTP 429** after a burst of terminal restarts. The guardian falls back
  to `ff_cache.json` and recovers on its own — `"feed":"disk cache"` after a restart is the
  expected state, not an alarm.

`TEST=N` injects a fake event N minutes ahead to verify the block end to end.

## Display only — never blocks, never closes

- **Hour-risk band**: the gold risk table (VERY LOW … VERY HIGH by UTC band) is shown on the
  panel and published to `ng_status.json` as `hour_risk`, flagged `blocks:false`. In v1.x it
  gated entries; in v2.0 it is informational. (Measurement showed the basket-stop damage
  clustered at 02–03 UTC, a band the table calls VERY LOW — the filter was blocking the
  wrong hours.)
- **Weekly-close warning**: `Show_SessionWarning` shows `WEEKLY CLOSE SOON` in the last
  `SessionWarn_Min = 5` minutes before the Friday close (`SessionClose_HourGMT = 21`). It
  does **not** flatten. The weekend-gap risk it warns about is real and now a manual call:
  send `CLOSEALL` before the close if you want to be flat.

## Rejection backoff

| Input | Rejection | Reaction |
|---|---|---|
| `ServerBlock_Min = 10` | **Server** refuses trading (market closed / disabled) | Pause entries 10 minutes |
| `LocalBlock_Sec = 10` | **Terminal** not armed yet (err 4109/4110/4111) | Pause 10 seconds |

The split matters: the local rejection clears by itself seconds after an init, so spending
the full server backoff on it would idle the EA for no reason.

> Persistent **4109** through restarts and `AT_ON` is not a backoff problem: the EA's own
> "Allow live trading" checkbox (F7 → Common) is off, and the journal says *trade operations
> not allowed by settings*.

## Warm-up

`OpenWarmup_Min = 3` vetoes entries in the first minutes after a session reopens, because
thin opening quotes are not real moves.

## `AT_OFF` observability

If the global AutoTrading button is off, the strategy is idle. v2.0 makes that loud: the
status JSON reports `"status":"AT_OFF"` and the log prints one `AT_OFF` line a minute, so a
button left off by a previous session (the terminal remembers it across restarts) can never
masquerade as a quiet market.

> **Order of operations:** always close orders **before** turning AutoTrading off. With AT
> off, close and delete both fail.
