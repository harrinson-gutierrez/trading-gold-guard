# Architecture

Cerberus is a **single EA on a single chart** with two independent heads. It is not a
framework: there is one source file per platform, and the heads communicate only through
shared state (GlobalVariables and the guardian's pause flags).

## Execution model

Everything runs from two entry points, and both do almost the same work:

| | `OnTick()` | `OnTimer()` (every 5 s) |
|---|---|---|
| Guardian rules A–E | ✅ | ✅ |
| News / schedule evaluation | ✅ | ✅ |
| ORACLE grid | ✅ | ✅ |
| Panel refresh | ✅ | ✅ |
| Command file, feed refresh, volatility window | — | ✅ |
| Weekend pre-close flatten | — | ✅ |
| `ng_status.json` write | — | every 30 s |

**Why both.** A chart only ticks for its own symbol, so a symbol that Cerberus watches but
does not host would never be evaluated on ticks alone; the timer covers it. And the panel
is refreshed from `EventSetTimer`, not from ticks, because during the daily quote pause
tick-driven panels go blank exactly when you most want to read them.

The consequence is that the grid can run twice in the same second (a tick burst plus the
timer) before a fresh order appears in `PositionsTotal`. That is what
`Oracle_MinSecsBetweenAdds` (default 2 s) exists to prevent: without it a burst stacks
several levels pips apart and silently violates `GridSize`.

## The two heads

### Guardian

Scope: **every position in the terminal**, whatever magic opened it. This is deliberate —
it is how the guardian polices foreign EAs. Its powers:

- Close individual positions (rules A, B, D) or everything (rule E).
- Pause a single symbol (rule C) or all trading (news, manual).
- Toggle the terminal's **global** AutoTrading button through `user32.dll`
  (`PostMessageW(WM_COMMAND, 32851)` on MT5, `33020` on MT4).

Details: [Guardian rules](Guardian).

### ORACLE

Scope: its own two magics only.

| Magic | Role |
|---|---|
| `7799` | Engine A — BUY ladder when both engines are on |
| `9977` | Engine B — SELL ladder when both engines are on |
| `777999` | Manual `BUY`/`SELL` commands (guardian testing) |

Details: [ORACLE engine](Oracle-Engine).

## Persisted state

State lives in terminal **GlobalVariables**, so it survives a restart — which matters,
because loading new EA code requires restarting the terminal.

| GlobalVariable | Meaning |
|---|---|
| `NG_ManualPause` | Manual `PAUSE` is active — only `RESUME` clears it |
| `NG_DisabledByGuard` | The guardian turned AutoTrading off (news / rule E) |
| `CB_DisabledBySched` | The **scheduler** turned it off — a separate flag so news and schedule never fight over the button |
| `NG_DayDate` / `NG_DayStartBal` | Rule E daily baseline (`RESETDAY` re-anchors it) |
| `CB_OracleOn` | Strategy head enabled (default 1) |
| `CB_ovTP`, `CB_ovGrid`, `CB_ovLot`, `CB_ovFactor`, `CB_ovMaxLev`, `CB_ovBstop`, `CB_ovEmaGate` | Hot config overrides — see [Configuration](Configuration-and-Presets) |

The `NG_` prefix is legacy (the project was renamed from Spanish *Cerbero* / *NewsGuard*).
It is kept on purpose: renaming the variables would have orphaned live state mid-soak.

The active **symbol** override is a string, which GlobalVariables cannot hold, so it lives
in `ng_active_symbol.txt` instead.

> **Trap:** a stale `NG_ManualPause` survives a move to another machine. If AutoTrading
> refuses to come up on a fresh VPS, the guardian is re-disabling it every tick from an
> inherited pause. Read `ng_status.json`, not the log's INIT line, and send `RESUME`.

## Files

All under the terminal's `MQL5\Files\` (MT4: `MQL4\Files\`):

| File | Direction | Contents |
|---|---|---|
| `ng_command.txt` | in | One command per write, consumed within 5 s |
| `ng_status.json` | out | Full state every 30 s |
| `Cerberus_log.csv` | out | `gmt_date;action;detail` |
| `ff_cache.json` | out | Calendar cache, so a failed fetch is not a blind guardian |
| `symbol_presets.txt` | both | Per-symbol config presets |
| `ng_active_symbol.txt` | both | Active traded symbol |

`ng_status.json` is the integration surface: the [compare panel](Tools-and-Panels) and any
external report read it and never touch the terminal.

```json
{"ea":"Cerberus","version":"1.15","status":"RUNNING",
 "config":{"symbol":"XAUUSDm","tp":15,"grid":30,"lot":0.01,"factor":1.0,"maxlev":0},
 "basket_stop":{"usd":0,"hits_today":0},
 "balance":3836.33,"equity":3836.33,
 "closed_trades":5164,"win_rate_pct":58.8,"realized_pl":-555.59,
 "avg_win":0.43,"avg_loss":-0.88,
 "heads":{"oracle":"ON","baskets":[]}}
```

Note `avg_win` 0.43 against `avg_loss` −0.88 in that real sample: a 58.8 % win rate with a
0.49 ratio still loses money. This is why the panel reports both — see
[Safety model](Safety-Model).
