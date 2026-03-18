#!/usr/bin/env python3
"""
Regression runner for L2 cache UVM verification.
Supports parallel simulation on multiple cores, HTML report generation,
pass/fail tracking, coverage merging, and CI integration.

Usage:
    python3 run_regression.py --plan test_plan.yaml --jobs 8 --tool vcs
    python3 run_regression.py --test l2_eviction_test --seed 12345
    python3 run_regression.py --cov_merge --report_only

Requirements:
    pip install jinja2 pyyaml
"""

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import time
import yaml
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import List, Optional


# =============================================================================
# Configuration
# =============================================================================

DEFAULT_TOOL    = "vcs"
DEFAULT_JOBS    = 4
TIMEOUT_SECONDS = 1800  # 30 min per test
REPORT_DIR      = Path("reports/regression")
SIM_DIR         = Path("sim")


# =============================================================================
# Data classes
# =============================================================================

@dataclass
class TestResult:
    name:       str
    seed:       int
    status:     str       # PASS / FAIL / TIMEOUT / COMPILE_ERROR
    elapsed:    float
    log_path:   str
    errors:     List[str] = field(default_factory=list)
    warnings:   List[str] = field(default_factory=list)
    coverage:   float = 0.0
    sim_time_ns: float = 0.0


@dataclass
class TestConfig:
    name:       str
    test_class: str
    num_seeds:  int  = 1
    timeout:    int  = TIMEOUT_SECONDS
    plusargs:   dict = field(default_factory=dict)
    tags:       List[str] = field(default_factory=list)
    enabled:    bool = True


# =============================================================================
# Simulation runner
# =============================================================================

class SimRunner:
    """Invokes the simulator for one test/seed combination."""

    TOOL_CMD = {
        "vcs": {
            "compile": (
                "vcs -full64 -sverilog -timescale=1ns/1ps "
                "+vcs+lic+wait +v2k "
                "-f sim/vcs/vcs_filelist.f "
                "-o sim/vcs/{top} "
                "-Mdir sim/vcs/csrc"
            ),
            "sim": (
                "sim/vcs/{top} "
                "+UVM_TESTNAME={test} "
                "+ntb_random_seed={seed} "
                "+UVM_VERBOSITY={verbosity} "
                "{plusargs} "
                "-l {log}"
            ),
        },
        "xcelium": {
            "compile": (
                "xmvlog -64bit -sv "
                "-f sim/xcelium/xm_filelist.f "
                "-log sim/xcelium/compile.log"
            ),
            "sim": (
                "xmsim -64bit "
                "+UVM_TESTNAME={test} "
                "+ntb_random_seed={seed} "
                "+UVM_VERBOSITY={verbosity} "
                "{plusargs} "
                "-l {log} "
                "l2_cache_top_tb"
            ),
        },
    }

    def __init__(self, tool: str, verbosity: str = "UVM_MEDIUM"):
        self.tool = tool
        self.verbosity = verbosity

    def compile(self) -> bool:
        """Compile RTL and TB — only needed once per regression."""
        cmd = self.TOOL_CMD[self.tool]["compile"].format(top="l2_cache_top_sim")
        print(f"[COMPILE] {self.tool}: running...")
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"[COMPILE ERROR]\n{result.stderr[-2000:]}")
            return False
        print("[COMPILE] SUCCESS")
        return True

    def run(self, config: TestConfig, seed: int) -> TestResult:
        """Run one test with one seed. Returns TestResult."""
        log_dir  = REPORT_DIR / "logs" / config.name
        log_dir.mkdir(parents=True, exist_ok=True)
        log_path = str(log_dir / f"seed_{seed}.log")

        plusarg_str = " ".join(f"+{k}={v}" for k, v in config.plusargs.items())

        cmd = self.TOOL_CMD[self.tool]["sim"].format(
            top       = "l2_cache_top_sim",
            test      = config.test_class,
            seed      = seed,
            verbosity = self.verbosity,
            plusargs  = plusarg_str,
            log       = log_path,
        )

        start = time.time()
        try:
            result = subprocess.run(
                cmd,
                shell   = True,
                timeout = config.timeout,
                capture_output = True,
                text    = True,
            )
            elapsed = time.time() - start
            status, errors, warnings = self._parse_log(log_path)

            return TestResult(
                name     = config.name,
                seed     = seed,
                status   = status,
                elapsed  = elapsed,
                log_path = log_path,
                errors   = errors,
                warnings = warnings,
                coverage = self._extract_coverage(log_path),
                sim_time_ns = self._extract_sim_time(log_path),
            )

        except subprocess.TimeoutExpired:
            return TestResult(
                name    = config.name,
                seed    = seed,
                status  = "TIMEOUT",
                elapsed = config.timeout,
                log_path= log_path,
                errors  = [f"Simulation timed out after {config.timeout}s"],
            )

    def _parse_log(self, log_path: str):
        """Parse simulation log for PASS/FAIL and error messages."""
        errors   = []
        warnings = []
        status   = "FAIL"

        if not Path(log_path).exists():
            return "COMPILE_ERROR", ["Log file not found"], []

        with open(log_path) as f:
            for line in f:
                if re.search(r'\*\* TEST PASSED \*\*|UVM_ERROR\s+:\s+0\b', line):
                    status = "PASS"
                if re.search(r'UVM_FATAL|UVM_ERROR\b', line, re.I):
                    errors.append(line.strip())
                    status = "FAIL"
                if re.search(r'UVM_WARNING', line, re.I):
                    warnings.append(line.strip())

        return status, errors, warnings

    def _extract_coverage(self, log_path: str) -> float:
        """Extract total functional coverage % from log."""
        with open(log_path, errors='ignore') as f:
            for line in f:
                m = re.search(r'Total Coverage\s*:\s*([\d.]+)%', line)
                if m:
                    return float(m.group(1))
        return 0.0

    def _extract_sim_time(self, log_path: str) -> float:
        """Extract simulation end time in ns."""
        with open(log_path, errors='ignore') as f:
            content = f.read()
        m = re.search(r'(\d+(?:\.\d+)?)ns', content)
        return float(m.group(1)) if m else 0.0


# =============================================================================
# Regression orchestrator
# =============================================================================

class RegressionRunner:
    def __init__(self, args):
        self.args    = args
        self.tool    = args.tool
        self.jobs    = args.jobs
        self.runner  = SimRunner(self.tool)
        self.results: List[TestResult] = []
        REPORT_DIR.mkdir(parents=True, exist_ok=True)

    def load_plan(self) -> List[TestConfig]:
        """Load test plan from YAML."""
        with open(self.args.plan) as f:
            plan = yaml.safe_load(f)

        configs = []
        for t in plan.get("tests", []):
            cfg = TestConfig(
                name       = t["name"],
                test_class = t.get("test_class", t["name"]),
                num_seeds  = t.get("num_seeds", self.args.seeds),
                timeout    = t.get("timeout", TIMEOUT_SECONDS),
                plusargs   = t.get("plusargs", {}),
                tags       = t.get("tags", []),
                enabled    = t.get("enabled", True),
            )
            # Filter by tag if specified
            if self.args.tag and self.args.tag not in cfg.tags:
                continue
            if cfg.enabled:
                configs.append(cfg)

        return configs

    def build_jobs(self, configs: List[TestConfig]):
        """Expand configs × seeds into job list."""
        jobs = []
        if self.args.test:
            # Single test override
            seeds = [self.args.seed] if self.args.seed else list(range(self.args.seeds))
            cfg = TestConfig(
                name       = self.args.test,
                test_class = self.args.test,
                num_seeds  = len(seeds),
            )
            jobs = [(cfg, s) for s in seeds]
        else:
            import random
            for cfg in configs:
                seeds = [random.randint(1, 0x7FFF_FFFF)
                         for _ in range(cfg.num_seeds)]
                if self.args.seed:
                    seeds = [self.args.seed]
                jobs.extend((cfg, s) for s in seeds)
        return jobs

    def run(self):
        # Compile first
        if not self.args.skip_compile:
            if not self.runner.compile():
                sys.exit(1)

        configs = self.load_plan()
        jobs    = self.build_jobs(configs)

        print(f"\n[REGRESSION] Running {len(jobs)} jobs on {self.jobs} parallel workers")
        print(f"[REGRESSION] Tool: {self.tool}  Plan: {self.args.plan}\n")

        start = time.time()

        with concurrent.futures.ProcessPoolExecutor(max_workers=self.jobs) as pool:
            futures = {
                pool.submit(self.runner.run, cfg, seed): (cfg.name, seed)
                for cfg, seed in jobs
            }
            for future in concurrent.futures.as_completed(futures):
                name, seed = futures[future]
                try:
                    result = future.result()
                    self.results.append(result)
                    icon = "✅" if result.status == "PASS" else "❌"
                    print(f"  {icon} {result.name}[seed={result.seed:010d}]"
                          f"  {result.status}  {result.elapsed:.1f}s"
                          f"  cov={result.coverage:.1f}%")
                except Exception as exc:
                    print(f"  💥 {name}[seed={seed}] raised exception: {exc}")

        elapsed = time.time() - start
        self._print_summary(elapsed)
        self._write_json_report()
        self._write_html_report()

        # Non-zero exit if any failures
        failures = sum(1 for r in self.results if r.status != "PASS")
        sys.exit(1 if failures else 0)

    def _print_summary(self, elapsed: float):
        passed  = sum(1 for r in self.results if r.status == "PASS")
        failed  = sum(1 for r in self.results if r.status == "FAIL")
        timeout = sum(1 for r in self.results if r.status == "TIMEOUT")
        total   = len(self.results)
        avg_cov = sum(r.coverage for r in self.results) / max(total, 1)

        print("\n" + "=" * 60)
        print("  REGRESSION SUMMARY")
        print("=" * 60)
        print(f"  Total  : {total}")
        print(f"  PASS   : {passed}")
        print(f"  FAIL   : {failed}")
        print(f"  TIMEOUT: {timeout}")
        print(f"  Avg Coverage: {avg_cov:.1f}%")
        print(f"  Wall time   : {elapsed:.1f}s")
        print("=" * 60)
        if failed or timeout:
            print("  ⚠️  REGRESSION FAILED")
        else:
            print("  ✅  ALL TESTS PASSED")
        print("=" * 60)

    def _write_json_report(self):
        data = {
            "timestamp": datetime.now().isoformat(),
            "total"    : len(self.results),
            "pass"     : sum(1 for r in self.results if r.status == "PASS"),
            "fail"     : sum(1 for r in self.results if r.status != "PASS"),
            "results"  : [
                {
                    "name"    : r.name,
                    "seed"    : r.seed,
                    "status"  : r.status,
                    "elapsed" : round(r.elapsed, 2),
                    "coverage": r.coverage,
                    "errors"  : r.errors[:5],
                }
                for r in self.results
            ],
        }
        out = REPORT_DIR / "results.json"
        with open(out, "w") as f:
            json.dump(data, f, indent=2)
        print(f"[REPORT] JSON: {out}")

    def _write_html_report(self):
        """Generate a standalone HTML regression report."""
        rows = ""
        for r in sorted(self.results, key=lambda x: x.status):
            color = "#d4edda" if r.status == "PASS" else "#f8d7da"
            errs  = "<br>".join(r.errors[:3]) if r.errors else ""
            rows += (
                f"<tr style='background:{color}'>"
                f"<td>{r.name}</td>"
                f"<td><code>{r.seed}</code></td>"
                f"<td><b>{r.status}</b></td>"
                f"<td>{r.elapsed:.1f}s</td>"
                f"<td>{r.coverage:.1f}%</td>"
                f"<td><a href='{r.log_path}'>log</a></td>"
                f"<td><small>{errs}</small></td>"
                f"</tr>"
            )

        passed  = sum(1 for r in self.results if r.status == "PASS")
        total   = len(self.results)
        avg_cov = sum(r.coverage for r in self.results) / max(total, 1)

        html = f"""<!DOCTYPE html>
<html><head><meta charset='utf-8'>
<title>L2 Cache Regression Report</title>
<style>
  body {{ font-family: monospace; background: #1e1e1e; color: #d4d4d4; padding: 20px; }}
  h1   {{ color: #569cd6; }}
  .summary {{ background: #252526; padding: 15px; border-radius: 6px; margin-bottom: 20px; }}
  table {{ border-collapse: collapse; width: 100%; }}
  th    {{ background: #333; color: #9cdcfe; padding: 8px; text-align: left; }}
  td    {{ padding: 6px 8px; border-bottom: 1px solid #3a3a3a; color: #000; }}
  a     {{ color: #4ec9b0; }}
</style>
</head><body>
<h1>🔬 L2 Cache — Regression Report</h1>
<div class='summary'>
  <b>Date:</b> {datetime.now().strftime('%Y-%m-%d %H:%M')} &nbsp;|&nbsp;
  <b>Tool:</b> {self.tool} &nbsp;|&nbsp;
  <b>Tests:</b> {total} &nbsp;|&nbsp;
  <b>PASS:</b> {passed}/{total} &nbsp;|&nbsp;
  <b>Avg Coverage:</b> {avg_cov:.1f}%
</div>
<table>
  <tr>
    <th>Test</th><th>Seed</th><th>Status</th>
    <th>Time</th><th>Coverage</th><th>Log</th><th>Errors</th>
  </tr>
  {rows}
</table>
</body></html>"""

        out = REPORT_DIR / "regression_report.html"
        out.write_text(html)
        print(f"[REPORT] HTML: {out}")


# =============================================================================
# CLI
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="L2 Cache UVM Regression Runner")
    parser.add_argument("--plan",          default="scripts/regression/test_plan.yaml")
    parser.add_argument("--tool",          default=DEFAULT_TOOL, choices=["vcs","xcelium"])
    parser.add_argument("--jobs",    "-j", type=int, default=DEFAULT_JOBS)
    parser.add_argument("--seeds",         type=int, default=3,
                        help="Seeds per test (from plan)")
    parser.add_argument("--seed",          type=int, default=None,
                        help="Override: run all tests with this seed")
    parser.add_argument("--test",          default=None,
                        help="Run a single named test")
    parser.add_argument("--tag",           default=None,
                        help="Filter tests by tag")
    parser.add_argument("--skip_compile",  action="store_true")
    parser.add_argument("--verbosity",     default="UVM_MEDIUM")
    parser.add_argument("--report_only",   action="store_true",
                        help="Re-generate HTML from existing results.json")
    args = parser.parse_args()

    RegressionRunner(args).run()


if __name__ == "__main__":
    main()
