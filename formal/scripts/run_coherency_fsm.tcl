###############################################################################
# Script     : formal/scripts/run_coherency_fsm.tcl
# Tool       : Cadence JasperGold FPV
# Proof goal : Coherency FSM state machine correctness and liveness
# Usage      : jg -fpv formal/scripts/run_coherency_fsm.tcl
###############################################################################

clear -all

analyze -sv12 -f {
  rtl/cache/l2_cache_pkg.sv
  rtl/cache/l2_coherency_fsm.sv
  formal/props/props_coherency_fsm.sv
}

elaborate \
  -top l2_coherency_fsm \
  -parameter ADDR_WIDTH 40 \
  -parameter DATA_WIDTH 64 \
  -parameter NUM_SETS   512 \
  -parameter WAYS       4 \
  -parameter TAG_BITS   25 \
  -parameter INDEX_BITS 9 \
  -parameter OFFSET_BITS 6

bind l2_coherency_fsm props_coherency_fsm #(
  .ADDR_WIDTH (40),
  .DATA_WIDTH (64)
) u_props_coh (
  .clk           (clk),
  .rst_n         (rst_n),
  .coh_state     (coh_state),
  .coh_next      (coh_next),
  .ac_valid      (ac_valid),
  .ac_ready      (ac_ready),
  .ac_snoop      (ac_snoop),
  .ac_addr       (ac_addr),
  .cr_valid      (cr_valid),
  .cr_ready      (cr_ready),
  .cr_resp       (cr_resp),
  .cd_valid      (cd_valid),
  .cd_ready      (cd_ready),
  .cd_last       (cd_last),
  .snoop_hit_r   (snoop_hit_r),
  .snoop_dirty_r (snoop_dirty_r),
  .snoop_mesi_r  (snoop_mesi_r),
  .snoop_wb_req  (snoop_wb_req),
  .wb_pending    (wb_pending)
);

clock  clk
reset  ~rst_n

# Environment constraints
assume -name asm_coh_ac_valid_stable {
  (ac_valid && !ac_ready) |=> ac_valid
}
assume -name asm_coh_ac_aligned {
  ac_valid |-> (ac_addr[5:0] == 6'b0)
}
assume -name asm_coh_cr_ready_bounded {
  cr_valid |-> ##[0:4] cr_ready
}
assume -name asm_coh_cd_ready_bounded {
  cd_valid |-> ##[0:4] cd_ready
}
assume -name asm_coh_legal_snoop_type {
  ac_valid |-> (ac_snoop inside {4'h1, 4'h7, 4'h9, 4'hB, 4'hD})
}

set_prove_time_limit 1200
set_engine_mode {Hp Ht K I}

prove -all

report -results -file reports/formal/coherency_fsm_results.rpt
report -summary -file reports/formal/coherency_fsm_summary.rpt
report -cover   -file reports/formal/coherency_fsm_coverage.rpt

set proven [llength [get_results -type assert -status proven]]
set failed [llength [get_results -type assert -status failed]]
puts "Coherency FSM: proven=$proven failed=$failed"
if {$failed > 0} { exit 1 } else { exit 0 }
