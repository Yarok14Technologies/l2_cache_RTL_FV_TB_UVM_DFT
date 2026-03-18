###############################################################################
# Script     : dc_synthesis.tcl
# Tool       : Synopsys Design Compiler (DC Ultra)
# Project    : L2 Cache Controller
# Description: Complete synthesis flow — read RTL, apply constraints,
#              compile with retiming and scan insertion, generate reports.
#
# Usage: dc_shell -f scripts/dc_synthesis/dc_synthesis.tcl \
#          -x "set WAYS 4; set CACHE_SIZE_KB 256; set CLK_PERIOD_NS 2.0"
###############################################################################

###############################################################################
# 0. Configuration — override on command line if needed
###############################################################################
if {![info exists WAYS]}           { set WAYS           4     }
if {![info exists CACHE_SIZE_KB]}  { set CACHE_SIZE_KB  256   }
if {![info exists CLK_PERIOD_NS]}  { set CLK_PERIOD_NS  2.0   }
if {![info exists PROCESS_NODE]}   { set PROCESS_NODE   "28nm" }
if {![info exists DESIGN_TOP]}     { set DESIGN_TOP     "l2_cache_top" }
if {![info exists ENABLE_SCAN]}    { set ENABLE_SCAN    1     }
if {![info exists ENABLE_RETIME]}  { set ENABLE_RETIME  1     }

puts "INFO: Synthesizing ${DESIGN_TOP} at ${CLK_PERIOD_NS}ns, ${WAYS}-way, ${CACHE_SIZE_KB}KB"

###############################################################################
# 1. Setup — libraries
###############################################################################
set_app_var target_library  [list \
  libs/${PROCESS_NODE}/slow_1v0_125c.db \
]

set_app_var link_library    [list \
  *                                    \
  libs/${PROCESS_NODE}/slow_1v0_125c.db \
  libs/memory/sram_sp_hd_256x26.db     \
  libs/memory/sram_sp_hd_256x512.db    \
]

set_app_var symbol_library  [list generic.sdb]

# Enable VHDL/SV analysis
set_app_var hdlin_sv_enable_rtl_synthesis true
set_app_var hdlin_check_no_latch           true

###############################################################################
# 2. Read RTL
###############################################################################
define_design_lib WORK -path ./work

# Compile all RTL sources
analyze -format sverilog -work WORK [list \
  rtl/cache/l2_cache_pkg.sv         \
  rtl/cache/l2_tag_array.sv         \
  rtl/cache/l2_lru_controller.sv    \
  rtl/cache/l2_coherency_fsm.sv     \
  rtl/cache/l2_hit_miss_detect.sv   \
  rtl/cache/l2_request_pipeline.sv  \
  rtl/cache/l2_data_array.sv        \
  rtl/cache/l2_mshr.sv              \
  rtl/cache/l2_axi_master.sv        \
  rtl/cache/l2_cache_top.sv         \
]

# Elaborate with parameters
elaborate ${DESIGN_TOP} \
  -parameters "WAYS=${WAYS},CACHE_SIZE_KB=${CACHE_SIZE_KB}" \
  -work WORK

current_design ${DESIGN_TOP}
link

###############################################################################
# 3. Apply timing constraints
###############################################################################
source constraints/l2_cache.sdc

###############################################################################
# 4. Pre-synthesis checks
###############################################################################
check_design > reports/check_design_pre.rpt
check_timing > reports/check_timing_pre.rpt

###############################################################################
# 5. Compilation
###############################################################################
# Set compile options
set compile_args {}
if {$ENABLE_RETIME} { lappend compile_args "-retime" }
if {$ENABLE_SCAN}   { lappend compile_args "-scan"   }

# Ultra compile for best PPA
eval compile_ultra {*}$compile_args

# Incremental compile to pick up post-compile timing fixes
compile_ultra -incremental

###############################################################################
# 6. Post-compile optimizations
###############################################################################

# Fix hold violations with minimum delay buffers
set_fix_hold [get_clocks clk]
compile_ultra -incremental -only_hold_time

# High fanout synthesis (reset, clock enable)
set_max_fanout 20 [current_design]
compile_ultra -incremental -no_autoungroup

###############################################################################
# 7. Reports
###############################################################################
file mkdir reports

# Timing: worst 20 paths, full clock expansion
report_timing \
  -max_paths 20 \
  -path_type full_clock_expanded \
  -delay_type max \
  -sort_by slack \
  > reports/timing_setup.rpt

report_timing \
  -max_paths 20 \
  -path_type full_clock_expanded \
  -delay_type min \
  -sort_by slack \
  > reports/timing_hold.rpt

# Area breakdown
report_area   -hierarchy       > reports/area.rpt
report_area   -nosplit -hier   > reports/area_hier.rpt

# Power (uses switching activity if .saif provided)
if {[file exists sim/switching_activity.saif]} {
  read_saif -input sim/switching_activity.saif -instance ${DESIGN_TOP}
  report_power -analysis_effort high > reports/power.rpt
} else {
  set_switching_activity -toggle_rate 0.2 -static_probability 0.5 [all_registers]
  report_power > reports/power_estimated.rpt
}

# Cell utilization
report_cell  > reports/cell_count.rpt
report_net   > reports/net_count.rpt
report_clock > reports/clocks.rpt

# QOR summary
report_qor   > reports/qor.rpt

###############################################################################
# 8. DFT / Scan insertion
###############################################################################
if {$ENABLE_SCAN} {
  # DFT configuration
  set_scan_configuration \
    -clock_mixing      no_mix \
    -add_lockup_latch  true   \
    -style             multiplexed_flip_flop

  # Insert scan chains (one chain per clock domain)
  insert_dft

  # Preview scan coverage
  preview_dft > reports/dft_preview.rpt

  # Compile after DFT insertion
  compile_ultra -incremental -scan

  # DFT report
  report_scan_path > reports/scan_chains.rpt
}

###############################################################################
# 9. Netlist output
###############################################################################
file mkdir netlist

# Verilog netlist
write -format verilog \
  -hierarchy \
  -output netlist/${DESIGN_TOP}.v

# Design database
write -format ddc \
  -hierarchy \
  -output netlist/${DESIGN_TOP}.ddc

# SDF for gate-level simulation
write_sdf \
  -version 3.0 \
  -context verilog \
  -load_delay net \
  netlist/${DESIGN_TOP}.sdf

# SDC for PnR
write_sdc \
  -nosplit \
  netlist/${DESIGN_TOP}.sdc

# SPEF (if available, for power analysis)
# write_parasitics -output netlist/${DESIGN_TOP}.spef

###############################################################################
# 10. Final summary
###############################################################################
echo "============================================="
echo "  SYNTHESIS COMPLETE: ${DESIGN_TOP}"
echo "  Parameters: WAYS=${WAYS} SIZE=${CACHE_SIZE_KB}KB"
echo "  Clock target: ${CLK_PERIOD_NS} ns"
echo "============================================="

# Check for setup violations
set wns [get_attribute [get_timing_paths -delay_type max] slack]
if {$wns < 0} {
  echo "WARNING: Setup violations exist. WNS = ${wns} ns"
} else {
  echo "INFO: Setup timing CLEAN. WNS = ${wns} ns"
}

exit
