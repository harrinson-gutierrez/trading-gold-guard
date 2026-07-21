# Configuration and presets

Cerberus has **three configuration layers**, each overriding the previous one. Knowing
which layer is winning is the difference between "the EA ignores my settings" and
"I edited the seed, not the live value".

```
1. EA inputs           .chr chart file / .set file        seed only, read at OnInit
2. Hot overrides       SET / BSTOP / EMAGATE / SYMBOL     GlobalVariables, survive restarts
3. Presets             PRESET <sym>                       file on disk, applied as overrides
```

The inputs in the `.chr` are **only the seed**. Once an override or preset is applied it
wins until cleared — deleting the `CB_ov*` GlobalVariables, or setting the input value
again. The internal accessors (`EffTP()`, `EffGrid()`, `EffLot()`, `EffFactor()`,
`EffMaxLev()`, `EffBstop()`) always resolve the layers in that order, so no code path can
accidentally read the seed.

**Where to see what is actually live:** `ng_status.json` → `config:{}`, or the chart panel.
Never assume from the `.chr`.

```json
"config":{"symbol":"XAUUSDm","tp":15,"grid":30,"lot":0.01,"factor":1.00,"maxlev":0}
```

## Preset file

`MQL5\Files\symbol_presets.txt` (MT4: `MQL4\Files\`). Plain text, hand-editable, one line
per symbol:

```
SYMBOL=TP,GRID,LOT,FACTOR,MAXLEV[,BSTOP]
```

| Field | Meaning |
|---|---|
| `TP` | Basket take profit, pips from the weighted average |
| `GRID` | Pips against before adding the next level |
| `LOT` | Fixed lot per level |
| `FACTOR` | Lot multiplier per level (1.00 = additive) |
| `MAXLEV` | Hard depth cap (0 = use the capital-proportional cap) |
| `BSTOP` | *optional* — per-symbol basket stop in USD (0 = off) |

`BSTOP` is the sixth field precisely because it does not generalise: a $20 stop sized for
ETH baskets is disproportionate for gold's 0.01-lot baskets. Legacy five-field lines leave
the current basket stop untouched rather than resetting it.

### Commands

| Command | Effect |
|---|---|
| `PRESET <sym>` | Load that symbol's line, apply it **and switch the traded symbol** |
| `SAVEPRESET` | Write the current live config back under the active symbol |
| `CONFIG` | Log the active config |

`SAVEPRESET` rewrites the file, replacing only the active symbol's line and preserving the
others.

## Production preset

Identical on both platforms — verified live in the MT4 and MT5 terminals:

```
XAUUSDm=15,30,0.01,1.00,0,0
```

15-pip basket TP, 30-pip grid step, 0.01 lots per level, additive, no hard depth cap,
basket stop off in the file. On XAUUSDm a strategy pip is $0.01, so this is a 15-cent
target with a 30-cent step.

The basket stop is commonly raised **live** (`BSTOP 30`) without editing the file; the
GlobalVariable override wins over the file until cleared, which is why the file can read
`0` while the panel shows `30`.

## Input set file

`config/Cerberus_XAUUSDm.set` is the full production input set, loadable from MetaEditor
or the Strategy Tester's *Load* button on either platform. Deviations from the compiled
defaults:

| Input | Compiled default | Production `.set` | Reason |
|---|---|---|---|
| `Oracle_TakeProfit` | 20 | **15** | Tighter cycle measured on gold |
| `Oracle_GridSize` | 50 | **30** | Matches the 15-pip TP spacing |
| `Oracle_NewBasketNeedsEMA` | false | **true** | Without it: 26 baskets/21 min vs Oracle 2.0's 11 |
| `Oracle_DollarsPerLevel` | 180 | **0** | Proportional cap disabled while the lot sits at the 0.01 floor |
| `UseHourFilter` | true | **false** | The soak measures the engine unfiltered |

Everything else matches the source defaults documented in
[Guardian rules](Guardian) and [ORACLE engine](Oracle-Engine).

## Editing inputs without the GUI

The chart file `MQL5\Profiles\Charts\Default\chartNN.chr` is **UTF-16** and must be edited
with the terminal **closed** — the terminal rewrites it on exit, discarding your changes
otherwise.

The `<expert>` block sits in the chart header right after `windows_total=1`, and needs:

```
expertmode=5     ; live trading + DLL imports
```

Cerberus writes `.bak`, `.bak2`, … backups when inputs are edited. Keep them: a `.chr`
saved without its `<expert>` block means the EA silently does not load and the panel
disappears. See [Operations playbook](Operations-Playbook) for the exact scenario that
caused this once.

## Switching symbol

`SYMBOL <sym>` flattens and switches; `PRESET <sym>` does the same **and** applies that
symbol's stored config. The active symbol persists in `ng_active_symbol.txt` (a string,
which GlobalVariables cannot store).

> After a switch, Cerberus calls `ChartSetSymbolPeriod`, which is **asynchronous** and
> queues an EA re-init. Never close or restart the terminal in the seconds right after —
> see [Operations playbook](Operations-Playbook).
