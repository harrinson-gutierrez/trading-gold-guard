#!/usr/bin/env python3
"""Compare the Cerberus (MT5) engine against Oracle 2.0 (MT4) from live 1 Hz
position snapshots written by PosRecorder.mq5 / PosRecorder.mq4.

The golden-master comparator (golden_master_compare.py) diffs Strategy Tester
reports; this one diffs what the two engines actually DID, second by second, on
two live accounts running the same nominal config. It answers the questions the
tester cannot: do they take the same side at the same time, how far apart are
their grid levels, how deep does each basket get, how long does a cycle live,
and what is the win/loss ratio per basket.

A "basket" here is one engine's (magic's) uninterrupted occupation of the
market: it starts when that magic goes from 0 open positions to >=1 and ends
when it returns to 0. That is the unit both engines actually manage - they share
one basket TP across every level.

Usage:
    python engine_live_compare.py --mt5 pos_snapshot_mt5.csv --mt4 pos_snapshot_mt4.csv \
        [--start "2026.07.21 17:15:00"] [--end "2026.07.21 18:15:00"] [--pip 0.01] [--json out.json]

Pip note: XAUUSDm quotes with 3 decimals on Exness, and BOTH engines size their
grid in _Point*10 units, so one strategy pip is 0.01 price units ($0.01 on a
0.01 lot). That is the --pip default. It is NOT the guardian's PipSizeOverride
(0.1), which only scales rule A.
"""

import argparse
import csv
import json
from collections import defaultdict
from datetime import datetime
from statistics import mean, median

TS_FMT = "%Y.%m.%d %H:%M:%S"


# ----------------------------------------------------------------- loading
def load_samples(path, start=None, end=None):
    """CSV -> {timestamp: {equity, balance, floating, positions[]}}, one entry per second."""
    samples = {}
    with open(path, newline="", encoding="ascii", errors="replace") as fh:
        for row in csv.DictReader(fh, delimiter=";"):
            raw_ts = (row.get("ts_gmt") or "").strip()
            try:
                ts = datetime.strptime(raw_ts, TS_FMT)
            except ValueError:
                continue
            if start and ts < start:
                continue
            if end and ts >= end:
                continue
            snap = samples.setdefault(ts, {
                "equity": _f(row["equity"]), "balance": _f(row["balance"]),
                "floating": _f(row["floating"]), "positions": [],
            })
            ticket = (row.get("ticket") or "0").strip()
            if ticket in ("", "0"):
                continue          # heartbeat line: the account IS flat this second
            snap["positions"].append({
                "ticket": ticket,
                "magic": (row.get("magic") or "0").strip(),
                "symbol": (row.get("symbol") or "").strip(),
                "type": (row.get("type") or "").strip(),
                "lots": _f(row["lots"]),
                "open_price": _f(row["open_price"]),
                "age_s": int(_f(row["age_s"])),
                "tp": _f(row["tp"]),
                "sl": _f(row["sl"]),
                "profit": _f(row["profit"]) + _f(row["swap"]),
                "spread_pts": _f(row.get("spread_pts", 0)),
            })
    return samples


def _f(v):
    try:
        return float(str(v).strip() or 0)
    except ValueError:
        return 0.0


# ----------------------------------------------------------------- baskets
def build_baskets(samples, pip, pip_points=10):
    """Split each magic's timeline into baskets (0 -> N -> 0 occupations)."""
    baskets = []
    open_now = {}                      # magic -> basket being accumulated
    prev_tickets = {}                  # magic -> ticket set at the previous second

    for ts in sorted(samples):
        by_magic = defaultdict(list)
        for p in samples[ts]["positions"]:
            by_magic[p["magic"]].append(p)

        for magic, basket in list(open_now.items()):
            if magic not in by_magic:                       # went flat: close it
                basket["end"] = ts
                baskets.append(basket)
                del open_now[magic]
                prev_tickets.pop(magic, None)

        for magic, positions in by_magic.items():
            tickets = {p["ticket"] for p in positions}
            basket = open_now.get(magic)
            # Total ticket turnover inside ONE second = the engine closed its
            # basket at TP and armed the next one before the next sample. At 1 Hz
            # that looks like an uninterrupted occupation; without this split the
            # two cycles merge and the gap between them shows up as a bogus
            # sub-pip "grid step" (and as double depth). Cerberus cycles fast
            # enough for this to matter - Oracle, slower, rarely triggers it.
            if basket is not None and prev_tickets.get(magic) and not (tickets & prev_tickets[magic]):
                basket["end"] = ts
                baskets.append(basket)
                del open_now[magic]
                basket = None
            prev_tickets[magic] = tickets
            if basket is None:
                basket = open_now[magic] = {
                    "magic": magic, "start": ts, "end": None,
                    "levels": {},        # ticket -> first snapshot of it
                    "depth_max": 0, "floating_min": 0.0, "floating_last": 0.0,
                    "tp_seen": set(), "spread": [],
                    "adds_pips": [],     # clean adds: distance to the basket extreme
                    "adds_dirty": 0,     # adds seen in a second where something also closed
                    "_prev": None, "_extreme": None,
                }

            # How the ENGINE measures an add: adverse distance from the basket
            # EXTREME (Oracle_OnSymbol: `adverse = (dir<0) ? bid-last : last-bid`,
            # last = extreme). Only count seconds where nothing closed - a
            # non-atomic basket close leaves stragglers next to the first level
            # of the NEXT cycle, which would fake a sub-grid add.
            prev = basket["_prev"]
            if prev is not None:
                new_tk = tickets - prev
                if new_tk:
                    if prev <= tickets and basket["_extreme"] is not None:
                        for p in positions:
                            if p["ticket"] in new_tk:
                                # The gate is `adverse = |extreme - BID| >= grid`, but a
                                # BUY level fills at the ASK - one spread ABOVE the bid.
                                # Entry-to-entry therefore understates a BUY add by exactly
                                # one spread (24 pips on XAUUSDm, ~80% of a 30-pip grid).
                                # Add it back so the number is comparable to the gate.
                                d = abs(p["open_price"] - basket["_extreme"]) / pip
                                if p["type"] == "BUY":
                                    d += p["spread_pts"] / pip_points
                                basket["adds_pips"].append(d)
                    else:
                        basket["adds_dirty"] += len(new_tk)
            side_is_buy = positions[0]["type"] == "BUY"
            prices = [p["open_price"] for p in positions]
            basket["_extreme"] = min(prices) if side_is_buy else max(prices)
            basket["_prev"] = tickets
            floating = sum(p["profit"] for p in positions)
            basket["depth_max"] = max(basket["depth_max"], len(positions))
            basket["floating_min"] = min(basket["floating_min"], floating)
            basket["floating_last"] = floating
            for p in positions:
                basket["levels"].setdefault(p["ticket"], dict(p, first_seen=ts))
                if p["tp"]:
                    basket["tp_seen"].add(round(p["tp"], 5))
                if p["spread_pts"]:
                    basket["spread"].append(p["spread_pts"])

    for magic, basket in open_now.items():                  # still open at the cut
        basket["end"] = None
        basket["open_at_end"] = True
        baskets.append(basket)

    for b in baskets:
        _finish(b, pip)
    return sorted(baskets, key=lambda b: b["start"])


def _finish(b, pip):
    levels = sorted(b["levels"].values(), key=lambda p: (p["first_seen"], p["ticket"]))
    b["n_levels"] = len(levels)
    b["sides"] = sorted({p["type"] for p in levels})
    b["hedged"] = len(b["sides"]) > 1
    b["lots"] = sum(p["lots"] for p in levels)
    b["entries"] = [p["open_price"] for p in levels]
    b["symbol"] = levels[0]["symbol"] if levels else ""

    # Grid step measured the way a grid actually adds: distance from each new
    # level to the NEAREST already-open level (adding off the basket extreme
    # means consecutive-by-time is not the same as consecutive-by-price).
    steps = []
    for i, p in enumerate(levels[1:], start=1):
        prev = [q["open_price"] for q in levels[:i]]
        steps.append(min(abs(p["open_price"] - x) for x in prev) / pip)
    b["steps_pips"] = steps
    b["span_pips"] = (max(b["entries"]) - min(b["entries"])) / pip if len(levels) > 1 else 0.0

    if b["end"]:
        b["duration_s"] = int((b["end"] - b["start"]).total_seconds())
    else:
        b["duration_s"] = None

    # TP distance from the volume-weighted average entry (the shared basket TP).
    if levels and b["tp_seen"]:
        vol = sum(p["lots"] for p in levels) or 1
        avg = sum(p["open_price"] * p["lots"] for p in levels) / vol
        tp = sorted(b["tp_seen"])[-1] if levels[0]["type"] == "BUY" else sorted(b["tp_seen"])[0]
        b["tp_dist_pips"] = abs(tp - avg) / pip
        b["avg_entry"] = avg
    else:
        b["tp_dist_pips"] = None
        b["avg_entry"] = None
    b["spread_med"] = median(b["spread"]) if b["spread"] else None


# ----------------------------------------------------------------- summaries
def summarize(name, samples, baskets):
    if not samples:
        return {"name": name, "samples": 0}
    times = sorted(samples)
    span = int((times[-1] - times[0]).total_seconds()) + 1
    in_market = sum(1 for t in times if samples[t]["positions"])
    closed = [b for b in baskets if b["duration_s"] is not None]
    wins = [b for b in closed if b["floating_last"] > 0]
    losses = [b for b in closed if b["floating_last"] <= 0]

    def ag(key, source=closed, fn=mean):
        vals = [b[key] for b in source if b.get(key) is not None]
        return fn(vals) if vals else None

    all_steps = [s for b in baskets for s in b["steps_pips"]]
    all_adds = [a for b in baskets for a in b["adds_pips"]]
    return {
        "adds_clean": len(all_adds),
        "adds_dirty": sum(b["adds_dirty"] for b in baskets),
        "add_pips_med": median(all_adds) if all_adds else None,
        "add_pips_min": min(all_adds) if all_adds else None,
        "add_pips_max": max(all_adds) if all_adds else None,
        "adds_under_20": sum(1 for a in all_adds if a < 20),
        "name": name,
        "samples": len(times), "window_s": span,
        "gaps_s": span - len(times),
        "first": times[0].strftime(TS_FMT), "last": times[-1].strftime(TS_FMT),
        "equity_first": samples[times[0]]["equity"], "equity_last": samples[times[-1]]["equity"],
        "in_market_pct": 100.0 * in_market / len(times),
        "baskets": len(baskets), "baskets_closed": len(closed),
        "levels_total": sum(b["n_levels"] for b in baskets),
        "depth_max": max((b["depth_max"] for b in baskets), default=0),
        "depth_avg": ag("n_levels", baskets),
        "step_pips_med": median(all_steps) if all_steps else None,
        "step_pips_min": min(all_steps) if all_steps else None,
        "step_pips_max": max(all_steps) if all_steps else None,
        "tp_dist_pips_med": ag("tp_dist_pips", baskets, median),
        "span_pips_max": max((b["span_pips"] for b in baskets), default=0),
        "dur_s_med": ag("duration_s", closed, median),
        "dur_s_max": max((b["duration_s"] for b in closed), default=0),
        "float_min_worst": min((b["floating_min"] for b in baskets), default=0),
        "pl_sum": sum(b["floating_last"] for b in closed),
        "wins": len(wins), "losses": len(losses),
        "win_rate_pct": 100.0 * len(wins) / len(closed) if closed else None,
        "avg_win": mean([b["floating_last"] for b in wins]) if wins else None,
        "avg_loss": mean([b["floating_last"] for b in losses]) if losses else None,
        "hedged_baskets": sum(1 for b in baskets if b["hedged"]),
        "buy_baskets": sum(1 for b in baskets if b["sides"] == ["BUY"]),
        "sell_baskets": sum(1 for b in baskets if b["sides"] == ["SELL"]),
        "spread_med": median([b["spread_med"] for b in baskets if b["spread_med"] is not None])
                      if any(b["spread_med"] is not None for b in baskets) else None,
    }


def direction_agreement(s5, s4):
    """Per second: what side is each platform holding? Only seconds present in both count."""
    common = sorted(set(s5) & set(s4))
    both_in = same = opposite = only5 = only4 = flat_both = 0
    for t in common:
        d5 = _side(s5[t]["positions"])
        d4 = _side(s4[t]["positions"])
        if d5 and d4:
            both_in += 1
            if d5 == d4:
                same += 1
            elif "MIX" not in (d5, d4):
                opposite += 1
        elif d5:
            only5 += 1
        elif d4:
            only4 += 1
        else:
            flat_both += 1
    return {
        "common_s": len(common), "both_in_market_s": both_in,
        "same_side_s": same, "opposite_side_s": opposite,
        "only_mt5_s": only5, "only_mt4_s": only4, "flat_both_s": flat_both,
        "same_side_pct": 100.0 * same / both_in if both_in else None,
    }


def _side(positions):
    if not positions:
        return None
    sides = {p["type"] for p in positions}
    return sides.pop() if len(sides) == 1 else "MIX"


# ----------------------------------------------------------------- output
def fmt(v, nd=2):
    if v is None:
        return "-"
    return f"{v:.{nd}f}" if isinstance(v, float) else str(v)


def report(sum5, sum4, agree, baskets5, baskets4):
    rows = [
        ("Muestras (s)", "samples", 0), ("Huecos (s)", "gaps_s", 0),
        ("Tiempo en mercado %", "in_market_pct", 1),
        ("Canastas", "baskets", 0), ("Canastas cerradas", "baskets_closed", 0),
        ("Niveles abiertos", "levels_total", 0),
        ("Profundidad max", "depth_max", 0), ("Profundidad media", "depth_avg", 2),
        ("Adds medidos limpios", "adds_clean", 0),
        ("Adds descartados (cierre mixto)", "adds_dirty", 0),
        ("ADD vs extremo pips (mediana)", "add_pips_med", 1),
        ("ADD vs extremo pips (min)", "add_pips_min", 1),
        ("ADD vs extremo pips (max)", "add_pips_max", 1),
        ("Adds por debajo de 20 pips", "adds_under_20", 0),
        ("Paso grid pips (mediana)", "step_pips_med", 1),
        ("Paso grid pips (min)", "step_pips_min", 1),
        ("Paso grid pips (max)", "step_pips_max", 1),
        ("Distancia TP pips (mediana)", "tp_dist_pips_med", 1),
        ("Amplitud canasta pips (max)", "span_pips_max", 1),
        ("Duracion ciclo s (mediana)", "dur_s_med", 0),
        ("Duracion ciclo s (max)", "dur_s_max", 0),
        ("Flotante peor USD", "float_min_worst", 2),
        ("P/L ciclos USD", "pl_sum", 2),
        ("Ganadoras", "wins", 0), ("Perdedoras", "losses", 0),
        ("Win rate %", "win_rate_pct", 1),
        ("Ganancia media USD", "avg_win", 2), ("Perdida media USD", "avg_loss", 2),
        ("Canastas BUY", "buy_baskets", 0), ("Canastas SELL", "sell_baskets", 0),
        ("Canastas cubiertas", "hedged_baskets", 0),
        ("Spread mediano (pts)", "spread_med", 0),
    ]
    out = ["", "=" * 74,
           f"  CERBERUS (MT5) vs ORACLE 2.0 (MT4) - {sum5.get('first','?')} .. {sum5.get('last','?')} GMT",
           "=" * 74, "",
           f"{'metrica':<30}{'CERBERUS MT5':>21}{'ORACLE MT4':>21}"]
    for label, key, nd in rows:
        out.append(f"{label:<30}{fmt(sum5.get(key), nd):>21}{fmt(sum4.get(key), nd):>21}")

    ratio5 = _ratio(sum5)
    ratio4 = _ratio(sum4)
    out += ["", f"{'Ratio gan/perd':<30}{fmt(ratio5):>21}{fmt(ratio4):>21}", "",
            "-" * 74, "  COINCIDENCIA DE DIRECCION (por segundo)", "-" * 74,
            f"  segundos comparables : {agree['common_s']}",
            f"  ambos en mercado     : {agree['both_in_market_s']}",
            f"  mismo lado           : {agree['same_side_s']}  ({fmt(agree['same_side_pct'],1)}%)",
            f"  lados opuestos       : {agree['opposite_side_s']}",
            f"  solo MT5 en mercado  : {agree['only_mt5_s']}",
            f"  solo MT4 en mercado  : {agree['only_mt4_s']}",
            f"  ambos planos         : {agree['flat_both_s']}", ""]

    for tag, baskets in (("CERBERUS MT5", baskets5), ("ORACLE MT4", baskets4)):
        out += ["-" * 74, f"  CANASTAS {tag}", "-" * 74,
                f"{'inicio':<10}{'magic':>7}{'lado':>6}{'niv':>4}  {'paso pips':>30}"
                f"{'dur s':>7}{'peor':>8}{'P/L':>8}"]
        for b in baskets:
            steps = ",".join(f"{s:.1f}" for s in b["steps_pips"][:8]) or "-"
            if len(b["steps_pips"]) > 8:
                steps += ",..."
            out.append(f"{b['start'].strftime('%H:%M:%S'):<10}{b['magic']:>7}"
                       f"{('/'.join(b['sides'])):>6}{b['n_levels']:>4}  {steps:>30}"
                       f"{fmt(b['duration_s'],0):>7}{fmt(b['floating_min']):>8}"
                       f"{fmt(b['floating_last']):>8}")
        out.append("")
    return "\n".join(out)


def _ratio(s):
    if not s.get("avg_win") or not s.get("avg_loss"):
        return None
    return abs(s["avg_win"] / s["avg_loss"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mt5", required=True)
    ap.add_argument("--mt4", required=True)
    ap.add_argument("--start")
    ap.add_argument("--end")
    ap.add_argument("--pip", type=float, default=0.01)
    ap.add_argument("--pip-points", type=float, default=10,
                    help="points per pip (10 on 3/5-digit symbols) - used to convert spread_pts")
    ap.add_argument("--json")
    a = ap.parse_args()

    start = datetime.strptime(a.start, TS_FMT) if a.start else None
    end = datetime.strptime(a.end, TS_FMT) if a.end else None

    s5 = load_samples(a.mt5, start, end)
    s4 = load_samples(a.mt4, start, end)
    b5 = build_baskets(s5, a.pip, a.pip_points)
    b4 = build_baskets(s4, a.pip, a.pip_points)
    sum5 = summarize("CERBERUS MT5", s5, b5)
    sum4 = summarize("ORACLE MT4", s4, b4)
    agree = direction_agreement(s5, s4)

    print(report(sum5, sum4, agree, b5, b4))

    if a.json:
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump({"mt5": sum5, "mt4": sum4, "agreement": agree,
                       "baskets_mt5": [_jb(b) for b in b5],
                       "baskets_mt4": [_jb(b) for b in b4]}, fh, indent=1, default=str)


def _jb(b):
    out = {k: v for k, v in b.items() if k not in ("levels", "tp_seen", "spread")}
    out["tp"] = sorted(b["tp_seen"])
    out["levels"] = [{k: v for k, v in p.items()} for p in
                     sorted(b["levels"].values(), key=lambda p: p["first_seen"])]
    return out


if __name__ == "__main__":
    main()
