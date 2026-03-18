// =============================================================================
// File       : ace_snoop_agent.sv
// Description: UVM ACE snoop agent — drives coherency snoop requests onto
//              the AC channel of the L2 DUT and captures CR/CD responses.
//              Includes: driver, monitor, sequencer, and interface.
// =============================================================================

`ifndef ACE_SNOOP_AGENT_SV
`define ACE_SNOOP_AGENT_SV

`include "uvm_macros.svh"
import uvm_pkg::*;
`include "l2_seq_items.sv"

// =============================================================================
// ACE Snoop Interface
// =============================================================================
interface ace_snoop_if #(
  parameter int ADDR_WIDTH = 40,
  parameter int DATA_WIDTH = 64
)(input logic clk, input logic rst_n);

  logic [ADDR_WIDTH-1:0] ac_addr;
  logic [3:0]            ac_snoop;
  logic                  ac_valid;
  logic                  ac_ready;

  logic [4:0]            cr_resp;
  logic                  cr_valid;
  logic                  cr_ready;

  logic [DATA_WIDTH-1:0] cd_data;
  logic                  cd_last;
  logic                  cd_valid;
  logic                  cd_ready;

  clocking driver_cb @(posedge clk);
    default input #1step output #1;
    output ac_addr, ac_snoop, ac_valid;
    output cr_ready;
    output cd_ready;
    input  ac_ready;
    input  cr_resp, cr_valid;
    input  cd_data, cd_last, cd_valid;
  endclocking

  clocking monitor_cb @(posedge clk);
    default input #1step;
    input ac_addr, ac_snoop, ac_valid, ac_ready;
    input cr_resp, cr_valid, cr_ready;
    input cd_data, cd_last, cd_valid, cd_ready;
  endclocking

  modport driver  (clocking driver_cb,  input clk, rst_n);
  modport monitor (clocking monitor_cb, input clk, rst_n);

endinterface

// =============================================================================
// ACE Snoop Sequencer
// =============================================================================
typedef uvm_sequencer #(ace_seq_item) ace_sequencer;

// =============================================================================
// ACE Snoop Driver
// =============================================================================
class ace_snoop_driver extends uvm_driver #(ace_seq_item);
  `uvm_component_utils(ace_snoop_driver)

  virtual ace_snoop_if.driver vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual ace_snoop_if.driver)::get(
          this, "", "ace_vif", vif))
      `uvm_fatal("ACE_DRV", "No virtual interface for ace_snoop_driver")
  endfunction

  task run_phase(uvm_phase phase);
    ace_seq_item item;
    // Idle defaults
    vif.driver_cb.ac_valid <= 1'b0;
    vif.driver_cb.cr_ready <= 1'b0;
    vif.driver_cb.cd_ready <= 1'b0;

    @(posedge vif.clk iff vif.rst_n);

    forever begin
      seq_item_port.get_next_item(item);
      drive_snoop(item);
      seq_item_port.item_done();
    end
  endtask

  task drive_snoop(ace_seq_item item);
    int start_cycle;
    start_cycle = $time;

    // ── AC channel ─────────────────────────────────────────────────────
    @(vif.driver_cb);
    vif.driver_cb.ac_addr  <= item.snoop_addr;
    vif.driver_cb.ac_snoop <= item.snoop_type;
    vif.driver_cb.ac_valid <= 1'b1;

    do @(vif.driver_cb); while (!vif.driver_cb.ac_ready);
    vif.driver_cb.ac_valid <= 1'b0;

    // ── CR channel ─────────────────────────────────────────────────────
    vif.driver_cb.cr_ready <= 1'b1;
    do @(vif.driver_cb); while (!vif.driver_cb.cr_valid);
    item.cr_resp = vif.driver_cb.cr_resp;
    vif.driver_cb.cr_ready <= 1'b0;

    item.response_cycles = ($time - start_cycle) / 2; // divide by period

    // ── CD channel (if PassDirty) ───────────────────────────────────────
    item.cd_valid = 1'b0;
    if (item.cr_resp[3]) begin  // PassDirty bit
      item.cd_valid = 1'b1;
      vif.driver_cb.cd_ready <= 1'b1;
      item.cd_data = new[8];  // 8 words × 8B = 64B line
      for (int i = 0; i < 8; i++) begin
        do @(vif.driver_cb); while (!vif.driver_cb.cd_valid);
        item.cd_data[i] = vif.driver_cb.cd_data;
        if (vif.driver_cb.cd_last) begin
          vif.driver_cb.cd_ready <= 1'b0;
          break;
        end
      end
    end

    `uvm_info("ACE_DRV", $sformatf(
      "Snoop complete: addr=0x%0h type=%0h resp=%05b cycles=%0d PassDirty=%0b",
      item.snoop_addr, item.snoop_type, item.cr_resp,
      item.response_cycles, item.cr_resp[3]), UVM_MEDIUM)
  endtask

endclass

// =============================================================================
// ACE Snoop Monitor
// =============================================================================
class ace_snoop_monitor extends uvm_monitor;
  `uvm_component_utils(ace_snoop_monitor)

  virtual ace_snoop_if.monitor vif;
  uvm_analysis_port #(ace_seq_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db #(virtual ace_snoop_if.monitor)::get(
          this, "", "ace_vif_mon", vif))
      `uvm_fatal("ACE_MON", "No virtual interface for ace_snoop_monitor")
  endfunction

  task run_phase(uvm_phase phase);
    ace_seq_item item;
    int start_cycle;

    forever begin
      // Wait for AC handshake
      do @(vif.monitor_cb); while (!(vif.monitor_cb.ac_valid &&
                                     vif.monitor_cb.ac_ready));
      start_cycle = $time;
      item = ace_seq_item::type_id::create("snoop_mon");
      item.snoop_addr = vif.monitor_cb.ac_addr;
      item.snoop_type = vif.monitor_cb.ac_snoop;

      // Wait for CR response
      do @(vif.monitor_cb); while (!(vif.monitor_cb.cr_valid &&
                                     vif.monitor_cb.cr_ready));
      item.cr_resp = vif.monitor_cb.cr_resp;
      item.response_cycles = ($time - start_cycle) / 2;

      // Capture CD data if present
      item.cd_valid = vif.monitor_cb.cr_resp[3]; // PassDirty
      if (item.cd_valid) begin
        item.cd_data = new[8];
        for (int i = 0; i < 8; i++) begin
          do @(vif.monitor_cb); while (!(vif.monitor_cb.cd_valid &&
                                         vif.monitor_cb.cd_ready));
          item.cd_data[i] = vif.monitor_cb.cd_data;
          if (vif.monitor_cb.cd_last) break;
        end
      end

      ap.write(item);
    end
  endtask

endclass

// =============================================================================
// ACE Snoop Agent
// =============================================================================
class ace_snoop_agent extends uvm_agent;
  `uvm_component_utils(ace_snoop_agent)

  ace_snoop_driver  driver;
  ace_snoop_monitor monitor;
  ace_sequencer     sequencer;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    monitor   = ace_snoop_monitor::type_id::create("monitor",   this);
    if (get_is_active() == UVM_ACTIVE) begin
      driver    = ace_snoop_driver::type_id::create("driver",    this);
      sequencer = ace_sequencer::type_id::create("sequencer", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    if (get_is_active() == UVM_ACTIVE)
      driver.seq_item_port.connect(sequencer.seq_item_export);
  endfunction

endclass

`endif // ACE_SNOOP_AGENT_SV
