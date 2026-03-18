###############################################################################
# Script     : run_mesi.tcl
# Tool       : Cadence JasperGold FPV
# Proof goal : MESI coherency protocol invariants and deadlock freedom
# Usage      : jg -fpv formal/scripts/run_mesi.tcl
###############################################################################

clear -all

###############################################################################
# 1. Analyse
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
  formal/props/props_mesi_coherency.sv
}

###############################################################################
# 2. Elaborate with black-boxes for SRAMs (focus on control logic)
###############################################################################
elaborate \
  -top l2_cache_top \
  -bbox_m {sram_sp_hd_256x512 sram_sp_hd_256x26} \
  -parameter WAYS 4 \
  -parameter CACHE_SIZE_KB 256 \
  -parameter MSHR_DEPTH 8 \
  -parameter NUM_SETS 512

# Bind MESI property module with hierarchical access to tag array state
bind l2_cache_top props_mesi_coherency #(
  .NUM_SETS   (512),
  .WAYS       (4),
  .ADDR_WIDTH (40),
  .DATA_WIDTH (64)
) u_props_mesi (
  .clk                  (clk),
  .rst_n                (rst_n),
  .mesi_state           (u_tag_array.tag_ram),  // hierarchical ref
  .valid_bit            (u_tag_array.tag_ram),
  .dirty_bit            (u_tag_array.tag_ram),
  .ac_addr              (ac_addr),
  .ac_snoop             (ac_snoop),
  .ac_valid             (ac_valid),
  .ac_ready             (ac_ready),
  .cr_resp              (cr_resp),
  .cr_valid             (cr_valid),
  .cr_ready             (cr_ready),
  .cd_data              (cd_data),
  .cd_last              (cd_last),
  .cd_valid             (cd_valid),
  .cd_ready             (cd_ready),
  .coh_state            (u_coherency.coh_state),
  .cache_hit            (cache_hit),
  .cache_miss           (cache_miss),
  .wb_pending           (wb_pending),
  .upgrade_req_sent     (u_coherency.upgrade_req_sent),
  .upgrade_ack_received (u_coherency.upgrade_ack_received)
);

###############################################################################
# 3. Clock / reset
###############################################################################
clock  clk
reset  ~rst_n

###############################################################################
# 4. Load MESI-specific constraints
###############################################################################
source formal/constraints/mesi_env_constraints.tcl

###############################################################################
# 5. Proof engine configuration
###############################################################################
set_prove_time_limit 7200    ;# 2 hours (MESI invariants need induction depth)

# Use proof engines: Heuristic, K-induction, Interpolation, IC3/PDR
set_engine_mode {Hp Ht Hd K I Tr}

# Increase induction depth for MESI state reachability
set_max_trace_length 256

# Cone of influence reduction (focus on coherency FSM)
set_coi_limit 500

###############################################################################
# 6. Prove invariants first (safety), then liveness
###############################################################################

# Run safety properties first (faster to converge)
prove -property {
  P_MESI_INV_ONE_MODIFIED
  P_MESI_INV_DIRTY_IFF_MODIFIED
  P_MESI_INV_VALID_FOR_NONI
  P_MESI_SNOOP_CR_STABLE
  P_MESI_SNOOP_CD_STABLE
  P_MESI_RESET_INVALID
}

# Then liveness (requires stronger engines)
prove -property {
  P_MESI_DEAD_SNOOP_RESPONSE
  P_MESI_DEAD_AC_ACCEPTED
  P_MESI_SNOOP_PASSDIRTY_HAS_CD
  P_MESI_SNOOP_PASSDIRTY_NEEDS_M
  P_MESI_TRANS_S_TO_M_UPGRADE
}

###############################################################################
# 7. Reports
###############################################################################
report -results  -file reports/formal/mesi_results.rpt
report -summary  -file reports/formal/mesi_summary.rpt
report -cover    -file reports/formal/mesi_coverage.rpt

# Dump witness traces for cover points
report -cover -status covered -witness \
  -file reports/formal/mesi_witnesses.rpt

###############################################################################
# 8. Pass/fail
###############################################################################
set proven [llength [get_results -type assert -status proven]]
set failed [llength [get_results -type assert -status failed]]
set undetermined [llength [get_results -type assert -status undetermined]]

puts "================================================="
puts "  MESI Coherency Formal Results"
puts "  Assert PROVEN      : $proven"
puts "  Assert FAILED      : $failed"
puts "  Assert UNDETERMINED: $undetermined"
puts "================================================="

if {$failed > 0}        { puts "*** PROOF FAILED ***";    exit 1 }
if {$undetermined > 0}  { puts "WARNING: Some undetermined — increase depth"; exit 2 }
puts "*** ALL MESI PROOFS PASSED ***"
exit 0
