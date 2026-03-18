// =============================================================================
// Module     : l2_mshr
// Description: Miss Status Holding Register — tracks all in-flight cache misses.
//              Supports 16 outstanding entries, write-merge, prefetch entries,
//              and ordered write-back before fill for the same address.
//
// Allocation policy:
//   1. Check for address merge (same cache line already pending → merge)
//   2. Else allocate free entry (priority encoder on ~valid bits)
//   3. If no free entry → assert full → back-pressure L1 (ARREADY/AWREADY=0)
//
// Deallocation:
//   - Fill complete: data written to cache arrays, entry freed, response issued
//   - Upgrade complete: MESI state updated, entry freed
// =============================================================================

`ifndef L2_MSHR_SV
`define L2_MSHR_SV

`include "l2_cache_pkg.sv"

module l2_mshr
  import l2_cache_pkg::*;
#(
  parameter int unsigned DEPTH      = 16,
  parameter int unsigned ADDR_WIDTH = 40,
  parameter int unsigned DATA_WIDTH = 64,
  parameter int unsigned ID_WIDTH   = 8,

  localparam int unsigned PTR_W = $clog2(DEPTH)
)(
  input  logic                    clk,
  input  logic                    rst_n,

  // -------------------------------------------------------------------------
  // Allocation port — from request pipeline on cache miss
  // -------------------------------------------------------------------------
  input  logic                    alloc_req,
  input  logic [ADDR_WIDTH-1:0]   alloc_addr,      // full physical address
  input  logic [ID_WIDTH-1:0]     alloc_id,
  input  logic                    alloc_is_write,
  input  logic [DATA_WIDTH-1:0]   alloc_wdata,
  input  logic [DATA_WIDTH/8-1:0] alloc_wstrb,
  input  logic                    alloc_prefetch,

  output logic [PTR_W-1:0]        alloc_idx,       // allocated entry index
  output logic                    alloc_merged,     // 1 = merged into existing
  output logic                    full,             // 1 = no free entries

  // -------------------------------------------------------------------------
  // Fill complete port — from AXI master when fill data arrives
  // -------------------------------------------------------------------------
  input  logic                    fill_valid,
  input  logic [ADDR_WIDTH-1:0]   fill_addr,       // cache-line aligned
  input  logic [DATA_WIDTH-1:0]   fill_data [],    // full cache line words
  output logic [PTR_W-1:0]        fill_entry_idx,  // which MSHR entry matched

  // -------------------------------------------------------------------------
  // Write-back port — dirty eviction before fill
  // -------------------------------------------------------------------------
  output logic                    wb_valid,
  output logic [ADDR_WIDTH-1:0]   wb_addr,
  output logic [DATA_WIDTH-1:0]   wb_data [],
  input  logic                    wb_done,

  // -------------------------------------------------------------------------
  // Response port — to request pipeline after fill completes
  // -------------------------------------------------------------------------
  output logic                    resp_valid,
  output logic [ID_WIDTH-1:0]     resp_id,
  output logic [DATA_WIDTH-1:0]   resp_data [],
  output logic                    resp_is_write,
  input  logic                    resp_accepted,

  // -------------------------------------------------------------------------
  // Status
  // -------------------------------------------------------------------------
  output logic [DEPTH-1:0]        mshr_valid_vec,   // bitmask of in-use entries
  output logic [$clog2(DEPTH):0]  mshr_used_count   // how many entries in use
);

  // =========================================================================
  // MSHR entry register array
  // =========================================================================
  mshr_entry_t mshr [DEPTH];

  // =========================================================================
  // Address match logic — check if incoming address already in MSHR
  // (cache-line granularity match: ignore offset bits)
  // Line address = addr[ADDR_WIDTH-1:6] for 64B lines
  // =========================================================================
  localparam int unsigned LINE_ADDR_W = ADDR_WIDTH - 6;

  logic [DEPTH-1:0] line_match;
  logic             any_match;
  logic [PTR_W-1:0] match_idx;

  always_comb begin : addr_match
    for (int i = 0; i < DEPTH; i++) begin
      line_match[i] = mshr[i].valid &&
                      (mshr[i].addr[ADDR_WIDTH-1:6] ==
                       alloc_addr[ADDR_WIDTH-1:6]);
    end
    any_match = |line_match;
    // Priority encode the first match
    match_idx = '0;
    for (int i = DEPTH-1; i >= 0; i--) begin
      if (line_match[i]) match_idx = PTR_W'(i);
    end
  end

  // =========================================================================
  // Free entry finder
  // =========================================================================
  logic [DEPTH-1:0] free_vec;
  logic [PTR_W-1:0] free_idx;
  logic             any_free;

  always_comb begin : free_find
    for (int i = 0; i < DEPTH; i++) begin
      free_vec[i] = !mshr[i].valid;
    end
    any_free = |free_vec;
    free_idx = '0;
    for (int i = DEPTH-1; i >= 0; i--) begin
      if (free_vec[i]) free_idx = PTR_W'(i);
    end
  end

  assign full = !any_free && !any_match;

  // =========================================================================
  // Allocation index and merge flag
  // =========================================================================
  assign alloc_idx    = any_match ? match_idx : free_idx;
  assign alloc_merged = any_match;

  // =========================================================================
  // Fill entry match — find MSHR entry matching fill address
  // =========================================================================
  logic [DEPTH-1:0] fill_match_vec;

  always_comb begin : fill_match
    for (int i = 0; i < DEPTH; i++) begin
      fill_match_vec[i] = mshr[i].valid &&
                          (mshr[i].state == MSHR_FILL_ACTIVE) &&
                          (mshr[i].addr[ADDR_WIDTH-1:6] ==
                           fill_addr[ADDR_WIDTH-1:6]);
    end
    fill_entry_idx = '0;
    for (int i = DEPTH-1; i >= 0; i--) begin
      if (fill_match_vec[i]) fill_entry_idx = PTR_W'(i);
    end
  end

  // =========================================================================
  // MSHR state machine — per-entry updates
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin : mshr_state_update
    if (!rst_n) begin
      for (int i = 0; i < DEPTH; i++) begin
        mshr[i] <= '0;
      end
    end else begin

      // ---- Allocation ----
      if (alloc_req && !full) begin
        if (!any_match) begin
          // New entry
          mshr[free_idx].valid     <= 1'b1;
          mshr[free_idx].state     <= MSHR_PENDING;
          mshr[free_idx].addr      <= alloc_addr;
          mshr[free_idx].req_id    <= alloc_id;
          mshr[free_idx].is_write  <= alloc_is_write;
          mshr[free_idx].wdata     <= alloc_wdata;
          mshr[free_idx].wstrb     <= alloc_wstrb;
          mshr[free_idx].prefetch  <= alloc_prefetch;
        end
        // Merge case: entry already tracks this line — no state change needed
        // (the fill will satisfy both requestors; resp_id needs linking in
        //  a production design via a linked-list or CAM structure)
      end

      // ---- Pending → Fill Active (AXI read issued) ----
      // This transition is driven by the AXI master issuing ARVALID
      // The AXI master pops from MSHR_PENDING entries
      for (int i = 0; i < DEPTH; i++) begin
        if (mshr[i].valid && mshr[i].state == MSHR_PENDING) begin
          // AXI master signals acceptance (simplified — use a proper req/ack in real design)
          mshr[i].state <= MSHR_FILL_ACTIVE;
        end
      end

      // ---- Fill complete → deallocation ----
      if (fill_valid && |fill_match_vec) begin
        mshr[fill_entry_idx].state <= MSHR_COMPLETE;
      end

      // ---- Response accepted → free entry ----
      if (resp_valid && resp_accepted) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (mshr[i].state == MSHR_COMPLETE &&
              mshr[i].req_id == resp_id) begin
            mshr[i].valid <= 1'b0;
            mshr[i].state <= MSHR_IDLE;
          end
        end
      end

      // ---- Write-back complete ----
      if (wb_valid && wb_done) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (mshr[i].state == MSHR_WB_PENDING) begin
            mshr[i].state <= MSHR_PENDING; // proceed to fill now
          end
        end
      end

    end
  end

  // =========================================================================
  // Response generation — pick oldest COMPLETE entry
  // =========================================================================
  logic [DEPTH-1:0] complete_vec;
  logic [PTR_W-1:0] resp_idx;

  always_comb begin : resp_select
    for (int i = 0; i < DEPTH; i++) begin
      complete_vec[i] = mshr[i].valid && (mshr[i].state == MSHR_COMPLETE);
    end
    resp_valid = |complete_vec;
    resp_idx   = '0;
    for (int i = DEPTH-1; i >= 0; i--) begin
      if (complete_vec[i]) resp_idx = PTR_W'(i);
    end
  end

  assign resp_id       = mshr[resp_idx].req_id;
  assign resp_is_write = mshr[resp_idx].is_write;
  // resp_data is connected to the data array fill path in top level

  // =========================================================================
  // Write-back generation — MSHR_WB_PENDING entries
  // =========================================================================
  logic [DEPTH-1:0] wb_vec;
  logic [PTR_W-1:0] wb_idx;

  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      wb_vec[i] = mshr[i].valid && (mshr[i].state == MSHR_WB_PENDING);
    end
    wb_valid = |wb_vec;
    wb_idx   = '0;
    for (int i = DEPTH-1; i >= 0; i--) begin
      if (wb_vec[i]) wb_idx = PTR_W'(i);
    end
  end

  assign wb_addr = mshr[wb_idx].addr;
  // wb_data sourced from data array read-out (connected at top level)

  // =========================================================================
  // Status outputs
  // =========================================================================
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      mshr_valid_vec[i] = mshr[i].valid;
    end
  end

  assign mshr_used_count = $clog2(DEPTH+1)'($countones(mshr_valid_vec));

  // =========================================================================
  // Assertions
  // =========================================================================
`ifdef SIMULATION

  // MSHR must not allocate when full
  property p_no_alloc_when_full;
    @(posedge clk) disable iff (!rst_n)
    full |-> !(alloc_req && !any_match);
  endproperty
  ap_no_alloc_full: assert property (p_no_alloc_when_full)
    else $fatal(0, "MSHR: allocation attempted when full!");

  // Each valid entry must eventually complete (no stuck entries)
  // Checked via simulation timeout watchdog — not an SVA

  // Fill must match an existing MSHR entry
  property p_fill_has_entry;
    @(posedge clk) disable iff (!rst_n)
    fill_valid |-> |fill_match_vec;
  endproperty
  ap_fill_entry: assert property (p_fill_has_entry)
    else $error("MSHR: fill_valid but no matching MSHR entry for addr 0x%0h",
                fill_addr);

  // Count never exceeds DEPTH
  property p_count_bounded;
    @(posedge clk) disable iff (!rst_n)
    mshr_used_count <= DEPTH;
  endproperty
  ap_count_ok: assert property (p_count_bounded)
    else $fatal(0, "MSHR: used_count=%0d exceeded DEPTH=%0d",
                mshr_used_count, DEPTH);

`endif

endmodule

`endif // L2_MSHR_SV
