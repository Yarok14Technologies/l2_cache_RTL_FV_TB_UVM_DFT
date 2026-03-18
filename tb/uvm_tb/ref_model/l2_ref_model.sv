// =============================================================================
// File       : l2_ref_model.sv
// Description: Golden software reference model for the L2 cache.
//              Maintains a behavioral cache model that mirrors the DUT state.
//              Produces expected read data and response codes consumed by
//              the scoreboard.
//
//              Model accuracy:
//                - Correct for write-back, write-allocate policy
//                - Tracks MESI state per line
//                - Models PLRU replacement (matches DUT exactly)
//                - Does NOT model ECC correction (that is tested separately)
// =============================================================================

`ifndef L2_REF_MODEL_SV
`define L2_REF_MODEL_SV

`include "uvm_macros.svh"
import uvm_pkg::*;
`include "l2_cache_pkg.sv"
`include "l2_seq_items.sv"

class l2_ref_model extends uvm_component;
  `uvm_component_utils(l2_ref_model)

  // ── Exports ────────────────────────────────────────────────────────────────
  uvm_analysis_export #(axi_seq_item) cpu_req_export;
  uvm_analysis_export #(axi_seq_item) mem_rsp_export;

  // ── Output to scoreboard ───────────────────────────────────────────────────
  uvm_analysis_port #(axi_seq_item) expected_ap;

  // ── Internal FIFOs ─────────────────────────────────────────────────────────
  uvm_tlm_analysis_fifo #(axi_seq_item) cpu_fifo;
  uvm_tlm_analysis_fifo #(axi_seq_item) mem_fifo;

  // ── Parameters ─────────────────────────────────────────────────────────────
  localparam int CACHE_SIZE_KB = 256;
  localparam int WAYS          = 4;
  localparam int LINE_SIZE_B   = 64;
  localparam int NUM_SETS      = (CACHE_SIZE_KB * 1024) / (WAYS * LINE_SIZE_B);
  localparam int WORDS_PER_LINE= LINE_SIZE_B / 8;  // 8 words × 64-bit

  // ── Behavioral cache model ─────────────────────────────────────────────────
  typedef struct {
    logic [39:0]  tag;
    logic         valid;
    logic         dirty;
    logic [1:0]   mesi;  // MESI_* encoding from pkg
    logic [63:0]  data [WORDS_PER_LINE];
  } cache_line_t;

  cache_line_t  model_cache [NUM_SETS][WAYS];

  // PLRU state per set (matches l2_lru_controller for 4-way: 3 bits)
  logic [2:0]   plru_state [NUM_SETS];

  // Backing memory model (infinite, word-addressed)
  logic [63:0]  backing_mem [logic[39:3]];

  // ── Constructor ────────────────────────────────────────────────────────────
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cpu_req_export = new("cpu_req_export", this);
    mem_rsp_export = new("mem_rsp_export", this);
    expected_ap    = new("expected_ap",    this);
    cpu_fifo       = new("cpu_fifo",       this);
    mem_fifo       = new("mem_fifo",       this);

    // Initialise model state
    for (int s = 0; s < NUM_SETS; s++) begin
      plru_state[s] = '0;
      for (int w = 0; w < WAYS; w++) begin
        model_cache[s][w] = '0;
      end
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    cpu_req_export.connect(cpu_fifo.analysis_export);
    mem_rsp_export.connect(mem_fifo.analysis_export);
  endfunction

  // ── Main run task ───────────────────────────────────────────────────────────
  task run_phase(uvm_phase phase);
    axi_seq_item req;
    forever begin
      cpu_fifo.get(req);
      if (req.is_write)
        process_write(req);
      else
        process_read(req);
    end
  endtask

  // ── Read processing ─────────────────────────────────────────────────────────
  task process_read(axi_seq_item req);
    axi_seq_item expected;
    int          set_idx;
    int          way;
    logic [39:0] line_addr;
    int          word_base;

    set_idx   = req.addr[12+6-1:6];   // INDEX_BITS=9, OFFSET=6 → [14:6]
    line_addr = {req.addr[39:6], 6'b0};
    word_base = req.addr[5:3];

    expected          = axi_seq_item::type_id::create("exp_rd");
    expected.addr     = req.addr;
    expected.id       = req.id;
    expected.is_write = 1'b0;
    expected.len      = req.len;
    expected.resp     = 2'b00;  // OKAY
    expected.rdata    = new[req.len + 1];

    // Check cache hit
    if (lookup_hit(set_idx, req.addr[39:15], way)) begin
      // Hit: return data from model cache
      for (int b = 0; b <= req.len; b++) begin
        expected.rdata[b] = model_cache[set_idx][way]
                              .data[(word_base + b) % WORDS_PER_LINE];
      end
      update_plru(set_idx, way);
    end else begin
      // Miss: data will come from backing memory (filled by mem_rsp handler)
      // Allocate line in model
      way = plru_victim(set_idx);

      // Handle dirty eviction
      if (model_cache[set_idx][way].valid &&
          model_cache[set_idx][way].dirty) begin
        writeback_to_mem(set_idx, way);
      end

      // Fill from backing memory
      fill_from_mem(set_idx, way, line_addr);
      update_plru(set_idx, way);

      for (int b = 0; b <= req.len; b++) begin
        expected.rdata[b] = model_cache[set_idx][way]
                              .data[(word_base + b) % WORDS_PER_LINE];
      end
    end

    expected_ap.write(expected);
  endtask

  // ── Write processing ────────────────────────────────────────────────────────
  task process_write(axi_seq_item req);
    axi_seq_item expected;
    int          set_idx;
    int          way;
    int          word_idx;
    logic [39:0] line_addr;

    set_idx   = req.addr[14:6];
    line_addr = {req.addr[39:6], 6'b0};
    word_idx  = req.addr[5:3];

    expected          = axi_seq_item::type_id::create("exp_wr");
    expected.addr     = req.addr;
    expected.id       = req.id;
    expected.is_write = 1'b1;
    expected.resp     = 2'b00;

    if (lookup_hit(set_idx, req.addr[39:15], way)) begin
      // Write hit — update in model
      for (int b = 0; b < 8; b++) begin
        if (req.wstrb[0][b]) begin  // wstrb[0] = first (and only) beat strobe
          model_cache[set_idx][way].data[word_idx][b*8+:8] =
            req.wdata[0][b*8+:8];
        end
      end
      model_cache[set_idx][way].dirty = 1'b1;
      model_cache[set_idx][way].mesi  = 2'b11; // MODIFIED
      update_plru(set_idx, way);
    end else begin
      // Write miss — allocate (write-allocate policy)
      way = plru_victim(set_idx);
      if (model_cache[set_idx][way].valid &&
          model_cache[set_idx][way].dirty) begin
        writeback_to_mem(set_idx, way);
      end
      fill_from_mem(set_idx, way, line_addr);
      // Apply write to freshly filled line
      for (int b = 0; b < 8; b++) begin
        if (req.wstrb[0][b])
          model_cache[set_idx][way].data[word_idx][b*8+:8] =
            req.wdata[0][b*8+:8];
      end
      model_cache[set_idx][way].dirty = 1'b1;
      model_cache[set_idx][way].mesi  = 2'b11;
      update_plru(set_idx, way);
    end

    // Update backing memory immediately for coherency tracking
    backing_mem[req.addr[39:3]] = req.wdata[0];

    expected_ap.write(expected);
  endtask

  // ── Helpers ─────────────────────────────────────────────────────────────────

  function bit lookup_hit(int set_idx, logic [24:0] req_tag, output int way);
    for (int w = 0; w < WAYS; w++) begin
      if (model_cache[set_idx][w].valid &&
          model_cache[set_idx][w].tag[39:15] == req_tag) begin
        way = w;
        return 1'b1;
      end
    end
    way = 0;
    return 1'b0;
  endfunction

  function int plru_victim(int set_idx);
    logic [2:0] state = plru_state[set_idx];
    // 4-way PLRU tree decode (matches l2_lru_controller)
    if (!state[2]) return state[1] ? 0 : 1;
    else           return state[0] ? 2 : 3;
  endfunction

  function void update_plru(int set_idx, int accessed_way);
    logic [2:0] s = plru_state[set_idx];
    case (accessed_way)
      0: begin s[2] = 1; s[1] = 1; end
      1: begin s[2] = 1; s[1] = 0; end
      2: begin s[2] = 0; s[0] = 1; end
      3: begin s[2] = 0; s[0] = 0; end
    endcase
    plru_state[set_idx] = s;
  endfunction

  task fill_from_mem(int set_idx, int way, logic [39:0] line_addr);
    model_cache[set_idx][way].valid = 1'b1;
    model_cache[set_idx][way].dirty = 1'b0;
    model_cache[set_idx][way].mesi  = 2'b10; // EXCLUSIVE
    model_cache[set_idx][way].tag   = line_addr;
    for (int w = 0; w < WORDS_PER_LINE; w++) begin
      logic [39:0] word_addr = line_addr + 40'(w * 8);
      if (backing_mem.exists(word_addr[39:3]))
        model_cache[set_idx][way].data[w] = backing_mem[word_addr[39:3]];
      else
        model_cache[set_idx][way].data[w] = '0;  // uninitialized = 0
    end
  endtask

  task writeback_to_mem(int set_idx, int way);
    logic [39:0] base = model_cache[set_idx][way].tag;
    for (int w = 0; w < WORDS_PER_LINE; w++) begin
      logic [39:0] word_addr = base + 40'(w * 8);
      backing_mem[word_addr[39:3]] = model_cache[set_idx][way].data[w];
    end
    model_cache[set_idx][way].dirty = 1'b0;
    model_cache[set_idx][way].mesi  = 2'b01; // SHARED (or will be INVALID)
  endtask

endclass

`endif // L2_REF_MODEL_SV
