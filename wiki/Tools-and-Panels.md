# Tools and panels

Everything here is **read-only** with respect to trading: no tool in this list opens,
modifies or closes an order.

## Live engine comparator

The strategy is validated by running it **side by side against the real Oracle 2.0 bot**,
each on its own demo account, same symbol, same instant — and comparing their behaviour until
the two agree.

`tools/engine_live_compare.py` diffs the two engines from the snapshots written by
PosRecorder: entries, sides, pip step between grid levels, depth per magic, cycle duration,
distance at which the basket TP is taken. This is how the v2.0 findings were established —
that Oracle fades the market, that it re-arms immediately after a close, that it keeps a lean
one-side book by closing baskets at avg + TP/n, that it opens
every level at a constant 0.01 lot.

Live comparison beats the tester here for a simple reason: the guardian's dependencies
(WebRequest, DLL toggles) do not exist in the Strategy Tester, and the differences that
mattered were behavioural, not statistical.

## PosRecorder

`src-mt4/PosRecorder.mq4`: a read-only 1 Hz snapshot of every open position, written as
`;`-separated CSV, one line per position per sample — plus a heartbeat line when the account
is flat, so the analysis can distinguish *no positions* from *no data*.

```
ts_gmt;equity;balance;floating;n_pos;ticket;magic;symbol;type;lots;open_price;age_s;sl;tp;profit;swap;bid;ask;spread_pts
```

The field to compare **across accounts** is `age_s`, not the raw open time: the two brokers'
server clocks differ, ages do not.

## The terminal journal as a live window

Oracle 2.0 is a black box — it writes no status JSON. Its behaviour is read from the
**terminal journal** (`<data>\logs\*.log`), which logs every order open, TP modify and close
with price and reason. That log is safe to read repeatedly (it is not a `MQL4\Files\` target
the EA holds open), so it is the primary real-time window into what Oracle actually does.

## Compare panel

`compare-panel/` serves a side-by-side, metric-by-metric comparison of the two accounts.

```powershell
powershell -ExecutionPolicy Bypass -File compare-panel\start.ps1
# http://127.0.0.1:8770/compare.html
```

Each terminal isolates its own data folder, so a static file server cannot aggregate them.
`compare_server.py` (Python stdlib, no dependencies) reads each account's status by
**absolute path**, normalises it, and serves `/compare.json` and `/compare.html`.

| Account | Source |
|---|---|
| Cerberus (`73114764`) | `ng_status.json` |
| Oracle 2.0 (`73114915`) | derived from the journal / PosRecorder snapshot |

## In-terminal panel

Cerberus draws its own chart panel, refreshed from `EventSetTimer` rather than from ticks —
a tick-driven panel goes blank during the daily quote pause, which is exactly when you want
to read it.

The panel shows the active config, the open baskets, each engine's fade side and whether it
is waiting for its side, the informational hour-risk band, and the last action.
`PANELDUMP` writes every line to `panel_dump.txt` so it can be read without a screenshot.
