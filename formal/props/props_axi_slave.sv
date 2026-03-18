// =============================================================================
// File       : props_axi_slave.sv
// Module     : l2_request_pipeline (AXI slave interface)
// Tool       : JasperGold FPV / Questa Formal
// Description: Formal SVA properties verifying full AXI4 protocol compliance
//              on the CPU-side slave port of the L2 cache.
//
//              Property categories:
//                P_AXS_*  — AXI Slave channel handshake rules
//                P_AXO_*  — AXI ordering / flow rules
//                P_AXD_*  — AXI data integrity rules
//                COV_AX_* — Cover points for reachability
//
// Bound to: l2_request_pipeline via bind in formal/scripts/run_axi_slave.tcl
// =============================================================================

`ifndef PROPS_AXI_SLAVE_SV
`define PROPS_AXI_SLAVE_SV

module props_axi_slave #(
  parameter int unsigned ADDR_WIDTH = 40,
  parameter int unsigned DATA_WIDTH = 64,
  parameter int unsigned ID_WIDTH   = 8
)(
  input logic                    clk,
  input logic                    rst_n,

  // AR channel
  input logic [ADDR_WIDTH-1:0]   s_axi_araddr,
  input logic [7:0]              s_axi_arlen,
  input logic [2:0]              s_axi_arsize,
  input logic [1:0]              s_axi_arburst,
  input logic [ID_WIDTH-1:0]     s_axi_arid,
  input logic                    s_axi_arvalid,
  input logic                    s_axi_arready,

  // R channel
  input logic [DATA_WIDTH-1:0]   s_axi_rdata,
  input logic [1:0]              s_axi_rresp,
  input logic                    s_axi_rlast,
  input logic [ID_WIDTH-1:0]     s_axi_rid,
  input logic                    s_axi_rvalid,
  input logic                    s_axi_rready,

  // AW channel
  input logic [ADDR_WIDTH-1:0]   s_axi_awaddr,
  input logic [7:0]              s_axi_awlen,
  input logic [ID_WIDTH-1:0]     s_axi_awid,
  input logic                    s_axi_awvalid,
  input logic                    s_axi_awready,

  // W channel
  input logic [DATA_WIDTH-1:0]   s_axi_wdata,
  input logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
  input logic                    s_axi_wlast,
  input logic                    s_axi_wvalid,
  input logic                    s_axi_wready,

  // B channel
  input logic [1:0]              s_axi_bresp,
  input logic [ID_WIDTH-1:0]     s_axi_bid,
  input logic                    s_axi_bvalid,
  input logic                    s_axi_bready,

  // Internal signals exposed for formal
  input logic                    mshr_full,
  input logic                    cache_hit,
  input logic                    cache_miss
);

  // ── Default clock / disable ──────────────────────────────────────────────
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // ===========================================================================
  // ── AR channel: VALID stability ─────────────────────────────────────────────
  // AXI4 spec §A3.2.1: Master must not deassert VALID before READY
  // ===========================================================================
  P_AXS_AR_VALID_STABLE: assert property (
    (s_axi_arvalid && !s_axi_arready) |=> s_axi_arvalid
  ) else $error("PROP FAIL: ARVALID deasserted before ARREADY");

  // AR address must be stable while ARVALID is asserted
  P_AXS_AR_ADDR_STABLE: assert property (
    (s_axi_arvalid && !s_axi_arready) |=>
    ($stable(s_axi_araddr) && $stable(s_axi_arlen) &&
     $stable(s_axi_arid)   && $stable(s_axi_arburst))
  ) else $error("PROP FAIL: AR channel signals changed while ARVALID held");

  // ===========================================================================
  // ── AW channel: VALID stability ─────────────────────────────────────────────
  // ===========================================================================
  P_AXS_AW_VALID_STABLE: assert property (
    (s_axi_awvalid && !s_axi_awready) |=> s_axi_awvalid
  ) else $error("PROP FAIL: AWVALID deasserted before AWREADY");

  P_AXS_AW_ADDR_STABLE: assert property (
    (s_axi_awvalid && !s_axi_awready) |=>
    ($stable(s_axi_awaddr) && $stable(s_axi_awlen) && $stable(s_axi_awid))
  ) else $error("PROP FAIL: AW channel signals changed while AWVALID held");

  // ===========================================================================
  // ── W channel: VALID stability ──────────────────────────────────────────────
  // ===========================================================================
  P_AXS_W_VALID_STABLE: assert property (
    (s_axi_wvalid && !s_axi_wready) |=> s_axi_wvalid
  ) else $error("PROP FAIL: WVALID deasserted before WREADY");

  P_AXS_W_DATA_STABLE: assert property (
    (s_axi_wvalid && !s_axi_wready) |=>
    ($stable(s_axi_wdata) && $stable(s_axi_wstrb) && $stable(s_axi_wlast))
  ) else $error("PROP FAIL: W channel signals changed while WVALID held");

  // ===========================================================================
  // ── R channel: VALID stability (DUT output) ──────────────────────────────────
  // ===========================================================================
  P_AXS_R_VALID_STABLE: assert property (
    (s_axi_rvalid && !s_axi_rready) |=> s_axi_rvalid
  ) else $error("PROP FAIL: RVALID deasserted before RREADY");

  P_AXS_R_DATA_STABLE: assert property (
    (s_axi_rvalid && !s_axi_rready) |=>
    ($stable(s_axi_rdata) && $stable(s_axi_rresp) &&
     $stable(s_axi_rlast) && $stable(s_axi_rid))
  ) else $error("PROP FAIL: R channel data changed while RVALID held");

  // ===========================================================================
  // ── B channel: VALID stability (DUT output) ──────────────────────────────────
  // ===========================================================================
  P_AXS_B_VALID_STABLE: assert property (
    (s_axi_bvalid && !s_axi_bready) |=> s_axi_bvalid
  ) else $error("PROP FAIL: BVALID deasserted before BREADY");

  P_AXS_B_RESP_STABLE: assert property (
    (s_axi_bvalid && !s_axi_bready) |=>
    ($stable(s_axi_bresp) && $stable(s_axi_bid))
  ) else $error("PROP FAIL: B channel signals changed while BVALID held");

  // ===========================================================================
  // ── Ordering: RVALID only after AR accepted ──────────────────────────────────
  // There must have been a prior AR handshake before RVALID can appear
  // ===========================================================================
  P_AXO_RVALID_AFTER_AR: assert property (
    s_axi_rvalid |->
    $past(s_axi_arvalid && s_axi_arready, 1, 1'b1, @(posedge clk))
  ) else $error("PROP FAIL: RVALID appeared without prior AR handshake");

  // BVALID only after AW accepted
  P_AXO_BVALID_AFTER_AW: assert property (
    s_axi_bvalid |->
    $past(s_axi_awvalid && s_axi_awready, 1, 1'b1, @(posedge clk))
  ) else $error("PROP FAIL: BVALID appeared without prior AW handshake");

  // ===========================================================================
  // ── RLAST correctness: must assert on beat (len+1) and only then ─────────────
  // ===========================================================================
  // Tracked burst beat counter (for formal — counts R beats on this transaction)
  logic [7:0] r_beat_cnt;
  logic [7:0] r_burst_len_r;  // registered ARLEN at time of AR handshake

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_beat_cnt    <= '0;
      r_burst_len_r <= '0;
    end else begin
      if (s_axi_arvalid && s_axi_arready)
        r_burst_len_r <= s_axi_arlen;
      if (s_axi_rvalid && s_axi_rready) begin
        if (s_axi_rlast) r_beat_cnt <= '0;
        else             r_beat_cnt <= r_beat_cnt + 1;
      end
    end
  end

  P_AXD_RLAST_ON_LAST_BEAT: assert property (
    (s_axi_rvalid && s_axi_rready && s_axi_rlast) |->
    (r_beat_cnt == r_burst_len_r)
  ) else $error("PROP FAIL: RLAST asserted at beat %0d, expected %0d",
                r_beat_cnt, r_burst_len_r);

  P_AXD_NO_RLAST_BEFORE_LAST: assert property (
    (s_axi_rvalid && s_axi_rready && !s_axi_rlast) |->
    (r_beat_cnt < r_burst_len_r)
  ) else $error("PROP FAIL: RLAST not asserted on final beat");

  // ===========================================================================
  // ── Response code validity ───────────────────────────────────────────────────
  // Valid RRESP codes: 00 (OKAY), 01 (EXOKAY), 10 (SLVERR)
  // 11 (DECERR) should not be generated by a properly addressed slave
  // ===========================================================================
  P_AXD_RRESP_VALID: assert property (
    (s_axi_rvalid && s_axi_rready) |->
    (s_axi_rresp inside {2'b00, 2'b01, 2'b10})
  ) else $error("PROP FAIL: illegal RRESP=0b%02b", s_axi_rresp);

  P_AXD_BRESP_VALID: assert property (
    (s_axi_bvalid && s_axi_bready) |->
    (s_axi_bresp inside {2'b00, 2'b01, 2'b10})
  ) else $error("PROP FAIL: illegal BRESP=0b%02b", s_axi_bresp);

  // ===========================================================================
  // ── Back-pressure: READY must not be asserted when MSHR is full ──────────────
  // ===========================================================================
  P_AXS_NO_ARREADY_WHEN_MSHR_FULL: assert property (
    mshr_full |-> !s_axi_arready
  ) else $error("PROP FAIL: ARREADY asserted while MSHR full");

  // ===========================================================================
  // ── Liveness: every request eventually gets a response ───────────────────────
  // Bounded: response within 512 cycles (covers fill latency)
  // ===========================================================================
  P_AXO_READ_LIVENESS: assert property (
    (s_axi_arvalid && s_axi_arready) |->
    ##[1:512] (s_axi_rvalid && s_axi_rready && s_axi_rlast)
  ) else $error("PROP FAIL: Read request with no response within 512 cycles");

  P_AXO_WRITE_LIVENESS: assert property (
    (s_axi_awvalid && s_axi_awready) |->
    ##[1:512] (s_axi_bvalid && s_axi_bready)
  ) else $error("PROP FAIL: Write request with no B response within 512 cycles");

  // ===========================================================================
  // ── Hit / miss mutual exclusion ──────────────────────────────────────────────
  // ===========================================================================
  P_AXD_HIT_MISS_EXCL: assert property (
    !(cache_hit && cache_miss)
  ) else $error("PROP FAIL: cache_hit and cache_miss both asserted");

  // ===========================================================================
  // ── Cover points ─────────────────────────────────────────────────────────────
  // ===========================================================================
  COV_AX_READ_HIT:  cover property ((s_axi_rvalid && s_axi_rready) ##0 cache_hit);
  COV_AX_READ_MISS: cover property ((s_axi_rvalid && s_axi_rready) ##0 cache_miss);
  COV_AX_WRITE_HIT: cover property ((s_axi_bvalid && s_axi_bready) ##0 cache_hit);
  COV_AX_BURST_8:   cover property (s_axi_arvalid && (s_axi_arlen == 8'd7));
  COV_AX_SLVERR:    cover property ((s_axi_rvalid && s_axi_rready) &&
                                     (s_axi_rresp == 2'b10));
  COV_AX_MSHR_BP:   cover property (mshr_full && s_axi_arvalid);

endmodule

`endif // PROPS_AXI_SLAVE_SV
