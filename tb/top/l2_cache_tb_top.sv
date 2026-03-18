// =============================================================================
// Module     : l2_cache_tb_top
// Description: Top-level simulation testbench.
//              - Generates clock and reset
//              - Instantiates DUT (l2_cache_top)
//              - Instantiates AXI and ACE interfaces
//              - Binds assertion module to DUT
//              - Registers all virtual interfaces in uvm_config_db
//              - Launches UVM test via run_test()
// =============================================================================

`timescale 1ns/1ps

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "l2_cache_pkg.sv"
`include "axi_slave_agent.sv"
`include "ace_snoop_agent.sv"
`include "l2_tests.sv"

module l2_cache_tb_top;

  // ── Parameters ─────────────────────────────────────────────────────────────
  localparam int ADDR_WIDTH   = 40;
  localparam int DATA_WIDTH   = 64;
  localparam int ID_WIDTH     = 8;
  localparam int CACHE_SIZE_KB= 256;
  localparam int WAYS         = 4;
  localparam int LINE_SIZE_B  = 64;
  localparam int MSHR_DEPTH   = 16;
  localparam int NUM_BANKS    = 4;
  localparam real CLK_PERIOD  = 2.0;  // 500 MHz

  // ── Clock and reset ────────────────────────────────────────────────────────
  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  always #(CLK_PERIOD/2) clk = ~clk;

  initial begin
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    `uvm_info("TB_TOP", "Reset deasserted — simulation running", UVM_NONE)
  end

  // ── Interfaces ─────────────────────────────────────────────────────────────
  axi4_if #(.ADDR_WIDTH(ADDR_WIDTH),
             .DATA_WIDTH(DATA_WIDTH),
             .ID_WIDTH  (ID_WIDTH))
    cpu_if (.clk(clk), .rst_n(rst_n));

  axi4_if #(.ADDR_WIDTH(ADDR_WIDTH),
             .DATA_WIDTH(DATA_WIDTH),
             .ID_WIDTH  (ID_WIDTH))
    mem_if (.clk(clk), .rst_n(rst_n));

  ace_snoop_if #(.ADDR_WIDTH(ADDR_WIDTH),
                  .DATA_WIDTH(DATA_WIDTH))
    snoop_if (.clk(clk), .rst_n(rst_n));

  // ── DUT ────────────────────────────────────────────────────────────────────
  l2_cache_top #(
    .CACHE_SIZE_KB (CACHE_SIZE_KB),
    .WAYS          (WAYS),
    .LINE_SIZE_B   (LINE_SIZE_B),
    .ADDR_WIDTH    (ADDR_WIDTH),
    .DATA_WIDTH    (DATA_WIDTH),
    .MSHR_DEPTH    (MSHR_DEPTH),
    .NUM_BANKS     (NUM_BANKS),
    .ID_WIDTH      (ID_WIDTH)
  ) dut (
    .clk           (clk),
    .rst_n         (rst_n),
    // CPU-side AXI slave
    .s_axi_araddr  (cpu_if.araddr),  .s_axi_arlen  (cpu_if.arlen),
    .s_axi_arsize  (cpu_if.arsize),  .s_axi_arburst(cpu_if.arburst),
    .s_axi_arid    (cpu_if.arid),    .s_axi_arvalid(cpu_if.arvalid),
    .s_axi_arready (cpu_if.arready),
    .s_axi_rdata   (cpu_if.rdata),   .s_axi_rresp  (cpu_if.rresp),
    .s_axi_rlast   (cpu_if.rlast),   .s_axi_rid    (cpu_if.rid),
    .s_axi_rvalid  (cpu_if.rvalid),  .s_axi_rready (cpu_if.rready),
    .s_axi_awaddr  (cpu_if.awaddr),  .s_axi_awlen  (cpu_if.awlen),
    .s_axi_awsize  (cpu_if.awsize),  .s_axi_awburst(cpu_if.awburst),
    .s_axi_awid    (cpu_if.awid),    .s_axi_awvalid(cpu_if.awvalid),
    .s_axi_awready (cpu_if.awready),
    .s_axi_wdata   (cpu_if.wdata),   .s_axi_wstrb  (cpu_if.wstrb),
    .s_axi_wlast   (cpu_if.wlast),   .s_axi_wvalid (cpu_if.wvalid),
    .s_axi_wready  (cpu_if.wready),
    .s_axi_bresp   (cpu_if.bresp),   .s_axi_bid    (cpu_if.bid),
    .s_axi_bvalid  (cpu_if.bvalid),  .s_axi_bready (cpu_if.bready),
    // Memory-side AXI master
    .m_axi_araddr  (mem_if.araddr),  .m_axi_arlen  (mem_if.arlen),
    .m_axi_arsize  (mem_if.arsize),  .m_axi_arburst(mem_if.arburst),
    .m_axi_arid    (mem_if.arid),    .m_axi_arvalid(mem_if.arvalid),
    .m_axi_arready (mem_if.arready),
    .m_axi_rdata   (mem_if.rdata),   .m_axi_rresp  (mem_if.rresp),
    .m_axi_rlast   (mem_if.rlast),   .m_axi_rid    (mem_if.rid),
    .m_axi_rvalid  (mem_if.rvalid),  .m_axi_rready (mem_if.rready),
    .m_axi_awaddr  (mem_if.awaddr),  .m_axi_awlen  (mem_if.awlen),
    .m_axi_awsize  (mem_if.awsize),  .m_axi_awburst(mem_if.awburst),
    .m_axi_awid    (mem_if.awid),    .m_axi_awvalid(mem_if.awvalid),
    .m_axi_awready (mem_if.awready),
    .m_axi_wdata   (mem_if.wdata),   .m_axi_wstrb  (mem_if.wstrb),
    .m_axi_wlast   (mem_if.wlast),   .m_axi_wvalid (mem_if.wvalid),
    .m_axi_wready  (mem_if.wready),
    .m_axi_bresp   (mem_if.bresp),   .m_axi_bid    (mem_if.bid),
    .m_axi_bvalid  (mem_if.bvalid),  .m_axi_bready (mem_if.bready),
    // ACE snoop
    .ac_addr       (snoop_if.ac_addr),
    .ac_snoop      (snoop_if.ac_snoop),
    .ac_valid      (snoop_if.ac_valid),
    .ac_ready      (snoop_if.ac_ready),
    .cr_resp       (snoop_if.cr_resp),
    .cr_valid      (snoop_if.cr_valid),
    .cr_ready      (snoop_if.cr_ready),
    .cd_data       (snoop_if.cd_data),
    .cd_last       (snoop_if.cd_last),
    .cd_valid      (snoop_if.cd_valid),
    .cd_ready      (snoop_if.cd_ready),
    // Control
    .cache_flush_req  ('0),
    .cache_power_down ('0)
  );

  // ── Bind assertions ─────────────────────────────────────────────────────────
  bind l2_cache_top l2_cache_assertions #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .ID_WIDTH   (ID_WIDTH),
    .MSHR_DEPTH (MSHR_DEPTH)
  ) u_sva (.*);

  // ── UVM config_db ────────────────────────────────────────────────────────────
  initial begin
    // CPU agent
    uvm_config_db #(virtual axi4_if.driver)::set(
      null, "*.env.cpu_agent.driver",  "axi_vif",     cpu_if);
    uvm_config_db #(virtual axi4_if.monitor)::set(
      null, "*.env.cpu_agent.monitor", "axi_vif_mon", cpu_if);
    // Memory agent
    uvm_config_db #(virtual axi4_if.driver)::set(
      null, "*.env.mem_agent.driver",  "axi_vif",     mem_if);
    uvm_config_db #(virtual axi4_if.monitor)::set(
      null, "*.env.mem_agent.monitor", "axi_vif_mon", mem_if);
    // Snoop agent
    uvm_config_db #(virtual ace_snoop_if.driver)::set(
      null, "*.env.snoop_agent.driver",  "ace_vif",     snoop_if);
    uvm_config_db #(virtual ace_snoop_if.monitor)::set(
      null, "*.env.snoop_agent.monitor", "ace_vif_mon", snoop_if);
  end

  // ── Timeout watchdog ─────────────────────────────────────────────────────────
  initial begin
    int timeout_ns;
    if (!$value$plusargs("TIMEOUT=%0d", timeout_ns)) timeout_ns = 10_000_000;
    #(1ns * timeout_ns);
    `uvm_fatal("TB_TOP", $sformatf("Simulation timeout at %0t", $time))
  end

  // ── Waveform dump ─────────────────────────────────────────────────────────────
  initial begin
    if ($test$plusargs("DUMP_WAVES")) begin
      $vcdplusfile("waves/l2_cache.vpd");
      $vcdpluson(0, l2_cache_tb_top);
    end
  end

  // ── Start UVM ────────────────────────────────────────────────────────────────
  initial run_test();

endmodule
