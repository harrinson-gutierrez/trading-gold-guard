# Trading Gold Guard — Cerberus

Documentation for **Cerberus**, a guarded grid-trading system for MetaTrader 4 and 5.
One Expert Advisor runs two heads on a single chart: a **guardian** that defends the
account against every position in the terminal, and the **ORACLE** strategy that trades it.

Both platform builds are kept in lockstep at **v1.15** and share the same inputs, command
channel and preset file format.

> **Demo only.** Nothing in this project touches a real account. See
> [Safety model](Safety-Model).

## Start here

| Page | What it answers |
|---|---|
| [Architecture](Architecture) | How the two heads, magics, timers and state fit together |
| [Guardian rules](Guardian) | What closes a position, and why each rule exists |
| [ORACLE engine](Oracle-Engine) | How the grid enters, adds, exits and stops |
| [Configuration and presets](Configuration-and-Presets) | The three config layers, `.set` files and `symbol_presets.txt` |
| [Command channel](Commands) | Every hot command, with MT4/MT5 availability |
| [Build and deploy](Build-and-Deploy) | Compiling, installing, editing inputs without the GUI |
| [MT4 vs MT5](MT4-vs-MT5) | Parity matrix and the platform-specific gaps |
| [Operations playbook](Operations-Playbook) | Live traps that already cost money once |
| [Tools and panels](Tools-and-Panels) | Golden master, live comparator, PosRecorder, compare panel |
| [Safety model](Safety-Model) | Rules of engagement, and how results are measured |

## The system in one screen

```
                      ┌──────────────────────────────────────┐
   ForexFactory ─────► │  GUARDIAN  (always on, all magics)   │
   calendar JSON       │  news · rules A/B/C/D/E · gates      │
   (+ disk cache)      └───────────────┬──────────────────────┘
                                       │ pause / close / block
                      ┌────────────────▼─────────────────────┐
                      │  ORACLE  (magics 7799 / 9977)        │
   ng_command.txt ───► │  EMA34 + HiLo(3) on M1               │
   (hot commands)      │  additive grid · shared basket TP    │
                      └───────────────┬──────────────────────┘
                                       │
                        ng_status.json · Cerberus_log.csv
```

The guardian is the last line, not the strategy. Every rule in it was added because a
measured loss demanded it — the reasoning is recorded on each page rather than lost in
commit messages.

## Repository

| Path | Contents |
|---|---|
| `src-mt5/` | `Cerberus.mq5` (3 100 lines), `PosRecorder.mq5` |
| `src-mt4/` | `Cerberus.mq4` (1 800 lines), `PosRecorder.mq4` |
| `config/` | Production `.set`, `symbol_presets.txt`, chart profiles, install notes |
| `tools/` | Golden-master and live engine comparators |
| `compare-panel/` | Read-only multi-account web panel |
| `docs/` | Design specs and experiment write-ups |
