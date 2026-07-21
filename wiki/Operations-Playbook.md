# Operations playbook

Traps that already cost money or downtime once. Each entry is a real incident, not a
precaution.

## Never `tail -f` a file under `Files\`

A follower holds the file open and **blocks the EA's `FileOpen`**. The EA cannot write, and
those log lines are gone — they survive only in the terminal journal (`MQL5\Logs\*.log`, in
**local** time) as `LOG FAIL`.

Read punctually instead (`Get-Content -Tail 40` once per cycle). And on Windows, killing a
monitor does **not** kill its `tail.exe` child — check `Get-Process tail, grep` afterwards.

## Never restart right after a symbol switch

`SYMBOL <sym>` and `PRESET <sym>` call `ChartSetSymbolPeriod`, which is **asynchronous**:
it queues an EA re-init so the basket visuals redraw on the new symbol.

On 2026-07-18 a terminal shutdown collided with that queued re-init and the terminal saved
a `.chr` **without its `<expert>` block**. The EA silently did not load on the next start —
no error, just a chart with no panel.

**Recovery:** restore the `.chr` from a `.bak` that still contains
`<expert> ... expertmode=5`. Cerberus writes `.bak`, `.bak2`, … whenever inputs are edited.

**Rule:** after a hot switch, wait. The chart move only happens on an explicit switch,
never at `OnInit`.

## AutoTrading will not stay on

Almost always an inherited pause, not a broken toggle.

1. Read `ng_status.json` — **not** the log's INIT line, which says nothing about it.
2. If a manual pause is set, the guardian re-disables AutoTrading **every tick**. Only `RESUME` clears `NG_ManualPause`.
3. This is the classic symptom after moving the terminal to a VPS: the GlobalVariable travelled with the profile.

On MT4 there is a second cause: a persistent error **4109** that survives restarts and
`AT_ON` is the EA's own *Allow live trading* checkbox (F7 → Common) being off. The journal
confirms it with *trade operations not allowed by settings*.

## Close before you disarm

With AutoTrading off, **close and delete both fail**. `AT_OFF` on a live basket strands it.
Sequence: `CLOSEALL` → confirm in the log → `AT_OFF`.

## The feed returns 429

`nfs.faireconomy.media` rate-limits after a burst of terminal restarts. The guardian falls
back to `ff_cache.json` and recovers on its own. `"feed":"disk cache"` right after a
restart is **expected**. Restarting again to "fix" it makes it worse.

## The rollover is not a market move

FX and metals pause on Exness between **21:00 and 22:00 GMT**. In that window every order
returns retcode 10018, and quotes are thin enough to print spikes that never happened in
real liquidity. `UseSessionFilter` and `Oracle_OpenWarmupMin` exist for this. Crypto
(BTCUSDm) trades 24/7 and does not have the window — which is also why it does not have the
weekend gap.

## The weekend gap

Gold and FX close Friday 21:00 UTC and reopen Sunday 22:00 — a grid left open hangs **49
hours** across an unhedgeable gap. `PreCloseCloseMin` with `PreCloseWeekendOnly=true`
flattens before the weekly close only, leaving the nightly rollover to the entry block.

## Symbol names are broker-specific

Gold on the Exness Trial is **`XAUUSDm`**. `XAUUSD`, `XAUUSDc` and `XAUUSDz` belong to
other account types and will not resolve. And XAUUSDm quotes with **3 decimals**, so
`PipSizeOverride=0.1` is required for the guardian's pip to stay $0.10.

## Crypto does not inherit gold's numbers

On BTCUSDm, "300 pips" (rule A) is a **$30** move, and the ~$10 spread eats any target that
works on gold. Per-position thresholds calibrated for gold do not transfer. Tightening
`MaxDDPct` without touching `StepxATR` once took BTC from one stop per night to **three in
20 minutes** — the two knobs are not independent.

## Editing a `.chr` by hand

- The file is **UTF-16**.
- Edit only with the terminal **closed** — it rewrites the file on exit.
- The `<expert>` block goes in the chart header right after `windows_total=1`, with `expertmode=5`.

## The Strategy Tester cannot test the guardian

No WebRequest, no DLL, no toggles. The guardian is verified by code review; the **engine**
is verified by the golden master. Do not conclude "the guardian is fine" from a green
backtest — it never ran.

## Manual orders during a soak

`BUY`/`SELL` commands open positions with magic `777999`, no SL, no TP, and no strategy
head to manage them. They pollute the metrics as orphans. Use them only to test a guardian
rule, then `CLOSEALL`.
