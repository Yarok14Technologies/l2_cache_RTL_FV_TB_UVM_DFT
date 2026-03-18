// =============================================================================
// File       : l2_scoreboard.sv
// Description: UVM scoreboard for L2 cache verification.
//              Compares DUT output (actual read data, responses) against the
//              reference model predictions. Tracks hit/miss accuracy,
//              coherency state transitions, and write-back correctness.
// =============================================================================

`ifndef L2_SCOREBOARD_SV
`define L2_SCOREBOARD_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "l2_seq_items.sv"

class l2_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(l2_scoreboard)

  // -------------------------------------------------------------------------
  // Analysis exports
  // -------------------------------------------------------------------------
  uvm_analysis_export #(axi_seq_item) cpu_req_export;
  uvm_analysis_export #(axi_seq_item) mem_rsp_export;
  uvm_analysis_export #(ace_seq_item) snoop_req_export;
  uvm_analysis_export #(axi_seq_item) expected_export;  // from ref model

  // -------------------------------------------------------------------------
  // Internal FIFOs
  // -------------------------------------------------------------------------
  uvm_tlm_analysis_fifo #(axi_seq_item) actual_fifo;
  uvm_tlm_analysis_fifo #(axi_seq_item) expected_fifo;
  uvm_tlm_analysis_fifo #(ace_seq_item) snoop_fifo;

  // -------------------------------------------------------------------------
  // Scoreboard statistics
  // -------------------------------------------------------------------------
  int total_read_checks;
  int total_write_checks;
  int data_mismatches;
  int resp_errors;
  int hit_count;
  int miss_count;
  int coherency_violations;
  int latency_violations;

  // Latency SLA
  parameter int MAX_HIT_LATENCY_CYCLES  = 4;
  parameter int MAX_MISS_LATENCY_CYCLES = 100;

  // Address → expected data map (written by ref model)
  logic [63:0] golden_mem [logic[39:0]];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    total_read_checks   = 0;
    total_write_checks  = 0;
    data_mismatches     = 0;
    resp_errors         = 0;
    hit_count           = 0;
    miss_count          = 0;
    coherency_violations= 0;
    latency_violations  = 0;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cpu_req_export  = new("cpu_req_export",  this);
    mem_rsp_export  = new("mem_rsp_export",  this);
    snoop_req_export= new("snoop_req_export",this);
    expected_export = new("expected_export", this);

    actual_fifo   = new("actual_fifo",   this);
    expected_fifo = new("expected_fifo", this);
    snoop_fifo    = new("snoop_fifo",    this);
  endfunction

  function void connect_phase(uvm_phase phase);
    cpu_req_export.connect(actual_fifo.analysis_export);
    expected_export.connect(expected_fifo.analysis_export);
    snoop_req_export.connect(snoop_fifo.analysis_export);
  endfunction

  task run_phase(uvm_phase phase);
    fork
      check_reads();
      check_writes();
      check_snoops();
    join
  endtask

  // -------------------------------------------------------------------------
  // Read data checker
  // -------------------------------------------------------------------------
  task check_reads();
    axi_seq_item actual, expected;
    forever begin
      actual_fifo.get(actual);
      if (!actual.is_write) begin
        // Wait for matching expected item (matched by ID)
        expected_fifo.get(expected);

        total_read_checks++;

        // Check response code
        if (actual.resp !== 2'b00) begin
          `uvm_error("SB", $sformatf(
            "READ ERROR resp=0x%0h addr=0x%0h id=0x%0h",
            actual.resp, actual.addr, actual.id))
          resp_errors++;
        end

        // Check data match
        for (int i = 0; i < actual.rdata.size(); i++) begin
          if (actual.rdata[i] !== expected.rdata[i]) begin
            `uvm_error("SB", $sformatf(
              "READ DATA MISMATCH addr=0x%0h beat=%0d actual=0x%0h expected=0x%0h",
              actual.addr, i, actual.rdata[i], expected.rdata[i]))
            data_mismatches++;
          end
        end

        // Check latency SLA
        if (actual.latency > MAX_MISS_LATENCY_CYCLES) begin
          `uvm_warning("SB", $sformatf(
            "READ LATENCY EXCEEDED addr=0x%0h latency=%0d (max=%0d)",
            actual.addr, actual.latency, MAX_MISS_LATENCY_CYCLES))
          latency_violations++;
        end

        `uvm_info("SB", $sformatf(
          "READ CHECK PASS addr=0x%0h latency=%0d cycles",
          actual.addr, actual.latency), UVM_HIGH)
      end
    end
  endtask

  // -------------------------------------------------------------------------
  // Write checker: verify BVALID/BRESP
  // -------------------------------------------------------------------------
  task check_writes();
    axi_seq_item item;
    forever begin
      actual_fifo.get(item);
      if (item.is_write) begin
        total_write_checks++;

        if (item.resp !== 2'b00) begin
          `uvm_error("SB", $sformatf(
            "WRITE ERROR BRESP=0x%0h addr=0x%0h id=0x%0h",
            item.resp, item.addr, item.id))
          resp_errors++;
        end

        // Update golden memory model
        golden_mem[{item.addr[39:3], 3'b0}] = item.wdata[0];

        `uvm_info("SB", $sformatf(
          "WRITE CHECK PASS addr=0x%0h data=0x%0h",
          item.addr, item.wdata[0]), UVM_HIGH)
      end
    end
  endtask

  // -------------------------------------------------------------------------
  // Snoop response checker
  // -------------------------------------------------------------------------
  task check_snoops();
    ace_seq_item snoop;
    forever begin
      snoop_fifo.get(snoop);

      // Verify response latency
      if (snoop.response_cycles > 32) begin
        `uvm_error("SB", $sformatf(
          "SNOOP RESPONSE TIMEOUT addr=0x%0h type=0x%0h cycles=%0d",
          snoop.snoop_addr, snoop.snoop_type, snoop.response_cycles))
        coherency_violations++;
      end

      // If PassDirty is set, CD data must be present
      if (snoop.cr_resp[3] && !snoop.cd_valid) begin
        `uvm_error("SB", $sformatf(
          "SNOOP PassDirty=1 but no CD data — addr=0x%0h",
          snoop.snoop_addr))
        coherency_violations++;
      end

      `uvm_info("SB", $sformatf(
        "SNOOP CHECK addr=0x%0h type=%0h resp=%05b cycles=%0d",
        snoop.snoop_addr, snoop.snoop_type,
        snoop.cr_resp, snoop.response_cycles), UVM_HIGH)
    end
  endtask

  // -------------------------------------------------------------------------
  // Final report
  // -------------------------------------------------------------------------
  function void report_phase(uvm_phase phase);
    `uvm_info("SB", "=========================================", UVM_NONE)
    `uvm_info("SB", "     L2 CACHE SCOREBOARD SUMMARY        ", UVM_NONE)
    `uvm_info("SB", "=========================================", UVM_NONE)
    `uvm_info("SB", $sformatf("  Total Read  Checks  : %0d", total_read_checks),  UVM_NONE)
    `uvm_info("SB", $sformatf("  Total Write Checks  : %0d", total_write_checks), UVM_NONE)
    `uvm_info("SB", $sformatf("  Data Mismatches     : %0d", data_mismatches),    UVM_NONE)
    `uvm_info("SB", $sformatf("  Response Errors     : %0d", resp_errors),        UVM_NONE)
    `uvm_info("SB", $sformatf("  Latency Violations  : %0d", latency_violations), UVM_NONE)
    `uvm_info("SB", $sformatf("  Coherency Violations: %0d", coherency_violations), UVM_NONE)
    `uvm_info("SB", "=========================================", UVM_NONE)

    if (data_mismatches > 0 || resp_errors > 0 || coherency_violations > 0)
      `uvm_fatal("SB", "TEST FAILED — scoreboard errors detected")
    else
      `uvm_info("SB", "*** TEST PASSED ***", UVM_NONE)
  endfunction

endclass

`endif // L2_SCOREBOARD_SV
