###############################################################################
# Script     : run_coverage.tcl
# Tool       : Cadence JasperGold FPV — Cover App
# Description: Drives all cover properties to closure.
#              Separate from prove -all because cover properties need
#              witness generation which is more resource-intensive.
#
# Usage      : jg -cover formal/cov/run_coverage.tcl
###############################################################################

clear -all

###############################################################################
# 1. Analyse and elaborate (same setup as proof scripts)
###############################################################################
analyze -sv12 -f {
  rtl/cache/l2_cache_pkg.sv
  rtl/cache/l2_lru_controller.sv
  rtl/cache/l2_tag_array.sv
  rtl/cache/l2_data_array.sv
  rtl/cache/l2_hit_miss_detect.sv
  rtl/cache/l2_request_pipeline.sv
  rtl/cache/l2_mshr.sv
  rtl/cache/l2_coherency_fsm.sv
  rtl/cache/l2_axi_master.sv
  rtl/cache/l2_cache_top.sv
  formal/props/props_axi_slave.sv
  formal/props/props_mesi_coherency.sv
  formal/props/props_mshr.sv
  formal/props/props_lru.sv
}

elaborate \
  -top l2_cache_top \
  -bbox_m {sram_sp_hd_256x512 sram_sp_hd_256x26} \
  -parameter WAYS 4 \
  -parameter CACHE_SIZE_KB 256 \
  -parameter MSHR_DEPTH 8

clock  clk
reset  ~rst_n

# Load all constraints
source formal/constraints/axi_env_constraints.tcl
source formal/constraints/mesi_env_constraints.tcl

###############################################################################
# 2. Coverage settings
###############################################################################
set_cover_time_limit 3600
set_max_trace_length 512

# Engine configuration optimised for cover witness generation
set_engine_mode {Hp Ht B}

###############################################################################
# 3. Collect all cover properties across all bound modules
###############################################################################
set cover_props [get_results -type cover]
puts "Total cover properties: [llength $cover_props]"

###############################################################################
# 4. Run cover
###############################################################################
cover -all

###############################################################################
# 5. Reports
###############################################################################
file mkdir reports/formal

report -cover \
  -status covered \
  -witness \
  -file reports/formal/cover_witnesses.rpt

report -cover \
  -status uncovered \
  -file reports/formal/cover_uncovered.rpt

report -cover \
  -file reports/formal/cover_all.rpt

###############################################################################
# 6. Coverage summary
###############################################################################
set total    [llength [get_results -type cover]]
set covered  [llength [get_results -type cover -status covered]]
set uncov    [llength [get_results -type cover -status uncovered]]
set vacuous  [llength [get_results -type cover -status vacuous]]

set pct [expr {$total > 0 ? 100.0 * $covered / $total : 0.0}]

puts "\n╔══════════════════════════════════════════════╗"
puts "║     Formal Cover Property Summary            ║"
puts "╠══════════════════════════════════════════════╣"
puts [format "║  Total properties  : %-24d ║" $total]
puts [format "║  Covered           : %-24d ║" $covered]
puts [format "║  Uncovered         : %-24d ║" $uncov]
puts [format "║  Vacuous           : %-24d ║" $vacuous]
puts [format "║  Coverage          : %-23.1f%% ║" $pct]
puts "╚══════════════════════════════════════════════╝\n"

# Print uncovered properties for debug
if {$uncov > 0} {
  puts "Uncovered properties (may need deeper bound or more constrained env):"
  foreach p [get_results -type cover -status uncovered] {
    puts "  - [get_property $p fullname]"
  }
}

if {$pct < 80.0} {
  puts "WARNING: Cover closure below 80% — check constraints"
  exit 2
}
puts "Cover closure: DONE"
exit 0
