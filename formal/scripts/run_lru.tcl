###############################################################################
# Script     : run_lru.tcl
# Tool       : Cadence JasperGold FPV
# Proof goal : Pseudo-LRU controller correctness
# Usage      : jg -fpv formal/scripts/run_lru.tcl
###############################################################################

clear -all

analyze -sv12 -f {
  rtl/cache/l2_lru_controller.sv
  formal/props/props_lru.sv
}

elaborate \
  -top l2_lru_controller \
  -parameter NUM_SETS 512 \
  -parameter WAYS 4

bind l2_lru_controller props_lru #(
  .NUM_SETS (512),
  .WAYS     (4)
) u_props_lru (
  .clk          (clk),
  .rst_n        (rst_n),
  .access_valid (access_valid),
  .access_set   (access_set),
  .access_way   (access_way),
  .victim_set   (victim_set),
  .victim_way   (victim_way),
  .lru_state    (plru_reg)
);

clock  clk
reset  ~rst_n

source formal/constraints/lru_env_constraints.tcl

set_prove_time_limit 600
set_engine_mode {Hp Ht K}
set_max_trace_length 64

prove -all

report -results -file reports/formal/lru_results.rpt
report -summary -file reports/formal/lru_summary.rpt
report -cover   -file reports/formal/lru_coverage.rpt

set proven [llength [get_results -type assert -status proven]]
set failed [llength [get_results -type assert -status failed]]
puts "LRU: proven=$proven failed=$failed"
if {$failed > 0} { exit 1 } else { exit 0 }
