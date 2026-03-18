// =============================================================================
// File       : l2_coverage.sv
// Description: Functional coverage collector for L2 cache verification.
//              Covers: MESI state transitions, snoop types, burst lengths,
//              hit/miss scenarios, bank conflicts, flush operations.
// =============================================================================

`ifndef L2_COVERAGE_SV
`define L2_COVERAGE_SV

`include "uvm_macros.svh"
import uvm_pkg::*;
`include "l2_cache_pkg.sv"
`include "l2_seq_items.sv"

class l2_coverage_collector extends uvm_subscriber #(axi_seq_item);
  `uvm_component_utils(l2_coverage_collector)

  uvm_analysis_export #(axi_seq_item) cpu_req_export;
  uvm_analysis_export #(ace_seq_item) snoop_req_export;

  uvm_tlm_analysis_fifo #(axi_seq_item) cpu_fifo;
  uvm_tlm_analysis_fifo #(ace_seq_item) snoop_fifo;

  // Most recent items for cross coverage
  axi_seq_item last_cpu_item;
  ace_seq_item last_snoop_item;

  // -------------------------------------------------------------------------
  // Covergroup: AXI transaction properties
  // -------------------------------------------------------------------------
  covergroup cg_axi_transactions;

    cp_rw: coverpoint last_cpu_item.is_write {
      bins read  = {0};
      bins write = {1};
    }

    cp_burst_len: coverpoint last_cpu_item.len {
      bins len_1   = {8'd0};
      bins len_4   = {8'd3};
      bins len_8   = {8'd7};       // full cache line
      bins len_16  = {8'd15};
      bins len_others = default;
    }

    cp_resp: coverpoint last_cpu_item.resp {
      bins okay   = {2'b00};
      bins exokay = {2'b01};
      bins slverr = {2'b10};
      bins decerr = {2'b11};
    }

    cp_latency_range: coverpoint last_cpu_item.latency {
      bins hit_fast  = {[1:4]};    // L2 hit
      bins hit_slow  = {[5:10]};
      bins miss_fast = {[11:30]};  // L3 fill
      bins miss_slow = {[31:100]}; // DRAM fill
      bins over_sla  = {[101:$]};  // SLA violation
    }

    cx_rw_latency: cross cp_rw, cp_latency_range;
    cx_rw_len:     cross cp_rw, cp_burst_len;

  endgroup

  // -------------------------------------------------------------------------
  // Covergroup: MESI state transitions
  // -------------------------------------------------------------------------
  import l2_cache_pkg::mesi_state_t;
  mesi_state_t prev_mesi_state;
  mesi_state_t curr_mesi_state;

  covergroup cg_mesi_transitions;
    cp_from: coverpoint prev_mesi_state {
      bins invalid   = {MESI_INVALID};
      bins shared    = {MESI_SHARED};
      bins exclusive = {MESI_EXCLUSIVE};
      bins modified  = {MESI_MODIFIED};
    }
    cp_to: coverpoint curr_mesi_state {
      bins invalid   = {MESI_INVALID};
      bins shared    = {MESI_SHARED};
      bins exclusive = {MESI_EXCLUSIVE};
      bins modified  = {MESI_MODIFIED};
    }
    cx_transition: cross cp_from, cp_to {
      // Illegal transition — must never be covered
      illegal_bins i_to_m_direct  = binsof(cp_from.invalid)   &&
                                    binsof(cp_to.modified);
      illegal_bins s_to_m_no_upg  = binsof(cp_from.shared)    &&
                                    binsof(cp_to.modified);
    }
  endgroup

  // -------------------------------------------------------------------------
  // Covergroup: Snoop types
  // -------------------------------------------------------------------------
  covergroup cg_snoop_types;
    cp_snoop_type: coverpoint last_snoop_item.snoop_type {
      bins read_shared      = {4'h1};
      bins read_unique      = {4'h7};
      bins clean_invalid    = {4'h9};
      bins clean_unique     = {4'hB};
      bins make_invalid     = {4'hD};
    }

    cp_snoop_hit_dirty: coverpoint last_snoop_item.cr_resp[3] {
      bins pass_dirty = {1};
      bins no_dirty   = {0};
    }

    cp_snoop_response_time: coverpoint last_snoop_item.response_cycles {
      bins fast  = {[1:5]};
      bins med   = {[6:16]};
      bins slow  = {[17:32]};
      bins over  = {[33:$]};  // potential deadlock territory
    }

    cx_type_dirty: cross cp_snoop_type, cp_snoop_hit_dirty;
  endgroup

  // -------------------------------------------------------------------------
  // Covergroup: Access patterns for cache lines
  // -------------------------------------------------------------------------
  covergroup cg_access_patterns;
    // Hit on M/E/S/I state
    cp_hit_on_mesi: coverpoint prev_mesi_state iff (last_cpu_item.latency <= 4) {
      bins hit_modified   = {MESI_MODIFIED};
      bins hit_exclusive  = {MESI_EXCLUSIVE};
      bins hit_shared     = {MESI_SHARED};
    }

    // Miss patterns
    cp_miss_type: coverpoint last_cpu_item.latency iff (last_cpu_item.latency > 4) {
      bins cold_miss   = {[5:20]};    // first access to line
      bins capacity    = {[21:50]};   // evicted due to capacity
      bins coherency   = {[51:100]};  // coherency invalidation miss
    }

    // Write after read on same address (RAW hazard in cache)
    cp_consecutive_rw: coverpoint {last_cpu_item.is_write} {
      bins read_then_write = (0 => 1);
      bins write_then_read = (1 => 0);
    }
  endgroup

  // -------------------------------------------------------------------------
  // Covergroup: Flush and power management
  // -------------------------------------------------------------------------
  bit flush_in_progress;
  bit cache_power_down_seen;

  covergroup cg_power_management;
    cp_flush: coverpoint flush_in_progress {
      bins flush_active = {1};
      bins flush_idle   = {0};
    }
    cp_power_down: coverpoint cache_power_down_seen {
      bins power_down_seen = {1};
    }
    // Flush during outstanding miss (stress scenario)
    cp_flush_with_miss: coverpoint flush_in_progress
      iff (last_cpu_item.latency > 10);
  endgroup

  // -------------------------------------------------------------------------
  // Constructor and build
  // -------------------------------------------------------------------------
  function new(string name, uvm_component parent);
    super.new(name, parent);
    last_cpu_item   = axi_seq_item::type_id::create("last_cpu");
    last_snoop_item = ace_seq_item::type_id::create("last_snoop");
    prev_mesi_state = MESI_INVALID;
    curr_mesi_state = MESI_INVALID;

    cg_axi_transactions = new();
    cg_mesi_transitions = new();
    cg_snoop_types      = new();
    cg_access_patterns  = new();
    cg_power_management = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cpu_req_export   = new("cpu_req_export",   this);
    snoop_req_export = new("snoop_req_export", this);
    cpu_fifo         = new("cpu_fifo",         this);
    snoop_fifo       = new("snoop_fifo",       this);
  endfunction

  function void connect_phase(uvm_phase phase);
    cpu_req_export.connect(cpu_fifo.analysis_export);
    snoop_req_export.connect(snoop_fifo.analysis_export);
  endfunction

  // write() called by the uvm_subscriber base class
  function void write(axi_seq_item t);
    last_cpu_item = t;
    cg_axi_transactions.sample();
    cg_access_patterns.sample();
  endfunction

  task run_phase(uvm_phase phase);
    ace_seq_item snoop;
    forever begin
      snoop_fifo.get(snoop);
      last_snoop_item = snoop;
      cg_snoop_types.sample();
    end
  endtask

  // -------------------------------------------------------------------------
  // Coverage report
  // -------------------------------------------------------------------------
  function void report_phase(uvm_phase phase);
    real axi_cov   = cg_axi_transactions.get_coverage();
    real mesi_cov  = cg_mesi_transitions.get_coverage();
    real snoop_cov = cg_snoop_types.get_coverage();
    real access_cov= cg_access_patterns.get_coverage();

    `uvm_info("COV", "=========================================", UVM_NONE)
    `uvm_info("COV", "     L2 CACHE COVERAGE REPORT           ", UVM_NONE)
    `uvm_info("COV", "=========================================", UVM_NONE)
    `uvm_info("COV", $sformatf("  AXI Transaction Coverage : %.1f%%", axi_cov),   UVM_NONE)
    `uvm_info("COV", $sformatf("  MESI Transition Coverage : %.1f%%", mesi_cov),  UVM_NONE)
    `uvm_info("COV", $sformatf("  Snoop Type Coverage      : %.1f%%", snoop_cov), UVM_NONE)
    `uvm_info("COV", $sformatf("  Access Pattern Coverage  : %.1f%%", access_cov),UVM_NONE)
    `uvm_info("COV", "=========================================", UVM_NONE)

    if (mesi_cov < 90.0)
      `uvm_warning("COV", "MESI coverage below 90% — add more coherency tests")
    if (snoop_cov < 95.0)
      `uvm_warning("COV", "Snoop type coverage below 95% — add snoop sequences")
  endfunction

endclass

`endif // L2_COVERAGE_SV
