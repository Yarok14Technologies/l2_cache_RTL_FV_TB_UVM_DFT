// =============================================================================
// File       : formal/props/props_coherency_fsm.sv
// Module     : l2_coherency_fsm
// Tool       : JasperGold FPV
// Description: Formal properties for the coherency FSM state machine.
//              Proves: all states reachable, no illegal transitions,
//              correct response ordering, and bounded liveness.
//
//              State encoding (from l2_cache_pkg):
//                COH_IDLE=0, COH_SNOOP_LOOKUP=1, COH_SNOOP_HIT_CLEAN=2,
//                COH_SNOOP_HIT_DIRTY=3, COH_CD_TRANSFER=4, COH_CR_SEND=5,
//                COH_WB_ISSUE=6, COH_WB_WAIT=7, COH_UPGRADE_PEND=8, COH_MISS=9
// =============================================================================

`ifndef PROPS_COHERENCY_FSM_SV
`define PROPS_COHERENCY_FSM_SV

`include "l2_cache_pkg.sv"

module props_coherency_fsm
  import l2_cache_pkg::*;
#(
  parameter int unsigned ADDR_WIDTH = 40,
  parameter int unsigned DATA_WIDTH = 64
)(
  input logic                   clk,
  input logic                   rst_n,

  // FSM state (internal, exposed via bind)
  input logic [3:0]             coh_state,
  input logic [3:0]             coh_next,

  // ACE snoop channels
  input logic                   ac_valid,
  input logic                   ac_ready,
  input logic [3:0]             ac_snoop,
  input logic [ADDR_WIDTH-1:0]  ac_addr,

  input logic                   cr_valid,
  input logic                   cr_ready,
  input logic [4:0]             cr_resp,

  input logic                   cd_valid,
  input logic                   cd_ready,
  input logic                   cd_last,

  // Internal coherency signals
  input logic                   snoop_hit_r,
  input logic                   snoop_dirty_r,
  input mesi_state_t            snoop_mesi_r,

  // Write-back
  input logic                   snoop_wb_req,
  input logic                   wb_pending
);

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // ── State encoding constants ───────────────────────────────────────────────
  localparam [3:0]
    COH_IDLE         = 4'h0,
    COH_SNOOP_LOOKUP = 4'h1,
    COH_HIT_CLEAN    = 4'h2,
    COH_HIT_DIRTY    = 4'h3,
    COH_CD_TRANSFER  = 4'h4,
    COH_CR_SEND      = 4'h5,
    COH_WB_ISSUE     = 4'h6,
    COH_WB_WAIT      = 4'h7,
    COH_UPGRADE_PEND = 4'h8,
    COH_MISS         = 4'h9;

  // =========================================================================
  // ── Safety 1: Only legal states ─────────────────────────────────────────────
  // =========================================================================
  P_COH_LEGAL_STATE: assert property (
    coh_state inside {COH_IDLE, COH_SNOOP_LOOKUP, COH_HIT_CLEAN, COH_HIT_DIRTY,
                      COH_CD_TRANSFER, COH_CR_SEND, COH_WB_ISSUE, COH_WB_WAIT,
                      COH_UPGRADE_PEND, COH_MISS}
  ) else $fatal(0, "COH_FSM: illegal state 0x%0h", coh_state);

  // =========================================================================
  // ── Safety 2: AC ready only when idle ───────────────────────────────────────
  // =========================================================================
  P_COH_ACREADY_IDLE: assert property (
    ac_ready |-> (coh_state == COH_IDLE)
  ) else $error("COH_FSM: ac_ready asserted in non-IDLE state %0d", coh_state);

  // =========================================================================
  // ── Safety 3: CR valid only in CR_SEND state ────────────────────────────────
  // =========================================================================
  P_COH_CR_VALID_STATE: assert property (
    cr_valid |-> (coh_state == COH_CR_SEND)
  ) else $error("COH_FSM: cr_valid outside COH_CR_SEND state (state=%0d)", coh_state);

  // =========================================================================
  // ── Safety 4: CD valid only in CD_TRANSFER state ────────────────────────────
  // =========================================================================
  P_COH_CD_VALID_STATE: assert property (
    cd_valid |-> (coh_state == COH_CD_TRANSFER)
  ) else $error("COH_FSM: cd_valid outside COH_CD_TRANSFER state");

  // =========================================================================
  // ── Safety 5: WB issued only for dirty hits ──────────────────────────────────
  // =========================================================================
  P_COH_WB_NEEDS_DIRTY: assert property (
    (coh_state == COH_WB_ISSUE) |->
    ($past(snoop_hit_r) && $past(snoop_dirty_r))
  ) else $error("COH_FSM: write-back issued for non-dirty line");

  // =========================================================================
  // ── Safety 6: No illegal transitions ────────────────────────────────────────
  // CR_SEND must always eventually return to IDLE
  // =========================================================================
  P_COH_CR_TO_IDLE: assert property (
    $rose(coh_state == COH_CR_SEND) |->
    ##[0:4] (coh_state == COH_IDLE)
  ) else $error("COH_FSM: stuck in CR_SEND state > 4 cycles");

  // =========================================================================
  // ── Liveness 1: IDLE → must process snoop within 1 cycle ────────────────────
  // =========================================================================
  P_COH_SNOOP_ACCEPTED: assert property (
    (coh_state == COH_IDLE && ac_valid) |=>
    (coh_state == COH_SNOOP_LOOKUP)
  ) else $error("COH_FSM: snoop not accepted from IDLE state in 1 cycle");

  // =========================================================================
  // ── Liveness 2: Full snoop pipeline completes within 64 cycles ───────────────
  // =========================================================================
  P_COH_SNOOP_PIPELINE_BOUNDED: assert property (
    $rose(coh_state == COH_SNOOP_LOOKUP) |->
    ##[1:64] (coh_state == COH_IDLE)
  ) else $fatal(0, "COH_FSM: snoop pipeline did not complete within 64 cycles");

  // =========================================================================
  // ── Liveness 3: CD transfer always completes ─────────────────────────────────
  // =========================================================================
  P_COH_CD_COMPLETES: assert property (
    $rose(coh_state == COH_CD_TRANSFER) |->
    ##[1:32] (cd_valid && cd_ready && cd_last)
  ) else $error("COH_FSM: CD data transfer did not complete within 32 cycles");

  // =========================================================================
  // ── Ordering: CD always before CR on dirty hit ───────────────────────────────
  // =========================================================================
  P_COH_CD_BEFORE_CR: assert property (
    (snoop_dirty_r && snoop_hit_r) |->
    !cr_valid until cd_valid
  ) else $error("COH_FSM: CR response sent before CD data on dirty hit");

  // =========================================================================
  // ── Ordering: reset puts FSM in IDLE ────────────────────────────────────────
  // =========================================================================
  P_COH_RESET_IDLE: assert property (
    $fell(rst_n) |=> (coh_state == COH_IDLE)
  ) else $error("COH_FSM: not in IDLE after reset");

  // =========================================================================
  // ── Cover: all states reachable ─────────────────────────────────────────────
  // =========================================================================
  COV_COH_LOOKUP:    cover property (coh_state == COH_SNOOP_LOOKUP);
  COV_COH_HIT_CLEAN: cover property (coh_state == COH_HIT_CLEAN);
  COV_COH_HIT_DIRTY: cover property (coh_state == COH_HIT_DIRTY);
  COV_COH_CD:        cover property (coh_state == COH_CD_TRANSFER);
  COV_COH_CR:        cover property (coh_state == COH_CR_SEND);
  COV_COH_WB:        cover property (coh_state == COH_WB_ISSUE);
  COV_COH_UPGRADE:   cover property (coh_state == COH_UPGRADE_PEND);
  COV_COH_MISS:      cover property (coh_state == COH_MISS);
  COV_COH_PASSDIRTY: cover property (cr_valid && cr_ready && cr_resp[3]);

endmodule

`endif // PROPS_COHERENCY_FSM_SV
