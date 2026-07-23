# Command channel

Cerberus is controlled by writing **one line** into `ng_command.txt` in the terminal's
`Files` folder. `ProcessCommand()` runs on the 5-second timer, so a command takes effect
within 5 s — **no recompile, no restart**.

```powershell
Set-Content "$env:APPDATA\MetaQuotes\Terminal\<MT4_ID>\MQL4\Files\ng_command.txt" "RESUME" -Encoding ascii -NoNewline
```

The file is consumed on read. Unknown commands are logged as `WARNING: unknown command`.

## Control

| Command | Effect |
|---|---|
| `AT_ON` / `AT_OFF` | Toggle the terminal's **global** AutoTrading button via `user32.dll` |
| `PAUSE` | Manual pause (`NG_ManualPause`), survives restarts |
| `RESUME` | Clear the manual pause **and** a rule E pause |
| `CLOSEALL` | Close every order in the terminal, all magics |
| `RESETDAY` | Re-anchor the rule E daily baseline and lift a rule E pause |
| `ORACLE_ON` / `ORACLE_OFF` | Enable / disable the strategy head (`CB4_OracleOn`) |

> `RESUME` is the **only** thing that clears a manual pause. A pause inherited on a new
> machine is the usual reason AutoTrading "will not stay on".

## Configuration (hot)

| Command | Effect |
|---|---|
| `SET TP=15 GRID=100 LOT=0.01 FACTOR=1.0 MAXLEV=0` | Any subset; re-anchors the open basket's TP immediately |
| `BSTOP <usd>` | Basket stop in USD, `0` = off |
| `CONFIG` | Log the active configuration |
| `PANELDUMP` | Write every panel line to `panel_dump.txt` |

`SET` and `BSTOP` persist in GlobalVariables and survive a restart. See
[Configuration](Configuration-and-Presets).

## Testing

| Command | Effect |
|---|---|
| `TEST=N` | Inject a fake High-impact event N minutes ahead, to watch the news block fire |

## Order of operations

Always **close orders before turning AutoTrading off**. With AT off, both close and delete
fail — so `AT_OFF` on a live basket leaves it stranded. The correct sequence is `CLOSEALL`,
wait for confirmation in the log, then `AT_OFF`.

## Verifying a command landed

Read (punctually) the tail of `Cerberus_log.csv`, or `ng_status.json`.

> **Never `tail -f` anything under `Files\`.** It blocks the EA's `FileOpen` and log lines
> are silently lost — they only survive in the terminal journal under `MQL4\Logs\`, in local
> time, as `LOG FAIL`. On Windows, killing the monitor does not kill its `tail.exe` child:
> check with `Get-Process tail`.
