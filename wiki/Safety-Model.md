# Safety model

## Rules of engagement

**Nothing touches a real account.** The system runs on a demo mirroring the real capital,
and it stays there until weeks of soak produce written metrics — then, and only then, by an
explicit decision. This is the operating rule the project was built under.

The guardian is the **last line, not the strategy**. It cannot make a losing engine
profitable. In v2.0 it bounds the damage two ways only: the daily-loss stop (rule E) and an
optional per-basket stop. Everything that closed a position *early* was removed, because
realising a loss breaks the average the shared basket TP relies on.

## Measure net USD, not win rate

The single most expensive lesson in this project.

A grid that never closes a loser produces a beautiful win rate while bleeding. Real numbers:

| Sample | Win rate | Result |
|---|---|---|
| Gold basket run | 74 % | **−$100** |
| BTC basket run | 86 % | **−$18** |
| Oracle 2.0 live | 62 % | **−$820 realized**, win/loss ratio 0.37 |
| Cerberus v1.x live tally | 66.5 % | avg win $0.76 vs avg loss **−$3.58** → ratio 0.21 |
| Faithful no-stop replica, 2.4-year backtest | 97 % winning cycles | **−99.99 %** |

The metric that matters is **net USD** and the **average-win / average-loss ratio**. A W/L
record is a knob: widen the target and the win rate falls, refuse to close losers and it
rises. Neither move changes expectancy.

That last row is the v2.0 motivation: Cerberus won *more* often than Oracle (66.5 % vs 62 %)
and still lost more, because its average loss was double Oracle's — the forced cuts. Removing
them is the whole point of v2.0.

> With a ~24-pip spread, a 15-pip TP has negative expectancy **at any win rate**. When the
> cost per cycle exceeds the target, no parameter tuning fixes it — the lever is the account
> type (Raw/Zero spread), not the settings.

## Equity, not balance

realised P/L and balance can climb while the account is actually losing, because the losing
baskets sit open in the floating. When judging the strategy, read **equity** at the same
instant, not balance: it includes what has not been closed yet. Both are true; only equity
is the result.

## What was rejected, and why

Recording rejections stops the same idea being rebuilt.

| Rejected | Why |
|---|---|
| **No-stop martingale grid** (the other half of Oracle 2.0) | 40 % drawdown tolerance; the faithful replica lost −99.99 % over 2.4 years despite 97 % winning cycles |
| **Tick-burst scalper** ("Bolt") | Retail feeds deliver ~1 tick/s — millisecond scalping does not exist here. The $10 BTC spread ate every target |
| **A $2.1 M backtest result** | An artifact: the margin required was impossible on a $4 k account, with a −$118 k floating drawdown |
| **A 65-config grid sweep** | Not one configuration passed PF > 1.2 with DD < 3 % out-of-sample; the tester overstates small-TP grids |
| **The old guardian rules A/B/C/D** | Each closed positions early, realising losses the basket TP would recover; they doubled the average loss |

## Backtest limits

- The Strategy Tester **cannot run the guardian** — no WebRequest, no DLL, no toggles. A
  green backtest says nothing about it.
- The tester systematically **overstates small-TP grids**, which is exactly this engine's
  shape.

The verdict on any strategy here comes from the live soak — and from the side-by-side
comparison against the real Oracle 2.0 running on a second demo account — not from the
tester.

## Operational safety

- Close orders **before** turning AutoTrading off — with AT off, closing fails.
- After a demo top-up, send `RESETDAY`, or the deposit reads as a gain and the rule E budget
  is wrong for the day.
- With `BasketStop_USD = 0` the broker-side SL is off too; rule E is the only automatic net,
  and it only runs while the terminal runs. For an unattended run set the basket stop above
  zero.
- Any EA in the terminal can close the whole terminal's orders — that is how the guardian
  polices foreign EAs. The AutoTrading button is terminal-global: **no EA can exempt itself
  from it**.

More in the [Operations playbook](Operations-Playbook).
