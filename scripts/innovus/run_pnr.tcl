################################################################################
# Script     : scripts/innovus/run_pnr.tcl
# Tool       : Cadence Innovus Implementation System 23.10+
# Description: Complete Place-and-Route flow for the L2 cache controller.
#              Includes: floorplan, power planning, placement, CTS,
#              routing, post-route optimisation, signoff extraction.
#
# Prerequisites:
#   - Post-synthesis DFT netlist : netlist/l2_cache_top.v
#   - SDC constraints            : netlist/l2_cache_top.sdc
#   - UPF power intent           : constraints/upf/l2_cache.upf
#   - LEF/TLEF files             : libs/28nm/*.lef
#   - SRAM abstract views        : libs/memory/*.lef
#   - RC tech file               : libs/28nm/rc_tech.qrc
#
# Usage:
#   innovus -batch -script scripts/innovus/run_pnr.tcl
#   innovus -common_ui -batch -script scripts/innovus/run_pnr.tcl
################################################################################

################################################################################
# 0. Configuration
################################################################################
set DESIGN_TOP   "l2_cache_top"
set PROCESS_NODE "28nm"
set CLK_PERIOD   2.0    ;# ns (500 MHz)
set CORE_UTIL    0.70   ;# 70% cell utilisation target

set NETLIST      "netlist/${DESIGN_TOP}.v"
set SDC          "netlist/${DESIGN_TOP}.sdc"
set UPF          "constraints/upf/l2_cache.upf"

file mkdir reports/innovus
file mkdir outputs/innovus

################################################################################
# 1. Initialise design
################################################################################

# Technology and libraries
set_db init_lef_file [list \
  libs/28nm/tech.tlef \
  libs/28nm/std_cells.lef \
  libs/memory/sram_sp_hd_256x512.lef \
  libs/memory/sram_sp_hd_256x26.lef \
]

set_db init_mmmc_file scripts/innovus/mmmc.tcl

read_netlist  $NETLIST -top $DESIGN_TOP
read_def      {}       ;# empty — floorplan will be created below

# Load UPF for power-aware implementation
read_power_intent -1801 $UPF
commit_power_intent

init_design

################################################################################
# 2. Floorplan
################################################################################

# Die area derived from area report (gates × 28nm cell area ≈ 0.6 mm²)
# Add 30% margin for routing and power grid
floorPlan \
  -coreSite  unit \
  -d         900 900 \   ;# 900 × 900 µm die
  -b         60  60  \   ;# 60 µm border
  -utilization $CORE_UTIL

# Place SRAM macros manually (fixed locations, away from edges)
# Data array — 4 banks, each ~100 × 100 µm
place_macro \
  -inst_name u_data_array/sram[0] \
  -orient     R0 \
  -location   {80 80}

place_macro \
  -inst_name u_data_array/sram[1] \
  -orient     R0 \
  -location   {80 220}

place_macro \
  -inst_name u_data_array/sram[2] \
  -orient     R0 \
  -location   {80 360}

place_macro \
  -inst_name u_data_array/sram[3] \
  -orient     R0 \
  -location   {80 500}

# Halo around macros (no standard cells within 5 µm)
add_halo -all_macros -halo_deltas {5 5 5 5}

################################################################################
# 3. Power planning
################################################################################

# VDD/VSS power rings around core
add_power_ring \
  -nets         {VDD VSS} \
  -layer        {M8 M9} \
  -width        4.0 \
  -spacing      2.0 \
  -offset       2.0

# Power stripes across core (M7 vertical, M8 horizontal)
add_stripe \
  -nets        {VDD VSS} \
  -layer       M7 \
  -direction   vertical \
  -width       2.0 \
  -pitch       40.0 \
  -start       20.0

add_stripe \
  -nets        {VDD VSS} \
  -layer       M8 \
  -direction   horizontal \
  -width       2.0 \
  -pitch       40.0 \
  -start       20.0

# Connect standard cell rails to stripes
sroute -connect core_pin \
       -nets    {VDD VSS}

################################################################################
# 4. Placement
################################################################################

place_design -concurrent_macros

# Post-placement optimisation
optDesign -preCTS

# Verify placement
check_place -max_density 0.85

report_design_area > reports/innovus/area_placed.rpt

################################################################################
# 5. Clock Tree Synthesis (CTS)
################################################################################

# CTS spec — target skew ≤ 50 ps, insertion delay ≤ 500 ps
create_clock_tree_spec \
  -file scripts/innovus/cts_spec.tcl \
  -max_skew    0.050 \
  -max_fanout  32

# Run CTS
clock_design

# Post-CTS hold fixing
optDesign -postCTS -hold

# Check clock tree quality
report_clock_timing \
  -type summary \
  > reports/innovus/cts_summary.rpt

################################################################################
# 6. Routing
################################################################################

route_design \
  -global_detail \
  -via_opt

# Post-route optimisation (setup + hold)
optDesign -postRoute
optDesign -postRoute -hold

# Check routing DRC
verify_connectivity -report reports/innovus/connectivity.rpt
verify_drc          -report reports/innovus/drc.rpt

################################################################################
# 7. Post-route signoff
################################################################################

# Extract RC parasitics
extract_rc \
  -outfile outputs/innovus/${DESIGN_TOP}.spef \
  -effort   medium

# Write SPEF for PrimeTime
write_parasitics \
  -format    spef \
  -output    outputs/innovus/${DESIGN_TOP}.spef

# IR drop analysis
analyze_power_via \
  -method    static \
  -frequency [expr {1e9 / $CLK_PERIOD}] \
  -report    reports/innovus/ir_drop.rpt

################################################################################
# 8. Output files
################################################################################

# Final netlist (with filler cells + tie cells)
write_netlist \
  -top_module_first \
  -output outputs/innovus/${DESIGN_TOP}_final.v

# DEF for mask generation
write_def \
  -routing  \
  -output   outputs/innovus/${DESIGN_TOP}.def

# GDSII for tapeout
streamOut \
  outputs/innovus/${DESIGN_TOP}.gds \
  -mapFile  libs/28nm/stream.map \
  -libName  $DESIGN_TOP \
  -merge    [list libs/memory/sram_sp_hd_256x512.gds \
                  libs/memory/sram_sp_hd_256x26.gds] \
  -units    2000 \
  -mode     ALL

# SDF for post-layout simulation
write_sdf \
  -precision 4 \
  outputs/innovus/${DESIGN_TOP}_postroute.sdf

################################################################################
# 9. Final reports
################################################################################
report_timing \
  -max_paths 20 \
  -path_type full \
  > reports/innovus/timing_postroute.rpt

report_power \
  -domain    PD_ALWAYS_ON \
  -domain    PD_CACHE_LOGIC \
  -domain    PD_DATA_SRAM \
  > reports/innovus/power_domains.rpt

report_area \
  > reports/innovus/area_final.rpt

puts "========================================="
puts "  P&R Complete: $DESIGN_TOP"
puts "  GDSII: outputs/innovus/${DESIGN_TOP}.gds"
puts "  SPEF:  outputs/innovus/${DESIGN_TOP}.spef"
puts "========================================="
