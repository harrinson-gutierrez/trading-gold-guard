# MT4 vs MT5

`src-mt4/Cerberus.mq4` is a **functional homolog** of `src-mt5/Cerberus.mq5`, not an
independent product. Input names, command names, file names, magics and rule semantics
match wherever the platform allows it. Both are at **v1.15**.

The MT5 build is roughly 3 100 lines, the MT4 build 1 800 — the difference is mostly panel
code and MQL5 API verbosity, not behaviour.

## Parity matrix

| Feature | MT5 | MT4 | Note |
|---|:--:|:--:|---|
| Guardian rules A / B / C / D / E | ✅ | ✅ | Same thresholds, same defaults |
| News windows + `ff_cache.json` | ✅ | ✅ | Same feed, same cache format |
| Hour filter, scheduler (soft/hard) | ✅ | ✅ | Same UTC windows and weekday flags |
| ORACLE engine (EMA34 + HiLo3, additive grid) | ✅ | ✅ | Verified by golden master |
| Grid anchored on the price extreme | ✅ | ✅ | Same fix on both |
| Shared basket TP, re-anchored on add | ✅ | ✅ | Server-side on both |
| Basket stop + cooldown + server SL | ✅ | ✅ | |
| Presets `symbol_presets.txt` | ✅ | ✅ | Same file format |
| Command channel | ✅ | ✅ | Except `SYMON`/`SYMOFF` |
| `ng_status.json` | ✅ | ✅ | MT4 reports `"ea":"Cerberus4"` |
| `SYMON` / `SYMOFF` | ✅ | — | Per-symbol enable/disable |
| Broker session query | ✅ | ⚠️ | See below |
| Chart panel | full | reduced | MT4 draws fewer objects |

## The one real API gap: sessions

MT5 asks the broker directly:

```cpp
SymbolInfoSessionTrade(sym, dow, i, from, to)   // MQL5 only
```

MQL4 has **no equivalent**, so the MT4 build cannot read the broker's real session table.
It approximates the weekly close with an input:

```cpp
input int FridayCloseHourGMT = 21;   // gold/FX weekly close hour (GMT)
```

This is the one spot where exact parity is impossible. If the Exness server offset is not
exactly what the input assumes, the MT4 pre-close flatten fires at a slightly different
minute than MT5's. Set `FridayCloseHourGMT` to the broker's actual close hour.

Everything else in the session logic — `UseSessionFilter`, `PreCloseCloseMin`,
`PreCloseWeekendOnly`, `WeekendGapHours` — exists on both, and `WeekendGapHours` is kept on
MT4 purely so a single `.set` file loads cleanly on either platform.

## Platform-specific constants

| | MT5 | MT4 |
|---|---|---|
| AutoTrading toggle | `PostMessageW(WM_COMMAND, 32851)` | `PostMessageW(WM_COMMAND, 33020)` |
| Trading API | `CTrade` (`Trade\Trade.mqh`) | `OrderSend` / `OrderClose` |
| Local "not armed" rejection | retcode `10027` | error `4109` |
| Server "trading disabled" | retcode `10026` | — |
| Rollover rejection | retcode `10018` | — |
| Log prefix | `Cerberus` | `Cerberus4` |
| Data folder | `<data>\MQL5\Files\` | `<data>\MQL4\Files\` |

MT4 is natively hedging, so no account-mode check is needed there; the MT5 account must be
explicitly a **hedging** account.

## Proving the engines match

The Strategy Tester cannot test the guardian (no WebRequest, no DLL, no toggles), but it
can test the engine. `tools/golden_master_compare.py` parses a tester report from each
platform and compares them in **normalised** terms:

- trade count (±5 %),
- buy/sell ratio (±10 %),
- **grid spacing between levels** — the thing the engine actually controls.

Tolerances rather than equality, because MT4 models ticks while MT5 can replay real ones;
a byte-identical trade log is impossible by construction. Full procedure in
[Tools and panels](Tools-and-Panels).
