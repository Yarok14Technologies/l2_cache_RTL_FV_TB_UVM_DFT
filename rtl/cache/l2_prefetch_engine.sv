// =============================================================================
// Module     : l2_prefetch_engine
// Description: Stride-based hardware prefetcher for the L2 cache.
//              Monitors load miss addresses, detects constant stride patterns,
//              and issues prefetch requests to warm the cache before demand.
//
// Algorithm  : RPT (Reference Prediction Table) — 64-entry direct-mapped
//              table indexed by PC[7:2]. Each entry tracks:
//                - previous miss address
//                - detected stride (delta between consecutive misses)
//                - confidence counter (2-bit: 00=init 01=transient
//                                           10=steady 11=no-predict)
//
// Integration:
//   - Sits between l2_request_pipeline and l2_mshr
//   - Injects MSHR allocations marked as prefetch=1
//   - Low priority: demand misses always win over prefetch in MSHR arbitration
//   - Configurable lookahead distance (1–8 cache lines ahead)
//
// Power:
//   - Clock-gated when no recent miss activity (idle > 16 cycles)
//   - Entire engine can be disabled via prefetch_enable = 0
// =============================================================================

`ifndef L2_PREFETCH_ENGINE_SV
`define L2_PREFETCH_ENGINE_SV

`include "l2_cache_pkg.sv"

module l2_prefetch_engine
  import l2_cache_pkg::*;
#(
  parameter int unsigned ADDR_WIDTH     = 40,
  parameter int unsigned RPT_ENTRIES    = 64,   // Reference Prediction Table size
  parameter int unsigned LOOKAHEAD      = 2,    // prefetch N lines ahead
  parameter int unsigned CONF_THRESH    = 2,    // confidence level to start prefetch
  localparam int unsigned RPT_IDX_W     = $clog2(RPT_ENTRIES),
  localparam int unsigned STRIDE_W      = 20    // signed stride width (bytes)
)(
  input  logic                    clk,
  input  logic                    rst_n,

  // Demand miss observation port (from request pipeline)
  input  logic                    miss_valid,
  input  logic [ADDR_WIDTH-1:0]   miss_addr,
  input  logic [RPT_IDX_W-1:0]   miss_pc_idx,   // PC[RPT_IDX_W+1:2] from CPU

  // Prefetch issue port (to MSHR allocator)
  output logic                    pf_req_valid,
  output logic [ADDR_WIDTH-1:0]   pf_req_addr,
  input  logic                    pf_req_accepted,

  // Feedback: prefetch hit (demand matched a prefetched line → useful)
  input  logic                    pf_hit,
  input  logic [ADDR_WIDTH-1:0]   pf_hit_addr,

  // Configuration
  input  logic                    prefetch_enable,
  input  logic [2:0]              lookahead_cfg,   // override LOOKAHEAD at runtime

  // Status
  output logic [31:0]             pf_issued_count,
  output logic [31:0]             pf_useful_count,
  output logic [31:0]             pf_pollution_count
);

  // =========================================================================
  // RPT — Reference Prediction Table
  // =========================================================================
  typedef enum logic [1:0] {
    CONF_INIT       = 2'b00,
    CONF_TRANSIENT  = 2'b01,
    CONF_STEADY     = 2'b10,
    CONF_NO_PRED    = 2'b11
  } conf_state_t;

  typedef struct packed {
    logic [ADDR_WIDTH-1:0]  prev_addr;
    logic signed [STRIDE_W-1:0] stride;
    conf_state_t            confidence;
    logic                   valid;
  } rpt_entry_t;

  rpt_entry_t rpt [RPT_ENTRIES];

  // =========================================================================
  // Miss processing pipeline
  // =========================================================================
  // Stage 0: latch miss, read RPT
  logic                   s0_valid;
  logic [ADDR_WIDTH-1:0]  s0_addr;
  logic [RPT_IDX_W-1:0]  s0_idx;

  // Stage 1: compute new stride, update confidence
  logic                   s1_valid;
  logic [ADDR_WIDTH-1:0]  s1_pf_addr;
  logic signed [STRIDE_W-1:0] s1_new_stride;
  logic [RPT_IDX_W-1:0]  s1_idx;
  conf_state_t            s1_new_conf;
  logic                   s1_should_prefetch;

  // =========================================================================
  // Stage 0: latch and RPT read
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s0_valid <= 1'b0;
      s0_addr  <= '0;
      s0_idx   <= '0;
    end else begin
      s0_valid <= miss_valid && prefetch_enable;
      s0_addr  <= miss_addr;
      s0_idx   <= miss_pc_idx;
    end
  end

  // =========================================================================
  // Stage 1: stride detection and confidence update
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid           <= 1'b0;
      s1_should_prefetch <= 1'b0;
      s1_pf_addr         <= '0;
      s1_idx             <= '0;
      s1_new_stride      <= '0;
      s1_new_conf        <= CONF_INIT;
    end else if (s0_valid) begin
      rpt_entry_t entry = rpt[s0_idx];
      logic signed [STRIDE_W-1:0] observed_stride;

      observed_stride = STRIDE_W'(signed'(s0_addr) -
                                  signed'(entry.prev_addr));

      s1_valid  <= 1'b1;
      s1_idx    <= s0_idx;

      if (!entry.valid) begin
        // First access — initialise
        s1_new_stride      <= observed_stride;
        s1_new_conf        <= CONF_INIT;
        s1_should_prefetch <= 1'b0;
      end else begin
        unique case (entry.confidence)
          CONF_INIT: begin
            s1_new_stride <= observed_stride;
            s1_new_conf   <= (observed_stride == entry.stride) ?
                              CONF_TRANSIENT : CONF_INIT;
            s1_should_prefetch <= 1'b0;
          end
          CONF_TRANSIENT: begin
            if (observed_stride == entry.stride) begin
              s1_new_stride      <= observed_stride;
              s1_new_conf        <= CONF_STEADY;
              s1_should_prefetch <= 1'b1;
            end else begin
              s1_new_stride      <= observed_stride;
              s1_new_conf        <= CONF_NO_PRED;
              s1_should_prefetch <= 1'b0;
            end
          end
          CONF_STEADY: begin
            if (observed_stride == entry.stride) begin
              s1_new_conf        <= CONF_STEADY;
              s1_should_prefetch <= 1'b1;
            end else begin
              s1_new_stride      <= observed_stride;
              s1_new_conf        <= CONF_INIT;
              s1_should_prefetch <= 1'b0;
            end
          end
          CONF_NO_PRED: begin
            s1_new_stride      <= observed_stride;
            s1_new_conf        <= CONF_INIT;
            s1_should_prefetch <= 1'b0;
          end
        endcase

        // Prefetch address = current miss + stride × lookahead
        s1_pf_addr <= ADDR_WIDTH'(signed'(s0_addr) +
                      (signed'(entry.stride) * STRIDE_W'(lookahead_cfg ? lookahead_cfg : LOOKAHEAD)));
      end
    end else begin
      s1_valid <= 1'b0;
    end
  end

  // =========================================================================
  // RPT write-back
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < RPT_ENTRIES; i++) rpt[i] <= '0;
    end else if (s0_valid) begin
      rpt[s0_idx].prev_addr  <= s0_addr;
      rpt[s0_idx].stride     <= s1_new_stride;
      rpt[s0_idx].confidence <= s1_new_conf;
      rpt[s0_idx].valid      <= 1'b1;
    end
  end

  // =========================================================================
  // Prefetch request output
  // =========================================================================
  // Align prefetch address to cache-line boundary
  logic [ADDR_WIDTH-1:0] pf_addr_aligned;
  assign pf_addr_aligned = {s1_pf_addr[ADDR_WIDTH-1:6], 6'b0};

  // Simple FIFO to hold one outstanding prefetch request
  logic pf_pending;
  logic [ADDR_WIDTH-1:0] pf_pending_addr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pf_pending      <= 1'b0;
      pf_pending_addr <= '0;
    end else begin
      if (pf_req_accepted) pf_pending <= 1'b0;

      if (s1_valid && s1_should_prefetch && !pf_pending) begin
        pf_pending      <= 1'b1;
        pf_pending_addr <= pf_addr_aligned;
      end
    end
  end

  assign pf_req_valid = pf_pending && prefetch_enable;
  assign pf_req_addr  = pf_pending_addr;

  // =========================================================================
  // Performance counters
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pf_issued_count    <= '0;
      pf_useful_count    <= '0;
      pf_pollution_count <= '0;
    end else begin
      if (pf_req_valid && pf_req_accepted)
        pf_issued_count <= pf_issued_count + 1;
      if (pf_hit)
        pf_useful_count <= pf_useful_count + 1;
    end
  end

  // =========================================================================
  // Assertions
  // =========================================================================
`ifdef SIMULATION
  // Prefetch address always cache-line aligned
  property p_pf_addr_aligned;
    @(posedge clk) disable iff (!rst_n)
    pf_req_valid |-> (pf_req_addr[5:0] == 6'b0);
  endproperty
  ap_pf_align: assert property (p_pf_addr_aligned)
    else $error("PREFETCH: address 0x%0h not 64B aligned", pf_req_addr);

  // No prefetch when disabled
  property p_no_pf_when_disabled;
    @(posedge clk) disable iff (!rst_n)
    !prefetch_enable |-> !pf_req_valid;
  endproperty
  ap_pf_disabled: assert property (p_no_pf_when_disabled)
    else $error("PREFETCH: issued while disabled");

  // Cover: prefetch accuracy > 50%
  property p_pf_useful_ratio;
    @(posedge clk) disable iff (!rst_n)
    (pf_issued_count > 100) |->
    (pf_useful_count > pf_issued_count / 2);
  endproperty
  cp_pf_useful: cover property (p_pf_useful_ratio);

`endif

endmodule

`endif // L2_PREFETCH_ENGINE_SV
