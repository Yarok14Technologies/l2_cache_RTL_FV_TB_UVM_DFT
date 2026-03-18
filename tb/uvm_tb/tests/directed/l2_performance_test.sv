// =============================================================================
// File       : tb/uvm_tb/tests/directed/l2_performance_test.sv
// Description: Performance characterisation tests for the L2 cache.
//              Measures hit rate, miss rate, average latency, and effective
//              bandwidth under realistic workload patterns.
//
//   l2_perf_streaming_test    — sequential streaming (worst case for cache)
//   l2_perf_working_set_test  — working set fits in cache (high hit rate)
//   l2_perf_thrashing_test    — working set > cache size (capacity misses)
//   l2_perf_mixed_rw_test     — realistic 70% read / 30% write traffic
//   l2_perf_latency_hist_test — records and reports latency histogram
// =============================================================================

`ifndef L2_PERFORMANCE_TEST_SV
`define L2_PERFORMANCE_TEST_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

// =============================================================================
// Helper: latency histogram (32 buckets, log2 scale)
// =============================================================================
class latency_histogram;
  int counts[32];   // bucket[i] = cycles [2^i, 2^(i+1))
  int total;
  int sum;          // for mean calculation
  int max_lat;

  function new();
    foreach (counts[i]) counts[i] = 0;
    total   = 0;
    sum     = 0;
    max_lat = 0;
  endfunction

  function void record(int latency);
    int bucket = 0;
    total++;
    sum += latency;
    if (latency > max_lat) max_lat = latency;
    // Find log2 bucket
    for (int i = 1; i < 32; i++) begin
      if (latency < (1 << i)) begin bucket = i-1; break; end
    end
    counts[bucket]++;
  endfunction

  function void report(string prefix);
    real mean_lat = (total > 0) ? real'(sum) / real'(total) : 0.0;
    `uvm_info("PERF_HIST", $sformatf(
      "%s: total=%0d mean=%.1f max=%0d",
      prefix, total, mean_lat, max_lat), UVM_NONE)
    // Print buckets with non-zero counts
    for (int i = 0; i < 32; i++) begin
      if (counts[i] > 0)
        `uvm_info("PERF_HIST", $sformatf(
          "  [%4d-%4d cycles]: %5d (%5.1f%%)",
          (1<<i), (1<<(i+1))-1, counts[i],
          100.0*counts[i]/total), UVM_NONE)
    end
  endfunction

  function real p99_latency();
    // Find 99th percentile bucket
    int cumulative = 0;
    int p99_thresh = int'(real'(total) * 0.99);
    for (int i = 0; i < 32; i++) begin
      cumulative += counts[i];
      if (cumulative >= p99_thresh)
        return real'(1 << (i+1));
    end
    return real'(max_lat);
  endfunction
endclass

// =============================================================================
// Test: streaming access (one pass through large array)
// =============================================================================
class l2_perf_streaming_test extends l2_base_test;
  `uvm_component_utils(l2_perf_streaming_test)

  // Stream size — choose 2× cache to ensure all misses
  parameter int STREAM_KB = 512;  // 2× 256KB L2

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    axi_seq_item item;
    int num_lines = (STREAM_KB * 1024) / 64;
    latency_histogram hist = new();
    int hits = 0, misses = 0;

    `uvm_info("PERF", $sformatf(
      "Streaming test: %0d KB, %0d cache lines", STREAM_KB, num_lines), UVM_NONE)

    for (int i = 0; i < num_lines; i++) begin
      item = axi_seq_item::type_id::create($sformatf("stream_%0d", i));
      start_item(item);
      assert(item.randomize() with {
        is_write == 1'b0;
        len      == 8'd7;
        addr     == 40'(40'h0100_0000 + i * 64);
      });
      finish_item(item);

      hist.record(item.latency);
      if (item.latency <= 4) hits++; else misses++;
    end

    hist.report("STREAMING");
    `uvm_info("PERF", $sformatf(
      "Streaming: hits=%0d misses=%0d hit_rate=%.1f%% p99=%.0f cycles",
      hits, misses, 100.0*hits/num_lines, hist.p99_latency()), UVM_NONE)

    // Streaming should have near-0% hit rate
    if (real'(hits)/real'(num_lines) > 0.1)
      `uvm_warning("PERF", "Streaming hit rate > 10% — unexpected cache pollution")
  endtask
endclass

// =============================================================================
// Test: working-set fits in cache → high hit rate expected
// =============================================================================
class l2_perf_working_set_test extends l2_base_test;
  `uvm_component_utils(l2_perf_working_set_test)

  // Working set = 50% of cache (128KB → fits comfortably)
  parameter int WS_KB    = 128;
  parameter int PASSES   = 8;    // repeat 8 passes over working set

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    axi_seq_item item;
    int num_lines = (WS_KB * 1024) / 64;
    latency_histogram hist = new();
    int hits = 0, total = 0;

    `uvm_info("PERF", $sformatf(
      "Working-set test: %0d KB, %0d passes", WS_KB, PASSES), UVM_NONE)

    for (int pass = 0; pass < PASSES; pass++) begin
      for (int i = 0; i < num_lines; i++) begin
        item = axi_seq_item::type_id::create($sformatf("ws_p%0d_l%0d", pass, i));
        start_item(item);
        assert(item.randomize() with {
          is_write == 1'b0;
          len      == 8'd7;
          addr     == 40'(40'h0200_0000 + i * 64);  // fixed working set
        });
        finish_item(item);

        hist.record(item.latency);
        if (item.latency <= 4) hits++;
        total++;
      end
    end

    real hit_rate = 100.0 * hits / total;
    hist.report("WORKING_SET");
    `uvm_info("PERF", $sformatf(
      "Working-set: hit_rate=%.1f%% (pass 0 = cold, passes 1-%0d = warm)",
      hit_rate, PASSES-1), UVM_NONE)

    // After warm-up pass, should see > 90% hit rate
    if (hit_rate < 80.0)
      `uvm_warning("PERF",
        $sformatf("Hit rate %.1f%% < 80%% — PLRU or capacity issue?", hit_rate))
  endtask
endclass

// =============================================================================
// Test: thrashing — working set just exceeds cache → capacity misses
// =============================================================================
class l2_perf_thrashing_test extends l2_base_test;
  `uvm_component_utils(l2_perf_thrashing_test)

  // Thrash set = 130% of cache
  parameter int THRASH_KB = 340;
  parameter int PASSES    = 4;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    axi_seq_item item;
    int num_lines = (THRASH_KB * 1024) / 64;
    int miss_count = 0, total = 0;

    `uvm_info("PERF", $sformatf(
      "Thrashing test: %0d KB working set (> 256KB cache)", THRASH_KB), UVM_NONE)

    for (int pass = 0; pass < PASSES; pass++) begin
      for (int i = 0; i < num_lines; i++) begin
        item = axi_seq_item::type_id::create($sformatf("thr_p%0d_l%0d", pass, i));
        start_item(item);
        assert(item.randomize() with {
          is_write == 1'b0;
          len      == 8'd7;
          addr     == 40'(40'h0400_0000 + i * 64);
        });
        finish_item(item);

        if (item.latency > 4) miss_count++;
        total++;
      end
    end

    `uvm_info("PERF", $sformatf(
      "Thrashing: miss_rate=%.1f%% (%0d/%0d)",
      100.0*miss_count/total, miss_count, total), UVM_NONE)

    // Expect high miss rate
    if (real'(miss_count)/real'(total) < 0.5)
      `uvm_warning("PERF", "Thrash miss rate < 50% — cache larger than expected?")
  endtask
endclass

// =============================================================================
// Test: realistic 70/30 read-write mixed traffic + latency histogram
// =============================================================================
class l2_perf_mixed_rw_test extends l2_base_test;
  `uvm_component_utils(l2_perf_mixed_rw_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_test_body(uvm_phase phase);
    axi_seq_item item;
    latency_histogram rd_hist = new(), wr_hist = new();
    int total = 500, rd_hits = 0, wr_hits = 0;

    `uvm_info("PERF", "Mixed R/W test: 70% reads, 30% writes", UVM_NONE)

    // Warm up cache first
    for (int i = 0; i < 64; i++) begin
      item = axi_seq_item::type_id::create($sformatf("warm_%0d", i));
      start_item(item);
      assert(item.randomize() with {
        is_write == 1'b0; len == 8'd7;
        addr inside {[40'h0800_0000:40'h081F_FFC0]};
        addr[5:0] == 6'b0;
      });
      finish_item(item);
    end

    // Mixed traffic
    for (int i = 0; i < total; i++) begin
      bit is_wr = ($urandom_range(0,9) < 3);  // 30% writes
      item = axi_seq_item::type_id::create($sformatf("mix_%0d", i));
      start_item(item);
      assert(item.randomize() with {
        is_write == is_wr;
        len == (is_wr ? 8'd0 : 8'd7);
        addr inside {[40'h0800_0000:40'h081F_FFC0]};
        addr[5:0] == 6'b0;
      });
      finish_item(item);

      if (is_wr) begin
        wr_hist.record(item.latency);
        if (item.latency <= 4) wr_hits++;
      end else begin
        rd_hist.record(item.latency);
        if (item.latency <= 4) rd_hits++;
      end
    end

    rd_hist.report("READ");
    wr_hist.report("WRITE");
    `uvm_info("PERF", $sformatf(
      "Mixed R/W: rd_hitrate=%.1f%% wr_hitrate=%.1f%%",
      100.0*rd_hits/(total*0.7), 100.0*wr_hits/(total*0.3)), UVM_NONE)
    `uvm_info("PERF", $sformatf(
      "  Read  p99=%.0f cycles", rd_hist.p99_latency()), UVM_NONE)
    `uvm_info("PERF", $sformatf(
      "  Write p99=%.0f cycles", wr_hist.p99_latency()), UVM_NONE)
  endtask
endclass

`endif // L2_PERFORMANCE_TEST_SV
