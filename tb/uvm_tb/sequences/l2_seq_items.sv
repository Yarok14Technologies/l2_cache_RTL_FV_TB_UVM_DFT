// =============================================================================
// File       : l2_seq_items.sv
// Description: UVM sequence items for L2 cache verification.
//              Includes AXI read/write, ACE snoop, and cache transaction items.
// =============================================================================

`ifndef L2_SEQ_ITEMS_SV
`define L2_SEQ_ITEMS_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

// =============================================================================
// AXI sequence item — represents one AXI4 read or write transaction
// =============================================================================
class axi_seq_item extends uvm_sequence_item;
  `uvm_object_utils_begin(axi_seq_item)
    `uvm_field_int(addr,     UVM_ALL_ON)
    `uvm_field_int(id,       UVM_ALL_ON)
    `uvm_field_int(len,      UVM_ALL_ON)
    `uvm_field_int(size,     UVM_ALL_ON)
    `uvm_field_int(burst,    UVM_ALL_ON)
    `uvm_field_int(is_write, UVM_ALL_ON)
    `uvm_field_array_int(wdata, UVM_ALL_ON)
    `uvm_field_array_int(wstrb, UVM_ALL_ON)
    `uvm_field_array_int(rdata, UVM_ALL_ON)
    `uvm_field_int(resp,     UVM_ALL_ON)
    `uvm_field_int(latency,  UVM_ALL_ON | UVM_NOPACK)
  `uvm_object_utils_end

  // -------------------------------------------------------------------------
  // Fields
  // -------------------------------------------------------------------------
  rand logic [39:0]  addr;
  rand logic [7:0]   id;
  rand logic [7:0]   len;      // burst length - 1
  rand logic [2:0]   size;     // transfer size (2^size bytes)
  rand logic [1:0]   burst;    // FIXED/INCR/WRAP
  rand logic         is_write;
  rand logic [63:0]  wdata[];
  rand logic [7:0]   wstrb[];
       logic [63:0]  rdata[];
       logic [1:0]   resp;
       int           latency;  // measured cycles from AR/AW to R/B

  // -------------------------------------------------------------------------
  // Constraints
  // -------------------------------------------------------------------------

  // Address aligned to transfer size
  constraint c_addr_align {
    addr[2:0] == 3'b000;  // 64-bit aligned
  }

  // INCR burst only (most common in cache workloads)
  constraint c_burst_incr {
    burst == 2'b01;
  }

  // Size = 3 (8 bytes, full 64-bit word)
  constraint c_size_64 {
    size == 3'b011;
  }

  // Reasonable burst lengths
  constraint c_len_reasonable {
    len inside {[0:7]};
  }

  // Write data array sized to burst length
  constraint c_wdata_size {
    wdata.size() == len + 1;
    wstrb.size() == len + 1;
  }

  // All byte enables enabled for writes (default)
  constraint c_wstrb_all {
    foreach (wstrb[i]) wstrb[i] == 8'hFF;
  }

  function new(string name = "axi_seq_item");
    super.new(name);
  endfunction

  // Address region helpers
  function bit in_cacheable_region();
    return (addr >= 40'h0000_0000 && addr < 40'hFFFF_0000);
  endfunction

  function bit is_cache_line_aligned();
    return (addr[5:0] == 6'b0);  // 64-byte line
  endfunction

endclass

// =============================================================================
// ACE snoop sequence item
// =============================================================================
class ace_seq_item extends uvm_sequence_item;
  `uvm_object_utils_begin(ace_seq_item)
    `uvm_field_int(snoop_addr,  UVM_ALL_ON)
    `uvm_field_int(snoop_type,  UVM_ALL_ON)
    `uvm_field_int(cr_resp,     UVM_ALL_ON)
    `uvm_field_array_int(cd_data, UVM_ALL_ON)
    `uvm_field_int(cd_valid,    UVM_ALL_ON)
    `uvm_field_int(response_cycles, UVM_ALL_ON | UVM_NOPACK)
  `uvm_object_utils_end

  rand logic [39:0]  snoop_addr;
  rand logic [3:0]   snoop_type;  // ace_snoop_t encoding
       logic [4:0]   cr_resp;
       logic [63:0]  cd_data[];
       logic         cd_valid;
       int           response_cycles;

  constraint c_snoop_addr_aligned {
    snoop_addr[5:0] == 6'b0;  // cache-line aligned
  }

  constraint c_valid_snoop_types {
    snoop_type inside {4'h1, 4'h7, 4'h9, 4'hB, 4'hD};
  }

  function new(string name = "ace_seq_item");
    super.new(name);
  endfunction

endclass

// =============================================================================
// l2_seq_base — base sequence with utility methods
// =============================================================================
class l2_seq_base extends uvm_sequence #(axi_seq_item);
  `uvm_object_utils(l2_seq_base)
  `uvm_declare_p_sequencer(axi_sequencer)

  function new(string name = "l2_seq_base");
    super.new(name);
  endfunction

  // Helper: perform a single cache-line-aligned read
  task do_cacheline_read(input logic [39:0] addr, output axi_seq_item item);
    item = axi_seq_item::type_id::create("cl_rd");
    start_item(item);
    if (!item.randomize() with {
      addr     == local::addr;
      is_write == 1'b0;
      len      == 8'd7;   // 8 beats × 8B = 64B cache line
    }) `uvm_fatal("SEQ", "Randomization failed for cacheline read")
    finish_item(item);
  endtask

  // Helper: perform a single 64-bit write
  task do_word_write(
    input logic [39:0] addr,
    input logic [63:0] data,
    output axi_seq_item item
  );
    item = axi_seq_item::type_id::create("w_wr");
    start_item(item);
    if (!item.randomize() with {
      addr     == local::addr;
      is_write == 1'b1;
      len      == 8'd0;
      wdata[0] == local::data;
    }) `uvm_fatal("SEQ", "Randomization failed for word write")
    finish_item(item);
  endtask

endclass

// =============================================================================
// Directed sequences
// =============================================================================

// Simple read hit sequence: write then read same address
class l2_read_after_write_seq extends l2_seq_base;
  `uvm_object_utils(l2_read_after_write_seq)

  rand logic [39:0] base_addr;
  rand int          num_transactions;

  constraint c_addr { base_addr[5:0] == 6'b0; }
  constraint c_num  { num_transactions inside {[1:16]}; }

  function new(string name = "l2_read_after_write_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item wr_item, rd_item;
    for (int i = 0; i < num_transactions; i++) begin
      do_word_write(base_addr + 40'(i * 8), 64'hDEAD_BEEF_0000_0000 | 64'(i),
                    wr_item);
      do_cacheline_read(base_addr, rd_item);
    end
  endtask
endclass

// Eviction test: fill all ways of one set, then one more to cause eviction
class l2_eviction_test_seq extends l2_seq_base;
  `uvm_object_utils(l2_eviction_test_seq)

  rand logic [39:0] set_base_addr;  // address targeting a specific set
  rand int          ways_to_fill;

  constraint c_aligned { set_base_addr[5:0] == 6'b0; }
  constraint c_ways    { ways_to_fill inside {[4:8]}; }

  function new(string name = "l2_eviction_test_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item item;
    // Fill ways_to_fill different tags that map to same set
    // Assuming 512-set cache, stride by NUM_SETS * LINE_SIZE = 512 * 64 = 32KB
    for (int w = 0; w <= ways_to_fill; w++) begin
      do_cacheline_read(set_base_addr + 40'(w * 32 * 1024), item);
      `uvm_info("SEQ", $sformatf("Eviction test: filled way sim %0d at addr %0h",
                w, set_base_addr + 40'(w * 32 * 1024)), UVM_MEDIUM)
    end
  endtask
endclass

// False sharing stress sequence: two alternating cores write adjacent words
class l2_false_sharing_seq extends l2_seq_base;
  `uvm_object_utils(l2_false_sharing_seq)

  rand logic [39:0] shared_line_addr;
  rand int          iterations;

  constraint c_aligned   { shared_line_addr[5:0] == 6'b0; }
  constraint c_iters     { iterations inside {[10:100]}; }

  function new(string name = "l2_false_sharing_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item item;
    // Core A writes offset 0, Core B writes offset 8 of same cache line
    for (int i = 0; i < iterations; i++) begin
      do_word_write(shared_line_addr,          64'(i), item);  // Core A
      do_word_write(shared_line_addr + 40'h8,  64'(i), item);  // Core B
    end
  endtask
endclass

// Outstanding transactions test (up to MSHR_DEPTH parallel misses)
class l2_outstanding_miss_seq extends l2_seq_base;
  `uvm_object_utils(l2_outstanding_miss_seq)

  rand int outstanding_count;
  constraint c_outstanding { outstanding_count inside {[4:16]}; }

  function new(string name = "l2_outstanding_miss_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item items[];
    items = new[outstanding_count];
    // Fire all reads simultaneously (non-blocking)
    fork
      for (int i = 0; i < outstanding_count; i++) begin
        automatic int idx = i;
        items[idx] = axi_seq_item::type_id::create($sformatf("miss_%0d", idx));
        start_item(items[idx]);
        if (!items[idx].randomize() with {
          is_write == 1'b0;
          len      == 8'd7;
          addr[39:16] == 24'(idx + 1);  // different pages = all miss
          addr[15:6]  == '0;
          addr[5:0]   == '0;
        }) `uvm_fatal("SEQ", "Outstanding miss randomize failed")
        finish_item(items[idx]);
      end
    join
  endtask
endclass

// Constrained random sequence for regression
class l2_random_traffic_seq extends l2_seq_base;
  `uvm_object_utils(l2_random_traffic_seq)

  rand int num_ops;
  rand int write_pct;  // percentage of writes

  constraint c_num_ops  { num_ops   inside {[50:500]}; }
  constraint c_wr_pct   { write_pct inside {[0:100]}; }

  function new(string name = "l2_random_traffic_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item item;
    for (int i = 0; i < num_ops; i++) begin
      item = axi_seq_item::type_id::create($sformatf("rand_op_%0d", i));
      start_item(item);
      if (!item.randomize() with {
        is_write == ($urandom_range(0, 99) < write_pct);
      }) `uvm_fatal("SEQ", "Random traffic randomize failed")
      finish_item(item);
    end
  endtask
endclass

`endif // L2_SEQ_ITEMS_SV
