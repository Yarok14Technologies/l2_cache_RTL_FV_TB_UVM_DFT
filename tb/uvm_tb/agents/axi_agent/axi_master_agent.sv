// =============================================================================
// File       : axi_master_agent.sv
// Description: UVM AXI4 master agent for the memory side of the L2 cache DUT.
//              Acts as a slave to the DUT's AXI master interface — it receives
//              fill read requests and dirty write-backs, responds with
//              configurable latency, and monitors all transactions for the
//              scoreboard.
//
//              Modes:
//                ACTIVE  — drives RDATA responses and BVALID
//                PASSIVE — monitor only (for snoop-on-memory-bus scenarios)
//
//              Configurable via uvm_config_db:
//                "mem_latency" (int) — cycles of read latency before RVALID
//                "mem_data_mode" (string) — "random" | "address_based"
// =============================================================================

`ifndef AXI_MASTER_AGENT_SV
`define AXI_MASTER_AGENT_SV

`include "uvm_macros.svh"
import uvm_pkg::*;
`include "l2_seq_items.sv"

// Reuse axi4_if from axi_slave_agent.sv (already compiled via +incdir)
// Sequencer reuse
typedef uvm_sequencer #(axi_seq_item) mem_sequencer;

// =============================================================================
// Memory responder driver  (AXI slave side — responds to DUT master)
// =============================================================================
class axi_master_driver extends uvm_driver #(axi_seq_item);
  `uvm_component_utils(axi_master_driver)

  virtual axi4_if.driver vif;

  // Configurable latency (cycles before RVALID is asserted after ARVALID)
  int mem_latency     = 20;
  // Data generation mode
  string data_mode    = "address_based";

  // Internal memory model — stores data written by DUT write-backs
  logic [63:0] mem_model [logic[39:3]];

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual axi4_if.driver)::get(
          this, "", "axi_vif", vif))
      `uvm_fatal("MEM_DRV", "No virtual interface for axi_master_driver")
    void'(uvm_config_db #(int)::get(this, "", "mem_latency", mem_latency));
    void'(uvm_config_db #(string)::get(this, "", "mem_data_mode", data_mode));
  endfunction

  task run_phase(uvm_phase phase);
    // Idle defaults
    vif.driver_cb.arready <= 1'b0;
    vif.driver_cb.rdata   <= '0;
    vif.driver_cb.rresp   <= 2'b00;
    vif.driver_cb.rlast   <= 1'b0;
    vif.driver_cb.rid     <= '0;
    vif.driver_cb.rvalid  <= 1'b0;
    vif.driver_cb.awready <= 1'b0;
    vif.driver_cb.wready  <= 1'b0;
    vif.driver_cb.bresp   <= 2'b00;
    vif.driver_cb.bid     <= '0;
    vif.driver_cb.bvalid  <= 1'b0;

    @(posedge vif.clk iff vif.rst_n);

    // Handle reads and writes concurrently
    fork
      handle_reads();
      handle_writes();
    join
  endtask

  // ---------------------------------------------------------------------------
  // Handle fill read transactions from the DUT AXI master
  // ---------------------------------------------------------------------------
  task handle_reads();
    logic [39:0]  req_addr;
    logic [7:0]   req_len;
    logic [7:0]   req_id;

    forever begin
      // ── Accept AR ────────────────────────────────────────────────────
      @(vif.driver_cb);
      vif.driver_cb.arready <= 1'b1;
      do @(vif.driver_cb); while (!vif.driver_cb.arvalid);

      req_addr = vif.driver_cb.araddr;
      req_len  = vif.driver_cb.arlen;
      req_id   = vif.driver_cb.arid;

      vif.driver_cb.arready <= 1'b0;

      // ── Simulated memory latency ──────────────────────────────────────
      repeat (mem_latency) @(vif.driver_cb);

      // ── Return R beats ────────────────────────────────────────────────
      vif.driver_cb.rvalid <= 1'b1;
      for (int beat = 0; beat <= req_len; beat++) begin
        logic [63:0] rdata_word;
        logic [39:0] beat_addr;

        beat_addr  = req_addr + 40'(beat * 8);

        // Return stored data if DUT previously wrote it, else synthesize
        if (mem_model.exists(beat_addr[39:3]))
          rdata_word = mem_model[beat_addr[39:3]];
        else if (data_mode == "address_based")
          rdata_word = {beat_addr[39:8], 8'(beat_addr[7:0] ^ 8'hAB)};
        else
          rdata_word = $urandom_range(0, 32'hFFFFFFFF) |
                       ({$urandom_range(0, 32'hFFFFFFFF)} << 32);

        vif.driver_cb.rdata  <= rdata_word;
        vif.driver_cb.rresp  <= 2'b00;   // OKAY
        vif.driver_cb.rid    <= req_id;
        vif.driver_cb.rlast  <= (beat == req_len);

        do @(vif.driver_cb); while (!vif.driver_cb.rready);
      end

      vif.driver_cb.rvalid <= 1'b0;
      vif.driver_cb.rlast  <= 1'b0;

      `uvm_info("MEM_DRV", $sformatf(
        "Fill served: addr=0x%0h len=%0d lat=%0d", req_addr, req_len, mem_latency),
        UVM_HIGH)
    end
  endtask

  // ---------------------------------------------------------------------------
  // Handle dirty write-back transactions from the DUT AXI master
  // ---------------------------------------------------------------------------
  task handle_writes();
    logic [39:0]  wr_addr;
    logic [7:0]   wr_len;
    logic [7:0]   wr_id;
    int           beat_cnt;

    forever begin
      // Accept AW
      @(vif.driver_cb);
      vif.driver_cb.awready <= 1'b1;
      do @(vif.driver_cb); while (!vif.driver_cb.awvalid);
      wr_addr = vif.driver_cb.awaddr;
      wr_len  = vif.driver_cb.awlen;
      wr_id   = vif.driver_cb.awid;
      vif.driver_cb.awready <= 1'b0;

      // Accept W beats
      beat_cnt = 0;
      vif.driver_cb.wready <= 1'b1;
      forever begin
        do @(vif.driver_cb); while (!vif.driver_cb.wvalid);
        begin
          logic [39:0] word_addr = wr_addr + 40'(beat_cnt * 8);
          mem_model[word_addr[39:3]] = vif.driver_cb.wdata;
        end
        if (vif.driver_cb.wlast) break;
        beat_cnt++;
      end
      vif.driver_cb.wready <= 1'b0;

      // B response — 2 cycle delay
      repeat(2) @(vif.driver_cb);
      vif.driver_cb.bid    <= wr_id;
      vif.driver_cb.bresp  <= 2'b00;
      vif.driver_cb.bvalid <= 1'b1;
      do @(vif.driver_cb); while (!vif.driver_cb.bready);
      vif.driver_cb.bvalid <= 1'b0;

      `uvm_info("MEM_DRV", $sformatf(
        "Write-back accepted: addr=0x%0h beats=%0d", wr_addr, beat_cnt+1),
        UVM_HIGH)
    end
  endtask

endclass

// =============================================================================
// Memory-side monitor — captures all fills and write-backs
// =============================================================================
class axi_master_monitor extends uvm_monitor;
  `uvm_component_utils(axi_master_monitor)

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
      `uvm_fatal("MEM_MON", "No virtual interface for axi_master_monitor")
  endfunction

  task run_phase(uvm_phase phase);
    fork
      monitor_fills();
      monitor_writebacks();
    join
  endtask

  task monitor_fills();
    axi_seq_item item;
    forever begin
      // Wait for AR handshake
      do @(vif.monitor_cb); while (!(vif.monitor_cb.arvalid &&
                                     vif.monitor_cb.arready));
      item          = axi_seq_item::type_id::create("fill_mon");
      item.addr     = vif.monitor_cb.araddr;
      item.len      = vif.monitor_cb.arlen;
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
      `uvm_info("MEM_MON", $sformatf(
        "Fill monitored: addr=0x%0h len=%0d", item.addr, item.len), UVM_HIGH)
    end
  endtask

  task monitor_writebacks();
    axi_seq_item item;
    forever begin
      do @(vif.monitor_cb); while (!(vif.monitor_cb.awvalid &&
                                     vif.monitor_cb.awready));
      item          = axi_seq_item::type_id::create("wb_mon");
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
      `uvm_info("MEM_MON", $sformatf(
        "Write-back monitored: addr=0x%0h", item.addr), UVM_HIGH)
    end
  endtask

endclass

// =============================================================================
// AXI Master Agent (memory-side)
// =============================================================================
class axi_master_agent extends uvm_agent;
  `uvm_component_utils(axi_master_agent)

  axi_master_driver  driver;
  axi_master_monitor monitor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    monitor = axi_master_monitor::type_id::create("monitor", this);
    if (get_is_active() == UVM_ACTIVE)
      driver = axi_master_driver::type_id::create("driver", this);
  endfunction

endclass

`endif // AXI_MASTER_AGENT_SV
