# Safety model

## Rules of engagement

**Nothing touches a real account.** The system runs on a demo mirroring the real capital,
and it stays there until weeks of soak produce written metrics — then, and only then, by an
explicit decision. This is not a disclaimer; it is the operating rule the project was built
under.

The guardian is the **last line, not the strategy**. It cannot make a losing engine
profitable. It exists to bound the damage of the engine being wrong, and every one of its
rules was added after a specific measured loss.

## Measure net USD, not win rate

The single most expensive lesson in this project.

A grid that never closes a loser produces a beautiful win rate while bleeding. Real numbers
from this system:

| Sample | Win rate | Result |
|---|---|---|
| Gold basket run | 74 % | **−$100** |
| BTC basket run | 86 % | **−$18** |
| Oracle 2.0 live | 62 % | **−$820 realized**, win/loss ratio 0.37 |
| Live MT5 tally | 58.8 % | avg win $0.43 vs avg loss $0.88 → ratio 0.49 |
| Faithful no-stop replica, 2.4-year backtest | 97 % winning cycles | **−99.99 %** |

The metric that matters is **net USD** and the **average-win / average-loss ratio**. A W/L
record is a knob, not a virtue: widen the target and the win rate falls, refuse to close
losers and it rises. Neither move changes expectancy.

Related: with a 24-pip spread, a 15-pip TP has negative expectancy **at any win rate**. When
the cost per cycle exceeds the target, no parameter tuning fixes it — the lever is the
account type (Raw/Zero spread), not the settings.

## Auto-off counts cycles, not dollars

The per-symbol auto-off disables a symbol after N cycles without an edge. Note what it
counts: **cycles**, not money. A symbol can be switched off with a strong W/L record and a
negative net. Read the net before overruling it with `SYMON`.

## What was rejected, and why

Recording rejections matters as much as recording features — it stops the same idea being
rebuilt.

| Rejected | Why |
|---|---|
| **No-stop martingale grid** (the other half of Oracle 2.0) | 40 % drawdown tolerance; the faithful replica lost −99.99 % over 2.4 years despite 97 % winning cycles |
| **Tick-burst scalper** ("Bolt") | Retail feeds deliver ~1 tick/s — millisecond scalping does not exist here. The $10 BTC spread ate every target; no-net ladder baskets erased strings of small wins twice |
| **A $2.1 M backtest result** | An artifact: the margin required was impossible on a $4 k account, with a −$118 k floating drawdown |
| **A 65-config grid sweep** | Not one configuration passed PF > 1.2 with DD < 3 % out-of-sample; the tester overstates small-TP grids |

The useful halves survived: the breakout entry and the per-symbol scaling live on inside
Cerberus. The dangerous halves were not rebuilt.

## Backtest limits

- The Strategy Tester **cannot run the guardian** — no WebRequest, no DLL, no toggles. A green backtest says nothing about it.
- The tester systematically **overstates small-TP grids**, which is exactly this engine's shape.
- MT4 models ticks; MT5 can replay real ones. Cross-platform comparison is valid only in normalised terms — see [Tools and panels](Tools-and-Panels).

The verdict on any strategy here comes from the live soak, not from the tester.

## Operational safety

- Close orders **before** turning AutoTrading off — with AT off, closing fails.
- Do not leave manual `BUY`/`SELL` command positions open: magic `777999`, no SL, no TP, no manager.
- After a demo top-up, send `RESETDAY`, or the deposit reads as a gain and the rule E budget is wrong for the day.
- Any EA in the terminal can close the whole terminal's orders — that is how the guardian polices foreign EAs. Equally, the AutoTrading button is terminal-global: **no EA can exempt itself from it**.

More in the [Operations playbook](Operations-Playbook).
