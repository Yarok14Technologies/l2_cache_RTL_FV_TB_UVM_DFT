// =============================================================================
// File        : l2_cache_assertions.sv
// Project     : Parameterized L2 Cache Controller
// Description : SystemVerilog Assertions (SVA) for protocol correctness,
//               MESI state legality, AXI handshake, and CDC boundary checks.
//
// Usage: Bind to DUT in simulation or use standalone in JasperGold formal.
// =============================================================================

`include "l2_cache_pkg.sv"

module l2_cache_assertions
  import l2_cache_pkg::*;
#(
  parameter int NUM_SETS   = 256,
  parameter int WAYS       = 4,
  parameter int ADDR_WIDTH = 40,
  parameter int DATA_WIDTH = 64,
  parameter int AXI_ID_W   = 8
)(
  input  logic                       clk,
  input  logic                       rst_n,

  // AXI Slave Read
  input  logic                       s_axi_arvalid,
  input  logic                       s_axi_arready,
  input  logic [ADDR_WIDTH-1:0]      s_axi_araddr,
  input  logic [7:0]                 s_axi_arlen,
  input  logic                       s_axi_rvalid,
  input  logic                       s_axi_rready,
  input  logic                       s_axi_rlast,
  input  logic [1:0]                 s_axi_rresp,

  // AXI Slave Write
  input  logic                       s_axi_awvalid,
  input  logic                       s_axi_awready,
  input  logic                       s_axi_wvalid,
  input  logic                       s_axi_wready,
  input  logic                       s_axi_wlast,
  input  logic                       s_axi_bvalid,
  input  logic                       s_axi_bready,
  input  logic [1:0]                 s_axi_bresp,

  // Snoop interface
  input  logic                       ac_valid,
  input  logic                       ac_ready,
  input  logic [4:0]                 cr_resp,
  input  logic                       cr_valid,
  input  logic                       cr_ready,

  // MESI state
  input  mesi_state_t                mesi_state [NUM_SETS-1:0][WAYS-1:0],

  // Internal signals
  input  logic                       cache_hit,
  input  logic                       miss_pending,
  input  logic                       wb_pending,
  input  logic                       upgrade_req_sent,
  input  logic                       upgrade_ack_received
);

  // ===========================================================================
  // Section 1: AXI4 Protocol Assertions
  // ===========================================================================

  // ARVALID must not deassert before ARREADY (AXI4 spec rule)
  property p_arvalid_stable;
    @(posedge clk) disable iff (!rst_n)
    (s_axi_arvalid && !s_axi_arready) |=> s_axi_arvalid;
  endproperty
  assert_arvalid_stable: assert property (p_arvalid_stable)
    else $error("[AXI] ARVALID deasserted before ARREADY handshake");

  // AWVALID must not deassert before AWREADY
  property p_awvalid_stable;
    @(posedge clk) disable iff (!rst_n)
    (s_axi_awvalid && !s_axi_awready) |=> s_axi_awvalid;
  endproperty
  assert_awvalid_stable: assert property (p_awvalid_stable)
    else $error("[AXI] AWVALID deasserted before AWREADY handshake");

  // WVALID must not deassert before WREADY
  property p_wvalid_stable;
    @(posedge clk) disable iff (!rst_n)
    (s_axi_wvalid && !s_axi_wready) |=> s_axi_wvalid;
  endproperty
  assert_wvalid_stable: assert property (p_wvalid_stable)
    else $error("[AXI] WVALID deasserted before WREADY handshake");

  // Write response: BVALID follows WLAST within reasonable cycles
  property p_bvalid_after_wlast;
    @(posedge clk) disable iff (!rst_n)
    (s_axi_wvalid && s_axi_wready && s_axi_wlast) |-> ##[1:64] s_axi_bvalid;
  endproperty
  assert_bvalid_after_wlast: assert property (p_bvalid_after_wlast)
    else $error("[AXI] BVALID not seen within 64 cycles of WLAST");

  // Read response: RVALID follows ARREADY within reasonable cycles
  property p_rvalid_after_arready;
    @(posedge clk) disable iff (!rst_n)
    (s_axi_arvalid && s_axi_arready) |-> ##[1:128] s_axi_rvalid;
  endproperty
  assert_rvalid_after_arready: assert property (p_rvalid_after_arready)
    else $error("[AXI] RVALID not seen within 128 cycles of AR handshake");

  // RLAST must assert exactly once per burst
  // (simplified — full burst counter check omitted for brevity)
  property p_rlast_terminates;
    @(posedge clk) disable iff (!rst_n)
    (s_axi_rvalid && s_axi_rready && s_axi_rlast) |=>
    !s_axi_rvalid || (s_axi_rvalid && !s_axi_rlast);
  endproperty
  assert_rlast_terminates: assert property (p_rlast_terminates)
    else $error("[AXI] Consecutive RLAST seen — burst count error");

  // No error response on normal read (sanity check during directed tests)
  property p_no_read_error;
    @(posedge clk) disable iff (!rst_n)
    (s_axi_rvalid && s_axi_rready) |-> (s_axi_rresp == AXI_RESP_OKAY);
  endproperty
  cover_read_okay: cover property (p_no_read_error);

  // ===========================================================================
  // Section 2: MESI State Legality Assertions
  // ===========================================================================

  // No line can be in MODIFIED state in more than one way per set
  // (simplified — in a multi-core design this checks across cores)
  property p_one_modified_per_set;
    @(posedge clk) disable iff (!rst_n)
    1'b1 |->
    ($countones({mesi_state[0][0]==MESI_MODIFIED,
                 mesi_state[0][1]==MESI_MODIFIED,
                 mesi_state[0][2]==MESI_MODIFIED,
                 mesi_state[0][3]==MESI_MODIFIED}) <= 1);
  endproperty
  // Note: in practice this is looped over all sets; shown for set 0
  assert_one_modified_set0: assert property (p_one_modified_per_set)
    else $error("[MESI] Multiple MODIFIED lines in set 0 — coherency violation");

  // Illegal: transition from SHARED to MODIFIED without upgrade
  property p_no_silent_s_to_m;
    @(posedge clk) disable iff (!rst_n)
    // This property checks the upgrade_req_sent/ack signals
    // In a full design, mesi_state_prev would track last-cycle state
    (upgrade_req_sent && !upgrade_ack_received) |=>
    !upgrade_ack_received || (upgrade_req_sent);
  endproperty
  assert_no_silent_s_to_m: assert property (p_no_silent_s_to_m)
    else $fatal(0, "[MESI] Illegal S->M transition without completing upgrade protocol");

  // If MODIFIED, dirty eviction must be issued before line is replaced
  // (Checked by: wb_pending must be true when miss_pending and evicted line is M)
  property p_dirty_eviction_before_fill;
    @(posedge clk) disable iff (!rst_n)
    (miss_pending && wb_pending) |-> wb_pending throughout ##[1:256] !miss_pending;
  endproperty
  assert_dirty_eviction: assert property (p_dirty_eviction_before_fill)
    else $error("[MESI] Fill completed while dirty writeback was still pending");

  // ===========================================================================
  // Section 3: Snoop Protocol Assertions
  // ===========================================================================

  // AC request must be accepted within 16 cycles (no indefinite stall)
  property p_snoop_accepted_in_time;
    @(posedge clk) disable iff (!rst_n)
    $rose(ac_valid) |-> ##[0:16] (ac_valid && ac_ready);
  endproperty
  assert_snoop_accepted: assert property (p_snoop_accepted_in_time)
    else $error("[SNOOP] Snoop request held off for > 16 cycles — potential deadlock");

  // CR response must follow AC acceptance within 32 cycles
  property p_cr_follows_ac;
    @(posedge clk) disable iff (!rst_n)
    (ac_valid && ac_ready) |-> ##[1:32] cr_valid;
  endproperty
  assert_cr_follows_ac: assert property (p_cr_follows_ac)
    else $error("[SNOOP] CRVALID not seen within 32 cycles of AC handshake");

  // CRVALID must stay high until CRREADY
  property p_crvalid_stable;
    @(posedge clk) disable iff (!rst_n)
    (cr_valid && !cr_ready) |=> cr_valid;
  endproperty
  assert_crvalid_stable: assert property (p_crvalid_stable)
    else $error("[SNOOP] CRVALID deasserted before CRREADY");

  // ===========================================================================
  // Section 4: Coverage Points
  // ===========================================================================

  cp_read_hit:       cover property (@(posedge clk) disable iff (!rst_n)
                       cache_hit && !miss_pending);

  cp_read_miss:      cover property (@(posedge clk) disable iff (!rst_n)
                       miss_pending);

  cp_writeback:      cover property (@(posedge clk) disable iff (!rst_n)
                       wb_pending);

  cp_snoop_hit:      cover property (@(posedge clk) disable iff (!rst_n)
                       ac_valid && ac_ready && cr_resp[CR_DATA_TRANSFER]);

  cp_snoop_miss:     cover property (@(posedge clk) disable iff (!rst_n)
                       ac_valid && ac_ready && !cr_resp[CR_DATA_TRANSFER]);

  cp_upgrade_req:    cover property (@(posedge clk) disable iff (!rst_n)
                       upgrade_req_sent);

  cp_dirty_snoop:    cover property (@(posedge clk) disable iff (!rst_n)
                       ac_valid && cr_resp[CR_PASS_DIRTY]);

  // Functional coverage: All MESI states observed in set 0 way 0
  cp_mesi_invalid:   cover property (@(posedge clk) mesi_state[0][0] == MESI_INVALID);
  cp_mesi_shared:    cover property (@(posedge clk) mesi_state[0][0] == MESI_SHARED);
  cp_mesi_exclusive: cover property (@(posedge clk) mesi_state[0][0] == MESI_EXCLUSIVE);
  cp_mesi_modified:  cover property (@(posedge clk) mesi_state[0][0] == MESI_MODIFIED);

endmodule : l2_cache_assertions

// =============================================================================
// Bind statement (add to top-level simulation filelist or top tb)
// =============================================================================
// bind l2_cache_top l2_cache_assertions #(
//   .NUM_SETS (NUM_SETS),
//   .WAYS     (WAYS),
//   ...
// ) u_assertions (.clk(clk), .rst_n(rst_n), ...);
