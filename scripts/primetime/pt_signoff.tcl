###############################################################################
# Script     : pt_signoff.tcl
# Tool       : Synopsys PrimeTime PX
# Description: Static Timing Analysis signoff for L2 Cache Controller.
#              Reads post-PnR netlist + SPEF, reports setup/hold at all corners.
#
# Usage: pt_shell -f scripts/primetime/pt_signoff.tcl \
#          -x "set CORNER slow"
###############################################################################

if {![info exists CORNER]}      { set CORNER     "slow"    }
if {![info exists CLK_PERIOD]}  { set CLK_PERIOD  2.0      }
if {![info exists DESIGN_TOP]}  { set DESIGN_TOP "l2_cache_top" }

###############################################################################
# 1. Libraries
###############################################################################
set_app_var search_path [list libs/28nm libs/memory]

set_app_var target_library [list \
  libs/28nm/${CORNER}_1v0_125c.db \
  libs/memory/sram_sp_hd_256x26.db \
  libs/memory/sram_sp_hd_256x512.db \
]

set_app_var link_library [concat * $target_library]

###############################################################################
# 2. Read design
###############################################################################
read_verilog netlist/${DESIGN_TOP}.v
current_design $DESIGN_TOP
link_design

###############################################################################
# 3. Read timing constraints
###############################################################################
read_sdc netlist/${DESIGN_TOP}.sdc

###############################################################################
# 4. Read parasitics (post-PnR extraction)
###############################################################################
if {[file exists netlist/${DESIGN_TOP}.spef]} {
  read_parasitics -format spef netlist/${DESIGN_TOP}.spef
} else {
  puts "WARNING: No SPEF found — using ideal wire load"
  set_wire_load_mode enclosed
}

###############################################################################
# 5. Operating conditions (per corner)
###############################################################################
switch $CORNER {
  slow  { set_operating_conditions slow_1v0_125c  }
  fast  { set_operating_conditions fast_1v1_m40c  }
  typ   { set_operating_conditions typical_1v0_25c }
}

###############################################################################
# 6. Timing analysis
###############################################################################
update_timing -full

# Setup
report_timing \
  -delay_type max \
  -max_paths  50 \
  -path_type  full_clock_expanded \
  -sort_by    slack \
  > reports/synthesis/sta_setup_${CORNER}.rpt

# Hold
report_timing \
  -delay_type min \
  -max_paths  50 \
  -path_type  full_clock_expanded \
  -sort_by    slack \
  > reports/synthesis/sta_hold_${CORNER}.rpt

# Summary
report_timing_summary \
  > reports/synthesis/sta_summary_${CORNER}.rpt

###############################################################################
# 7. Power analysis (with SAIF or toggle rates)
###############################################################################
if {[file exists sim/switching_activity.saif]} {
  reset_switching_activity
  read_saif -input sim/switching_activity.saif \
            -instance_name ${DESIGN_TOP}
  update_power
  report_power -hierarchy \
    > reports/synthesis/power_${CORNER}.rpt
}

###############################################################################
# 8. Check and print WNS/TNS
###############################################################################
set wns_setup [get_attribute [get_timing_paths -delay_type max] slack]
set wns_hold  [get_attribute [get_timing_paths -delay_type min] slack]

echo "============================================="
echo "  PrimeTime Signoff: $DESIGN_TOP ($CORNER)"
echo "  Clock target : ${CLK_PERIOD} ns"
echo "  WNS (setup)  : $wns_setup ns"
echo "  WNS (hold)   : $wns_hold ns"
echo "============================================="

if {$wns_setup < 0 || $wns_hold < 0} {
  echo "*** TIMING VIOLATIONS EXIST ***"
  exit 1
} else {
  echo "*** TIMING CLEAN ***"
  exit 0
}
