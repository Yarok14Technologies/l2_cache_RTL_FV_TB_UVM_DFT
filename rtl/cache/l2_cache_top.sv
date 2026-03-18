// =============================================================================
// Module     : l2_cache_top
// Project    : L2 Cache Controller — Industrial Grade RTL
// Author     : Bibin N Biji
// Description: Top-level wrapper for the parameterized L2 cache controller.
//              Integrates tag array, data array, LRU controller, coherency FSM,
//              and AXI4 / AXI-ACE master/slave interfaces.
//
// Parameters:
//   CACHE_SIZE_KB  - Total cache size in KB (default: 256)
//   WAYS           - Number of cache ways (default: 4)
//   LINE_SIZE_B    - Cache line size in bytes (default: 64)
//   ADDR_WIDTH     - Physical address width (default: 40)
//   DATA_WIDTH     - Data bus width in bits (default: 64)
//   MSHR_DEPTH     - Number of MSHR entries (default: 16)
//   NUM_BANKS      - Number of data SRAM banks (default: 4)
//
// Coherency : MESI protocol, compatible with AXI-ACE snoop channels
// ECC       : SECDED per 64-bit word
// =============================================================================

`ifndef L2_CACHE_TOP_SV
`define L2_CACHE_TOP_SV

`include "l2_cache_pkg.sv"

module l2_cache_top
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

  // Derived — do not override
  localparam int unsigned NUM_SETS     = (CACHE_SIZE_KB * 1024) / (WAYS * LINE_SIZE_B),
  localparam int unsigned INDEX_BITS   = $clog2(NUM_SETS),
  localparam int unsigned OFFSET_BITS  = $clog2(LINE_SIZE_B),
  localparam int unsigned TAG_BITS     = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS,
  localparam int unsigned WORDS_PER_LINE = LINE_SIZE_B / (DATA_WIDTH / 8),
  localparam int unsigned ECC_BITS     = 8  // SECDED for 64-bit
)(
  // -------------------------------------------------------------------------
  // Global signals
  // -------------------------------------------------------------------------
  input  logic                    clk,
  input  logic                    rst_n,

  // -------------------------------------------------------------------------
  // CPU-side AXI4-Lite slave interface (L1 miss port)
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // Memory-side AXI4 master interface (to L3/DRAM)
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // AXI-ACE snoop channels (coherency)
  // -------------------------------------------------------------------------
  input  logic [ADDR_WIDTH-1:0]   ac_addr,
  input  logic [3:0]              ac_snoop,   // snoop type encoding
  input  logic                    ac_valid,
  output logic                    ac_ready,

  output logic [4:0]              cr_resp,    // CRRESP[4:0]
  output logic                    cr_valid,
  input  logic                    cr_ready,

  output logic [DATA_WIDTH-1:0]   cd_data,
  output logic                    cd_last,
  output logic                    cd_valid,
  input  logic                    cd_ready,

  // -------------------------------------------------------------------------
  // Status & performance counters
  // -------------------------------------------------------------------------
  output logic                    cache_hit,
  output logic                    cache_miss,
  output logic                    wb_pending,
  output logic [31:0]             perf_hit_count,
  output logic [31:0]             perf_miss_count,
  output logic [31:0]             perf_wb_count,

  // -------------------------------------------------------------------------
  // Power management
  // -------------------------------------------------------------------------
  input  logic                    cache_flush_req,
  output logic                    cache_flush_done,
  input  logic                    cache_power_down
);

  // =========================================================================
  // Internal signal declarations
  // =========================================================================

  // Pipeline stage 0→1: address decode
  logic [INDEX_BITS-1:0]     pipe_set_index;
  logic [TAG_BITS-1:0]       pipe_req_tag;
  logic [OFFSET_BITS-1:0]    pipe_offset;
  logic                      pipe_req_valid;
  logic                      pipe_req_is_write;
  logic [DATA_WIDTH-1:0]     pipe_req_wdata;
  logic [DATA_WIDTH/8-1:0]   pipe_req_wstrb;
  logic [ID_WIDTH-1:0]       pipe_req_id;

  // Tag array outputs
  logic [TAG_BITS-1:0]       tag_rd_data  [WAYS];
  logic                      tag_valid_bit[WAYS];
  logic                      tag_dirty_bit[WAYS];
  mesi_state_t               tag_mesi_state[WAYS];

  // Hit/miss resolution
  logic                      hit_any;
  logic [WAYS-1:0]           hit_way_oh;   // one-hot hit way
  logic [$clog2(WAYS)-1:0]   hit_way_bin;

  // LRU
  logic [WAYS-2:0]           lru_state    [NUM_SETS];
  logic [$clog2(WAYS)-1:0]   lru_victim_way;

  // MSHR
  mshr_entry_t               mshr         [MSHR_DEPTH];
  logic                      mshr_full;
  logic                      mshr_alloc_req;
  logic [$clog2(MSHR_DEPTH)-1:0] mshr_alloc_idx;

  // Fill buffer
  logic [DATA_WIDTH-1:0]     fill_data    [WORDS_PER_LINE];
  logic                      fill_valid;
  logic [ADDR_WIDTH-1:0]     fill_addr;

  // Write-back buffer
  logic [DATA_WIDTH-1:0]     wb_data      [WORDS_PER_LINE];
  logic [ADDR_WIDTH-1:0]     wb_addr;
  logic                      wb_valid;
  logic                      wb_done;

  // =========================================================================
  // Sub-module instantiations
  // =========================================================================

  l2_request_pipeline #(
    .ADDR_WIDTH   (ADDR_WIDTH),
    .DATA_WIDTH   (DATA_WIDTH),
    .INDEX_BITS   (INDEX_BITS),
    .TAG_BITS     (TAG_BITS),
    .OFFSET_BITS  (OFFSET_BITS),
    .ID_WIDTH     (ID_WIDTH)
  ) u_req_pipe (
    .clk             (clk),
    .rst_n           (rst_n),
    .s_axi_araddr    (s_axi_araddr),
    .s_axi_arlen     (s_axi_arlen),
    .s_axi_arsize    (s_axi_arsize),
    .s_axi_arburst   (s_axi_arburst),
    .s_axi_arid      (s_axi_arid),
    .s_axi_arvalid   (s_axi_arvalid),
    .s_axi_arready   (s_axi_arready),
    .s_axi_awaddr    (s_axi_awaddr),
    .s_axi_awid      (s_axi_awid),
    .s_axi_awvalid   (s_axi_awvalid),
    .s_axi_awready   (s_axi_awready),
    .s_axi_wdata     (s_axi_wdata),
    .s_axi_wstrb     (s_axi_wstrb),
    .s_axi_wlast     (s_axi_wlast),
    .s_axi_wvalid    (s_axi_wvalid),
    .s_axi_wready    (s_axi_wready),
    .pipe_set_index  (pipe_set_index),
    .pipe_req_tag    (pipe_req_tag),
    .pipe_offset     (pipe_offset),
    .pipe_req_valid  (pipe_req_valid),
    .pipe_req_is_write(pipe_req_is_write),
    .pipe_req_wdata  (pipe_req_wdata),
    .pipe_req_wstrb  (pipe_req_wstrb),
    .pipe_req_id     (pipe_req_id),
    .mshr_full       (mshr_full)
  );

  l2_tag_array #(
    .NUM_SETS   (NUM_SETS),
    .WAYS       (WAYS),
    .TAG_BITS   (TAG_BITS),
    .INDEX_BITS (INDEX_BITS)
  ) u_tag_array (
    .clk            (clk),
    .rst_n          (rst_n),
    .rd_index       (pipe_set_index),
    .rd_en          (pipe_req_valid),
    .tag_rd_data    (tag_rd_data),
    .valid_rd       (tag_valid_bit),
    .dirty_rd       (tag_dirty_bit),
    .mesi_rd        (tag_mesi_state),
    // write back from fill
    .wr_en          (fill_valid),
    .wr_index       (fill_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS]),
    .wr_way         (lru_victim_way),
    .wr_tag         (fill_addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS]),
    .wr_valid       (1'b1),
    .wr_dirty       (1'b0),
    .wr_mesi        (MESI_EXCLUSIVE),
    // flush
    .flush_req      (cache_flush_req),
    .flush_done     (cache_flush_done)
  );

  l2_hit_miss_detect #(
    .WAYS     (WAYS),
    .TAG_BITS (TAG_BITS)
  ) u_hit_miss (
    .req_tag      (pipe_req_tag),
    .tag_rd_data  (tag_rd_data),
    .valid_bit    (tag_valid_bit),
    .hit_any      (hit_any),
    .hit_way_oh   (hit_way_oh),
    .hit_way_bin  (hit_way_bin)
  );

  l2_lru_controller #(
    .NUM_SETS (NUM_SETS),
    .WAYS     (WAYS)
  ) u_lru (
    .clk          (clk),
    .rst_n        (rst_n),
    .access_valid (pipe_req_valid & hit_any),
    .access_set   (pipe_set_index),
    .access_way   (hit_way_bin),
    .lru_state    (lru_state),
    .victim_way   (lru_victim_way)
  );

  l2_data_array #(
    .NUM_SETS     (NUM_SETS),
    .WAYS         (WAYS),
    .DATA_WIDTH   (DATA_WIDTH),
    .WORDS_PER_LINE(WORDS_PER_LINE),
    .NUM_BANKS    (NUM_BANKS),
    .ECC_BITS     (ECC_BITS)
  ) u_data_array (
    .clk           (clk),
    .rst_n         (rst_n),
    .rd_index      (pipe_set_index),
    .rd_way        (hit_way_bin),
    .rd_word_sel   (pipe_offset[OFFSET_BITS-1:$clog2(DATA_WIDTH/8)]),
    .rd_en         (pipe_req_valid & hit_any & ~pipe_req_is_write),
    .rd_data       (s_axi_rdata),
    .wr_index      (pipe_set_index),
    .wr_way        (hit_way_bin),
    .wr_word_sel   (pipe_offset[OFFSET_BITS-1:$clog2(DATA_WIDTH/8)]),
    .wr_data       (pipe_req_wdata),
    .wr_strb       (pipe_req_wstrb),
    .wr_en         (pipe_req_valid & hit_any & pipe_req_is_write),
    // fill path
    .fill_en       (fill_valid),
    .fill_index    (fill_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS]),
    .fill_way      (lru_victim_way),
    .fill_data     (fill_data),
    // power
    .power_down    (cache_power_down)
  );

  l2_mshr #(
    .DEPTH      (MSHR_DEPTH),
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .ID_WIDTH   (ID_WIDTH)
  ) u_mshr (
    .clk           (clk),
    .rst_n         (rst_n),
    .alloc_req     (pipe_req_valid & ~hit_any),
    .alloc_addr    ({pipe_req_tag, pipe_set_index, pipe_offset}),
    .alloc_id      (pipe_req_id),
    .alloc_is_write(pipe_req_is_write),
    .alloc_idx     (mshr_alloc_idx),
    .full          (mshr_full),
    .fill_valid    (fill_valid),
    .fill_addr     (fill_addr),
    .fill_data     (fill_data),
    .wb_valid      (wb_valid),
    .wb_addr       (wb_addr),
    .wb_data       (wb_data),
    .wb_done       (wb_done)
  );

  l2_axi_master #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .ID_WIDTH   (ID_WIDTH),
    .LINE_SIZE_B(LINE_SIZE_B)
  ) u_axi_master (
    .clk           (clk),
    .rst_n         (rst_n),
    // fill read
    .rd_req_valid  (~hit_any & pipe_req_valid & ~mshr_full),
    .rd_req_addr   ({pipe_req_tag, pipe_set_index, {OFFSET_BITS{1'b0}}}),
    .rd_req_id     (pipe_req_id),
    .fill_valid    (fill_valid),
    .fill_addr     (fill_addr),
    .fill_data     (fill_data),
    // write-back
    .wb_valid      (wb_valid),
    .wb_addr       (wb_addr),
    .wb_data       (wb_data),
    .wb_done       (wb_done),
    // AXI master ports
    .m_axi_araddr  (m_axi_araddr),
    .m_axi_arlen   (m_axi_arlen),
    .m_axi_arsize  (m_axi_arsize),
    .m_axi_arburst (m_axi_arburst),
    .m_axi_arid    (m_axi_arid),
    .m_axi_arvalid (m_axi_arvalid),
    .m_axi_arready (m_axi_arready),
    .m_axi_rdata   (m_axi_rdata),
    .m_axi_rresp   (m_axi_rresp),
    .m_axi_rlast   (m_axi_rlast),
    .m_axi_rid     (m_axi_rid),
    .m_axi_rvalid  (m_axi_rvalid),
    .m_axi_rready  (m_axi_rready),
    .m_axi_awaddr  (m_axi_awaddr),
    .m_axi_awlen   (m_axi_awlen),
    .m_axi_awsize  (m_axi_awsize),
    .m_axi_awburst (m_axi_awburst),
    .m_axi_awid    (m_axi_awid),
    .m_axi_awvalid (m_axi_awvalid),
    .m_axi_awready (m_axi_awready),
    .m_axi_wdata   (m_axi_wdata),
    .m_axi_wstrb   (m_axi_wstrb),
    .m_axi_wlast   (m_axi_wlast),
    .m_axi_wvalid  (m_axi_wvalid),
    .m_axi_wready  (m_axi_wready),
    .m_axi_bresp   (m_axi_bresp),
    .m_axi_bid     (m_axi_bid),
    .m_axi_bvalid  (m_axi_bvalid),
    .m_axi_bready  (m_axi_bready)
  );

  l2_coherency_fsm #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .NUM_SETS   (NUM_SETS),
    .WAYS       (WAYS),
    .TAG_BITS   (TAG_BITS),
    .INDEX_BITS (INDEX_BITS),
    .OFFSET_BITS(OFFSET_BITS)
  ) u_coherency (
    .clk             (clk),
    .rst_n           (rst_n),
    .ac_addr         (ac_addr),
    .ac_snoop        (ac_snoop),
    .ac_valid        (ac_valid),
    .ac_ready        (ac_ready),
    .cr_resp         (cr_resp),
    .cr_valid        (cr_valid),
    .cr_ready        (cr_ready),
    .cd_data         (cd_data),
    .cd_last         (cd_last),
    .cd_valid        (cd_valid),
    .cd_ready        (cd_ready),
    .tag_rd_data     (tag_rd_data),
    .valid_bit       (tag_valid_bit),
    .dirty_bit       (tag_dirty_bit),
    .mesi_state      (tag_mesi_state),
    .hit_any         (hit_any),
    .hit_way_bin     (hit_way_bin),
    .wb_pending      (wb_pending)
  );

  // =========================================================================
  // Performance counters
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      perf_hit_count  <= '0;
      perf_miss_count <= '0;
      perf_wb_count   <= '0;
    end else begin
      if (pipe_req_valid &  hit_any) perf_hit_count  <= perf_hit_count  + 1;
      if (pipe_req_valid & ~hit_any) perf_miss_count <= perf_miss_count + 1;
      if (wb_valid & wb_done)        perf_wb_count   <= perf_wb_count   + 1;
    end
  end

  assign cache_hit  = pipe_req_valid &  hit_any;
  assign cache_miss = pipe_req_valid & ~hit_any;

endmodule

`endif // L2_CACHE_TOP_SV
