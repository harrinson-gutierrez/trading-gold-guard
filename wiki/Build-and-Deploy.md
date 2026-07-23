# Build and deploy

## Compile

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1   # src-mt4/*.mq4 -> MT4 EXNESS
```

The script copies the sources into that terminal's `Experts` folder, compiles them with the
terminal's own MetaEditor, prints the errors and warnings, and **exits non-zero unless every
EA reports 0 errors**.

Compiling works with the terminal open. **Loading** the new binary does not.

## Restart to load new code

```powershell
Get-Process terminal | Where-Object { $_.Path -like "*EXNESS\terminal.exe" } | ForEach-Object { $_.CloseMainWindow() }
# wait for exit, then relaunch
& "C:\Program Files (x86)\MetaTrader 4 EXNESS\terminal.exe"
```

`CloseMainWindow()` rather than `Kill()`: the terminal must save its profile on the way out.
The profile keeps charts, EAs and inputs, so nothing has to be reattached.

## Check what is actually running

The source version and the deployed binary drift apart easily, because compiling and loading
are separate steps. Compare:

```
#property version "2.00"          # in the source
"version":"2.00"                  # in ng_status.json  <- the binary actually loaded
```

If they differ, the terminal is still running an older `.ex4` and needs a restart. The
`INIT` log line also prints the effective config, so a redeploy is verified by reading it —
e.g. `ENTRY=FADE ... GRID=100 ... new basket on HiLo flip`.

## Terminal setup (once per terminal)

Tools → Options → Expert Advisors:

1. ✅ **Allow algorithmic trading** — and the AutoTrading toolbar button ON.
2. ✅ **Allow DLL imports** — required for the AutoTrading toggle through `user32.dll`.
3. ✅ **Allow WebRequest for** `https://nfs.faireconomy.media`.

Item 3 is **GUI-only**: MetaTrader stores that list encrypted, so it cannot be deployed from
a file. Without it the calendar fetch fails with error 4014 and the guardian runs on
`ff_cache.json`. This is the one manual step on a new machine.

The account must be **hedging** — a basket holds several positions on the same symbol.

## File-based login

```ini
; a startup config passed positionally to terminal.exe
[Common]
Login=73114764
Password=...
Server=Exness-Trial12

[Experts]
AllowLiveTrading=1
AllowDllImport=1
Enabled=1
```

```powershell
& "C:\Program Files (x86)\MetaTrader 4 EXNESS\terminal.exe" "<path>\login.ini"
```

After the first login the credentials are stored in `accounts.dat` and the file is no longer
needed — delete it (it holds the password in clear text).

> **Danger:** an MT4 launched with a login `.ini` **trades live** if its profile contains a
> chart with an EA attached and AutoTrading enabled. A "lab" terminal is only a lab while
> its profile is empty.

## Deploying to a VPS

Only the compiled EA and the terminal settings travel. On arrival:

1. Re-do the WebRequest whitelist by hand (it does not travel).
2. Check `ng_status.json` before anything else — an inherited `NG_ManualPause` will keep
   re-disabling AutoTrading every tick, and the log's INIT line will not tell you. Send
   `RESUME`. (In v2.0 the status also reports `AT_OFF` outright when the button is down.)
3. Expect `"feed":"disk cache"` at first, and expect HTTP 429 if the terminal was restarted
   in a burst. It recovers alone.

## Release convention

Binaries published on a release carry the version in the file name (`Cerberus_v2.0.ex4`),
but the binary inside the terminal keeps the plain name `Cerberus.ex4` — the `.chr` loads
the EA **by that name**. Every publication bumps the version; never overwrite an
already-published tag.
