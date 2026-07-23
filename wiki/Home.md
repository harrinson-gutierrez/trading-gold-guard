# Trading Gold Guard — Cerberus

Documentation for **Cerberus**, a guarded grid-trading system for **MetaTrader 4**.
One Expert Advisor runs two heads on a single chart: a **guardian** that defends the
account against every position in the terminal, and the **ORACLE** strategy that trades it —
a measured replica of the Oracle 2.0 bot.

Current version **v2.0**. From this version the project is **MetaTrader 4 only**; the earlier
parallel MQL5 build was removed.

> **Demo only.** Nothing in this project touches a real account. See
> [Safety model](Safety-Model).

## Start here

| Page | What it answers |
|---|---|
| [Architecture](Architecture) | How the two heads, magics, timers and state fit together |
| [Guardian rules](Guardian) | What defends the account: rule E + the optional basket stop |
| [ORACLE engine](Oracle-Engine) | How the grid fades the market, enters, adds, exits and stops |
| [Configuration](Configuration-and-Presets) | The MAIN inputs, the `.set` file, hot overrides |
| [Command channel](Commands) | Every hot command |
| [Build and deploy](Build-and-Deploy) | Compiling, installing, editing inputs without the GUI |
| [Operations playbook](Operations-Playbook) | Live traps that already cost money once |
| [Tools and panels](Tools-and-Panels) | Live comparator, PosRecorder, compare panel |
| [Safety model](Safety-Model) | Rules of engagement, and how results are measured |

## The system in one screen

```
                      ┌──────────────────────────────────────┐
   ForexFactory ─────► │  GUARDIAN  (always on, all magics)   │
   calendar JSON       │  news block · rule E · basket stop   │
   (+ disk cache)      └───────────────┬──────────────────────┘
                                       │ block new / close-all / cut basket
                      ┌────────────────▼─────────────────────┐
                      │  ORACLE  (magics 7799 / 9977)        │
   ng_command.txt ───► │  MA34(EMA,Open) + Gann HiLo(3,EMA)   │
   (hot commands)      │  FADES the market · one basket/flip  │
                      └───────────────┬──────────────────────┘
                                       │
                        ng_status.json · Cerberus_log.csv
```

The guardian is the last line, not the strategy. v2.0 stripped it to the two nets the owner
kept on purpose — the daily-loss stop and an optional per-basket stop — because every rule
that closed a position *early* was realising losses the shared basket TP would have
recovered.

## Repository

| Path | Contents |
|---|---|
| `src-mt4/` | `Cerberus.mq4` (~1 500 lines), `PosRecorder.mq4` |
| `config/` | Production `.set`, chart profiles, install notes |
| `tools/` | Live engine comparator |
| `compare-panel/` | Read-only multi-account web panel |
| `docs/` | Design specs and experiment write-ups |
