// =============================================================================
// File       : axi_slave_agent.sv
// Description: UVM AXI4 slave agent — drives AXI transactions onto the
//              CPU-side (slave) interface of the L2 cache DUT.
//              Contains: driver, monitor, sequencer.
// =============================================================================

`ifndef AXI_SLAVE_AGENT_SV
`define AXI_SLAVE_AGENT_SV

`include "uvm_macros.svh"
import uvm_pkg::*;
`include "l2_seq_items.sv"

// =============================================================================
// AXI Interface
// =============================================================================
interface axi4_if #(
  parameter int ADDR_WIDTH = 40,
  parameter int DATA_WIDTH = 64,
  parameter int ID_WIDTH   = 8
)(input logic clk, input logic rst_n);

  // Read address
  logic [ADDR_WIDTH-1:0] araddr;
  logic [7:0]            arlen;
  logic [2:0]            arsize;
  logic [1:0]            arburst;
  logic [ID_WIDTH-1:0]   arid;
  logic                  arvalid;
  logic                  arready;
  // Read data
  logic [DATA_WIDTH-1:0] rdata;
  logic [1:0]            rresp;
  logic                  rlast;
  logic [ID_WIDTH-1:0]   rid;
  logic                  rvalid;
  logic                  rready;
  // Write address
  logic [ADDR_WIDTH-1:0] awaddr;
  logic [7:0]            awlen;
  logic [2:0]            awsize;
  logic [1:0]            awburst;
  logic [ID_WIDTH-1:0]   awid;
  logic                  awvalid;
  logic                  awready;
  // Write data
  logic [DATA_WIDTH-1:0] wdata;
  logic [DATA_WIDTH/8-1:0] wstrb;
  logic                  wlast;
  logic                  wvalid;
  logic                  wready;
  // Write response
  logic [1:0]            bresp;
  logic [ID_WIDTH-1:0]   bid;
  logic                  bvalid;
  logic                  bready;

  // -----------------------------------------------------------------------
  // Clocking blocks
  // -----------------------------------------------------------------------
  clocking driver_cb @(posedge clk);
    default input #1step output #1;
    // Driven by driver (master)
    output araddr, arlen, arsize, arburst, arid, arvalid;
    output awaddr, awlen, awsize, awburst, awid, awvalid;
    output wdata, wstrb, wlast, wvalid;
    output rready, bready;
    // Sampled by driver
    input  arready, awready, wready;
    input  rdata, rresp, rlast, rid, rvalid;
    input  bresp, bid, bvalid;
  endclocking

  clocking monitor_cb @(posedge clk);
    default input #1step;
    input araddr, arlen, arsize, arburst, arid, arvalid, arready;
    input awaddr, awlen, awsize, awburst, awid, awvalid, awready;
    input wdata, wstrb, wlast, wvalid, wready;
    input rdata, rresp, rlast, rid, rvalid, rready;
    input bresp, bid, bvalid, bready;
  endclocking

  modport driver  (clocking driver_cb,  input clk, rst_n);
  modport monitor (clocking monitor_cb, input clk, rst_n);

endinterface

// =============================================================================
// AXI Sequencer
// =============================================================================
typedef uvm_sequencer #(axi_seq_item) axi_sequencer;

// =============================================================================
// AXI Driver
// =============================================================================
class axi_driver extends uvm_driver #(axi_seq_item);
  `uvm_component_utils(axi_driver)

  virtual axi4_if.driver vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual axi4_if.driver)::get(
          this, "", "axi_vif", vif))
      `uvm_fatal("DRV", "No virtual interface found for axi_driver")
  endfunction

  task run_phase(uvm_phase phase);
    axi_seq_item item;
    // Initialize outputs
    reset_signals();
    // Wait for reset deassertion
    @(posedge vif.clk iff vif.rst_n);

    forever begin
      seq_item_port.get_next_item(item);
      if (item.is_write)
        drive_write(item);
      else
        drive_read(item);
      seq_item_port.item_done();
    end
  endtask

  // -------------------------------------------------------------------------
  // Drive AXI read transaction
  // -------------------------------------------------------------------------
  task drive_read(axi_seq_item item);
    int start_time;
    start_time = $time;

    // AR channel
    @(vif.driver_cb);
    vif.driver_cb.araddr  <= item.addr;
    vif.driver_cb.arlen   <= item.len;
    vif.driver_cb.arsize  <= item.size;
    vif.driver_cb.arburst <= item.burst;
    vif.driver_cb.arid    <= item.id;
    vif.driver_cb.arvalid <= 1'b1;

    // Wait for ARREADY
    do @(vif.driver_cb); while (!vif.driver_cb.arready);
    vif.driver_cb.arvalid <= 1'b0;

    // R channel — collect all beats
    item.rdata = new[item.len + 1];
    vif.driver_cb.rready <= 1'b1;

    for (int beat = 0; beat <= item.len; beat++) begin
      do @(vif.driver_cb); while (!vif.driver_cb.rvalid);
      item.rdata[beat] = vif.driver_cb.rdata;
      item.resp        = vif.driver_cb.rresp;
      if (beat == item.len) begin
        assert (vif.driver_cb.rlast)
          else `uvm_error("DRV", "RLAST not set on last beat")
      end
    end

    vif.driver_cb.rready <= 1'b0;
    item.latency = ($time - start_time) / 1;  // in ns
  endtask

  // -------------------------------------------------------------------------
  // Drive AXI write transaction
  // -------------------------------------------------------------------------
  task drive_write(axi_seq_item item);
    int start_time;
    start_time = $time;

    fork
      // AW channel
      begin
        @(vif.driver_cb);
        vif.driver_cb.awaddr  <= item.addr;
        vif.driver_cb.awlen   <= item.len;
        vif.driver_cb.awsize  <= item.size;
        vif.driver_cb.awburst <= item.burst;
        vif.driver_cb.awid    <= item.id;
        vif.driver_cb.awvalid <= 1'b1;
        do @(vif.driver_cb); while (!vif.driver_cb.awready);
        vif.driver_cb.awvalid <= 1'b0;
      end

      // W channel
      begin
        for (int beat = 0; beat <= item.len; beat++) begin
          @(vif.driver_cb);
          vif.driver_cb.wdata  <= item.wdata[beat];
          vif.driver_cb.wstrb  <= item.wstrb[beat];
          vif.driver_cb.wlast  <= (beat == item.len);
          vif.driver_cb.wvalid <= 1'b1;
          do @(vif.driver_cb); while (!vif.driver_cb.wready);
        end
        vif.driver_cb.wvalid <= 1'b0;
        vif.driver_cb.wlast  <= 1'b0;
      end
    join

    // B channel
    vif.driver_cb.bready <= 1'b1;
    do @(vif.driver_cb); while (!vif.driver_cb.bvalid);
    item.resp = vif.driver_cb.bresp;
    vif.driver_cb.bready <= 1'b0;

    item.latency = ($time - start_time) / 1;
  endtask

  task reset_signals();
    vif.driver_cb.arvalid <= '0;
    vif.driver_cb.awvalid <= '0;
    vif.driver_cb.wvalid  <= '0;
    vif.driver_cb.rready  <= '0;
    vif.driver_cb.bready  <= '0;
  endtask

endclass

// =============================================================================
// AXI Monitor
// =============================================================================
class axi_monitor extends uvm_monitor;
  `uvm_component_utils(axi_monitor)

  virtual axi4_if.monitor vif;
  uvm_analysis_port #(axi_seq_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db #(virtual axi4_if.monitor)::get(
          this, "", "axi_vif_mon", vif))
      `uvm_fatal("MON", "No virtual interface for axi_monitor")
  endfunction

  task run_phase(uvm_phase phase);
    fork
      monitor_reads();
      monitor_writes();
    join
  endtask

  task monitor_reads();
    axi_seq_item item;
    forever begin
      // Wait for ARVALID && ARREADY
      do @(vif.monitor_cb); while (!(vif.monitor_cb.arvalid &&
                                     vif.monitor_cb.arready));
      item          = axi_seq_item::type_id::create("mon_rd");
      item.addr     = vif.monitor_cb.araddr;
      item.len      = vif.monitor_cb.arlen;
      item.size     = vif.monitor_cb.arsize;
      item.burst    = vif.monitor_cb.arburst;
      item.id       = vif.monitor_cb.arid;
      item.is_write = 1'b0;
      item.rdata    = new[item.len + 1];

      // Collect R beats
      for (int b = 0; b <= item.len; b++) begin
        do @(vif.monitor_cb); while (!(vif.monitor_cb.rvalid &&
                                       vif.monitor_cb.rready));
        item.rdata[b] = vif.monitor_cb.rdata;
        item.resp     = vif.monitor_cb.rresp;
      end
      ap.write(item);
    end
  endtask

  task monitor_writes();
    axi_seq_item item;
    forever begin
      do @(vif.monitor_cb); while (!(vif.monitor_cb.awvalid &&
                                     vif.monitor_cb.awready));
      item          = axi_seq_item::type_id::create("mon_wr");
      item.addr     = vif.monitor_cb.awaddr;
      item.len      = vif.monitor_cb.awlen;
      item.id       = vif.monitor_cb.awid;
      item.is_write = 1'b1;
      item.wdata    = new[item.len + 1];
      item.wstrb    = new[item.len + 1];

      for (int b = 0; b <= item.len; b++) begin
        do @(vif.monitor_cb); while (!(vif.monitor_cb.wvalid &&
                                       vif.monitor_cb.wready));
        item.wdata[b] = vif.monitor_cb.wdata;
        item.wstrb[b] = vif.monitor_cb.wstrb;
      end

      do @(vif.monitor_cb); while (!(vif.monitor_cb.bvalid &&
                                     vif.monitor_cb.bready));
      item.resp = vif.monitor_cb.bresp;
      ap.write(item);
    end
  endtask

endclass

// =============================================================================
// AXI Slave Agent
// =============================================================================
class axi_slave_agent extends uvm_agent;
  `uvm_component_utils(axi_slave_agent)

  axi_driver    driver;
  axi_monitor   monitor;
  axi_sequencer sequencer;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    monitor   = axi_monitor::type_id::create("monitor",   this);
    if (get_is_active() == UVM_ACTIVE) begin
      driver    = axi_driver::type_id::create("driver",    this);
      sequencer = axi_sequencer::type_id::create("sequencer", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    if (get_is_active() == UVM_ACTIVE)
      driver.seq_item_port.connect(sequencer.seq_item_export);
  endfunction

endclass

`endif // AXI_SLAVE_AGENT_SV
