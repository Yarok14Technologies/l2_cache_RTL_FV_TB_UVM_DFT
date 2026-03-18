###############################################################################
# Script     : run_mshr.tcl
# Tool       : Cadence JasperGold FPV
# Proof goal : MSHR correctness — occupancy, no lost requests, ordering
# Usage      : jg -fpv formal/scripts/run_mshr.tcl
###############################################################################

clear -all

analyze -sv12 -f {
  rtl/cache/l2_cache_pkg.sv
  rtl/cache/l2_mshr.sv
  formal/props/props_mshr.sv
}

# Elaborate directly on MSHR module (faster convergence — no full cache)
elaborate \
  -top l2_mshr \
  -parameter DEPTH 16 \
  -parameter ADDR_WIDTH 40 \
  -parameter DATA_WIDTH 64 \
  -parameter ID_WIDTH   8

bind l2_mshr props_mshr #(
  .DEPTH      (16),
  .ADDR_WIDTH (40),
  .DATA_WIDTH (64),
  .ID_WIDTH   (8)
) u_props_mshr (
  .clk             (clk),
  .rst_n           (rst_n),
  .alloc_req       (alloc_req),
  .alloc_addr      (alloc_addr),
  .alloc_id        (alloc_id),
  .alloc_is_write  (alloc_is_write),
  .alloc_merged    (alloc_merged),
  .alloc_idx       (alloc_idx),
  .full            (full),
  .fill_valid      (fill_valid),
  .fill_addr       (fill_addr),
  .fill_entry_idx  (fill_entry_idx),
  .resp_valid      (resp_valid),
  .resp_id         (resp_id),
  .resp_accepted   (resp_accepted),
  .wb_valid        (wb_valid),
  .wb_done         (wb_done),
  .mshr            (mshr),
  .mshr_valid_vec  (mshr_valid_vec),
  .mshr_used_count (mshr_used_count)
);

clock  clk
reset  ~rst_n

source formal/constraints/mshr_env_constraints.tcl

set_prove_time_limit 3600
set_engine_mode {Hp Ht K I}
set_max_trace_length 512

# Safety first
prove -property {
  P_MSHR_SAF_COUNT_BOUNDED
  P_MSHR_SAF_FULL_CORRECT
  P_MSHR_SAF_NO_ALLOC_FULL
  P_MSHR_SAF_FILL_HAS_ENTRY
  P_MSHR_SAF_FILL_ADDR_MATCH
  P_MSHR_SAF_STATE_LEGAL
  P_MSHR_SAF_RESET_CLEAN
}

# Ordering and liveness (heavier)
prove -property {
  P_MSHR_LIV_ENTRY_COMPLETES
  P_MSHR_LIV_FILL_TO_RESP
  P_MSHR_ORD_WB_BEFORE_FILL
}

# Duplicate address check — run separately (more resource-intensive)
prove -property {P_MSHR_SAF_NO_DUPLICATE_ADDR}

report -results -file reports/formal/mshr_results.rpt
report -summary -file reports/formal/mshr_summary.rpt
report -cover   -file reports/formal/mshr_coverage.rpt

set proven [llength [get_results -type assert -status proven]]
set failed [llength [get_results -type assert -status failed]]

puts "================================================="
puts "  MSHR Formal Results"
puts "  Assert PROVEN : $proven"
puts "  Assert FAILED : $failed"
puts "================================================="

if {$failed > 0} { exit 1 } else { exit 0 }
