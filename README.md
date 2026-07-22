# Trading Gold Guard — Cerberus

A guarded grid-trading system for MetaTrader. One EA, **Cerberus**, runs two heads in a
single chart: an always-on **guardian** that defends the account, and the **ORACLE**
strategy that trades it. It ships as two builds kept in lockstep — MQL5 and MQL4 —
sharing the same inputs, the same command channel and the same preset file format.

Current deployment: Exness demo, gold `XAUUSDm`, hedging, 1:200. **Demo soak only** — see
[Safety model](#safety-model).

| Build | Source | Version | Terminal |
|---|---|---|---|
| MT5 | [src-mt5/Cerberus.mq5](src-mt5/Cerberus.mq5) | 1.15 | MetaTrader 5 EXNESS (Trial `198622897`) |
| MT4 | [src-mt4/Cerberus.mq4](src-mt4/Cerberus.mq4) | 1.15 | MetaTrader 4 EXNESS (demo `73114636`) |

The MQL4 build is a **functional homolog**, not a rewrite: same rules, same engine, same
input names wherever the feature exists on the platform. The engine parity is verified
with a golden-master comparator over Strategy Tester reports — see
[tools/GOLDEN_MASTER.md](tools/GOLDEN_MASTER.md).

## The two heads

### Guardian (always on, all magics)

The guardian polices **every** position in the terminal, including those of other EAs.
Each rule exists because a measured loss demanded it.

| Rule | Trigger (default) | Action |
|---|---|---|
| **News** | High-impact ForexFactory event, ±30 min | Blocks trading in the window (JSON feed + disk cache, survives HTTP 429) |
| **A** | Position `MaxAdversePips` = 300 pips against, floored at `RuleA_xATR` = 15×ATR(M1) | Closes that position |
| **B** | Margin level below `MinMarginLevelPct` = 200 % | Closes the worst position in a loop until recovered |
| **C** | Per symbol: M1 candle > 5×ATR, or a 5-candle range > 8×ATR | 3-min renewable pause for **that symbol only**; optionally closes its basket (`CloseOnVolSpike`, off) |
| **D** | Position losing more than `MaxLossPerTradeUSD` = 60 USD | Closes that position |
| **E** | Daily loss above `MaxDailyLossUSD` = 200 USD | Closes **everything** and pauses until `RESUME` |

Plus three soft entry gates that never close anything:

- **Hour filter** (`UseHourFilter`): blocks new entries in the VERY HIGH UTC bands of the gold risk table (08:00–09:30, 12:00–15:30).
- **Scheduler** (`UseSchedule`, off): up to four user-defined UTC `HH:MM` windows + per-weekday flags. `SchedKillAT=false` is soft (only Cerberus stops entering); `true` is hard — closes every order and turns the **global** AutoTrading button off on entering a window, affecting all EAs.
- **Session filter** (`UseSessionFilter`): asks the broker whether the symbol is tradable now, so nothing is fired into the daily rollover pause. `PreCloseCloseMin` flattens baskets 5 min before the **weekend** close (`PreCloseWeekendOnly`) to avoid holding a grid across the gap.

### ORACLE strategy (magics 7799 / 9977)

A faithful replica of the Oracle 2.0 bot, with the risk net it lacked.

- **Direction**: Gann HiLo(3) gives a continuous side; EMA(34) on M1 confirms it.
- **Two engines**: with both on, A takes only BUY signals and B only SELL — one ladder per side. With a single engine on, it trades both sides, one basket at a time.
- **Grid**: on an adverse move of `GRID` pips it adds a level at **constant lot** (`FACTOR = 1.0` — additive, *not* martingale ×2).
- **Exit**: one shared server-side TP for the whole basket, `TP` pips from the weighted average, re-anchored on every add.
- **Depth cap**: `Oracle_MaxGridLevels`, or a capital-proportional cap (`Oracle_BaseCapital` / `Oracle_DollarsPerLevel`) so the risk scales with the declared balance instead of relying on a cushion.
- **Basket stop**: `Oracle_BasketStopUSD` cuts a basket at −N USD floating, with a cooldown before re-arming. `Oracle_UseServerSL` mirrors it as a broker-side SL per position, so it still executes if our close orders get rejected.
  > ⚠️ **`Oracle_BasketStopUSD = 0` disables the broker-side SL too.** The SL is attached only when the basket stop is armed (`Oracle_UseServerSL && EffBstop() > 0`), so running with the stop off leaves **every** defense client-side. Measured 2026-07-22: the broker disabled algo trading (retcode 10026) during a $27/hour move in gold; rules A and E fired and all 191 close attempts were rejected, while the positions carried `sl=0.000`. Keep it above zero in live use.
- **New-basket EMA gate** (`Oracle_NewBasketNeedsEMA`): the HiLo always carries a side, so without this gate Cerberus re-arms a basket the second it closes one. Hot-switchable with `EMAGATE ON|OFF`.

## Configuration: inputs, overrides, presets

Three layers, each winning over the previous one:

```
EA inputs (.chr / .set)  →  hot overrides (SET/BSTOP/EMAGATE)  →  preset file (PRESET <sym>)
        seed only                persist in GlobalVariables         persists on disk
```

The `.chr` inputs are only the **seed**: once an override or preset is applied it wins
until cleared (delete the `CB_ov*` GlobalVariables or set the input again). The active
config is always visible in `ng_status.json` (`config:{}`) and on the chart panel.

### Preset file

`MQL5\Files\symbol_presets.txt` (MT4: `MQL4\Files\`), one hand-editable line per symbol:

```
SYMBOL=TP,GRID,LOT,FACTOR,MAXLEV[,BSTOP]
```

`PRESET <sym>` loads a line, applies it **and** switches the traded symbol.
`SAVEPRESET` writes the current config back under the active symbol. `BSTOP` is the
optional 6th field so each symbol keeps its own basket stop (a $20 stop sized for ETH
baskets is disproportionate for gold's 0.01-lot baskets); 5-field legacy lines leave the
current stop untouched.

**Production preset, identical on both platforms** ([config/symbol_presets.txt](config/symbol_presets.txt)):

```
XAUUSDm=15,30,0.01,1.00,0,120
```

| Field | Value | Meaning |
|---|---|---|
| `TP` | 15 | Basket TP, pips from the weighted average |
| `GRID` | 30 | Pips against before adding the next level |
| `LOT` | 0.01 | Fixed lot per level |
| `FACTOR` | 1.00 | Additive grid (no lot multiplication) |
| `MAXLEV` | 0 | No hard depth cap → the capital-proportional cap applies |
| `BSTOP` | 120 | Basket stop in USD. **Do not set 0 in live use** — it also removes the broker-side SL (see above). Tunable live with `BSTOP <usd>` |

On XAUUSDm a strategy pip is `Point*10` = **$0.01**, so `TP=15` is a 15-cent move and
`GRID=30` a 30-cent step.

### Input set

[config/Cerberus_XAUUSDm.set](config/Cerberus_XAUUSDm.set) is the full production input
set for gold, loadable from the MetaEditor / Strategy Tester "Load" button on either
platform. Where it deviates from the compiled defaults:

| Input | Source default | Production `.set` | Why |
|---|---|---|---|
| `Oracle_TakeProfit` | 20 | **15** | Tighter cycle measured on gold |
| `Oracle_GridSize` | 50 | **30** | Matches the 15-pip TP spacing |
| `Oracle_NewBasketNeedsEMA` | false | **true** | Without it, cadence hit 26 baskets/21 min against Oracle 2.0's 11 |
| `Oracle_DollarsPerLevel` | 180 | **0** | Proportional cap disabled while the lot is the 0.01 floor |
| `UseHourFilter` | true | **false** | The soak measures the engine unfiltered |

## Command channel

Write **one line** to `ng_command.txt` in the terminal's `Files` folder; Cerberus picks it
up within 30 s, no restart.

| Command | Effect | MT5 | MT4 |
|---|---|:--:|:--:|
| `AT_ON` / `AT_OFF` | Toggle the global AutoTrading button (via `user32.dll`) | ✅ | ✅ |
| `PAUSE` / `RESUME` | Manual pause; `RESUME` also clears rule E | ✅ | ✅ |
| `CLOSEALL` | Close every order in the terminal | ✅ | ✅ |
| `RESETDAY` | Re-anchor the rule E daily baseline (use after a demo top-up) | ✅ | ✅ |
| `TEST=N` | Inject a fake news event N minutes ahead | ✅ | ✅ |
| `BUY\|SELL <sym> <lots>` | Manual order (guardian testing only) | ✅ | ✅ |
| `ORACLE_ON` / `ORACLE_OFF` | Enable/disable the strategy head | ✅ | ✅ |
| `SYMBOL <sym>` | Flatten and switch the traded symbol | ✅ | ✅ |
| `SET TP=… GRID=… LOT=… FACTOR=… MAXLEV=…` | Hot config, any subset; re-anchors the open basket's TP | ✅ | ✅ |
| `PRESET <sym>` | Load that symbol's preset **and** switch to it | ✅ | ✅ |
| `SAVEPRESET` | Save the current config under the active symbol | ✅ | ✅ |
| `CONFIG` | Log the active config | ✅ | ✅ |
| `BSTOP <usd>` | Hot basket stop (0 = off) | ✅ | ✅ |
| `EMAGATE ON\|OFF` | New-basket EMA gate | ✅ | ✅ |
| `SYMON` / `SYMOFF <sym>` | Revive / disable a symbol | ✅ | — |

## Build & install

```powershell
powershell -ExecutionPolicy Bypass -File build-mt5.ps1   # src-mt5/*.mq5 -> MT5 EXNESS
powershell -ExecutionPolicy Bypass -File build.ps1       # src-mt4/*.mq4 -> MT4 EXNESS
```

Each script copies its sources into the terminal's `Experts` folder and compiles them with
that terminal's MetaEditor, demanding **0 errors**. The MT5 script falls back to a
portable MT5 install for lab work when the Exness terminal is absent.

Compiling works with the terminal open, but **loading** a new binary needs a terminal
restart (`CloseMainWindow()` on the process, then relaunch). The profile keeps charts,
EAs and inputs.

## Terminal setup (once per terminal)

Tools → Options → Expert Advisors:

1. ✅ Allow algorithmic trading (AutoTrading button ON).
2. ✅ Allow DLL imports — required for the AutoTrading toggle through `user32.dll`.
3. ✅ Allow WebRequest for `https://nfs.faireconomy.media` — **GUI only**: MetaTrader stores this list encrypted, it cannot be set from a file. Without it the calendar fails with error 4014 and the guardian runs on cache.

The account must be **hedging** — a basket holds several positions per symbol.

## Runtime files

In `MQL5\Files\` (MT4: `MQL4\Files\`):

| File | Contents |
|---|---|
| `Cerberus_log.csv` | Action log, `gmt_date;action;detail` |
| `ng_status.json` | Full state every 30 s: config, baskets, tally, drawdown |
| `ng_command.txt` | Command channel (consumed on read) |
| `ff_cache.json` | ForexFactory calendar cache |
| `symbol_presets.txt` | Per-symbol presets |

> ⚠️ Never `tail -f` a file in this folder — it blocks the EA's `FileOpen` and log lines
> are silently lost. Read them punctually instead.

## Tools

| Path | Purpose |
|---|---|
| [tools/golden_master_compare.py](tools/golden_master_compare.py) | Parses MT4/MT5 Strategy Tester reports and asserts the engines behave equivalently (trade count, buy/sell ratio, grid spacing) |
| [tools/engine_live_compare.py](tools/engine_live_compare.py) | Compares the live engines second by second from the PosRecorder snapshots |
| [src-mt5/PosRecorder.mq5](src-mt5/PosRecorder.mq5) · [src-mt4/PosRecorder.mq4](src-mt4/PosRecorder.mq4) | Read-only 1 Hz CSV snapshot of every open position — never touches an order |
| `compare-panel/` *(local only)* | Read-only web panel comparing the MT4 and MT5 accounts side by side, metric by metric |

## Safety model

**Nothing touches a real account.** The system runs on demo until weeks of soak produce
written metrics, and only then by explicit decision. The guardian is the last line, not
the strategy — and a win rate is not an edge: measure **net USD** and the
average-win/average-loss ratio, because a grid that never closes losers can show 63 % wins
while bleeding.

Full documentation: **[the wiki](../../wiki)**.
