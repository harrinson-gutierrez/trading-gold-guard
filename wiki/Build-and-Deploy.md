# Build and deploy

## Compile

```powershell
powershell -ExecutionPolicy Bypass -File build-mt5.ps1   # src-mt5/*.mq5 -> MT5 EXNESS
powershell -ExecutionPolicy Bypass -File build.ps1       # src-mt4/*.mq4 -> MT4 EXNESS
```

Each script copies its sources into that terminal's `Experts` folder, compiles them with
that terminal's own MetaEditor, prints the errors and warnings, and **exits non-zero unless
every EA reports 0 errors**. `build-mt5.ps1` falls back to a portable MT5 install
(`%LOCALAPPDATA%\Programs\MT5Lab`) for lab work when the Exness terminal is absent.

Compiling works with the terminal open. **Loading** the new binary does not.

## Restart to load new code

```powershell
Get-Process terminal64 | Where-Object { $_.Path -like "*EXNESS*" } | ForEach-Object { $_.CloseMainWindow() }
# wait for exit, then relaunch
& "C:\Program Files\MetaTrader 5 EXNESS\terminal64.exe"
```

`CloseMainWindow()` rather than `Kill()`: the terminal must save its profile on the way
out. The profile keeps charts, EAs and inputs, so nothing has to be reattached.

The MT4 twin is the `terminal` process under `MetaTrader 4 EXNESS`.

## Check what is actually running

The source version and the deployed binary drift apart easily, because compiling and
loading are separate steps. Compare:

```
#property version "1.15"          # in the source
"version":"1.15"                  # in ng_status.json  <- the binary actually loaded
```

If they differ, the terminal is still running an older `.ex5`/`.ex4` and needs a restart.

## Terminal setup (once per terminal)

Tools → Options → Expert Advisors:

1. ✅ **Allow algorithmic trading** — and the AutoTrading toolbar button ON.
2. ✅ **Allow DLL imports** — required for the AutoTrading toggle through `user32.dll`.
3. ✅ **Allow WebRequest for** `https://nfs.faireconomy.media`.

Item 3 is **GUI-only**: MetaTrader stores that list encrypted, so it cannot be deployed
from a file or a script. Without it the calendar fetch fails with error 4014 and the
guardian runs blind on `ff_cache.json`. This is the one manual step on a new machine.

The account must be **hedging** — a basket holds several positions on the same symbol.

## File-based login

```ini
; <data>\config\start_exness.ini
[Common]
Login=198622897
Password=...
Server=Exness-MT5Trial11
```

```powershell
& "C:\Program Files\MetaTrader 5 EXNESS\terminal64.exe" /config:"<data>\config\start_exness.ini"
```

After the first login the credentials are stored and the flag is no longer needed.

> **Danger:** a portable MT5 launched with a login `.ini` **trades live** if its profile
> contains charts with EAs attached. A "lab" terminal is only a lab while its profile is
> empty.

## Editing inputs without the GUI

Chart files live in `MQL5\Profiles\Charts\Default\chartNN.chr`, are **UTF-16**, and must be
edited with the terminal **closed** (it rewrites them on exit). The `<expert>` block sits
in the chart header immediately after `windows_total=1` and needs `expertmode=5`
(live trading + DLL).

A `.chr` saved without its `<expert>` block means the EA does not load at all — no error,
just an empty chart. Recovery is to restore from one of the `.bak` files Cerberus writes.

## Deploying to a VPS

Only the compiled EA and the terminal settings travel. On arrival:

1. Re-do the WebRequest whitelist by hand (it does not travel).
2. Check `ng_status.json` before anything else — an inherited `NG_ManualPause` will keep re-disabling AutoTrading every tick, and the log's INIT line will not tell you. Send `RESUME`.
3. Expect `"feed":"disk cache"` at first, and expect HTTP 429 if the terminal was restarted in a burst. It recovers alone.

## Release convention

Binaries published on a release carry the version in the file name
(`Cerberus_v1.15.ex5`), but the binary inside the terminal keeps the plain name
`Cerberus.ex5` / `Cerberus.ex4` — the `.chr` loads the EA **by that name**. Every
publication bumps the version; never overwrite an already published tag.
