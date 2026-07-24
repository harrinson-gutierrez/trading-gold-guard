# Trading Gold Guard — Cerberus

A guarded grid-trading system for **MetaTrader 4**. One EA, **Cerberus**, runs two heads in
a single chart: an always-on **guardian** that defends the account, and the **ORACLE**
strategy that trades it — a faithful, measured replica of the Oracle 2.0 bot.

Current deployment: Exness MT4 demo, gold `XAUUSDm`, hedging, 1:200. **Demo soak only** —
see [Risk disclosure](#-risk-disclosure).

> **MT4 only.** Earlier versions shipped a parallel MQL5 build; from v2.0 the project is
> MetaTrader 4 exclusively. The MT5 sources and release binaries were removed.

## ⚠️ Risk disclosure

**This is a high-risk experimental system. It is not a product, not advice, and not
validated. Do not run it with money you cannot afford to lose entirely.**

- **It is a grid. The payoff is asymmetric.** Profit per cycle is capped (`TP` = 15 pips on
  a 0.01 lot), the loss is not. Every adverse level adds exposure while price keeps going
  the wrong way. A high win rate is a *knob*, not an edge: measured cycles have run at
  62–97 % wins while the account bled in net USD, because the winners are small and the
  losers are the whole basket.
- **It fades the market.** The strategy enters *against* the move (buys weakness, sells
  strength) and averages down. That is what a mean-reversion grid does; it works until it
  meets the move that does not revert, and then the whole basket is the loss.
- **It does not protect against market volatility.** The guardian reacts *after* the move
  starts — it cannot predict gaps, news spikes, or a broker halting execution. Measured
  2026-07-22: the broker disabled algo trading during a $27/hour move in gold and every
  close attempt was rejected. Only the broker-side SL survives that, and only if
  `BasketStop_USD > 0`. Slippage, spread widening, requotes, weekend gaps and rollover
  halts are all outside the EA's control.
- **The EA only defends while it runs.** Measured 2026-07-23: the terminal sat off for 13 h
  with a live basket; nothing guarded it, and rule E only fired on restart with the damage
  already done. An unattended VPS or a broker-side SL is the only cover for that.
- **On small accounts the losses are disproportionately large.** The 0.01-lot minimum is a
  hard floor — the strategy cannot be scaled down below it. The same basket that risks a
  few percent on $4 000 can be a margin call on $500. The capital-proportional depth cap
  (`Capital_Base` / `Capital_PerLevel`) mitigates this but does not remove it.
- **No backtest here has passed validation.** A 65-config sweep plus out-of-sample produced
  zero configurations meeting PF > 1.2 with DD < 3 %, and the tester systematically
  overstates small-TP grids. A faithful replica of the reference bot lost **−99.99 %** over
  a 2.4-year backtest *despite* 97 % winning cycles.

Use it as a study of guarded grid mechanics, an EA skeleton, or a measurement harness. Do
not use it as a money machine.

| Build | Source | Version | Terminal |
|---|---|---|---|
| MT4 | [src-mt4/Cerberus.mq4](src-mt4/Cerberus.mq4) | 2.0 | MetaTrader 4 EXNESS (demo `73114764`) |

The strategy is validated live, side by side, against the real Oracle 2.0 bot running on a
separate demo account (`73114915`) — same symbol, same instant — until the two behave
alike.

## The two heads

### Guardian (always on, all magics)

The guardian polices **every** position in the terminal, including those of other EAs.
v2.0 keeps only the two nets the owner chose deliberately:

| Rule | Trigger (default) | Action |
|---|---|---|
| **E — daily loss** | Equity down `DailyLoss_USD` = 200 USD from the day baseline | Closes **everything** and pauses until `RESUME` |
| **Basket stop** *(optional)* | A basket floating below `BasketStop_USD` (default **0 = off**) | Cuts that basket, with a cooldown before re-arming. `BasketStop_ServerSL` mirrors it as a broker-side SL per position so it still executes if our close orders are rejected |

**Display only — never blocks, never closes:**

- **News**: on a High-impact event (any currency, ±`News_MinutesBefore`/`After` = 30/45 min)
  it stops opening **new** baskets; open baskets are left alone. ForexFactory JSON feed with
  disk cache. This matches Oracle's `NewsAction=0`.
- **Hour-risk band** and **weekly-close warning**: shown on the panel and in
  `ng_status.json`, purely informational.

> **Removed in v2.0:** rule A (adverse pips), rule B (margin level), rule C (volatility
> breaker), rule D (USD per position), the close-all on news, the Friday pre-close flatten
> and the whole scheduler. Every one of them *closed* a position early, which realises a
> loss the shared basket TP would usually have recovered — the mechanism that pushed the
> average loss to −$3.58 against Oracle's −$1.78 while winning *more* often.

### ORACLE strategy (magics 7799 / 9977)

A faithful replica of the Oracle 2.0 bot — measured live, not guessed.

- **Direction — it fades the market.** Gann HiLo(3, EMA) gives the trend/breakout side;
  the entry is the **opposite** of it (falling market → BUY, rising → SELL). MA(34, EMA on
  the **Open**) is the tie-breaker before the HiLo has a side. Verified side-by-side against
  the real Oracle, which trades the same way with `InpHILOFilterInverter=false`.
- **Two engines, one side at a time**: magic **7799 takes the SELL** side and **9977 the
  BUY** side (the reverse of Oracle's own cosmetic labels). Before a fresh basket arms, any
  basket the *other* engine still holds is closed, so a fade flip leaves the book on **one
  side only** — no hedged SELL+BUY dead weight.
- **Cadence — re-arm immediately**, like Oracle: as long as the fade side is valid, a closed
  basket opens the next on the following tick. (A HiLo-flip gate was tried and removed — it
  starved the win-booking to ~28 basket cycles against Oracle's ~72.)
- **Grid**: on an adverse move of `GridStep_Pips` it adds a level at **constant lot**
  (`Lot_Factor = 1.0` — additive, *not* martingale ×2; confirmed by Oracle opening every
  level at 0.01).
- **Trend brake**: `TrendBrake_MaxDistPips` (default **120**, ≈ $12 on XAUUSD; lowered from 150 so a gradual grind — where the MA follows price down and the distance never spikes — gets braked earlier, not only a fast move). While price is more than N pips
  from the MA34 — a strong directional move — **no new basket and no adds** open (the book is
  only allowed to run and close). Fading a runaway trend is what buries a grid; Oracle stays
  quiet in that regime (~1 open/min) while Cerberus was opening 2–6/min into the same move.
  Measured live: with the brake on, Cerberus matched Oracle at 20 vs 19 opens and depth 3 vs 3
  over the same window. Visible on the panel and in `ng_status.json` (`trend_brake`).
- **Exit — hybrid, like Oracle.** Each order has its own individual server-side TP
  (`TakeProfit_Pips` from *its own* open) to book quick scalps; **and** the whole basket
  closes when its total floating equals one TP unit — the weighted average at **+TP / n**
  pips, not +TP. A deep 5-level ladder therefore clears on a 3-pip bounce instead of an
  unreachable 15, which is what keeps the book lean (measured: floating fell from −$16.54 to
  −$1.70, matching Oracle). Whichever exit hits first.
- **Depth cap**: `MaxGrid_Levels`, or a capital-proportional cap
  (`Capital_Base` / `Capital_PerLevel`) so the risk scales with the declared balance.
- **Basket stop**: `BasketStop_USD` (default 0). ⚠️ **At 0 the broker-side SL is off too** —
  the SL is attached only when the stop is armed. With the stop off, the account-level rule E
  is the only net. Set it above zero for any unattended run.

## Configuration

The 10 inputs that get tuned live sit at the top of the file under `======== MAIN ========`;
everything else is grouped behind `SIGNAL` / `NEWS` / `DISPLAY ONLY` / `ADVANCED`
separators. Input labels read like the variable name, in English.

| MAIN input | Production value | Meaning |
|---|---|---|
| `Symbol_Traded` | XAUUSDm | Traded symbol |
| `TakeProfit_Pips` | 15 | Basket TP, pips from the weighted average |
| `GridStep_Pips` | 100 | Pips against before adding the next level |
| `Lot_Fixed` | 0.01 | Fixed lot per level |
| `Lot_Factor` | 1.0 | Additive grid (no lot multiplication) |
| `MaxSpread_Points` | 240 | No entry/add above this spread |
| `MaxGrid_Levels` | 0 | 0 → the capital-proportional cap applies |
| `DailyLoss_USD` | 200 | Rule E: close everything and pause |
| `BasketStop_USD` | 0 | Optional per-basket stop (0 = off, like Oracle) |

On XAUUSDm a strategy pip is `Point*10` = **$0.01**, so `TP=15` is a 15-cent move and
`GRID=100` a $1.00 step. Hot overrides (`SET`, `BSTOP`) persist in GlobalVariables and win
over the `.chr` seed until cleared; the active config is always in `ng_status.json`
(`config:{}`) and on the panel.

[config/Cerberus_XAUUSDm.set](config/Cerberus_XAUUSDm.set) is the full production input set,
loadable from the MetaEditor "Load" button.

## Command channel

Write **one line** to `ng_command.txt` in the terminal's `Files` folder; Cerberus picks it
up within 30 s, no restart.

| Command | Effect |
|---|---|
| `AT_ON` / `AT_OFF` | Toggle the global AutoTrading button (via `user32.dll`) |
| `PAUSE` / `RESUME` | Manual pause; `RESUME` also clears a rule E pause |
| `CLOSEALL` | Close every order in the terminal |
| `RESETDAY` | Re-anchor the rule E daily baseline (use after a demo top-up) |
| `TEST=N` | Inject a fake news event N minutes ahead (tests the news block) |
| `ORACLE_ON` / `ORACLE_OFF` | Enable/disable the strategy head |
| `SET TP=… GRID=… LOT=… FACTOR=… MAXLEV=…` | Hot config, any subset; re-anchors the open basket's TP |
| `BSTOP <usd>` | Hot basket stop (0 = off) |
| `CONFIG` / `PANELDUMP` | Log the active config / dump the panel to a file |

## Build & install

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1   # src-mt4/*.mq4 -> MT4 EXNESS
```

The script copies the sources into the terminal's `Experts` folder and compiles them with
that terminal's MetaEditor, demanding **0 errors**. Compiling works with the terminal open,
but **loading** a new binary needs a terminal restart (`CloseMainWindow()` on the process,
then relaunch). The profile keeps charts, EAs and inputs.

## Terminal setup (once per terminal)

Tools → Options → Expert Advisors:

1. ✅ Allow algorithmic trading (AutoTrading button ON).
2. ✅ Allow DLL imports — required for the AutoTrading toggle through `user32.dll`.
3. ✅ Allow WebRequest for `https://nfs.faireconomy.media` — **GUI only**: MetaTrader stores
   this list encrypted, it cannot be set from a file. Without it the calendar fails with
   error 4014 and the guardian runs on cache.

The account must be **hedging** — a basket holds several positions per symbol.

## Runtime files

In `MQL4\Files\`:

| File | Contents |
|---|---|
| `Cerberus_log.csv` | Action log, `gmt_date;action;detail` |
| `ng_status.json` | Full state every 30 s: config, baskets, tally, drawdown |
| `ng_command.txt` | Command channel (consumed on read) |
| `ff_cache.json` | ForexFactory calendar cache |

> ⚠️ Never `tail -f` a file in this folder — it blocks the EA's `FileOpen` and log lines
> are silently lost. Read them punctually instead.

## Tools

| Path | Purpose |
|---|---|
| [src-mt4/PosRecorder.mq4](src-mt4/PosRecorder.mq4) | Read-only 1 Hz CSV snapshot of every open position — never touches an order |
| [tools/engine_live_compare.py](tools/engine_live_compare.py) | Diffs the live baskets of Cerberus against the real Oracle 2.0 from the PosRecorder snapshots |
| `compare-panel/` *(local only)* | Read-only web panel comparing the two accounts side by side, metric by metric |

## Safety model

**Nothing touches a real account.** The system runs on demo until weeks of soak produce
written metrics, and only then by explicit decision. The guardian is the last line, not the
strategy — and a win rate is not an edge: measure **net USD** and the
average-win/average-loss ratio, because a grid that never closes losers can show 63 % wins
while bleeding.

What the guardian **can** do: cut a basket, flatten the account and stop the day. What it
**cannot** do: predict a move, execute when the broker refuses orders, close a gap it was
already holding through, guard the account while the terminal is off, or make a
negative-expectancy engine positive. Read the [Risk disclosure](#-risk-disclosure) before
running any of this anywhere.

## Licence and disclaimer

Provided **as is**, with no warranty of any kind, for research and educational use. This is
not financial advice and not a solicitation to trade. Trading leveraged CFDs on margin
carries a high risk of losing money rapidly, including more than the initial deposit on
non-protected accounts. The authors accept no liability for any loss arising from the use of
this code. You are solely responsible for anything you run on your own account.

Full documentation: **[the wiki](../../wiki)**.
