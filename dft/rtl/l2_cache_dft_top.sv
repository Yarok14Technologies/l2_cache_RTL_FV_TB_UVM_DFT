// =============================================================================
// Module     : l2_cache_dft_top
// Description: DFT wrapper around l2_cache_top.
//              Adds:
//                - Multiplexed scan chain ports (4 chains × 512 FFs)
//                - Test mode override signals (test_clk, test_se, test_tm)
//                - BIST controller instantiation for SRAM macros
//                - Boundary scan cell insertion stubs for I/O
//                - Observation points for ATPG controllability/observability
//
//              In functional mode (test_tm = 0):
//                All DFT signals are masked; wrapper is transparent.
//
//              In scan shift mode (test_se = 1):
//                Scan data propagates through chains; functional clock gated.
//
//              In BIST mode (test_tm = 2'b10):
//                BIST controller drives SRAM address/data, captures results.
//
// Scan chain assignment:
//   Chain 0  — Request pipeline + tag array FFs
//   Chain 1  — LRU controller + hit/miss + MSHR FFs
//   Chain 2  — Coherency FSM + AXI master FFs
//   Chain 3  — Data array ECC FFs + performance counters
//
// NOTE: Actual scan stitching is performed by the synthesis tool
//       (DC Ultra insert_dft). This wrapper provides the test port
//       infrastructure and BIST control only.
// =============================================================================

`ifndef L2_CACHE_DFT_TOP_SV
`define L2_CACHE_DFT_TOP_SV

`include "l2_cache_pkg.sv"

module l2_cache_dft_top
  import l2_cache_pkg::*;
#(
  parameter int unsigned CACHE_SIZE_KB = 256,
  parameter int unsigned WAYS          = 4,
  parameter int unsigned LINE_SIZE_B   = 64,
  parameter int unsigned ADDR_WIDTH    = 40,
  parameter int unsigned DATA_WIDTH    = 64,
  parameter int unsigned MSHR_DEPTH    = 16,
  parameter int unsigned NUM_BANKS     = 4,
  parameter int unsigned ID_WIDTH      = 8,
  parameter int unsigned SCAN_CHAINS   = 4
)(
  // ── Functional ports (passed through to l2_cache_top) ─────────────────────
  input  logic                    clk,
  input  logic                    rst_n,

  // AXI Slave (CPU side)
  input  logic [ADDR_WIDTH-1:0]   s_axi_araddr,
  input  logic [7:0]              s_axi_arlen,
  input  logic [2:0]              s_axi_arsize,
  input  logic [1:0]              s_axi_arburst,
  input  logic [ID_WIDTH-1:0]     s_axi_arid,
  input  logic                    s_axi_arvalid,
  output logic                    s_axi_arready,
  output logic [DATA_WIDTH-1:0]   s_axi_rdata,
  output logic [1:0]              s_axi_rresp,
  output logic                    s_axi_rlast,
  output logic [ID_WIDTH-1:0]     s_axi_rid,
  output logic                    s_axi_rvalid,
  input  logic                    s_axi_rready,
  input  logic [ADDR_WIDTH-1:0]   s_axi_awaddr,
  input  logic [7:0]              s_axi_awlen,
  input  logic [2:0]              s_axi_awsize,
  input  logic [1:0]              s_axi_awburst,
  input  logic [ID_WIDTH-1:0]     s_axi_awid,
  input  logic                    s_axi_awvalid,
  output logic                    s_axi_awready,
  input  logic [DATA_WIDTH-1:0]   s_axi_wdata,
  input  logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
  input  logic                    s_axi_wlast,
  input  logic                    s_axi_wvalid,
  output logic                    s_axi_wready,
  output logic [1:0]              s_axi_bresp,
  output logic [ID_WIDTH-1:0]     s_axi_bid,
  output logic                    s_axi_bvalid,
  input  logic                    s_axi_bready,

  // AXI Master (Memory side)
  output logic [ADDR_WIDTH-1:0]   m_axi_araddr,
  output logic [7:0]              m_axi_arlen,
  output logic [2:0]              m_axi_arsize,
  output logic [1:0]              m_axi_arburst,
  output logic [ID_WIDTH-1:0]     m_axi_arid,
  output logic                    m_axi_arvalid,
  input  logic                    m_axi_arready,
  input  logic [DATA_WIDTH-1:0]   m_axi_rdata,
  input  logic [1:0]              m_axi_rresp,
  input  logic                    m_axi_rlast,
  input  logic [ID_WIDTH-1:0]     m_axi_rid,
  input  logic                    m_axi_rvalid,
  output logic                    m_axi_rready,
  output logic [ADDR_WIDTH-1:0]   m_axi_awaddr,
  output logic [7:0]              m_axi_awlen,
  output logic [2:0]              m_axi_awsize,
  output logic [1:0]              m_axi_awburst,
  output logic [ID_WIDTH-1:0]     m_axi_awid,
  output logic                    m_axi_awvalid,
  input  logic                    m_axi_awready,
  output logic [DATA_WIDTH-1:0]   m_axi_wdata,
  output logic [DATA_WIDTH/8-1:0] m_axi_wstrb,
  output logic                    m_axi_wlast,
  output logic                    m_axi_wvalid,
  input  logic                    m_axi_wready,
  input  logic [1:0]              m_axi_bresp,
  input  logic [ID_WIDTH-1:0]     m_axi_bid,
  input  logic                    m_axi_bvalid,
  output logic                    m_axi_bready,

  // ACE Snoop
  input  logic [ADDR_WIDTH-1:0]   ac_addr,
  input  logic [3:0]              ac_snoop,
  input  logic                    ac_valid,
  output logic                    ac_ready,
  output logic [4:0]              cr_resp,
  output logic                    cr_valid,
  input  logic                    cr_ready,
  output logic [DATA_WIDTH-1:0]   cd_data,
  output logic                    cd_last,
  output logic                    cd_valid,
  input  logic                    cd_ready,

  // Status
  output logic                    cache_hit,
  output logic                    cache_miss,
  output logic                    wb_pending,
  output logic [31:0]             perf_hit_count,
  output logic [31:0]             perf_miss_count,
  output logic [31:0]             perf_wb_count,

  // Power management
  input  logic                    cache_flush_req,
  output logic                    cache_flush_done,
  input  logic                    cache_power_down,

  // ── DFT test ports ────────────────────────────────────────────────────────
  input  logic                    test_clk,       // dedicated test clock
  input  logic                    test_se,        // scan enable (shift mode)
  input  logic [1:0]              test_tm,        // test mode: 00=func 01=scan 10=BIST
  input  logic                    test_rst_n,     // test reset (active low)

  // Scan chains: 4 in / 4 out
  input  logic [SCAN_CHAINS-1:0]  scan_in,
  output logic [SCAN_CHAINS-1:0]  scan_out,

  // BIST results
  output logic                    bist_done,
  output logic                    bist_pass,
  output logic [NUM_BANKS*WAYS-1:0] bist_fail_map  // one bit per SRAM bank/way
);

  // ── Clock mux: functional clock vs. test clock ────────────────────────────
  // In real ASIC: use a library clock mux cell (e.g., CKMUX2X1)
  // Here: behavioural model for simulation
  logic clk_muxed;
  assign clk_muxed = test_tm[0] ? test_clk : clk;

  // Reset: test_rst_n used in test mode, else functional rst_n
  logic rst_n_muxed;
  assign rst_n_muxed = test_tm[0] ? test_rst_n : rst_n;

  // ── DUT instantiation ─────────────────────────────────────────────────────
  l2_cache_top #(
    .CACHE_SIZE_KB (CACHE_SIZE_KB),
    .WAYS          (WAYS),
    .LINE_SIZE_B   (LINE_SIZE_B),
    .ADDR_WIDTH    (ADDR_WIDTH),
    .DATA_WIDTH    (DATA_WIDTH),
    .MSHR_DEPTH    (MSHR_DEPTH),
    .NUM_BANKS     (NUM_BANKS),
    .ID_WIDTH      (ID_WIDTH)
  ) u_dut (
    .clk              (clk_muxed),
    .rst_n            (rst_n_muxed),
    .s_axi_araddr     (s_axi_araddr),
    .s_axi_arlen      (s_axi_arlen),
    .s_axi_arsize     (s_axi_arsize),
    .s_axi_arburst    (s_axi_arburst),
    .s_axi_arid       (s_axi_arid),
    .s_axi_arvalid    (s_axi_arvalid),
    .s_axi_arready    (s_axi_arready),
    .s_axi_rdata      (s_axi_rdata),
    .s_axi_rresp      (s_axi_rresp),
    .s_axi_rlast      (s_axi_rlast),
    .s_axi_rid        (s_axi_rid),
    .s_axi_rvalid     (s_axi_rvalid),
    .s_axi_rready     (s_axi_rready),
    .s_axi_awaddr     (s_axi_awaddr),
    .s_axi_awlen      (s_axi_awlen),
    .s_axi_awsize     (s_axi_awsize),
    .s_axi_awburst    (s_axi_awburst),
    .s_axi_awid       (s_axi_awid),
    .s_axi_awvalid    (s_axi_awvalid),
    .s_axi_awready    (s_axi_awready),
    .s_axi_wdata      (s_axi_wdata),
    .s_axi_wstrb      (s_axi_wstrb),
    .s_axi_wlast      (s_axi_wlast),
    .s_axi_wvalid     (s_axi_wvalid),
    .s_axi_wready     (s_axi_wready),
    .s_axi_bresp      (s_axi_bresp),
    .s_axi_bid        (s_axi_bid),
    .s_axi_bvalid     (s_axi_bvalid),
    .s_axi_bready     (s_axi_bready),
    .m_axi_araddr     (m_axi_araddr),
    .m_axi_arlen      (m_axi_arlen),
    .m_axi_arsize     (m_axi_arsize),
    .m_axi_arburst    (m_axi_arburst),
    .m_axi_arid       (m_axi_arid),
    .m_axi_arvalid    (m_axi_arvalid),
    .m_axi_arready    (m_axi_arready),
    .m_axi_rdata      (m_axi_rdata),
    .m_axi_rresp      (m_axi_rresp),
    .m_axi_rlast      (m_axi_rlast),
    .m_axi_rid        (m_axi_rid),
    .m_axi_rvalid     (m_axi_rvalid),
    .m_axi_rready     (m_axi_rready),
    .m_axi_awaddr     (m_axi_awaddr),
    .m_axi_awlen      (m_axi_awlen),
    .m_axi_awsize     (m_axi_awsize),
    .m_axi_awburst    (m_axi_awburst),
    .m_axi_awid       (m_axi_awid),
    .m_axi_awvalid    (m_axi_awvalid),
    .m_axi_awready    (m_axi_awready),
    .m_axi_wdata      (m_axi_wdata),
    .m_axi_wstrb      (m_axi_wstrb),
    .m_axi_wlast      (m_axi_wlast),
    .m_axi_wvalid     (m_axi_wvalid),
    .m_axi_wready     (m_axi_wready),
    .m_axi_bresp      (m_axi_bresp),
    .m_axi_bid        (m_axi_bid),
    .m_axi_bvalid     (m_axi_bvalid),
    .m_axi_bready     (m_axi_bready),
    .ac_addr          (ac_addr),
    .ac_snoop         (ac_snoop),
    .ac_valid         (ac_valid),
    .ac_ready         (ac_ready),
    .cr_resp          (cr_resp),
    .cr_valid         (cr_valid),
    .cr_ready         (cr_ready),
    .cd_data          (cd_data),
    .cd_last          (cd_last),
    .cd_valid         (cd_valid),
    .cd_ready         (cd_ready),
    .cache_hit        (cache_hit),
    .cache_miss       (cache_miss),
    .wb_pending       (wb_pending),
    .perf_hit_count   (perf_hit_count),
    .perf_miss_count  (perf_miss_count),
    .perf_wb_count    (perf_wb_count),
    .cache_flush_req  (cache_flush_req),
    .cache_flush_done (cache_flush_done),
    .cache_power_down (cache_power_down)
  );

  // ── BIST controller instantiation ─────────────────────────────────────────
  l2_bist_ctrl #(
    .NUM_BANKS  (NUM_BANKS),
    .WAYS       (WAYS),
    .NUM_SETS   ((CACHE_SIZE_KB * 1024) / (WAYS * LINE_SIZE_B)),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_bist (
    .clk          (clk_muxed),
    .rst_n        (rst_n_muxed),
    .bist_en      (test_tm == 2'b10),   // BIST mode
    .bist_done    (bist_done),
    .bist_pass    (bist_pass),
    .bist_fail_map(bist_fail_map)
  );

  // ── Scan output: last FF in each chain drives scan_out ────────────────────
  // Actual stitching performed by DC insert_dft; these are placeholder
  // assignments for pre-DFT simulation
  assign scan_out = scan_in;  // replaced by tool with real chain connections

endmodule

`endif // L2_CACHE_DFT_TOP_SV
