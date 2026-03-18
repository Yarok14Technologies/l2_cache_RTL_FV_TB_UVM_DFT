// =============================================================================
// File       : l2_cache_env.sv
// Description: Top-level UVM environment for the L2 cache verification.
//              All sub-components instantiated and connected here.
//
// Component hierarchy:
//   l2_cache_env
//     ├── cpu_agent      (axi_slave_agent)   — CPU-side AXI4 master
//     ├── mem_agent      (axi_master_agent)  — Memory-side AXI4 slave
//     ├── snoop_agent    (ace_snoop_agent)   — ACE snoop injection
//     ├── ref_model      (l2_ref_model)      — Golden behavioral model
//     ├── scoreboard     (l2_scoreboard)     — Correctness checker
//     └── coverage       (l2_coverage_collector) — Functional coverage
// =============================================================================

`ifndef L2_CACHE_ENV_SV
`define L2_CACHE_ENV_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

// All sub-component files resolved via +incdir at compile time
// (declared in sim/vcs/vcs_filelist.f and sim/xcelium/xm_filelist.f)

class l2_cache_env extends uvm_env;
  `uvm_component_utils(l2_cache_env)

  // ── Sub-components ─────────────────────────────────────────────────────────
  axi_slave_agent       cpu_agent;
  axi_master_agent      mem_agent;
  ace_snoop_agent       snoop_agent;
  l2_ref_model          ref_model;
  l2_scoreboard         scoreboard;
  l2_coverage_collector coverage;

  // ── TLM analysis FIFOs (wire agents → scoreboard/coverage) ────────────────
  uvm_tlm_analysis_fifo #(axi_seq_item) cpu_req_fifo;
  uvm_tlm_analysis_fifo #(axi_seq_item) mem_rsp_fifo;
  uvm_tlm_analysis_fifo #(ace_seq_item) snoop_fifo;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    cpu_agent   = axi_slave_agent::type_id::create("cpu_agent",   this);
    mem_agent   = axi_master_agent::type_id::create("mem_agent",  this);
    snoop_agent = ace_snoop_agent::type_id::create("snoop_agent", this);
    ref_model   = l2_ref_model::type_id::create("ref_model",      this);
    scoreboard  = l2_scoreboard::type_id::create("scoreboard",    this);
    coverage    = l2_coverage_collector::type_id::create("coverage", this);

    cpu_req_fifo = new("cpu_req_fifo", this);
    mem_rsp_fifo = new("mem_rsp_fifo", this);
    snoop_fifo   = new("snoop_fifo",   this);

    // Configure mem_agent as ACTIVE (it needs to respond to DUT's master port)
    uvm_config_db #(uvm_active_passive_enum)::set(
      this, "mem_agent", "is_active", UVM_ACTIVE);
  endfunction

  function void connect_phase(uvm_phase phase);
    // CPU agent monitor → ref_model + scoreboard + coverage
    cpu_agent.monitor.ap.connect(ref_model.cpu_req_export);
    cpu_agent.monitor.ap.connect(scoreboard.cpu_req_export);
    cpu_agent.monitor.ap.connect(coverage.cpu_req_export);

    // Memory agent monitor → ref_model + scoreboard (fill data verification)
    mem_agent.monitor.ap.connect(ref_model.mem_rsp_export);
    mem_agent.monitor.ap.connect(scoreboard.mem_rsp_export);

    // Snoop agent monitor → scoreboard + coverage
    snoop_agent.monitor.ap.connect(scoreboard.snoop_req_export);
    snoop_agent.monitor.ap.connect(coverage.snoop_req_export);

    // Ref model → scoreboard (expected response)
    ref_model.expected_ap.connect(scoreboard.expected_export);
  endfunction

endclass

`endif // L2_CACHE_ENV_SV
