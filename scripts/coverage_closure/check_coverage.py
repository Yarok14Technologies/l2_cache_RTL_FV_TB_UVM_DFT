#!/usr/bin/env python3
"""
scripts/coverage_closure/check_coverage.py
Coverage closure analysis and gap reporting for the L2 cache regression.

Reads merged coverage data (VCS URG or Xcelium IMC output),
checks against configurable thresholds, reports uncovered bins,
and generates an actionable HTML gap report.

Usage:
    python3 scripts/coverage_closure/check_coverage.py \
        --db reports/coverage/merged/dashboard.json \
        --min-line    100 \
        --min-branch  100 \
        --min-toggle   95 \
        --min-fsm     100 \
        --min-func     90 \
        --fail-on-miss

    # From JSON regression results (quick CI check):
    python3 scripts/coverage_closure/check_coverage.py \
        --db reports/regression/results.json \
        --min-coverage 90
"""

import argparse
import json
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional


# ── Data structures ────────────────────────────────────────────────────────────

@dataclass
class CoverageMetric:
    name:       str
    value:      float       # percentage 0–100
    target:     float
    covered:    int = 0
    total:      int = 0
    uncovered:  List[str] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return self.value >= self.target

    @property
    def gap(self) -> float:
        return max(0.0, self.target - self.value)


@dataclass
class CoverageReport:
    timestamp:  str
    tool:       str
    metrics:    Dict[str, CoverageMetric] = field(default_factory=dict)

    @property
    def all_passed(self) -> bool:
        return all(m.passed for m in self.metrics.values())


# ── Parsers ────────────────────────────────────────────────────────────────────

def parse_urg_dashboard(path: str) -> CoverageReport:
    """Parse VCS URG JSON dashboard output."""
    report = CoverageReport(
        timestamp = datetime.now().isoformat(),
        tool      = "vcs_urg"
    )
    try:
        with open(path) as f:
            data = json.load(f)

        # URG dashboard structure: data["metrics"][type]["coverage"]
        metric_map = {
            "line"     : "Line",
            "branch"   : "Branch",
            "toggle"   : "Toggle",
            "fsm"      : "FSM State",
            "assertion": "Assertion",
            "functional": "Functional",
        }
        for key, name in metric_map.items():
            if key in data.get("metrics", {}):
                m = data["metrics"][key]
                val = float(m.get("coverage", 0))
                covered = int(m.get("covered", 0))
                total   = int(m.get("total", 1))
                report.metrics[key] = CoverageMetric(
                    name    = name,
                    value   = val,
                    target  = 0.0,  # set by caller
                    covered = covered,
                    total   = total
                )
    except (FileNotFoundError, json.JSONDecodeError, KeyError) as e:
        print(f"[WARN] Could not parse URG dashboard: {e}")
        # Return empty report — thresholds will flag as 0%
    return report


def parse_regression_json(path: str) -> CoverageReport:
    """Parse the Python regression runner results.json for avg coverage."""
    report = CoverageReport(
        timestamp = datetime.now().isoformat(),
        tool      = "regression_runner"
    )
    try:
        with open(path) as f:
            data = json.load(f)

        results = data.get("results", [])
        if results:
            avg_cov = sum(r.get("coverage", 0) for r in results) / len(results)
            report.metrics["functional"] = CoverageMetric(
                name    = "Avg Functional Coverage",
                value   = avg_cov,
                target  = 0.0,
                covered = data.get("pass", 0),
                total   = data.get("total", 1)
            )
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"[WARN] Could not parse regression JSON: {e}")
    return report


# ── Threshold application ──────────────────────────────────────────────────────

def apply_thresholds(report: CoverageReport, thresholds: dict) -> None:
    """Apply target thresholds to each metric."""
    for key, target in thresholds.items():
        if key in report.metrics:
            report.metrics[key].target = target
        else:
            # Metric not measured — create entry with 0%
            report.metrics[key] = CoverageMetric(
                name   = key.replace("_", " ").title(),
                value  = 0.0,
                target = target
            )


# ── HTML report ────────────────────────────────────────────────────────────────

def generate_html(report: CoverageReport, output: str) -> None:
    """Generate an HTML coverage gap report."""
    rows = ""
    for key, m in report.metrics.items():
        color = "#d4edda" if m.passed else "#f8d7da"
        badge = "✅ PASS" if m.passed else f"❌ GAP {m.gap:.1f}%"
        bar_w = int(m.value)
        rows += f"""
        <tr style="background:{color}">
          <td><b>{m.name}</b></td>
          <td>
            <div style="background:#ddd;border-radius:4px;height:18px;width:200px">
              <div style="background:{'#28a745' if m.passed else '#dc3545'};
                          width:{bar_w}%;height:18px;border-radius:4px"></div>
            </div>
          </td>
          <td>{m.value:.1f}%</td>
          <td>{m.target:.1f}%</td>
          <td>{m.covered}/{m.total}</td>
          <td>{badge}</td>
        </tr>"""

    overall = "✅ ALL PASS" if report.all_passed else "❌ GAPS FOUND"
    html = f"""<!DOCTYPE html>
<html><head><meta charset='utf-8'>
<title>L2 Cache Coverage Report</title>
<style>
  body  {{ font-family: monospace; background: #1e1e1e; color: #d4d4d4; padding: 20px }}
  h1    {{ color: #569cd6 }}
  table {{ border-collapse: collapse; width: 100% }}
  th    {{ background: #333; color: #9cdcfe; padding: 8px; text-align: left }}
  td    {{ padding: 6px 10px; border-bottom: 1px solid #333; color: #000 }}
  .banner {{ padding: 12px; border-radius: 6px;
             background: {'#d4edda' if report.all_passed else '#f8d7da'};
             color: #000; margin-bottom: 16px; font-size: 1.2em }}
</style></head><body>
<h1>🔬 L2 Cache — Coverage Closure Report</h1>
<div class='banner'>{overall} &nbsp;|&nbsp; Tool: {report.tool}
  &nbsp;|&nbsp; {report.timestamp}</div>
<table>
  <tr>
    <th>Metric</th><th>Progress</th><th>Actual</th>
    <th>Target</th><th>Covered/Total</th><th>Status</th>
  </tr>
  {rows}
</table>
</body></html>"""
    Path(output).write_text(html)
    print(f"[REPORT] HTML: {output}")


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="L2 Cache coverage closure checker")
    parser.add_argument("--db",           required=True,
                        help="Coverage database (URG JSON or regression JSON)")
    parser.add_argument("--min-line",     type=float, default=100.0)
    parser.add_argument("--min-branch",   type=float, default=100.0)
    parser.add_argument("--min-toggle",   type=float, default=95.0)
    parser.add_argument("--min-fsm",      type=float, default=100.0)
    parser.add_argument("--min-func",     type=float, default=90.0)
    parser.add_argument("--min-coverage", type=float, default=None,
                        help="Single threshold for all metrics (CI shorthand)")
    parser.add_argument("--fail-on-miss", action="store_true",
                        help="Exit 1 if any metric below target")
    parser.add_argument("--html",         default="reports/coverage/gap_report.html",
                        help="Output HTML report path")
    args = parser.parse_args()

    # Auto-detect parser
    db_path = args.db
    if "regression" in db_path or "results.json" in db_path:
        report = parse_regression_json(db_path)
    else:
        report = parse_urg_dashboard(db_path)

    # Build threshold dict
    if args.min_coverage is not None:
        thresholds = {k: args.min_coverage for k in
                      ["line","branch","toggle","fsm","functional"]}
    else:
        thresholds = {
            "line"       : args.min_line,
            "branch"     : args.min_branch,
            "toggle"     : args.min_toggle,
            "fsm"        : args.min_fsm,
            "functional" : args.min_func,
        }
    apply_thresholds(report, thresholds)

    # Console summary
    print("\n" + "="*55)
    print("  L2 Cache Coverage Closure Summary")
    print("="*55)
    for key, m in report.metrics.items():
        status = "PASS" if m.passed else f"FAIL (gap {m.gap:.1f}%)"
        print(f"  {m.name:<28} {m.value:5.1f}% / {m.target:.1f}%  [{status}]")
    print("="*55)

    if report.all_passed:
        print("  ✅ ALL COVERAGE TARGETS MET")
    else:
        missing = [m.name for m in report.metrics.values() if not m.passed]
        print(f"  ❌ COVERAGE GAPS: {', '.join(missing)}")

    # HTML output
    Path(args.html).parent.mkdir(parents=True, exist_ok=True)
    generate_html(report, args.html)

    if args.fail_on_miss and not report.all_passed:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
