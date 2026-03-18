#!/usr/bin/env python3
"""
scripts/power/run_power_analysis.py
Automated power analysis flow for the L2 cache controller.

Workflow:
  1. Run a representative simulation to generate a SAIF or VCD file
  2. Invoke PrimeTime PX with the switching activity data
  3. Parse the power report and check against budget
  4. Generate a breakdown chart (dynamic vs leakage per domain)

Usage:
    python3 scripts/power/run_power_analysis.py \
        --test   l2_random_traffic_test \
        --seed   42 \
        --corner slow \
        --budget 15.0        # mW total power budget

Requirements:
    VCS + PrimeTime PX
    pip install matplotlib (optional, for chart generation)
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from dataclasses import dataclass
from typing import Optional


@dataclass
class PowerResult:
    domain:       str
    dynamic_mw:   float
    leakage_mw:   float
    total_mw:     float
    toggle_rate:  Optional[float] = None


def run_simulation_with_saif(test: str, seed: int, tool: str = "vcs") -> str:
    """Run simulation and generate SAIF switching activity file."""
    saif_path = f"sim/saif/{test}_{seed}.saif"
    Path("sim/saif").mkdir(parents=True, exist_ok=True)

    if tool == "vcs":
        cmd = [
            f"sim/vcs/l2_cache_top_sim",
            f"+UVM_TESTNAME={test}",
            f"+ntb_random_seed={seed}",
            "+UVM_VERBOSITY=UVM_NONE",
            f"+SAIF_OUTPUT={saif_path}",
            "-ucli", "-do",
            f"dumpsaif -scope tb.dut -output {saif_path}; run; exit",
        ]
    else:
        cmd = [
            "xmsim", "-64bit", f"+UVM_TESTNAME={test}",
            f"+ntb_random_seed={seed}",
            "l2_cache_tb_top",
            f"-sv_saif {saif_path}",
        ]

    print(f"[POWER] Running simulation to generate SAIF: {saif_path}")
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        print(f"[POWER] Simulation failed:\n{result.stderr[-1000:]}")
        sys.exit(1)

    if not Path(saif_path).exists():
        print(f"[POWER] SAIF not generated: {saif_path}")
        sys.exit(1)

    print(f"[POWER] SAIF generated: {saif_path}")
    return saif_path


def run_primetime_px(saif_path: str, corner: str, clk_ns: float = 2.0) -> str:
    """Invoke PrimeTime PX and return the power report path."""
    report_path = f"reports/synthesis/power_{corner}.rpt"
    Path("reports/synthesis").mkdir(parents=True, exist_ok=True)

    pt_script = f"""
read_verilog netlist/l2_cache_top.v
current_design l2_cache_top
link_design
read_sdc netlist/l2_cache_top.sdc
read_parasitics -format spef outputs/innovus/l2_cache_top.spef
set_operating_conditions {corner}_1v0_125c
reset_switching_activity
read_saif -input {saif_path} -instance_name l2_cache_top
update_power
report_power -hierarchy -verbose > {report_path}
report_power -domains {{PD_ALWAYS_ON PD_CACHE_LOGIC PD_DATA_SRAM}} >> {report_path}
exit
"""
    pt_script_path = "reports/synthesis/run_pt_power.tcl"
    with open(pt_script_path, "w") as f:
        f.write(pt_script)

    print(f"[POWER] Running PrimeTime PX ({corner} corner)...")
    result = subprocess.run(
        ["pt_shell", "-f", pt_script_path],
        capture_output=True, text=True, timeout=1200
    )
    if result.returncode != 0:
        print(f"[POWER] PrimeTime failed:\n{result.stderr[-1000:]}")
        sys.exit(1)

    print(f"[POWER] Report: {report_path}")
    return report_path


def parse_power_report(report_path: str) -> list[PowerResult]:
    """Parse PrimeTime PX power report."""
    results = []
    with open(report_path) as f:
        content = f.read()

    # Pattern: module/domain name followed by dynamic and leakage power
    # PrimeTime format: <name>  <dynamic_mW>  <leakage_mW>  <total_mW>
    pattern = re.compile(
        r"(PD_\w+|l2_\w+)\s+"
        r"([\d.]+(?:e[+-]\d+)?)\s+"   # dynamic
        r"([\d.]+(?:e[+-]\d+)?)\s+"   # leakage
        r"([\d.]+(?:e[+-]\d+)?)",      # total
        re.MULTILINE
    )
    for m in pattern.finditer(content):
        try:
            results.append(PowerResult(
                domain     = m.group(1),
                dynamic_mw = float(m.group(2)) * 1000,  # W → mW
                leakage_mw = float(m.group(3)) * 1000,
                total_mw   = float(m.group(4)) * 1000,
            ))
        except ValueError:
            pass

    return results


def check_budget(results: list[PowerResult], budget_mw: float) -> bool:
    """Check total power against budget."""
    # Sum top-level domains
    total = sum(r.total_mw for r in results
                if r.domain.startswith("PD_"))
    if not results:
        # Fallback: sum all modules
        total = sum(r.total_mw for r in results)

    print(f"\n[POWER] Total power: {total:.2f} mW (budget: {budget_mw:.2f} mW)")
    if total > budget_mw:
        print(f"[POWER] ❌ OVER BUDGET by {total - budget_mw:.2f} mW!")
        return False
    print(f"[POWER] ✅ Within budget (margin: {budget_mw - total:.2f} mW)")
    return True


def print_breakdown(results: list[PowerResult]) -> None:
    """Print formatted power breakdown table."""
    print("\n" + "="*65)
    print(f"  {'Domain/Module':<28} {'Dynamic':>8} {'Leakage':>8} {'Total':>8}")
    print(f"  {'':28} {'(mW)':>8} {'(mW)':>8} {'(mW)':>8}")
    print("="*65)
    for r in sorted(results, key=lambda x: x.total_mw, reverse=True)[:15]:
        print(f"  {r.domain:<28} {r.dynamic_mw:8.3f} {r.leakage_mw:8.3f} {r.total_mw:8.3f}")
    print("="*65)


def generate_chart(results: list[PowerResult], output: str) -> None:
    """Generate power breakdown bar chart (requires matplotlib)."""
    try:
        import matplotlib.pyplot as plt
        import matplotlib.patches as mpatches

        domains = [r for r in results if r.domain.startswith("PD_")]
        if not domains:
            domains = results[:6]

        names = [r.domain.replace("PD_", "") for r in domains]
        dyn   = [r.dynamic_mw for r in domains]
        leak  = [r.leakage_mw for r in domains]

        x = range(len(names))
        fig, ax = plt.subplots(figsize=(8, 5))
        ax.bar(x, dyn,  label="Dynamic",  color="#4472C4")
        ax.bar(x, leak, bottom=dyn, label="Leakage", color="#ED7D31")

        ax.set_xticks(list(x))
        ax.set_xticklabels(names, rotation=20, ha="right")
        ax.set_ylabel("Power (mW)")
        ax.set_title("L2 Cache Power Breakdown by Domain")
        ax.legend()
        ax.grid(axis="y", alpha=0.3)

        plt.tight_layout()
        plt.savefig(output, dpi=150)
        print(f"[POWER] Chart: {output}")
    except ImportError:
        print("[POWER] matplotlib not available — skipping chart")


def main():
    parser = argparse.ArgumentParser(description="L2 Cache power analysis")
    parser.add_argument("--test",   default="l2_random_traffic_test")
    parser.add_argument("--seed",   type=int, default=42)
    parser.add_argument("--corner", default="slow",
                        choices=["slow", "fast", "typical"])
    parser.add_argument("--budget", type=float, default=15.0,
                        help="Total power budget in mW")
    parser.add_argument("--tool",   default="vcs", choices=["vcs", "xcelium"])
    parser.add_argument("--skip_sim", action="store_true",
                        help="Skip simulation, use existing SAIF")
    parser.add_argument("--saif",   default=None,
                        help="Existing SAIF file path (implies --skip_sim)")
    parser.add_argument("--chart",  default="reports/synthesis/power_chart.png")
    args = parser.parse_args()

    # Step 1: Generate switching activity
    if args.saif:
        saif_path = args.saif
    elif args.skip_sim:
        saif_path = f"sim/saif/{args.test}_{args.seed}.saif"
        if not Path(saif_path).exists():
            print(f"[POWER] SAIF not found: {saif_path}")
            sys.exit(1)
    else:
        saif_path = run_simulation_with_saif(args.test, args.seed, args.tool)

    # Step 2: Run PrimeTime PX
    report_path = run_primetime_px(saif_path, args.corner)

    # Step 3: Parse and report
    results = parse_power_report(report_path)
    if not results:
        print("[POWER] WARNING: No power data parsed from report")

    print_breakdown(results)
    generate_chart(results, args.chart)

    # Step 4: Budget check
    ok = check_budget(results, args.budget)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
