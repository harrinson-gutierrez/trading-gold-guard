# Architecture

Cerberus is a **single EA on a single chart** with two independent heads. It is not a
framework: one source file, and the heads communicate only through shared state
(GlobalVariables and the guardian's pause flags).

## Execution model

Everything runs from two entry points:

| | `OnTick()` | `OnTimer()` (every 5 s) |
|---|---|---|
| Rule E + basket stop | ✅ | ✅ |
| News evaluation (tracking) | ✅ | ✅ |
| ORACLE grid | ✅ | ✅ |
| Panel refresh | ✅ | ✅ |
| Command file, feed refresh | — | ✅ |
| `ng_status.json` write | — | every 30 s |

**Why both.** The panel is refreshed from `EventSetTimer`, not ticks, because during the
daily quote pause tick-driven panels go blank exactly when you most want to read them.

The consequence is that the grid can run twice in the same second (a tick burst plus the
timer) before a fresh order appears in `OrdersTotal`. That is what `MinSecs_BetweenAdds`
(default 2 s) prevents: without it a burst stacks several levels pips apart and violates
`GridStep`.

## The two heads

### Guardian

Scope: **every position in the terminal**, whatever magic opened it — that is how it polices
foreign EAs. Its powers in v2.0:

- Close everything (rule E) or cut a single basket (basket stop).
- Pause all trading (news block, manual pause).
- Toggle the terminal's **global** AutoTrading button through `user32.dll`
  (`PostMessageW(WM_COMMAND, 33020)`).

Details: [Guardian rules](Guardian).

### ORACLE

Scope: its own two magics only.

| Magic | Role (both engines on) |
|---|---|
| `7799` | Engine A — **SELL** ladder |
| `9977` | Engine B — **BUY** ladder |

Details: [ORACLE engine](Oracle-Engine).

## Persisted state

State lives in terminal **GlobalVariables**, so it survives a restart — which matters,
because loading new EA code requires restarting the terminal.

| GlobalVariable | Meaning |
|---|---|
| `NG_ManualPause` | Manual `PAUSE` is active — only `RESUME` clears it |
| `NG_DisabledByGuard` | Legacy news lock (cleared on init in v2.0; news no longer touches the button) |
| `NG_DayDate` / `NG_DayStartBal` | Rule E daily baseline (`RESETDAY` re-anchors it) |
| `CB4_OracleOn` | Strategy head enabled (default 1) |
| `CB4_hiloSide` | Persisted Gann HiLo side, so the fade/cadence state resumes correctly after a restart |
| `CB4_ovTP`, `CB4_ovGrid`, `CB4_ovLot`, `CB4_ovFactor`, `CB4_ovMaxLev`, `CB4_ovBstop` | Hot `SET`/`BSTOP` overrides |

The `NG_` prefix is legacy (the project was renamed from Spanish *Cerbero*). It is kept on
purpose: renaming the variables would orphan live state mid-soak.

> **Trap:** a stale `NG_ManualPause` survives a move to another machine. If AutoTrading
> refuses to come up on a fresh VPS, the guardian is re-disabling it every tick from an
> inherited pause. Read `ng_status.json`, not the log's INIT line, and send `RESUME`.

## Files

All under the terminal's `MQL4\Files\`:

| File | Direction | Contents |
|---|---|---|
| `ng_command.txt` | in | One command per write, consumed within 5 s |
| `ng_status.json` | out | Full state every 30 s |
| `Cerberus_log.csv` | out | `gmt_date;action;detail` |
| `ff_cache.json` | out | Calendar cache, so a failed fetch is not a blind guardian |

`ng_status.json` is the integration surface: the [compare panel](Tools-and-Panels) and any
external report read it and never touch the terminal.

```json
{"ea":"Cerberus4","version":"2.00","status":"RUNNING",
 "hour_risk":{"band":"MEDIUM","level":2,"blocks":false},
 "config":{"symbol":"XAUUSDm","tp":15,"grid":100,"lot":0.01,"maxlev":0},
 "basket_stop":{"usd":0,"hits_today":0},
 "balance":1000.60,"equity":1000.60,
 "closed_trades":1450,"win_rate_pct":66.5,"realized_pl":-1010.87,
 "avg_win":0.76,"avg_loss":-3.58,
 "heads":{"oracle":"ON","baskets":[]}}
```

Note `avg_win` 0.76 against `avg_loss` −3.58 in that real sample: a 66.5 % win rate still
loses money. The panel reports both — see [Safety model](Safety-Model).
