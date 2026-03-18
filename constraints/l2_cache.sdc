# =============================================================================
# File        : l2_cache.sdc
# Project     : Parameterized L2 Cache Controller
# Description : Synopsys Design Constraints (SDC) for synthesis and STA.
#               Targeting 500 MHz (2.0 ns clock period) in 28nm process.
#
# Usage: source constraints/l2_cache.sdc  (in Design Compiler or PrimeTime)
# =============================================================================

# ---- User-configurable variables ---------------------------------------------
set CLK_PERIOD     2.0  ;# nanoseconds — 500 MHz
set CLK_SKEW_MAX   0.05 ;# 50 ps max clock skew budget
set IN_DELAY_RATIO 0.30 ;# 30% of clock period for input delay
set OUT_DELAY_RATIO 0.35 ;# 35% of clock period for output delay

# ---- Primary clock definition -----------------------------------------------
create_clock -name clk \
             -period $CLK_PERIOD \
             -waveform "0 [expr $CLK_PERIOD / 2.0]" \
             [get_ports clk]

set_clock_uncertainty -setup $CLK_SKEW_MAX [get_clocks clk]
set_clock_uncertainty -hold  0.02          [get_clocks clk]
set_clock_transition  0.05                 [get_clocks clk]

# ---- Input delays (from L1 / CPU domain) ------------------------------------
set_input_delay -clock clk \
                -max [expr $CLK_PERIOD * $IN_DELAY_RATIO] \
                [remove_from_collection [all_inputs] [get_ports {clk rst_n}]]

set_input_delay -clock clk \
                -min 0.05 \
                [remove_from_collection [all_inputs] [get_ports {clk rst_n}]]

# ---- Output delays (to L1 / CPU return path) ---------------------------------
set_output_delay -clock clk \
                 -max [expr $CLK_PERIOD * $OUT_DELAY_RATIO] \
                 [all_outputs]

set_output_delay -clock clk \
                 -min -0.05 \
                 [all_outputs]

# ---- Reset constraints -------------------------------------------------------
# rst_n is asynchronous — set false path for timing (reset synchronizer is
# upstream; here we only care about functional timing in the reset domain)
set_false_path -from [get_ports rst_n]

# ---- SRAM macro constraints --------------------------------------------------
# Tag SRAM: 1-cycle read latency — standard path (no multicycle needed for 4-way)
# For 16-way cache with deep compare tree, uncomment the multicycle path below:
# set_multicycle_path -setup 2 \
#     -through [get_cells u_tag_array/*] \
#     -to [get_cells *tag_compare_reg*]
# set_multicycle_path -hold 1 \
#     -through [get_cells u_tag_array/*] \
#     -to [get_cells *tag_compare_reg*]

# SRAM power-down / test pins — not in functional timing path
set_false_path -to [get_pins -hierarchical -filter "name =~ SD"]
set_false_path -to [get_pins -hierarchical -filter "name =~ TEST"]
set_false_path -to [get_pins -hierarchical -filter "name =~ BIST*"]

# ---- Performance counter outputs — relaxed timing ---------------------------
# Perf counters are sampled by software, not on critical path
set_multicycle_path -setup 4 -to [get_ports perf_*]
set_multicycle_path -hold  3 -to [get_ports perf_*]

# ---- AXI master interface (to L3/DRAM) — same clock domain -----------------
# If AXI master is in a different clock domain, add a new clock and CDC paths here
# For single-clock design, AXI master is same clock:
set_max_delay -from [get_ports m_axi_*] [expr $CLK_PERIOD * 1.5]

# ---- Scan chain false paths (DFT) -------------------------------------------
# Set by DFT insertion tool — placeholder to show methodology:
# set_false_path -through [get_pins -hierarchical -filter "name =~ SE"]

# ---- Design rule constraints ------------------------------------------------
set_max_fanout 20 [current_design]
set_max_transition 0.15 [current_design]  ;# 150 ps max slew

# ---- Operating conditions ---------------------------------------------------
# Use worst-case (slow) corner for setup, best-case (fast) for hold
# set_operating_conditions -max SLOW -min FAST

# ---- Timing report configuration --------------------------------------------
# set_app_var report_default_significant_digits 4

# ---- End of constraints ------------------------------------------------------
puts "SDC loaded: CLK_PERIOD=${CLK_PERIOD}ns (${[expr int(1000/$CLK_PERIOD)]}MHz)"
