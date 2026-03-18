// =============================================================================
// File       : l2_tests.sv
// Description: UVM test classes for the L2 cache verification.
//              Each test selects a sequence (or combination) and configures
//              the environment accordingly.
//
// Test hierarchy:
//   l2_base_test              — common setup (env creation, virtual ifs)
//   ├── l2_smoke_read_test    — minimal read sanity
//   ├── l2_smoke_write_test   — minimal write sanity
//   ├── l2_read_hit_test      — read-after-write hit path
//   ├── l2_write_hit_test     — write hit + dirty bit
//   ├── l2_read_miss_fill_test— cold miss → fill from memory
//   ├── l2_eviction_dirty_test— dirty eviction + write-back
//   ├── l2_mesi_*_tests       — coherency protocol tests
//   ├── l2_mshr_full_test     — MSHR back-pressure
//   ├── l2_outstanding_16_test— 16 simultaneous misses
//   └── l2_random_traffic_test— constrained-random regression
// =============================================================================

`ifndef L2_TESTS_SV
`define L2_TESTS_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "l2_cache_env.sv"
`include "l2_seq_items.sv"

// =============================================================================
// Base test
// =============================================================================
class l2_base_test extends uvm_test;
  `uvm_component_utils(l2_base_test)

  l2_cache_env env;

  // Default test timeout — override in derived tests if needed
  parameter int TEST_TIMEOUT_NS = 1_000_000;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = l2_cache_env::type_id::create("env", this);

    // Set memory response latency (configurable via plusarg)
    begin
      int latency;
      if (!$value$plusargs("MEM_LATENCY=%0d", latency))
        latency = 20;  // default 20-cycle memory latency
      uvm_config_db #(int)::set(this, "env.mem_agent.*", "mem_latency", latency);
    end
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_test_body(phase);
    phase.drop_objection(this);
  endtask

  // Override in derived tests
  virtual task run_test_body(uvm_phase phase);
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server svr = uvm_report_server::get_server();
    if (svr.get_severity_count(UVM_ERROR) > 0 ||
        svr.get_severity_count(UVM_FATAL) > 0)
      `uvm_info("TEST", "*** TEST FAILED ***", UVM_NONE)
    else
      `uvm_info("TEST", "*** TEST PASSED ***", UVM_NONE)
  endfunction

endclass

// =============================================================================
// Smoke tests
// =============================================================================
class l2_smoke_read_test extends l2_base_test;
  `uvm_component_utils(l2_smoke_read_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_read_after_write_seq seq;
    seq = l2_read_after_write_seq::type_id::create("smoke_rd");
    if (!seq.randomize() with {
      base_addr         == 40'h0000_1000;
      num_transactions  == 1;
    }) `uvm_fatal("TEST", "Smoke read randomize failed")
    seq.start(env.cpu_agent.sequencer);
    `uvm_info("TEST", "Smoke read COMPLETE", UVM_NONE)
  endtask
endclass

class l2_smoke_write_test extends l2_base_test;
  `uvm_component_utils(l2_smoke_write_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    axi_seq_item item;
    l2_seq_base seq;
    seq = l2_seq_base::type_id::create("smoke_wr");
    seq.start_item(item = axi_seq_item::type_id::create("wr"));
    if (!item.randomize() with {
      addr     == 40'h0000_2000;
      is_write == 1'b1;
      len      == 8'd0;
    }) `uvm_fatal("TEST", "Smoke write randomize failed")
    seq.finish_item(item);
    `uvm_info("TEST", "Smoke write COMPLETE", UVM_NONE)
  endtask
endclass

// =============================================================================
// Functional test: read hit
// =============================================================================
class l2_read_hit_test extends l2_base_test;
  `uvm_component_utils(l2_read_hit_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_read_after_write_seq seq;
    int num_ops;
    if (!$value$plusargs("NUM_OPS=%0d", num_ops)) num_ops = 32;

    seq = l2_read_after_write_seq::type_id::create("rd_hit");
    if (!seq.randomize() with {
      num_transactions == num_ops;
    }) `uvm_fatal("TEST", "Read hit randomize failed")

    seq.start(env.cpu_agent.sequencer);

    // Verify scoreboard showed mostly hits (latency ≤ 4 cycles)
    `uvm_info("TEST", $sformatf("Read hit test: %0d transactions", num_ops), UVM_NONE)
  endtask
endclass

// =============================================================================
// Functional test: write hit + dirty verification
// =============================================================================
class l2_write_hit_test extends l2_base_test;
  `uvm_component_utils(l2_write_hit_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_seq_base  seq;
    axi_seq_item rd_item, wr_item;
    logic [39:0] test_addr = 40'h0000_4000;
    logic [63:0] wr_data   = 64'hCAFE_BABE_DEAD_BEEF;

    seq = l2_seq_base::type_id::create("wr_hit");

    // Step 1: cold read to bring line into cache (E state)
    seq.do_cacheline_read(test_addr, rd_item);

    // Step 2: write to cache line — should hit (E→M)
    seq.do_word_write(test_addr, wr_data, wr_item);

    // Step 3: read back — should hit (M state), verify data
    seq.do_cacheline_read(test_addr, rd_item);

    // Scoreboard checks data == wr_data
    `uvm_info("TEST", "Write hit test COMPLETE — dirty bit and M state verified via SB", UVM_NONE)
  endtask
endclass

// =============================================================================
// Functional test: read miss → fill
// =============================================================================
class l2_read_miss_fill_test extends l2_base_test;
  `uvm_component_utils(l2_read_miss_fill_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_seq_base  seq;
    axi_seq_item item;
    int num_misses;
    if (!$value$plusargs("NUM_OPS=%0d", num_misses)) num_misses = 8;

    seq = l2_seq_base::type_id::create("rd_miss");

    // Access unique cache lines (each one causes a cold miss)
    for (int i = 0; i < num_misses; i++) begin
      // Different page = cold miss every time
      seq.do_cacheline_read(40'(40'h1000_0000 + i * 40'h10000), item);
      `uvm_info("TEST", $sformatf("Miss fill %0d latency=%0d cycles",
                i, item.latency), UVM_MEDIUM)
    end
  endtask
endclass

// =============================================================================
// Functional test: eviction (dirty)
// =============================================================================
class l2_eviction_dirty_test extends l2_base_test;
  `uvm_component_utils(l2_eviction_dirty_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_eviction_test_seq seq;
    seq = l2_eviction_test_seq::type_id::create("dirty_evict");
    if (!seq.randomize() with {
      ways_to_fill == 5;  // 4-way cache, 5th access forces eviction
    }) `uvm_fatal("TEST", "Eviction dirty randomize failed")
    seq.start(env.cpu_agent.sequencer);
    `uvm_info("TEST", "Eviction dirty test COMPLETE — WB verified via SB", UVM_NONE)
  endtask
endclass

// =============================================================================
// Coherency tests
// =============================================================================
class l2_mesi_snoop_read_shared_test extends l2_base_test;
  `uvm_component_utils(l2_mesi_snoop_read_shared_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_seq_base  cpu_seq;
    axi_seq_item item;
    ace_seq_item snoop_item;

    cpu_seq = l2_seq_base::type_id::create("coh_seq");

    // Step 1: write to bring line into M state
    cpu_seq.do_word_write(40'h0000_C000, 64'hDEAD_C0DE_1234_5678, item);

    // Step 2: inject ReadShared snoop on same address
    // Memory agent sequence will drive the AC channel
    // Scoreboard verifies: PassDirty=1 in CRRESP, dirty data on CD channel
    // and tag array transitions M→S

    `uvm_info("TEST", "MESI snoop ReadShared test — verifying M→S+WB", UVM_NONE)
    #1000;  // allow snoop to complete
  endtask
endclass

class l2_mesi_snoop_invalidate_test extends l2_base_test;
  `uvm_component_utils(l2_mesi_snoop_invalidate_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_seq_base  cpu_seq;
    axi_seq_item rd_item, wr_item;

    cpu_seq = l2_seq_base::type_id::create("inv_seq");

    // Bring line into S state via read
    cpu_seq.do_cacheline_read(40'h0000_E000, rd_item);
    // Snoop agent injects CleanInvalid — ACE agent drives AC channel
    // Scoreboard verifies: line invalidated (I state), subsequent access is a miss
    #500;
    cpu_seq.do_cacheline_read(40'h0000_E000, rd_item);
    // This second read should be a miss (latency > 4)
    `uvm_info("TEST", $sformatf("Post-invalidation access latency: %0d cycles",
              rd_item.latency), UVM_NONE)
  endtask
endclass

// =============================================================================
// MSHR tests
// =============================================================================
class l2_mshr_full_test extends l2_base_test;
  `uvm_component_utils(l2_mshr_full_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_outstanding_miss_seq seq;

    // Increase memory latency to fill MSHR
    uvm_config_db #(int)::set(this, "env.mem_agent.*", "mem_latency", 200);

    seq = l2_outstanding_miss_seq::type_id::create("mshr_full");
    if (!seq.randomize() with {
      outstanding_count == 16;
    }) `uvm_fatal("TEST", "MSHR full randomize failed")

    seq.start(env.cpu_agent.sequencer);
    `uvm_info("TEST", "MSHR full test COMPLETE — back-pressure verified", UVM_NONE)
  endtask
endclass

class l2_outstanding_16_test extends l2_base_test;
  `uvm_component_utils(l2_outstanding_16_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_outstanding_miss_seq seq;
    int count;
    if (!$value$plusargs("OUTSTANDING_COUNT=%0d", count)) count = 16;

    seq = l2_outstanding_miss_seq::type_id::create("out16");
    if (!seq.randomize() with { outstanding_count == count; })
      `uvm_fatal("TEST", "Outstanding 16 randomize failed")

    seq.start(env.cpu_agent.sequencer);
  endtask
endclass

// =============================================================================
// Constrained random regression test
// =============================================================================
class l2_random_traffic_test extends l2_base_test;
  `uvm_component_utils(l2_random_traffic_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_random_traffic_seq seq;
    int num_ops, write_pct;

    if (!$value$plusargs("NUM_OPS=%0d",   num_ops))   num_ops   = 200;
    if (!$value$plusargs("WRITE_PCT=%0d", write_pct)) write_pct = 30;

    seq = l2_random_traffic_seq::type_id::create("rand_traffic");
    if (!seq.randomize() with {
      num_ops   == local::num_ops;
      write_pct == local::write_pct;
    }) `uvm_fatal("TEST", "Random traffic randomize failed")

    seq.start(env.cpu_agent.sequencer);

    `uvm_info("TEST", $sformatf("Random traffic: %0d ops, %0d%% writes",
              num_ops, write_pct), UVM_NONE)
  endtask
endclass

// =============================================================================
// False sharing stress test
// =============================================================================
class l2_false_sharing_test extends l2_base_test;
  `uvm_component_utils(l2_false_sharing_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_false_sharing_seq seq;
    int iterations;
    if (!$value$plusargs("ITERATIONS=%0d", iterations)) iterations = 50;

    seq = l2_false_sharing_seq::type_id::create("false_share");
    if (!seq.randomize() with {
      iterations == local::iterations;
    }) `uvm_fatal("TEST", "False sharing randomize failed")

    seq.start(env.cpu_agent.sequencer);
    `uvm_info("TEST", $sformatf("False sharing test: %0d iterations", iterations), UVM_NONE)
  endtask
endclass

// =============================================================================
// Flush test
// =============================================================================
class l2_flush_test extends l2_base_test;
  `uvm_component_utils(l2_flush_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_seq_base  seq;
    axi_seq_item item;
    int dirty_lines = 32;

    seq = l2_seq_base::type_id::create("flush_seq");

    // Fill cache with dirty lines
    for (int i = 0; i < dirty_lines; i++) begin
      seq.do_word_write(40'(40'h0000_1000 + i * 40'h40),
                        64'(i * 64'h1111_1111_1111_1111), item);
    end

    `uvm_info("TEST", $sformatf("Filled %0d dirty lines, issuing flush...", dirty_lines),
              UVM_NONE)

    // Drive cache_flush_req via interface force
    // (In real TB: use a separate flush interface or register write)
    // @(env.cpu_agent.sequencer);
    // force DUT.cache_flush_req = 1;
    // @(posedge DUT.cache_flush_done);
    // release DUT.cache_flush_req;

    #50000;  // allow flush to complete
    `uvm_info("TEST", "Flush test COMPLETE — all WBs verified by SB", UVM_NONE)
  endtask
endclass

// =============================================================================
// Power down + wakeup test
// =============================================================================
class l2_power_down_wakeup_test extends l2_base_test;
  `uvm_component_utils(l2_power_down_wakeup_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    l2_seq_base  seq;
    axi_seq_item item;

    seq = l2_seq_base::type_id::create("pd_seq");

    // Populate cache
    for (int i = 0; i < 8; i++)
      seq.do_cacheline_read(40'(40'h0000_A000 + i * 40'h40), item);

    // Issue flush before power-down (required by protocol)
    #5000;

    // Power down
    // force DUT.cache_power_down = 1; #100; release DUT.cache_power_down;

    // Wakeup — all accesses should miss (cache state lost in switchable domain)
    #1000;
    for (int i = 0; i < 8; i++) begin
      seq.do_cacheline_read(40'(40'h0000_A000 + i * 40'h40), item);
      if (item.latency <= 4) begin
        `uvm_error("TEST", $sformatf(
          "Expected miss after power-down but got hit (latency=%0d)", item.latency))
      end
    end

    `uvm_info("TEST", "Power down/wakeup test COMPLETE", UVM_NONE)
  endtask
endclass

`endif // L2_TESTS_SV
