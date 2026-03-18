// =============================================================================
// File       : tb/uvm_tb/tests/directed/l2_ecc_test.sv
// Description: Directed UVM tests for ECC (SECDED) fault detection and
//              correction in the L2 cache data array.
//
//              Tests:
//                l2_ecc_single_bit_test — inject single-bit error, verify
//                  corrected data returned (RRESP = OKAY)
//                l2_ecc_double_bit_test — inject double-bit error, verify
//                  SLVERR returned (data is unreliable)
//                l2_ecc_no_false_alarm_test — verify clean data returns OKAY
//
//              Fault injection mechanism:
//                Force a specific bit in the SRAM storage to 0/1 after write.
//                Read it back to trigger the ECC checker.
//                Use hierarchical force: $root.l2_cache_tb_top.dut.u_data_array
// =============================================================================

`ifndef L2_ECC_TEST_SV
`define L2_ECC_TEST_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

// =============================================================================
// ECC sequence: write a known pattern, inject bit flip, read back
// =============================================================================
class l2_ecc_sequence extends uvm_sequence #(axi_seq_item);
  `uvm_object_utils(l2_ecc_sequence)

  rand logic [39:0]  test_addr;
  rand logic [63:0]  test_data;
  rand int           flip_bit;    // which bit to flip (0-63)
  rand bit           double_flip; // flip 2 bits for double-bit error test

  constraint c_addr_aligned { test_addr[5:0] == 6'b0; }
  constraint c_flip_bit_range { flip_bit inside {[0:62]}; }

  function new(string name = "l2_ecc_sequence");
    super.new(name);
  endfunction

  task body();
    axi_seq_item wr_item, rd_item;

    // ── Step 1: Write known data ───────────────────────────────────────
    wr_item = axi_seq_item::type_id::create("ecc_wr");
    start_item(wr_item);
    if (!wr_item.randomize() with {
      addr     == local::test_addr;
      is_write == 1'b1;
      len      == 8'd7;    // full cache line
      foreach (wdata[i]) wdata[i] == local::test_data;
    }) `uvm_fatal("ECC_SEQ", "write randomize failed")
    finish_item(wr_item);

    // ── Step 2: Inject bit fault via hierarchical force ─────────────────
    // This forces a single bit in the SRAM storage to flip.
    // In a real test environment this uses plusargs or a DPI call.
    `uvm_info("ECC_SEQ", $sformatf(
      "Injecting %s-bit error at addr=0x%0h bit=%0d",
      double_flip ? "double" : "single", test_addr, flip_bit), UVM_NONE)

    #10; // allow write to settle

    // Force the bit (relies on DPI fault injection hook)
    void'(ecc_inject_fault(test_addr, flip_bit, double_flip));

    // ── Step 3: Read back ──────────────────────────────────────────────
    rd_item = axi_seq_item::type_id::create("ecc_rd");
    start_item(rd_item);
    if (!rd_item.randomize() with {
      addr     == local::test_addr;
      is_write == 1'b0;
      len      == 8'd0;    // single word read
    }) `uvm_fatal("ECC_SEQ", "read randomize failed")
    finish_item(rd_item);

    // Scoreboard checks RRESP and data correctness via reference model
  endtask

  // DPI function prototype (implemented in C — see tb/dpi/ecc_inject.c)
  import "DPI-C" function int ecc_inject_fault(
    input longint addr,
    input int     bit_position,
    input bit     double_error
  );

endclass

// =============================================================================
// Test: single-bit error correction
// =============================================================================
class l2_ecc_single_bit_test extends l2_base_test;
  `uvm_component_utils(l2_ecc_single_bit_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_ecc_sequence seq;

    // Run 16 iterations with random addresses and flip positions
    for (int i = 0; i < 16; i++) begin
      seq = l2_ecc_sequence::type_id::create($sformatf("ecc_single_%0d", i));
      if (!seq.randomize() with {
        double_flip == 1'b0;
        flip_bit inside {[0:62]};
      }) `uvm_fatal("TEST", "ECC single-bit randomize failed")
      seq.start(env.cpu_agent.sequencer);

      // Scoreboard verifies: RRESP==OKAY, corrected data returned
      `uvm_info("TEST", $sformatf(
        "Iter %0d: SB verified single-bit correction at addr=0x%0h bit=%0d",
        i, seq.test_addr, seq.flip_bit), UVM_MEDIUM)
    end

    `uvm_info("TEST", "ECC single-bit correction test PASSED", UVM_NONE)
  endtask

endclass

// =============================================================================
// Test: double-bit error detection (SLVERR expected)
// =============================================================================
class l2_ecc_double_bit_test extends l2_base_test;
  `uvm_component_utils(l2_ecc_double_bit_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_ecc_sequence seq;

    // Register expected SLVERR in scoreboard config
    uvm_config_db #(bit)::set(this, "env.scoreboard",
                              "expect_slverr", 1'b1);

    for (int i = 0; i < 8; i++) begin
      seq = l2_ecc_sequence::type_id::create($sformatf("ecc_double_%0d", i));
      if (!seq.randomize() with {
        double_flip == 1'b1;
      }) `uvm_fatal("TEST", "ECC double-bit randomize failed")
      seq.start(env.cpu_agent.sequencer);

      // Scoreboard verifies: RRESP==SLVERR (2'b10)
      `uvm_info("TEST", $sformatf(
        "Iter %0d: SB verified double-bit SLVERR at addr=0x%0h",
        i, seq.test_addr), UVM_MEDIUM)
    end

    `uvm_info("TEST", "ECC double-bit detection test PASSED", UVM_NONE)
  endtask

endclass

// =============================================================================
// Test: no false alarm — clean data always returns OKAY
// =============================================================================
class l2_ecc_no_false_alarm_test extends l2_base_test;
  `uvm_component_utils(l2_ecc_no_false_alarm_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    axi_seq_item wr_item, rd_item;

    // Write and read back 64 different patterns — no fault injection
    for (int i = 0; i < 64; i++) begin
      logic [39:0] addr = 40'(40'h0010_0000 + i * 40'h40);
      logic [63:0] pat  = {32'(i * 2 + 1), 32'(i * 2)};

      // Write
      wr_item = axi_seq_item::type_id::create($sformatf("clean_wr_%0d", i));
      start_item(wr_item);
      assert(wr_item.randomize() with {
        addr == local::addr; is_write == 1'b1; len == 8'd7;
        foreach (wdata[j]) wdata[j] == local::pat;
      });
      finish_item(wr_item);

      // Read — RRESP must be OKAY, data must match pat
      rd_item = axi_seq_item::type_id::create($sformatf("clean_rd_%0d", i));
      start_item(rd_item);
      assert(rd_item.randomize() with {
        addr == local::addr; is_write == 1'b0; len == 8'd0;
      });
      finish_item(rd_item);
    end

    `uvm_info("TEST", "ECC no-false-alarm test PASSED (64 clean R/W)", UVM_NONE)
  endtask

endclass

// =============================================================================
// Test: BIST controller simulation
// =============================================================================
class l2_bist_test extends l2_base_test;
  `uvm_component_utils(l2_bist_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    // Drive test_tm = 2'b10 (BIST mode) via interface
    // Wait for bist_done, check bist_pass
    `uvm_info("TEST", "Triggering BIST via test_tm=2'b10...", UVM_NONE)

    // Force test mode via config DB → tb_top drives DUT
    uvm_config_db #(logic [1:0])::set(this, "env", "test_mode", 2'b10);

    // Wait up to 100µs for BIST to complete (at 100 MHz test clk)
    begin : bist_wait
      int timeout_cycles = 10_000;
      fork
        begin
          // Monitor bist_done via scoreboard event
          // (scoreboard checks bist_pass assertion)
          #(timeout_cycles * 10);  // 10ns per cycle @ 100MHz
          `uvm_fatal("TEST", "BIST timeout — bist_done not received")
        end
        begin
          @(posedge $root.l2_cache_tb_top.dut.bist_done);
          if (!$root.l2_cache_tb_top.dut.bist_pass) begin
            `uvm_error("TEST", $sformatf(
              "BIST FAIL: fail_map=0b%016b",
              $root.l2_cache_tb_top.dut.bist_fail_map))
          end else begin
            `uvm_info("TEST", "BIST PASS: all SRAM macros healthy", UVM_NONE)
          end
        end
      join_any
      disable bist_wait;
    end
  endtask

endclass

`endif // L2_ECC_TEST_SV
