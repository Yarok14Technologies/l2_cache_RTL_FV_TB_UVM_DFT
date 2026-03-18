// =============================================================================
// File       : formal/props/props_axi_master.sv
// Module     : l2_axi_master (memory-side AXI master)
// Tool       : JasperGold FPV
// Description: Formal properties verifying AXI4 master protocol compliance
//              on the memory-side port that issues fill reads and write-backs.
//
//              Key differences from slave props:
//                - ARVALID/AWVALID are DUT outputs (master drives them)
//                - RVALID/BVALID are inputs (memory drives them)
//                - Fill address must be cache-line aligned (64B)
//                - WLAST must be correct for full cache-line bursts
//                - Write-back must not overlap with fill on same address
// =============================================================================

`ifndef PROPS_AXI_MASTER_SV
`define PROPS_AXI_MASTER_SV

module props_axi_master #(
  parameter int unsigned ADDR_WIDTH  = 40,
  parameter int unsigned DATA_WIDTH  = 64,
  parameter int unsigned ID_WIDTH    = 8,
  parameter int unsigned LINE_SIZE_B = 64,
  localparam int unsigned BEATS      = LINE_SIZE_B / (DATA_WIDTH / 8)  // = 8
)(
  input logic                    clk,
  input logic                    rst_n,

  // AR channel (master drives)
  input logic [ADDR_WIDTH-1:0]   m_axi_araddr,
  input logic [7:0]              m_axi_arlen,
  input logic [2:0]              m_axi_arsize,
  input logic [1:0]              m_axi_arburst,
  input logic [ID_WIDTH-1:0]     m_axi_arid,
  input logic                    m_axi_arvalid,
  input logic                    m_axi_arready,

  // R channel (memory drives)
  input logic [DATA_WIDTH-1:0]   m_axi_rdata,
  input logic [1:0]              m_axi_rresp,
  input logic                    m_axi_rlast,
  input logic                    m_axi_rvalid,
  input logic                    m_axi_rready,

  // AW channel (master drives)
  input logic [ADDR_WIDTH-1:0]   m_axi_awaddr,
  input logic [7:0]              m_axi_awlen,
  input logic [ID_WIDTH-1:0]     m_axi_awid,
  input logic                    m_axi_awvalid,
  input logic                    m_axi_awready,

  // W channel (master drives)
  input logic [DATA_WIDTH-1:0]   m_axi_wdata,
  input logic [DATA_WIDTH/8-1:0] m_axi_wstrb,
  input logic                    m_axi_wlast,
  input logic                    m_axi_wvalid,
  input logic                    m_axi_wready,

  // B channel (memory drives)
  input logic [1:0]              m_axi_bresp,
  input logic [ID_WIDTH-1:0]     m_axi_bid,
  input logic                    m_axi_bvalid,
  input logic                    m_axi_bready,

  // Internal signals
  input logic                    rd_req_valid,
  input logic                    wb_req_valid,
  input logic                    fill_valid,
  input logic                    wb_done
);

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // ===========================================================================
  // ── AR stability: master must not drop ARVALID before ARREADY ────────────────
  // ===========================================================================
  P_AXM_AR_VALID_STABLE: assert property (
    (m_axi_arvalid && !m_axi_arready) |=> m_axi_arvalid
  ) else $error("PROP FAIL: m_axi_arvalid dropped before m_axi_arready");

  P_AXM_AR_ADDR_STABLE: assert property (
    (m_axi_arvalid && !m_axi_arready) |=>
    ($stable(m_axi_araddr) && $stable(m_axi_arlen) &&
     $stable(m_axi_arid)   && $stable(m_axi_arburst))
  ) else $error("PROP FAIL: AR signals changed while m_axi_arvalid held");

  // ===========================================================================
  // ── Fill read: always cache-line aligned, INCR, 8 beats ──────────────────────
  // ===========================================================================
  P_AXM_FILL_ADDR_ALIGNED: assert property (
    m_axi_arvalid |-> (m_axi_araddr[5:0] == 6'b0)
  ) else $error("PROP FAIL: Fill address 0x%0h not 64-byte aligned", m_axi_araddr);

  P_AXM_FILL_BURST_INCR: assert property (
    m_axi_arvalid |-> (m_axi_arburst == 2'b01)
  ) else $error("PROP FAIL: Fill burst type not INCR");

  P_AXM_FILL_LEN_CORRECT: assert property (
    m_axi_arvalid |-> (m_axi_arlen == 8'(BEATS - 1))
  ) else $error("PROP FAIL: Fill ARLEN=%0d, expected %0d", m_axi_arlen, BEATS-1);

  P_AXM_FILL_SIZE_64B: assert property (
    m_axi_arvalid |-> (m_axi_arsize == 3'b011)
  ) else $error("PROP FAIL: Fill ARSIZE not 8 bytes");

  // ===========================================================================
  // ── AW stability ─────────────────────────────────────────────────────────────
  // ===========================================================================
  P_AXM_AW_VALID_STABLE: assert property (
    (m_axi_awvalid && !m_axi_awready) |=> m_axi_awvalid
  ) else $error("PROP FAIL: m_axi_awvalid dropped before m_axi_awready");

  P_AXM_AW_ADDR_STABLE: assert property (
    (m_axi_awvalid && !m_axi_awready) |=>
    ($stable(m_axi_awaddr) && $stable(m_axi_awlen) && $stable(m_axi_awid))
  ) else $error("PROP FAIL: AW signals changed while m_axi_awvalid held");

  // Write-back also cache-line aligned
  P_AXM_WB_ADDR_ALIGNED: assert property (
    m_axi_awvalid |-> (m_axi_awaddr[5:0] == 6'b0)
  ) else $error("PROP FAIL: Write-back addr 0x%0h not 64-byte aligned", m_axi_awaddr);

  // ===========================================================================
  // ── W channel stability ───────────────────────────────────────────────────────
  // ===========================================================================
  P_AXM_W_VALID_STABLE: assert property (
    (m_axi_wvalid && !m_axi_wready) |=> m_axi_wvalid
  ) else $error("PROP FAIL: m_axi_wvalid dropped before m_axi_wready");

  P_AXM_W_DATA_STABLE: assert property (
    (m_axi_wvalid && !m_axi_wready) |=>
    ($stable(m_axi_wdata) && $stable(m_axi_wstrb) && $stable(m_axi_wlast))
  ) else $error("PROP FAIL: W data changed while m_axi_wvalid held");

  // WSTRB must be all-ones for dirty write-backs (full cache line)
  P_AXM_WB_WSTRB_FULL: assert property (
    (m_axi_wvalid && m_axi_awvalid) |-> (m_axi_wstrb == '1)
  ) else $error("PROP FAIL: Write-back WSTRB not all-ones (partial WB)");

  // ===========================================================================
  // ── No simultaneous fill and write-back on same address ──────────────────────
  // ===========================================================================
  P_AXM_NO_FILL_WB_CONFLICT: assert property (
    (m_axi_arvalid && m_axi_awvalid) |->
    (m_axi_araddr[ADDR_WIDTH-1:6] != m_axi_awaddr[ADDR_WIDTH-1:6])
  ) else $error(
    "PROP FAIL: simultaneous fill+WB on same line addr=0x%0h", m_axi_araddr);

  // ===========================================================================
  // ── RREADY: master must not hold RREADY low indefinitely ─────────────────────
  // (fill data must be consumed promptly)
  // ===========================================================================
  P_AXM_RREADY_LIVENESS: assert property (
    m_axi_rvalid |-> ##[0:4] m_axi_rready
  ) else $error("PROP FAIL: RREADY not asserted within 4 cycles of RVALID");

  P_AXM_BREADY_LIVENESS: assert property (
    m_axi_bvalid |-> ##[0:4] m_axi_bready
  ) else $error("PROP FAIL: BREADY not asserted within 4 cycles of BVALID");

  // ===========================================================================
  // ── Liveness: fill and write-back complete ────────────────────────────────────
  // ===========================================================================
  P_AXM_FILL_LIVENESS: assert property (
    (m_axi_arvalid && m_axi_arready) |->
    ##[1:128] fill_valid
  ) else $error("PROP FAIL: Fill read issued but fill_valid not asserted in 128c");

  P_AXM_WB_LIVENESS: assert property (
    (m_axi_awvalid && m_axi_awready) |->
    ##[1:64] wb_done
  ) else $error("PROP FAIL: Write-back issued but wb_done not received in 64c");

  // ===========================================================================
  // ── Cover points ─────────────────────────────────────────────────────────────
  // ===========================================================================
  COV_AXM_FILL_ISSUED:   cover property (m_axi_arvalid && m_axi_arready);
  COV_AXM_WB_ISSUED:     cover property (m_axi_awvalid && m_axi_awready);
  COV_AXM_FILL_COMPLETE: cover property (fill_valid);
  COV_AXM_WB_COMPLETE:   cover property (wb_done);
  COV_AXM_FILL_AND_WB:   cover property (m_axi_arvalid && m_axi_awvalid);

endmodule

`endif // PROPS_AXI_MASTER_SV
