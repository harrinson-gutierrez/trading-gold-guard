# Tools and panels

Everything here is **read-only** with respect to trading: no tool in this list opens,
modifies or closes an order.

## Golden master — engine parity across platforms

`tools/golden_master_compare.py` proves that the MT4 and MT5 engines behave the same, so a
change on one platform cannot silently diverge from the other.

It parses each platform's Strategy Tester HTML report and compares them in **normalised**
terms, never absolute prices:

| Metric | Tolerance |
|---|---|
| Trade count | ±5 % |
| Buy/sell ratio | ±10 % |
| Grid spacing between levels | ±2 pips |

```bash
python tools/golden_master_compare.py mt5_report.htm mt4_report.htm --label-a MT5 --label-b MT4
```

Exit `0` = engines agree, `1` = divergence to investigate.

**Procedure.** Run both testers on `XAUUSDm` M1, same period, with **identical** inputs:
`Oracle_TakeProfit=15`, `Oracle_GridSize=30`, `Oracle_FixedLot=0.01`,
`Oracle_GridFactor=1.0`, both engines on, `CloseOnVolSpike=false`,
`Oracle_BasketStopUSD=0`. Save each report (right-click on the results tab) and compare.

**Why tolerances, not equality.** MT5 can replay real ticks; MT4 models them. A
byte-identical trade log is impossible by construction, so the comparator validates
*equivalent behaviour* instead of pretending to determinism it cannot have.

**Regression use.** The tester does not run the guardian, so guardian work should not move
the engine at all. Capture `mt4_before.htm` and `mt4_after.htm` around such a change and
compare them: these should match exactly, since it is the same engine. A difference means
something touched the engine by accident.

Full write-up: `tools/GOLDEN_MASTER.md`.

## Live engine comparator

`tools/engine_live_compare.py` compares the two engines **live**, second by second, from
the snapshots written by PosRecorder — entries, sides, pip step between grid levels, depth
per magic, cycle duration, distance at which the basket TP is taken.

## PosRecorder

`src-mt5/PosRecorder.mq5` and `src-mt4/PosRecorder.mq4`: a read-only 1 Hz snapshot of every
open position, written as `;`-separated CSV, one line per position per sample — plus a
heartbeat line when the account is flat, so the analysis can distinguish *no positions*
from *no data*.

```
ts_gmt;equity;balance;floating;n_pos;ticket;magic;symbol;type;lots;open_price;age_s;sl;tp;profit;swap;bid;ask;spread_pts
```

The field to compare **across platforms** is `age_s`, not the raw open time: the two
brokers' server clocks differ, ages do not.

## Compare panel

`compare-panel/` serves a side-by-side, metric-by-metric comparison of the accounts running
in different terminals.

```powershell
powershell -ExecutionPolicy Bypass -File compare-panel\start.ps1
# http://127.0.0.1:8770/compare.html
```

Each terminal isolates its own data folder, so a static file server cannot aggregate them.
`compare_server.py` (Python stdlib, no dependencies) reads each account's status JSON by
**absolute path**, normalises it to a common schema, and serves `/compare.json` and
`/compare.html`. `start.ps1` first stops any stale listener on port 8770.

| Account | Platform | Source |
|---|---|---|
| Oracle | MT4 | `oracle_status.json` |
| Cerberus | MT5 | `ng_status.json` |

## In-terminal panel

Cerberus draws its own chart panel, refreshed from `EventSetTimer` rather than from ticks —
a tick-driven panel goes blank during the daily quote pause, which is exactly when you want
to read it.

The panel shows the active config, the open baskets, the guardian state and the last
action. The MT4 build draws a reduced version of it.

> If the chart is black and there is no panel at all, suspect the **profile**, not the EA:
> MT5 loads from `Profiles\Charts\`, and `common.ini`'s `ProfileLast` decides which one.
> Set it to `Default` and copy a known-good `.chr` in.
