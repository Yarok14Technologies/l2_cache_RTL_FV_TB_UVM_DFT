###############################################################################
# Script     : run_gls_atpg.tcl
# Tool       : Synopsys VCS / Cadence Xcelium — Gate-Level Simulation
# Description: Runs gate-level simulation using the generated ATPG patterns
#              to verify fault coverage on the actual post-synthesis netlist.
#              Can also be used for scan chain continuity verification.
#
# Usage (VCS):
#   vcs -full64 -v netlist/l2_cache_dft_top.v \
#       -v libs/28nm/slow_1v0_125c.v \
#       dft/patterns/l2_patterns.v \
#       dft/atpg/gls_tb.v \
#       -o sim/vcs/gls_sim
#   ./sim/vcs/gls_sim +SCAN_TEST +FAULT_TYPE=stuck
###############################################################################

###############################################################################
# GLS Testbench stub (gls_tb.v)
# Instantiates DUT + ATPG pattern generator and result checker
###############################################################################

`timescale 1ns/1ps

module gls_tb;

  // ── Parameters ─────────────────────────────────────────────────────────────
  localparam SCAN_CHAINS  = 4;
  localparam CHAIN_LENGTH = 512;
  localparam ADDR_WIDTH   = 40;
  localparam DATA_WIDTH   = 64;

  // ── Clocks and resets ──────────────────────────────────────────────────────
  logic func_clk  = 0;
  logic test_clk  = 0;
  logic rst_n     = 0;
  logic test_rst_n= 0;

  always #1.0  func_clk  = ~func_clk;   // 500 MHz functional
  always #5.0  test_clk  = ~test_clk;   // 100 MHz test clock (slower for stability)

  // ── DUT ports ──────────────────────────────────────────────────────────────
  logic [SCAN_CHAINS-1:0] scan_in  = '0;
  logic [SCAN_CHAINS-1:0] scan_out;
  logic                   test_se  = 0;
  logic [1:0]             test_tm  = 2'b00;
  logic                   bist_done;
  logic                   bist_pass;

  // Tie off functional ports
  logic [ADDR_WIDTH-1:0]  s_axi_araddr = '0;
  logic                   s_axi_arvalid= '0;
  // ... (all other AXI ports tied to 0 in GLS scan test)

  // ── DUT instantiation ──────────────────────────────────────────────────────
  l2_cache_dft_top u_dut (
    .clk         (func_clk),
    .rst_n       (rst_n),
    .test_clk    (test_clk),
    .test_se     (test_se),
    .test_tm     (test_tm),
    .test_rst_n  (test_rst_n),
    .scan_in     (scan_in),
    .scan_out    (scan_out),
    .bist_done   (bist_done),
    .bist_pass   (bist_pass),
    // Tie off all functional inputs
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    // ... remaining ports tied to 0
    .cache_flush_req  (1'b0),
    .cache_power_down (1'b0),
    .m_axi_arready    (1'b0),
    .m_axi_rvalid     (1'b0),
    .m_axi_rdata      ('0),
    .m_axi_rresp      (2'b0),
    .m_axi_rlast      (1'b0),
    .m_axi_rid        ('0),
    .m_axi_awready    (1'b0),
    .m_axi_wready     (1'b0),
    .m_axi_bvalid     (1'b0),
    .m_axi_bresp      (2'b0),
    .m_axi_bid        ('0),
    .ac_addr          ('0),
    .ac_snoop         ('0),
    .ac_valid         (1'b0),
    .cr_ready         (1'b0),
    .cd_ready         (1'b0),
    .s_axi_awaddr     ('0), .s_axi_awvalid(1'b0),
    .s_axi_wdata      ('0), .s_axi_wvalid (1'b0),
    .s_axi_wstrb      ('0), .s_axi_wlast  (1'b0),
    .s_axi_bready     (1'b0),
    .s_axi_arlen      ('0), .s_axi_arsize ('0),
    .s_axi_arburst    ('0), .s_axi_arid   ('0),
    .s_axi_rready     (1'b0),
    .s_axi_awlen      ('0), .s_axi_awsize ('0),
    .s_axi_awburst    ('0), .s_axi_awid   ('0)
  );

  // ── Test sequence ───────────────────────────────────────────────────────────
  integer pass_count = 0;
  integer fail_count = 0;

  task scan_load_and_capture(
    input  logic [SCAN_CHAINS-1:0][CHAIN_LENGTH-1:0] pattern_in,
    output logic [SCAN_CHAINS-1:0][CHAIN_LENGTH-1:0] pattern_out
  );
    // ── Shift phase ──────────────────────────────────────────────────
    test_se = 1'b1;
    repeat (CHAIN_LENGTH) begin
      @(posedge test_clk);
      for (int c = 0; c < SCAN_CHAINS; c++) begin
        scan_in[c] = pattern_in[c][0];
        pattern_in[c] = {1'b0, pattern_in[c][CHAIN_LENGTH-1:1]};  // shift
      end
    end
    test_se = 1'b0;

    // ── Capture pulse (one functional clock edge) ─────────────────────
    @(posedge func_clk); #0.1;

    // ── Unload phase ──────────────────────────────────────────────────
    test_se = 1'b1;
    for (int b = 0; b < CHAIN_LENGTH; b++) begin
      @(posedge test_clk);
      for (int c = 0; c < SCAN_CHAINS; c++) begin
        pattern_out[c] = {scan_out[c], pattern_out[c][CHAIN_LENGTH-1:1]};
      end
    end
    test_se = 1'b0;
  endtask

  initial begin
    // ── Reset ──────────────────────────────────────────────────────────
    rst_n      = 1'b0;
    test_rst_n = 1'b0;
    test_tm    = 2'b01;   // scan test mode
    repeat (10) @(posedge test_clk);
    test_rst_n = 1'b1;
    rst_n      = 1'b1;

    $display("[GLS] Scan chain continuity test starting...");

    // ── Continuity test: walk a 1 through each chain ──────────────────
    for (int chain = 0; chain < SCAN_CHAINS; chain++) begin
      automatic logic [SCAN_CHAINS-1:0][CHAIN_LENGTH-1:0] p_in  = '0;
      automatic logic [SCAN_CHAINS-1:0][CHAIN_LENGTH-1:0] p_out = '0;
      p_in[chain][0] = 1'b1;   // single 1 at head of chain

      scan_load_and_capture(p_in, p_out);

      // After CHAIN_LENGTH shift clocks the 1 should appear at tail
      if (p_out[chain][CHAIN_LENGTH-1]) begin
        $display("[GLS] PASS: Chain %0d continuity OK", chain);
        pass_count++;
      end else begin
        $display("[GLS] FAIL: Chain %0d broken — no 1 emerged at tail", chain);
        fail_count++;
      end
    end

    // ── BIST test ─────────────────────────────────────────────────────
    $display("[GLS] Running BIST...");
    test_tm = 2'b10;
    @(posedge bist_done);
    if (bist_pass) begin
      $display("[GLS] PASS: BIST all SRAM macros passed");
      pass_count++;
    end else begin
      $display("[GLS] FAIL: BIST — some SRAM macros failed");
      fail_count++;
    end
    test_tm = 2'b01;

    // ── Final result ──────────────────────────────────────────────────
    $display("");
    $display("================================================");
    $display("  GLS ATPG Simulation Summary");
    $display("  PASS: %0d   FAIL: %0d", pass_count, fail_count);
    $display("================================================");

    if (fail_count > 0) $fatal(1, "GLS: TEST FAILED");
    else                $display("GLS: ALL TESTS PASSED");
    $finish;
  end

  // Simulation timeout
  initial begin
    #10_000_000;
    $fatal(1, "GLS: Simulation timeout");
  end

endmodule
