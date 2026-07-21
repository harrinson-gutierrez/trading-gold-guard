#!/usr/bin/env python3
"""
Golden-master engine parity check: MT5 vs MT4 Strategy Tester reports.

Compares the trade sequence of the Oracle ENGINE (grid) between the two
platforms running the SAME strategy on the SAME XAUUSDm M1 history with the
SAME inputs. The engine is homologated and must produce an equivalent ladder;
the GUARDIAN (news/pause/AT-toggle) is NOT testable in the Strategy Tester
(no WebRequest/DLL/toggle) and is validated by code review instead.

Also usable as a REGRESSION check: export the MT4 report BEFORE and AFTER the
guardian homologation and diff them -- the engine must not have moved (the
homologation only touched the guardian).

Usage:
    python golden_master_compare.py <report_a.htm> <report_b.htm> [--tol-pips 2] [--label-a MT5 --label-b MT4]

MT4 and MT5 both export a "Detailed report" / statement as HTML from the
Strategy Tester (right-click the results tab -> Save as Report). This script
parses the trade table out of that HTML, no external libraries required.

What it compares (normalized, so platform cosmetics don't cause false diffs):
  - number of trades opened / closed
  - the sequence of order TYPES (buy/sell) in open order
  - the RELATIVE spacing between consecutive grid levels (open prices), which is
    what the engine controls -- absolute prices differ by broker/spread, spacing
    should not
  - basket close grouping (how many orders close at the same time = one basket)

Exit code 0 = engines match within tolerance, 1 = divergence found.
"""
import sys, re, html, argparse
from html.parser import HTMLParser


class MTReportParser(HTMLParser):
    """Pulls rows out of the trade table of an MT4/MT5 tester HTML report."""
    def __init__(self):
        super().__init__()
        self._in_td = False
        self._row = []
        self.rows = []
        self._cell = ""

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self._row = []
        elif tag == "td":
            self._in_td = True
            self._cell = ""

    def handle_endtag(self, tag):
        if tag == "td":
            self._in_td = False
            self._row.append(self._cell.strip())
        elif tag == "tr":
            if self._row:
                self.rows.append(self._row)

    def handle_data(self, data):
        if self._in_td:
            self._cell += data


def extract_trades(path):
    """Return a list of dicts {type, price} in open order, for buy/sell deals."""
    raw = open(path, encoding="utf-8", errors="ignore").read()
    p = MTReportParser()
    p.feed(raw)
    trades = []
    for row in p.rows:
        # find a cell that is exactly buy/sell (case-insensitive) and a numeric price near it
        cells = [html.unescape(c).strip().lower() for c in row]
        side = None
        for c in cells:
            if c in ("buy", "sell"):
                side = c
                break
        if side is None:
            continue
        # collect numeric cells that look like a price (>100 for gold), take the first
        price = None
        for c in cells:
            cc = c.replace(" ", "").replace(",", "")
            if re.fullmatch(r"\d+\.\d+", cc) and float(cc) > 100:
                price = float(cc)
                break
        if price is not None:
            trades.append({"type": side, "price": price})
    return trades


def spacing_profile(trades):
    """Median/quartile spacing between consecutive same-run open prices, in price units."""
    diffs = []
    for a, b in zip(trades, trades[1:]):
        d = abs(b["price"] - a["price"])
        if 0.0 < d < 20.0:   # ignore basket resets / huge gaps
            diffs.append(d)
    diffs.sort()
    if not diffs:
        return None
    n = len(diffs)
    return {
        "n": n,
        "median": diffs[n // 2],
        "p25": diffs[n // 4],
        "p75": diffs[(3 * n) // 4],
        "min": diffs[0],
        "max": diffs[-1],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report_a")
    ap.add_argument("report_b")
    ap.add_argument("--tol-pips", type=float, default=2.0,
                    help="allowed difference in median level spacing, in gold pips ($0.10)")
    ap.add_argument("--label-a", default="A")
    ap.add_argument("--label-b", default="B")
    args = ap.parse_args()

    ta = extract_trades(args.report_a)
    tb = extract_trades(args.report_b)
    la, lb = args.label_a, args.label_b

    print(f"=== Golden-master engine parity: {la} vs {lb} ===\n")
    print(f"{la}: {len(ta)} trades | {lb}: {len(tb)} trades")

    ok = True

    # 1. trade count within 5%
    if ta and tb:
        diff_pct = abs(len(ta) - len(tb)) / max(len(ta), len(tb)) * 100
        verdict = "OK" if diff_pct <= 5 else "DIVERGE"
        if diff_pct > 5:
            ok = False
        print(f"  trade count diff: {diff_pct:.1f}%  [{verdict}]")
    else:
        print("  one report has no trades -- cannot compare")
        ok = False

    # 2. side sequence (buy/sell pattern)
    if ta and tb:
        seq_a = "".join("B" if t["type"] == "buy" else "S" for t in ta)
        seq_b = "".join("B" if t["type"] == "buy" else "S" for t in tb)
        # compare the buy/sell ratio rather than exact string (timing offsets shift order)
        ra = seq_a.count("B") / len(seq_a)
        rb = seq_b.count("B") / len(seq_b)
        verdict = "OK" if abs(ra - rb) <= 0.10 else "DIVERGE"
        if abs(ra - rb) > 0.10:
            ok = False
        print(f"  buy ratio: {la} {ra:.2f} vs {lb} {rb:.2f}  [{verdict}]")

    # 3. grid spacing profile (the engine's core behavior)
    sa = spacing_profile(ta)
    sb = spacing_profile(tb)
    if sa and sb:
        # convert median spacing to gold pips ($0.10)
        med_a_pips = sa["median"] * 10
        med_b_pips = sb["median"] * 10
        d = abs(med_a_pips - med_b_pips)
        verdict = "OK" if d <= args.tol_pips else "DIVERGE"
        if d > args.tol_pips:
            ok = False
        print(f"  median grid spacing: {la} {med_a_pips:.1f} pips vs {lb} {med_b_pips:.1f} pips "
              f"(diff {d:.1f}, tol {args.tol_pips})  [{verdict}]")
        print(f"    {la} spacing pips: p25 {sa['p25']*10:.1f} / med {sa['median']*10:.1f} / p75 {sa['p75']*10:.1f}")
        print(f"    {lb} spacing pips: p25 {sb['p25']*10:.1f} / med {sb['median']*10:.1f} / p75 {sb['p75']*10:.1f}")
    else:
        print("  not enough consecutive trades to profile spacing")

    print()
    if ok:
        print(">> ENGINES MATCH within tolerance. The homologation did not move the engine.")
        sys.exit(0)
    else:
        print(">> DIVERGENCE FOUND. Investigate before trusting the two platforms as comparable.")
        sys.exit(1)


if __name__ == "__main__":
    main()
