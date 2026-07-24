# Configuration

Cerberus has **two configuration layers**, the hot one overriding the seed. Knowing which is
winning is the difference between "the EA ignores my settings" and "I edited the seed, not
the live value".

```
1. EA inputs        .chr chart file / .set file     seed only, read at OnInit
2. Hot overrides    SET / BSTOP                      GlobalVariables, survive restarts
```

The inputs in the `.chr` are **only the seed**. Once an override is applied it wins until
cleared — deleting the `CB4_ov*` GlobalVariables, or setting the input value again. The
internal accessors (`EffTP()`, `EffGrid()`, `EffLot()`, `EffFactor()`, `EffMaxLev()`,
`EffBstop()`) always resolve seed-then-override, so no code path can accidentally read the
seed.

**Where to see what is actually live:** `ng_status.json` → `config:{}`, or the chart panel.
Never assume from the `.chr`.

```json
"config":{"symbol":"XAUUSDm","tp":15,"grid":100,"lot":0.01,"maxlev":0}
```

## The MAIN inputs

The ten inputs that get tuned live sit at the top of the file under `======== MAIN ========`.
Everything else is grouped behind `SIGNAL` / `NEWS` / `DISPLAY ONLY` / `ADVANCED`
separators. Input labels read like the variable name, in English.

| Input | Production | Meaning |
|---|---|---|
| `Symbol_Traded` | XAUUSDm | Traded symbol |
| `TakeProfit_Pips` | 15 | Basket TP, pips from the weighted average |
| `GridStep_Pips` | 100 | Pips against before adding the next level |
| `Lot_Fixed` | 0.01 | Fixed lot per level |
| `Lot_Factor` | 1.0 | Additive grid (1.0 = no lot multiplication) |
| `MaxSpread_Points` | 240 | No entry/add above this spread |
| `MaxGrid_Levels` | 0 | 0 → use the capital-proportional cap |
| `DailyLoss_USD` | 200 | Rule E: close everything and pause |
| `BasketStop_USD` | 0 | Optional per-basket stop (0 = off, like Oracle) |

On XAUUSDm a strategy pip is `Point*10` = **$0.01**, so `TP=15` is a 15-cent target and
`GRID=100` a $1.00 step.

## Hot overrides

| Command | Effect |
|---|---|
| `SET TP=15 GRID=100 LOT=0.01 FACTOR=1.0 MAXLEV=0` | Any subset; re-anchors the open basket's TP immediately |
| `BSTOP <usd>` | Basket stop in USD (0 = off) |
| `CONFIG` | Log the active config |

Both persist in GlobalVariables and survive a restart. The basket stop is commonly raised
**live** (`BSTOP 40`) without editing the `.chr`; the override wins over the seed until
cleared, which is why the `.chr` can read `0` while the panel shows `40`.

## Input set file

`config/Cerberus_XAUUSDm.set` is the full production input set, loadable from MetaEditor's
*Load* button. It carries the compiled defaults, which **are** the production config
(`TP=15 / GRID=100 / BSTOP=0`, fade, re-arm immediate, one side, hybrid TP/n exit). There are no deviations to
list in v2.0 — the defaults are the deployed config.

## Editing inputs without the GUI

The chart file `MQL4\Profiles\Default\chart01.CHR` must be edited with the terminal
**closed** — the terminal rewrites it on exit, discarding your changes otherwise.

The `<expert>` block sits near the end of the chart, before `</chart>`:

```
<expert>
name=Cerberus
flags=343      ; live trading + DLL imports enabled
window_num=0
<inputs>
...
</inputs>
</expert>
```

Because the input **names** changed in v2.0, an old `.chr` from a v1.x build carries stale
input lines; MT4 ignores unknown inputs and uses the compiled defaults for the rest. The
clean way to reset to defaults is to empty the `<inputs>` block (terminal closed) — MT4 then
seeds every input from the binary, which prints them in the `INIT` log line for
verification.

> Also clear the `CB4_ov*` GlobalVariables when resetting, or a stale hot override
> (e.g. an old `GRID=90`) will shadow the new default. See
> [Operations playbook](Operations-Playbook).
