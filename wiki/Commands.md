# Command channel

Cerberus is controlled by writing **one line** into `ng_command.txt` in the terminal's
`Files` folder. `ProcessCommandFile()` runs on the 5-second timer, so a command takes
effect within 5 s — **no recompile, no restart**.

```powershell
# MT5
Set-Content "$env:APPDATA\MetaQuotes\Terminal\<MT5_ID>\MQL5\Files\ng_command.txt" "RESUME" -Encoding utf8
# MT4
Set-Content "$env:APPDATA\MetaQuotes\Terminal\<MT4_ID>\MQL4\Files\ng_command.txt" "RESUME" -Encoding utf8
```

The file is consumed on read. Unknown commands are logged as `WARNING: unknown command`.

## Control

| Command | Effect | MT5 | MT4 |
|---|---|:--:|:--:|
| `AT_ON` / `AT_OFF` | Toggle the terminal's **global** AutoTrading button via `user32.dll` | ✅ | ✅ |
| `PAUSE` | Manual pause (`NG_ManualPause`), survives restarts | ✅ | ✅ |
| `RESUME` | Clear the manual pause **and** a rule E pause | ✅ | ✅ |
| `CLOSEALL` | Close every order in the terminal, all magics | ✅ | ✅ |
| `RESETDAY` | Re-anchor the rule E daily baseline and lift a rule E pause | ✅ | ✅ |
| `ORACLE_ON` / `ORACLE_OFF` | Enable / disable the strategy head (`CB_OracleOn`) | ✅ | ✅ |
| `SYMON <sym>` / `SYMOFF <sym>` | Revive / disable a symbol (`CB_Off_<sym>`) | ✅ | — |

> `RESUME` is the **only** thing that clears a manual pause. A pause inherited on a new
> machine is the usual reason AutoTrading "will not stay on".

## Configuration (hot)

| Command | Effect |
|---|---|
| `SYMBOL <sym>` | Flatten and switch the traded symbol |
| `SET TP=60 GRID=120 LOT=0.10 FACTOR=1.0 MAXLEV=0` | Any subset; re-anchors the open basket's TP immediately |
| `PRESET <sym>` | Load that symbol's preset **and** switch to it |
| `SAVEPRESET` | Save the current config under the active symbol |
| `CONFIG` | Log the active configuration |
| `BSTOP <usd>` | Basket stop in USD, `0` = off |
| `EMAGATE ON\|OFF` | New-basket EMA gate |

All of these persist in GlobalVariables and survive a restart. See
[Configuration and presets](Configuration-and-Presets).

## Testing

| Command | Effect |
|---|---|
| `TEST=N` | Inject a fake USD High-impact event N minutes ahead, to watch the news pause fire |
| `BUY <sym> <lots>` / `SELL <sym> <lots>` | Open a manual position with magic `777999` |

> **Do not leave manual orders open during a soak.** They carry magic `777999`, no SL and
> no TP, and no strategy head manages them — they are orphans in the metrics. Use them
> only to test a guardian rule, and clear them with `CLOSEALL`.

## Order of operations

Always **close orders before turning AutoTrading off**. With AT off, both close and delete
fail — so `AT_OFF` on a live basket leaves it stranded. The correct sequence is
`CLOSEALL`, wait for confirmation in the log, then `AT_OFF`.

## Verifying a command landed

Read (punctually) the tail of `Cerberus_log.csv`, or `ng_status.json` → `last_action`.

> **Never `tail -f` anything under `Files\`.** It blocks the EA's `FileOpen` and log lines
> are silently lost — they only survive in the terminal journal under `MQL5\Logs\`, in
> local time, as `LOG FAIL`. On Windows, killing the monitor does not kill its `tail.exe`
> child: check with `Get-Process tail`.
