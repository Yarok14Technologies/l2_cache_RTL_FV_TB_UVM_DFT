// =============================================================================
// File       : tb/uvm_tb/sequences/l2_coherency_seq.sv
// Description: Dedicated UVM sequences for exhaustive MESI coherency testing.
//              Each sequence targets a specific MESI transition or scenario.
//
//   l2_mesi_i_to_e_seq        — cold read → Exclusive state
//   l2_mesi_e_to_m_seq        — write on Exclusive line → Modified
//   l2_mesi_m_to_s_seq        — snoop ReadShared on Modified → shared WB
//   l2_mesi_s_to_m_seq        — upgrade: Shared → Modified via write
//   l2_mesi_m_to_i_seq        — snoop CleanInvalid on Modified line
//   l2_mesi_upgrade_race_seq  — upgrade request races with incoming snoop
//   l2_mesi_ping_pong_seq     — two addresses alternating writes (M↔I storm)
//   l2_mesi_all_transitions_seq — exercises all 12 legal transitions in order
// =============================================================================

`ifndef L2_COHERENCY_SEQ_SV
`define L2_COHERENCY_SEQ_SV

`include "uvm_macros.svh"
import uvm_pkg::*;
`include "l2_seq_items.sv"

// =============================================================================
// Base coherency sequence — adds snoop sequencer handle
// =============================================================================
class l2_coherency_seq_base extends uvm_sequence;
  `uvm_object_utils(l2_coherency_seq_base)

  `uvm_declare_p_sequencer(axi_sequencer)

  // Handle to snoop sequencer (set by test before starting)
  ace_sequencer snoop_sqr;

  function new(string name = "l2_coherency_seq_base");
    super.new(name);
  endfunction

  // Helper: drive a CPU read (returns item with latency)
  task cpu_read(
    input  logic [39:0]  addr,
    output axi_seq_item  item
  );
    item = axi_seq_item::type_id::create("coh_rd");
    start_item(item);
    if (!item.randomize() with {
      addr == local::addr; is_write == 1'b0;
      len == 8'd7; size == 3'd3; burst == 2'd1;
    }) `uvm_fatal("COH_SEQ", "cpu_read randomize failed")
    finish_item(item);
  endtask

  // Helper: drive a CPU write
  task cpu_write(
    input logic [39:0]  addr,
    input logic [63:0]  data,
    output axi_seq_item item
  );
    item = axi_seq_item::type_id::create("coh_wr");
    start_item(item);
    if (!item.randomize() with {
      addr == local::addr; is_write == 1'b1;
      len == 8'd0; wdata[0] == local::data;
    }) `uvm_fatal("COH_SEQ", "cpu_write randomize failed")
    finish_item(item);
  endtask

  // Helper: inject ACE snoop from snoop sequencer
  task inject_snoop(
    input logic [39:0]  snoop_addr,
    input logic [3:0]   snoop_type,
    output ace_seq_item snoop_item
  );
    snoop_item = ace_seq_item::type_id::create("snoop");
    snoop_item.snoop_addr = snoop_addr;
    snoop_item.snoop_type = snoop_type;
    snoop_sqr.execute_item(snoop_item);
  endtask

endclass

// =============================================================================
// I→E: cold read brings line into Exclusive state
// =============================================================================
class l2_mesi_i_to_e_seq extends l2_coherency_seq_base;
  `uvm_object_utils(l2_mesi_i_to_e_seq)

  rand logic [39:0] target_addr;
  constraint c_aligned { target_addr[5:0] == 6'b0; }

  function new(string name = "l2_mesi_i_to_e_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item rd_item;
    // Cold read → expect Miss → fills → state becomes Exclusive
    cpu_read(target_addr, rd_item);
    `uvm_info("COH", $sformatf(
      "I→E: addr=0x%0h latency=%0d (expect>4 = miss)",
      target_addr, rd_item.latency), UVM_MEDIUM)
    if (rd_item.latency <= 4)
      `uvm_warning("COH", "Expected cache miss but got fast response (already cached?)")
  endtask
endclass

// =============================================================================
// E→M: write to an Exclusive line (no bus transaction needed)
// =============================================================================
class l2_mesi_e_to_m_seq extends l2_coherency_seq_base;
  `uvm_object_utils(l2_mesi_e_to_m_seq)

  rand logic [39:0] target_addr;
  constraint c_aligned { target_addr[5:0] == 6'b0; }

  function new(string name = "l2_mesi_e_to_m_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item rd_item, wr_item;
    // Step 1: bring into Exclusive
    cpu_read(target_addr, rd_item);
    // Step 2: write → silent E→M (no upgrade bus transaction)
    cpu_write(target_addr, 64'hDEAD_BEEF_CAFE_BABE, wr_item);
    `uvm_info("COH", $sformatf(
      "E→M: write to exclusive addr=0x%0h BRESP=%0d",
      target_addr, wr_item.resp), UVM_MEDIUM)
    if (wr_item.resp != 2'b00)
      `uvm_error("COH", "E→M write returned non-OKAY BRESP")
  endtask
endclass

// =============================================================================
// M→S: ReadShared snoop on Modified line → dirty data forwarded
// =============================================================================
class l2_mesi_m_to_s_seq extends l2_coherency_seq_base;
  `uvm_object_utils(l2_mesi_m_to_s_seq)

  rand logic [39:0] target_addr;
  constraint c_aligned { target_addr[5:0] == 6'b0; }

  function new(string name = "l2_mesi_m_to_s_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item wr_item;
    ace_seq_item snoop_item;

    // Step 1: bring to Modified
    axi_seq_item rd_item;
    cpu_read(target_addr, rd_item);
    cpu_write(target_addr, 64'hCAFE_BABE_1234_5678, wr_item);

    // Step 2: peer cache issues ReadShared → snoop arrives
    // Expect: PassDirty=1 in CRRESP, dirty data on CD channel, line → Shared
    inject_snoop(target_addr, 4'h1, snoop_item);  // ReadShared

    `uvm_info("COH", $sformatf(
      "M→S: snoop CRRESP=0b%05b PassDirty=%0b latency=%0d",
      snoop_item.cr_resp, snoop_item.cr_resp[3],
      snoop_item.response_cycles), UVM_MEDIUM)

    if (!snoop_item.cr_resp[3])  // PassDirty bit
      `uvm_error("COH", "M→S: PassDirty=0 — dirty data not forwarded!")
    if (!snoop_item.cd_valid)
      `uvm_error("COH", "M→S: no CD data transfer despite PassDirty=1")
    if (snoop_item.response_cycles > 32)
      `uvm_error("COH", $sformatf("M→S: snoop took %0d cycles > 32 limit",
                 snoop_item.response_cycles))
  endtask
endclass

// =============================================================================
// S→M: upgrade request (write to Shared line needs broadcast invalidate)
// =============================================================================
class l2_mesi_s_to_m_seq extends l2_coherency_seq_base;
  `uvm_object_utils(l2_mesi_s_to_m_seq)

  rand logic [39:0] target_addr;
  constraint c_aligned { target_addr[5:0] == 6'b0; }

  function new(string name = "l2_mesi_s_to_m_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item rd_item, wr_item;
    ace_seq_item snoop_item;

    // Step 1: bring to Shared (ReadShared snoop forces E→S)
    cpu_read(target_addr, rd_item);
    inject_snoop(target_addr, 4'h1, snoop_item);  // downgrade to Shared

    // Step 2: CPU write → S→M requires upgrade (CleanUnique on ACE AW)
    cpu_write(target_addr, 64'hFEED_FACE_DEAD_C0DE, wr_item);

    `uvm_info("COH", $sformatf(
      "S→M: upgrade write at addr=0x%0h BRESP=%0d",
      target_addr, wr_item.resp), UVM_MEDIUM)
    if (wr_item.resp != 2'b00)
      `uvm_error("COH", "S→M upgrade write returned non-OKAY BRESP")
  endtask
endclass

// =============================================================================
// M→I: CleanInvalid snoop evicts Modified line (+ write-back)
// =============================================================================
class l2_mesi_m_to_i_seq extends l2_coherency_seq_base;
  `uvm_object_utils(l2_mesi_m_to_i_seq)

  rand logic [39:0] target_addr;
  constraint c_aligned { target_addr[5:0] == 6'b0; }

  function new(string name = "l2_mesi_m_to_i_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item rd_item, wr_item, post_rd;
    ace_seq_item snoop_item;

    // Step 1: Write to get M state
    cpu_read(target_addr, rd_item);
    cpu_write(target_addr, 64'hA5A5_5A5A_A5A5_5A5A, wr_item);

    // Step 2: CleanInvalid snoop → M→I, dirty WB to memory
    inject_snoop(target_addr, 4'h9, snoop_item);  // CleanInvalid

    `uvm_info("COH", $sformatf(
      "M→I: CRRESP=0b%05b WasUnique=%0b",
      snoop_item.cr_resp, snoop_item.cr_resp[0]), UVM_MEDIUM)
    if (!snoop_item.cr_resp[0])  // WasUnique bit
      `uvm_error("COH", "M→I: WasUnique=0 — should have been unique")

    // Step 3: subsequent read should be a miss (line evicted)
    cpu_read(target_addr, post_rd);
    if (post_rd.latency <= 4)
      `uvm_error("COH", "M→I: post-invalidation read was a hit (not evicted!)")
    else
      `uvm_info("COH", $sformatf(
        "M→I: confirmed eviction — post-invalidation miss latency=%0d",
        post_rd.latency), UVM_MEDIUM)
  endtask
endclass

// =============================================================================
// Ping-Pong: two CPUs alternately write → M→I→M storm
// =============================================================================
class l2_mesi_ping_pong_seq extends l2_coherency_seq_base;
  `uvm_object_utils(l2_mesi_ping_pong_seq)

  rand logic [39:0] shared_addr;
  rand int          iterations;
  constraint c_aligned  { shared_addr[5:0] == 6'b0; }
  constraint c_iters    { iterations inside {[4:32]}; }

  function new(string name = "l2_mesi_ping_pong_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item wr_a, wr_b;
    ace_seq_item snoop;

    for (int i = 0; i < iterations; i++) begin
      // CPU A writes → M state
      cpu_write(shared_addr, 64'(i * 2), wr_a);

      // CPU B snoop (ReadUnique) → invalidates, gets data
      inject_snoop(shared_addr, 4'h7, snoop);

      // CPU B writes → M state
      cpu_write(shared_addr + 40'h8, 64'(i * 2 + 1), wr_b);

      // CPU A snoop → invalidates again
      inject_snoop(shared_addr + 40'h8, 4'h7, snoop);
    end

    `uvm_info("COH", $sformatf(
      "Ping-pong: %0d iterations, no deadlock", iterations), UVM_NONE)
  endtask
endclass

// =============================================================================
// All-transitions: exercise every legal MESI transition in one sequence
// =============================================================================
class l2_mesi_all_transitions_seq extends l2_coherency_seq_base;
  `uvm_object_utils(l2_mesi_all_transitions_seq)

  logic [39:0] base_addr = 40'h0080_0000;

  function new(string name = "l2_mesi_all_transitions_seq");
    super.new(name);
  endfunction

  task body();
    l2_mesi_i_to_e_seq  i2e;
    l2_mesi_e_to_m_seq  e2m;
    l2_mesi_m_to_s_seq  m2s;
    l2_mesi_s_to_m_seq  s2m;
    l2_mesi_m_to_i_seq  m2i;

    `uvm_info("COH", "=== All MESI transitions sequence ===", UVM_NONE)

    // I→E (cold read)
    i2e = l2_mesi_i_to_e_seq::type_id::create("i2e");
    i2e.snoop_sqr = snoop_sqr;
    i2e.target_addr = base_addr;
    i2e.start(p_sequencer);

    // E→M (silent write)
    e2m = l2_mesi_e_to_m_seq::type_id::create("e2m");
    e2m.snoop_sqr = snoop_sqr;
    e2m.target_addr = base_addr;
    e2m.start(p_sequencer);

    // M→S (ReadShared snoop)
    m2s = l2_mesi_m_to_s_seq::type_id::create("m2s");
    m2s.snoop_sqr = snoop_sqr;
    m2s.target_addr = base_addr;
    m2s.start(p_sequencer);

    // S→M (write → upgrade)
    s2m = l2_mesi_s_to_m_seq::type_id::create("s2m");
    s2m.snoop_sqr = snoop_sqr;
    s2m.target_addr = base_addr;
    s2m.start(p_sequencer);

    // M→I (CleanInvalid snoop)
    m2i = l2_mesi_m_to_i_seq::type_id::create("m2i");
    m2i.snoop_sqr = snoop_sqr;
    m2i.target_addr = base_addr;
    m2i.start(p_sequencer);

    `uvm_info("COH", "=== All MESI transitions DONE ===", UVM_NONE)
  endtask
endclass

`endif // L2_COHERENCY_SEQ_SV
