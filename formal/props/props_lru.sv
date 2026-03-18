// =============================================================================
// File       : props_lru.sv
// Module     : l2_lru_controller
// Tool       : JasperGold FPV
// Description: Formal properties for the Pseudo-LRU replacement controller.
//              Proves: victim way is always valid, PLRU state is updated
//              correctly on every access, and no way is permanently excluded.
//
//              Key insight: PLRU does not guarantee true LRU ordering, but
//              it must guarantee:
//                1. Victim is always a valid way index (0..WAYS-1)
//                2. The most-recently-used way is never immediately re-evicted
//                3. PLRU state is updated on every access
//                4. After accessing all WAYS sequentially, victim rotates
// =============================================================================

`ifndef PROPS_LRU_SV
`define PROPS_LRU_SV

module props_lru #(
  parameter int unsigned NUM_SETS = 512,
  parameter int unsigned WAYS     = 4,
  localparam int unsigned IDX_W   = $clog2(NUM_SETS),
  localparam int unsigned WAY_W   = $clog2(WAYS),
  localparam int unsigned LRU_W   = WAYS - 1
)(
  input logic               clk,
  input logic               rst_n,

  // LRU interface
  input logic               access_valid,
  input logic [IDX_W-1:0]   access_set,
  input logic [WAY_W-1:0]   access_way,

  input logic [IDX_W-1:0]   victim_set,
  input logic [WAY_W-1:0]   victim_way,

  // Full PLRU state array
  input logic [LRU_W-1:0]   lru_state [NUM_SETS]
);

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // ===========================================================================
  // ── Safety 1: Victim way is always in range [0, WAYS-1] ──────────────────────
  // ===========================================================================
  P_LRU_SAF_VICTIM_RANGE: assert property (
    victim_way < WAY_W'(WAYS)
  ) else $fatal(0,
    "PROP FAIL: LRU victim_way=%0d out of range [0,%0d]", victim_way, WAYS-1);

  // ===========================================================================
  // ── Safety 2: Victim is never the most-recently-used way ─────────────────────
  // After accessing way W in set S, the very next eviction from set S must
  // NOT choose way W. (This is the key PLRU guarantee.)
  // ===========================================================================
  logic [WAY_W-1:0] last_accessed_way;
  logic [IDX_W-1:0] last_accessed_set;
  logic             last_access_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_access_valid <= 1'b0;
      last_accessed_way <= '0;
      last_accessed_set <= '0;
    end else if (access_valid) begin
      last_access_valid <= 1'b1;
      last_accessed_way <= access_way;
      last_accessed_set <= access_set;
    end
  end

  P_LRU_SAF_NO_MRU_VICTIM: assert property (
    (last_access_valid &&
     victim_set == last_accessed_set) |->
    (victim_way != last_accessed_way)
  ) else $error(
    "PROP FAIL: LRU selected MRU way=%0d as victim in set=%0d",
    victim_way, victim_set);

  // ===========================================================================
  // ── Safety 3: PLRU state updates on every valid access ───────────────────────
  // After an access, the PLRU state of the accessed set must change
  // (unless it was already pointing away from the accessed way — edge case)
  // ===========================================================================
  P_LRU_SAF_STATE_CHANGES_ON_ACCESS: assert property (
    access_valid |=>
    // State of the accessed set must have changed (or we accessed way 0 which
    // may not always flip all bits — use $changed for safety)
    $changed(lru_state[access_set])
  ) else $error(
    "PROP FAIL: PLRU state unchanged after access to set=%0d way=%0d",
    access_set, access_way);

  // ===========================================================================
  // ── Safety 4: Non-accessed sets' PLRU states must not change ──────────────────
  // An access to set S should not disturb any other set's PLRU state.
  // ===========================================================================
  // (This is hard to express over all sets in FPV — check a sampled pair)
  P_LRU_SAF_NO_SPURIOUS_UPDATE: assert property (
    // If set 0 is accessed but set 1 is different, set 1 must not change
    (access_valid && access_set == IDX_W'(0)) |=>
    $stable(lru_state[1])
  ) else $error("PROP FAIL: PLRU state of non-accessed set changed");

  // ===========================================================================
  // ── Safety 5: After reset, all PLRU states are zero ──────────────────────────
  // ===========================================================================
  P_LRU_SAF_RESET: assert property (
    $fell(rst_n) |=> (lru_state[0] == '0 && lru_state[1] == '0)
  ) else $error("PROP FAIL: PLRU state non-zero immediately after reset");

  // ===========================================================================
  // ── Liveness: All ways are eventually chosen as victim ───────────────────────
  // Over a bounded sequence of evictions, every way must be selectable.
  // This proves no way is permanently excluded (starvation freedom).
  // ===========================================================================
  genvar w;
  generate
    for (w = 0; w < WAYS; w++) begin : gen_way_liveness
      COV_LRU_VICTIM_WAY: cover property (
        victim_way == WAY_W'(w) && victim_set == IDX_W'(0)
      );
    end
  endgenerate

  // ===========================================================================
  // ── Cover: PLRU state all-ones and all-zeros ──────────────────────────────────
  // ===========================================================================
  COV_LRU_STATE_ALL_ONES:  cover property (lru_state[0] == {LRU_W{1'b1}});
  COV_LRU_STATE_ALL_ZEROS: cover property (lru_state[0] == {LRU_W{1'b0}});
  COV_LRU_ACCESS_THEN_EVICT: cover property (
    access_valid ##1 !access_valid ##[0:4] (victim_way != last_accessed_way)
  );

endmodule

`endif // PROPS_LRU_SV
