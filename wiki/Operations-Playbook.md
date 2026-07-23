# Operations playbook

Traps that already cost money or downtime once. Each entry is a real incident, not a
precaution.

## Never `tail -f` a file under `Files\`

A follower holds the file open and **blocks the EA's `FileOpen`**. The EA cannot write, and
those log lines are gone — they survive only in the terminal journal (`MQL4\Logs\*.log`, in
**local** time) as `LOG FAIL`.

Read punctually instead (`Get-Content -Tail 40` once per cycle). And on Windows, killing a
monitor does **not** kill its `tail.exe` child — check `Get-Process tail, grep` afterwards.

## AutoTrading will not stay on / nothing is trading

Two causes, both silent:

1. **An inherited pause.** If a manual pause is set, the guardian keeps AutoTrading logic
   off. Read `ng_status.json`, **not** the log's INIT line. Only `RESUME` clears
   `NG_ManualPause`. This is the classic symptom after moving the terminal to a VPS.
2. **The global button is simply off.** The terminal remembers the AutoTrading button across
   restarts, so a button left off by a previous session silently gates the whole strategy.
   v2.0 makes this loud — `ng_status.json` reports `"status":"AT_OFF"` and the log prints an
   `AT_OFF` line a minute — but the fix is the same: send `AT_ON`. (Measured 2026-07-23: 13
   minutes of zero orders because the button was off from a prior run.)

On MT4 a persistent error **4109** that survives restarts and `AT_ON` is a third cause: the
EA's own *Allow live trading* checkbox (F7 → Common) is off. The journal says *trade
operations not allowed by settings*.

## Clear stale hot overrides on a redeploy

The `.chr` seed and the `CB4_ov*` GlobalVariables are separate layers. A redeploy that resets
the `.chr` does **not** clear the overrides: an old `SET GRID=90` in `CB4_ovGrid` will shadow
a fresh `GRID=100` default and the new value never takes effect. Delete `gvariables.dat`
(terminal closed) — or the specific `CB4_ov*` variables — when resetting to defaults. Verify
from the `INIT` log line, which prints the effective config.

## The terminal off with a live basket

Measured 2026-07-23: the terminal sat off for 13 hours with an open basket. Nothing guarded
it — rule E, the basket stop and the news block all run only while the EA runs — and rule E
only fired on the next start, with the loss already taken. The only covers are an unattended
VPS and a broker-side SL (`BasketStop_USD > 0`, which also arms `BasketStop_ServerSL`).

## Close before you disarm

With AutoTrading off, **close and delete both fail**. `AT_OFF` on a live basket strands it.
Sequence: `CLOSEALL` → confirm in the log → `AT_OFF`.

## The feed returns 429 / shows 0 events

- `nfs.faireconomy.media` rate-limits after a burst of terminal restarts. The guardian falls
  back to `ff_cache.json` and recovers on its own. `"feed":"disk cache"` right after a
  restart is **expected**.
- "0 High events watched" is **not** a feed failure — it is the filter. v2.0 watches
  High-impact events for **all** currencies (a week can have zero USD-High but eleven across
  CAD/GBP/AUD/EUR). If the cache has events but the count is 0, check the filter, not the
  feed.

## The rollover is not a market move

FX and metals pause on Exness between **21:00 and 22:00 GMT**. In that window every order
returns retcode 10018, and quotes are thin enough to print spikes that never happened.
`OpenWarmup_Min` vetoes entries just after a reopen for the same reason. Crypto (BTCUSDm)
trades 24/7 and does not have the window.

## The weekend gap is now a manual call

Gold and FX close Friday 21:00 UTC and reopen Sunday 22:00 — a grid left open hangs **49
hours** across an unhedgeable gap. v2.0 does **not** auto-flatten before the close (the
pre-close flatten was removed); `Show_SessionWarning` only warns. If you want to be flat for
the weekend, send `CLOSEALL` before the Friday close yourself.

## Symbol names are broker-specific

Gold on the Exness Trial is **`XAUUSDm`**. `XAUUSD`, `XAUUSDc` and `XAUUSDz` belong to other
account types and will not resolve. XAUUSDm quotes with **3 decimals**, so a strategy pip is
`Point*10` = $0.01.

## Editing a `.chr` by hand

- The MT4 chart file (`MQL4\Profiles\Default\chart01.CHR`) is **ANSI / latin-1** — not
  UTF-16 (that is the MT5 format).
- Edit only with the terminal **closed** — it rewrites the file on exit.
- The `<expert>` block sits near the end, before `</chart>`, and needs `flags=343` (live
  trading + DLL). A `.chr` saved without its `<expert>` block means the EA does not load —
  no error, just an empty chart. Keep the `.bak` files.

## The Strategy Tester cannot test the guardian

No WebRequest, no DLL, no toggles. The guardian is verified by code review and by live
observation; do not conclude "the guardian is fine" from a green backtest — it never ran.
