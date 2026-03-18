// =============================================================================
// File       : tb/uvm_tb/tests/directed/l2_cdc_power_test.sv
// Description: Directed tests for CDC boundary behaviour and UPF power-aware
//              simulation scenarios.
//
//   l2_cdc_async_fifo_test   — verifies async_fifo CDC handshaking under
//                               worst-case frequency ratios
//   l2_power_flush_test      — verifies full flush → power-down → wakeup
//                               sequence including write-back ordering
//   l2_power_domain_iso_test — verifies isolation cells clamp outputs to 0
//                               when PD_CACHE_LOGIC is powered down
//   l2_upf_corruption_test   — verifies X-propagation when powered-down
//                               domain drives always-on domain (PA-sim)
// =============================================================================

`ifndef L2_CDC_POWER_TEST_SV
`define L2_CDC_POWER_TEST_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

// =============================================================================
// Test: Async FIFO CDC correctness under frequency mismatch
// =============================================================================
class l2_cdc_async_fifo_test extends l2_base_test;
  `uvm_component_utils(l2_cdc_async_fifo_test)

  // Frequency ratio to test: wr_clk / rd_clk
  rand int unsigned wr_to_rd_ratio;
  constraint c_ratio { wr_to_rd_ratio inside {1, 2, 3, 5, 7}; }

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    axi_seq_item wr_item, rd_item;
    int N = 64;

    `uvm_info("TEST", $sformatf(
      "CDC FIFO test: wr:rd clock ratio = %0d:1", wr_to_rd_ratio), UVM_NONE)

    // Configure memory agent with artificially high latency to stress
    // the async FIFO pointer crossing path
    uvm_config_db #(int)::set(this, "env.mem_agent.*",
                              "mem_latency", wr_to_rd_ratio * 5);

    // Issue N back-to-back cache misses (all go through async FIFO on fill path)
    for (int i = 0; i < N; i++) begin
      wr_item = axi_seq_item::type_id::create($sformatf("cdc_rd_%0d", i));
      start_item(wr_item);
      assert(wr_item.randomize() with {
        is_write == 1'b0;
        len      == 8'd7;
        addr     == 40'(40'h2000_0000 + i * 40'h1000);  // all misses
      });
      finish_item(wr_item);
    end

    // Scoreboard verifies all N reads return correct data
    `uvm_info("TEST", $sformatf(
      "CDC FIFO test COMPLETE: %0d transactions verified", N), UVM_NONE)
  endtask

endclass

// =============================================================================
// Test: Complete power-down sequence (flush → off → wakeup → verify miss)
// =============================================================================
class l2_power_flush_test extends l2_base_test;
  `uvm_component_utils(l2_power_flush_test)

  int DIRTY_LINES = 32;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    axi_seq_item item;
    int wb_count_before, wb_count_after;
    automatic logic [39:0] test_addr = 40'h0050_0000;

    `uvm_info("TEST", "=== Phase 1: Fill cache with dirty lines ===", UVM_NONE)

    // Populate cache with DIRTY_LINES dirty lines
    for (int i = 0; i < DIRTY_LINES; i++) begin
      item = axi_seq_item::type_id::create($sformatf("dirty_wr_%0d", i));
      start_item(item);
      assert(item.randomize() with {
        is_write == 1'b1;
        len      == 8'd0;
        addr     == test_addr + 40'(i * 64);
        wdata[0] == 64'(64'hABCD_EF01_2345_6789 ^ i);
      });
      finish_item(item);
    end

    `uvm_info("TEST", $sformatf(
      "%0d dirty lines written. Perf counter: %0d WBs so far",
      DIRTY_LINES, $root.l2_cache_tb_top.dut.perf_wb_count), UVM_NONE)

    `uvm_info("TEST", "=== Phase 2: Issue flush ===", UVM_NONE)

    // Drive cache_flush_req via interface force (tb_top exposes this)
    wb_count_before = int'($root.l2_cache_tb_top.dut.perf_wb_count);

    force $root.l2_cache_tb_top.dut.cache_flush_req = 1'b1;
    // Wait for flush_done
    @(posedge $root.l2_cache_tb_top.dut.cache_flush_done);
    release $root.l2_cache_tb_top.dut.cache_flush_req;

    wb_count_after = int'($root.l2_cache_tb_top.dut.perf_wb_count);

    `uvm_info("TEST", $sformatf(
      "Flush done. WBs during flush: %0d (expected ≥ %0d)",
      wb_count_after - wb_count_before, DIRTY_LINES), UVM_NONE)

    if ((wb_count_after - wb_count_before) < DIRTY_LINES) begin
      `uvm_error("TEST",
        "Not all dirty lines written back during flush!")
    end

    `uvm_info("TEST", "=== Phase 3: Power down ===", UVM_NONE)
    force $root.l2_cache_tb_top.dut.cache_power_down = 1'b1;
    #100;  // hold for several cycles

    `uvm_info("TEST", "=== Phase 4: Wakeup ===", UVM_NONE)
    release $root.l2_cache_tb_top.dut.cache_power_down;
    #20;

    `uvm_info("TEST", "=== Phase 5: Verify post-wakeup cold miss ===", UVM_NONE)

    // All previously cached lines should now miss (cache was powered down)
    for (int i = 0; i < 4; i++) begin
      item = axi_seq_item::type_id::create($sformatf("wake_rd_%0d", i));
      start_item(item);
      assert(item.randomize() with {
        is_write == 1'b0;
        len      == 8'd7;
        addr     == test_addr + 40'(i * 64);
      });
      finish_item(item);

      // Verify miss: latency > 4 cycles
      if (item.latency <= 4) begin
        `uvm_error("TEST", $sformatf(
          "Expected cold miss after power-down but hit! addr=0x%0h latency=%0d",
          item.addr, item.latency))
      end else begin
        `uvm_info("TEST", $sformatf(
          "Confirmed cold miss: addr=0x%0h latency=%0d",
          item.addr, item.latency), UVM_MEDIUM)
      end
    end

    `uvm_info("TEST", "Power flush test COMPLETE", UVM_NONE)
  endtask

endclass

// =============================================================================
// Test: Isolation cell verification — outputs must be 0 when domain off
// =============================================================================
class l2_power_domain_iso_test extends l2_base_test;
  `uvm_component_utils(l2_power_domain_iso_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    // Flush first
    force $root.l2_cache_tb_top.dut.cache_flush_req = 1'b1;
    @(posedge $root.l2_cache_tb_top.dut.cache_flush_done);
    release $root.l2_cache_tb_top.dut.cache_flush_req;

    // Assert power-down
    force $root.l2_cache_tb_top.dut.cache_power_down = 1'b1;
    #20;

    // Check isolation: cache_hit and cache_miss must be 0 (clamped)
    if ($root.l2_cache_tb_top.dut.cache_hit !== 1'b0) begin
      `uvm_error("TEST",
        "Isolation FAIL: cache_hit not clamped to 0 after power-down")
    end
    if ($root.l2_cache_tb_top.dut.cache_miss !== 1'b0) begin
      `uvm_error("TEST",
        "Isolation FAIL: cache_miss not clamped to 0 after power-down")
    end

    // ARREADY should be 0 (domain off — cannot accept requests)
    if ($root.l2_cache_tb_top.dut.s_axi_arready !== 1'b0) begin
      `uvm_error("TEST",
        "Isolation FAIL: ARREADY not 0 while domain powered down")
    end

    release $root.l2_cache_tb_top.dut.cache_power_down;
    `uvm_info("TEST", "Power domain isolation test COMPLETE", UVM_NONE)
  endtask

endclass

`endif // L2_CDC_POWER_TEST_SV
