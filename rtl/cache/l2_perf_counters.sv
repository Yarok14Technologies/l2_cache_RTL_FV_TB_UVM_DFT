// =============================================================================
// Module     : l2_perf_counters
// Description: Standalone performance counter block for the L2 cache.
//              Collects hit/miss/WB/prefetch statistics and exposes them
//              as memory-mapped registers (CSR interface via AXI4-Lite).
//
//              Counters (all 32-bit, saturating):
//                0x00  total_requests    — all read + write accesses
//                0x04  read_hits         — read hits (latency ≤ 2 cycles)
//                0x08  read_misses       — read misses (MSHR allocated)
//                0x0C  write_hits        — write hits (dirty bit set)
//                0x10  write_misses      — write misses (RFO issued)
//                0x14  writebacks        — dirty evictions to memory
//                0x18  pf_issued         — prefetch requests issued
//                0x1C  pf_useful         — prefetch hits (demand matched)
//                0x20  snoop_requests    — ACE snoop transactions received
//                0x24  snoop_hitrate     — snoops that found data (pass-dirty)
//                0x28  mshr_stalls       — cycles ARREADY deasserted (MSHR full)
//                0x2C  ecc_corrections   — single-bit ECC corrections applied
//                0x30  ecc_double_errors — double-bit ECC errors detected
//
//              Control:
//                0x40  ctrl              — bit0: enable, bit1: clear_on_read
//                0x44  snapshot          — write any → latch all counters atomically
//
// =============================================================================

`ifndef L2_PERF_COUNTERS_SV
`define L2_PERF_COUNTERS_SV

module l2_perf_counters #(
  parameter int unsigned ADDR_WIDTH = 40,
  parameter int unsigned DATA_WIDTH = 32   // CSR data width
)(
  input  logic                   clk,
  input  logic                   rst_n,

  // ── Event inputs (from cache pipeline) ──────────────────────────────────
  input  logic                   ev_read_hit,
  input  logic                   ev_read_miss,
  input  logic                   ev_write_hit,
  input  logic                   ev_write_miss,
  input  logic                   ev_writeback,
  input  logic                   ev_pf_issued,
  input  logic                   ev_pf_useful,
  input  logic                   ev_snoop_req,
  input  logic                   ev_snoop_hit,
  input  logic                   ev_mshr_stall,
  input  logic                   ev_ecc_corrected,
  input  logic                   ev_ecc_double_err,

  // ── AXI4-Lite CSR port (read-only from system; write = clear or control) ─
  input  logic [7:0]             csr_addr,
  input  logic                   csr_rd_en,
  output logic [DATA_WIDTH-1:0]  csr_rd_data,
  input  logic [DATA_WIDTH-1:0]  csr_wr_data,
  input  logic                   csr_wr_en,

  // ── Direct output bus (to l2_cache_top ports) ─────────────────────────
  output logic [31:0]            perf_hit_count,
  output logic [31:0]            perf_miss_count,
  output logic [31:0]            perf_wb_count
);

  // =========================================================================
  // Control register
  // =========================================================================
  logic        cnt_enable;
  logic        clear_on_read;
  logic        snapshot_req;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt_enable    <= 1'b1;  // enabled by default
      clear_on_read <= 1'b0;
      snapshot_req  <= 1'b0;
    end else begin
      snapshot_req <= 1'b0;
      if (csr_wr_en) begin
        unique case (csr_addr)
          8'h40: begin
            cnt_enable    <= csr_wr_data[0];
            clear_on_read <= csr_wr_data[1];
          end
          8'h44: snapshot_req <= 1'b1;
          default: ;
        endcase
      end
    end
  end

  // =========================================================================
  // Counter array (saturating 32-bit)
  // =========================================================================
  logic [31:0] cnt_total_req;
  logic [31:0] cnt_rd_hit;
  logic [31:0] cnt_rd_miss;
  logic [31:0] cnt_wr_hit;
  logic [31:0] cnt_wr_miss;
  logic [31:0] cnt_wb;
  logic [31:0] cnt_pf_issued;
  logic [31:0] cnt_pf_useful;
  logic [31:0] cnt_snoop_req;
  logic [31:0] cnt_snoop_hit;
  logic [31:0] cnt_mshr_stalls;
  logic [31:0] cnt_ecc_corr;
  logic [31:0] cnt_ecc_dbl;

  // Saturating increment task
  function automatic logic [31:0] sat_inc(input logic [31:0] cnt);
    return (&cnt) ? cnt : cnt + 1;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt_total_req  <= '0; cnt_rd_hit    <= '0; cnt_rd_miss   <= '0;
      cnt_wr_hit     <= '0; cnt_wr_miss   <= '0; cnt_wb        <= '0;
      cnt_pf_issued  <= '0; cnt_pf_useful <= '0; cnt_snoop_req <= '0;
      cnt_snoop_hit  <= '0; cnt_mshr_stalls <= '0;
      cnt_ecc_corr   <= '0; cnt_ecc_dbl   <= '0;
    end else if (cnt_enable) begin
      if (ev_read_hit  || ev_read_miss ||
          ev_write_hit || ev_write_miss)  cnt_total_req  <= sat_inc(cnt_total_req);
      if (ev_read_hit)                   cnt_rd_hit     <= sat_inc(cnt_rd_hit);
      if (ev_read_miss)                  cnt_rd_miss    <= sat_inc(cnt_rd_miss);
      if (ev_write_hit)                  cnt_wr_hit     <= sat_inc(cnt_wr_hit);
      if (ev_write_miss)                 cnt_wr_miss    <= sat_inc(cnt_wr_miss);
      if (ev_writeback)                  cnt_wb         <= sat_inc(cnt_wb);
      if (ev_pf_issued)                  cnt_pf_issued  <= sat_inc(cnt_pf_issued);
      if (ev_pf_useful)                  cnt_pf_useful  <= sat_inc(cnt_pf_useful);
      if (ev_snoop_req)                  cnt_snoop_req  <= sat_inc(cnt_snoop_req);
      if (ev_snoop_hit)                  cnt_snoop_hit  <= sat_inc(cnt_snoop_hit);
      if (ev_mshr_stall)                 cnt_mshr_stalls<= sat_inc(cnt_mshr_stalls);
      if (ev_ecc_corrected)              cnt_ecc_corr   <= sat_inc(cnt_ecc_corr);
      if (ev_ecc_double_err)             cnt_ecc_dbl    <= sat_inc(cnt_ecc_dbl);

      // Clear-on-read: zero counter after CSR read
      if (csr_rd_en && clear_on_read) begin
        unique case (csr_addr)
          8'h00: cnt_total_req   <= '0; 8'h04: cnt_rd_hit      <= '0;
          8'h08: cnt_rd_miss     <= '0; 8'h0C: cnt_wr_hit      <= '0;
          8'h10: cnt_wr_miss     <= '0; 8'h14: cnt_wb          <= '0;
          8'h18: cnt_pf_issued   <= '0; 8'h1C: cnt_pf_useful   <= '0;
          8'h20: cnt_snoop_req   <= '0; 8'h24: cnt_snoop_hit   <= '0;
          8'h28: cnt_mshr_stalls <= '0; 8'h2C: cnt_ecc_corr    <= '0;
          8'h30: cnt_ecc_dbl     <= '0;
          default: ;
        endcase
      end
    end
  end

  // =========================================================================
  // Snapshot registers (latched atomically on snapshot_req)
  // =========================================================================
  logic [31:0] snap_rd_hit, snap_rd_miss, snap_wb;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      snap_rd_hit  <= '0;
      snap_rd_miss <= '0;
      snap_wb      <= '0;
    end else if (snapshot_req) begin
      snap_rd_hit  <= cnt_rd_hit;
      snap_rd_miss <= cnt_rd_miss;
      snap_wb      <= cnt_wb;
    end
  end

  // =========================================================================
  // CSR read mux
  // =========================================================================
  always_comb begin
    csr_rd_data = '0;
    unique case (csr_addr)
      8'h00: csr_rd_data = cnt_total_req;
      8'h04: csr_rd_data = cnt_rd_hit;
      8'h08: csr_rd_data = cnt_rd_miss;
      8'h0C: csr_rd_data = cnt_wr_hit;
      8'h10: csr_rd_data = cnt_wr_miss;
      8'h14: csr_rd_data = cnt_wb;
      8'h18: csr_rd_data = cnt_pf_issued;
      8'h1C: csr_rd_data = cnt_pf_useful;
      8'h20: csr_rd_data = cnt_snoop_req;
      8'h24: csr_rd_data = cnt_snoop_hit;
      8'h28: csr_rd_data = cnt_mshr_stalls;
      8'h2C: csr_rd_data = cnt_ecc_corr;
      8'h30: csr_rd_data = cnt_ecc_dbl;
      8'h40: csr_rd_data = {30'b0, clear_on_read, cnt_enable};
      8'h48: csr_rd_data = snap_rd_hit;   // snapshot read-hit
      8'h4C: csr_rd_data = snap_rd_miss;  // snapshot read-miss
      8'h50: csr_rd_data = snap_wb;       // snapshot WB
      default: csr_rd_data = 32'hDEAD_BEEF;  // debug sentinel
    endcase
  end

  // =========================================================================
  // Direct output ports
  // =========================================================================
  assign perf_hit_count  = cnt_rd_hit;
  assign perf_miss_count = cnt_rd_miss;
  assign perf_wb_count   = cnt_wb;

  // =========================================================================
  // Assertions
  // =========================================================================
`ifdef SIMULATION
  // Counters must be monotonically non-decreasing when enabled
  property p_rd_hit_monotone;
    @(posedge clk) disable iff (!rst_n || !cnt_enable)
    cnt_rd_hit >= $past(cnt_rd_hit);
  endproperty
  ap_rdh_mono: assert property (p_rd_hit_monotone)
    else $error("PERF: read hit counter decreased");

  // Total requests = read + write hits + misses
  property p_total_consistent;
    @(posedge clk) disable iff (!rst_n)
    cnt_total_req == (cnt_rd_hit + cnt_rd_miss +
                      cnt_wr_hit + cnt_wr_miss) || (&cnt_total_req);
  endproperty
  ap_total: assert property (p_total_consistent)
    else $error("PERF: total_req inconsistent with component counters");
`endif

endmodule

`endif // L2_PERF_COUNTERS_SV
