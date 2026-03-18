###############################################################################
# Script     : run_atpg.tcl
# Tool       : Synopsys TetraMAX ATPG (or TetraMAX II)
# Description: Full ATPG flow for the L2 cache controller.
#              Reads post-DFT netlist, runs stuck-at and transition fault
#              campaign, generates compacted test patterns, and reports
#              fault coverage.
#
# Usage:
#   tmax -shell -run dft/atpg/run_atpg.tcl
#
# Expected outputs:
#   dft/patterns/l2_stuck_at.stil        — stuck-at test patterns (STIL)
#   dft/patterns/l2_transition.stil      — transition fault patterns
#   dft/patterns/l2_patterns.v           — Verilog simulation patterns
#   reports/dft/atpg_stuck_at.rpt        — fault coverage report
#   reports/dft/atpg_transition.rpt      — transition fault report
###############################################################################

###############################################################################
# 0. Setup
###############################################################################
set DESIGN_TOP    "l2_cache_dft_top"
set NETLIST       "netlist/${DESIGN_TOP}.v"
set TIMING_LIB    "libs/28nm/slow_1v0_125c.v"    ;# verilog timing model
set DFT_SDC       "constraints/l2_cache.sdc"

set COVERAGE_TARGET_STUCK  98.0   ;# % stuck-at coverage target
set COVERAGE_TARGET_TRANS  92.0   ;# % transition fault target

file mkdir reports/dft
file mkdir dft/patterns

###############################################################################
# 1. Read netlist (post-DFT gate-level)
###############################################################################
read_netlist -library $TIMING_LIB
read_netlist $NETLIST

set_current_design $DESIGN_TOP
build_model -merge

###############################################################################
# 2. Configure DFT signals
###############################################################################

# Scan enable
add_dft_signals scan_enable    -hookup_pin [get_pins test_se]

# Test clock
add_dft_signals master_clock   -hookup_pin [get_pins test_clk]

# Scan input / output per chain (4 chains)
foreach i {0 1 2 3} {
  add_dft_signals scan_data_in  -hookup_pin [get_pins scan_in[$i]]
  add_dft_signals scan_data_out -hookup_pin [get_pins scan_out[$i]]
}

# Reset — active low; must be deasserted during capture and shift
add_dft_signals reset          -active_state 0 -hookup_pin [get_pins test_rst_n]

###############################################################################
# 3. ATPG constraints
###############################################################################

# Clock period for timing-aware ATPG (2 ns = 500 MHz)
set_atpg_clock -period 2.0 [get_dft_signals master_clock]

# Constant outputs during test (power management pins)
add_input_constraints cache_power_down -c 0
add_input_constraints cache_flush_req  -c 0

# Primary outputs that are not observable during scan (tie X)
# RDATA, RVALID etc. — captured via scan chain not direct PO
add_output_masks s_axi_rdata
add_output_masks m_axi_wdata

###############################################################################
# 4. Run stuck-at ATPG campaign
###############################################################################
set_fault_type stuck

run_atpg \
  -auto_compression     on  \
  -dynamic_compression  on  \
  -effort               high

report_faults  -type summary > reports/dft/atpg_stuck_at.rpt
report_faults  -type detail  >> reports/dft/atpg_stuck_at.rpt

set sa_cov [get_atpg_coverage]
puts "Stuck-At Coverage: $sa_cov%"
if {$sa_cov < $COVERAGE_TARGET_STUCK} {
  puts "WARNING: Stuck-at coverage $sa_cov% < target $COVERAGE_TARGET_STUCK%"
}

# Write patterns (STIL + Verilog)
write_patterns dft/patterns/l2_stuck_at.stil  -format stil
write_patterns dft/patterns/l2_patterns.v     -format verilog

###############################################################################
# 5. Run transition fault ATPG campaign
###############################################################################
set_fault_type transition

run_atpg \
  -auto_compression    on \
  -launch_off_capture  on \
  -effort              high

report_faults  -type summary > reports/dft/atpg_transition.rpt
report_faults  -type detail  >> reports/dft/atpg_transition.rpt

set tf_cov [get_atpg_coverage]
puts "Transition Fault Coverage: $tf_cov%"
if {$tf_cov < $COVERAGE_TARGET_TRANS} {
  puts "WARNING: Transition coverage $tf_cov% < target $COVERAGE_TARGET_TRANS%"
}

write_patterns dft/patterns/l2_transition.stil -format stil

###############################################################################
# 6. Fault simulation on existing patterns (verify pattern quality)
###############################################################################
set_fault_type stuck
run_simulation  -pattern_set all

report_simulation > reports/dft/fault_sim.rpt

###############################################################################
# 7. Summary
###############################################################################
puts "================================================"
puts "  ATPG Complete: $DESIGN_TOP"
puts "  Stuck-At Coverage   : $sa_cov%  (target: $COVERAGE_TARGET_STUCK%)"
puts "  Transition Coverage : $tf_cov%  (target: $COVERAGE_TARGET_TRANS%)"
puts "  Patterns written to : dft/patterns/"
puts "  Reports written to  : reports/dft/"
puts "================================================"

if {$sa_cov < $COVERAGE_TARGET_STUCK || $tf_cov < $COVERAGE_TARGET_TRANS} {
  exit 1
} else {
  exit 0
}
