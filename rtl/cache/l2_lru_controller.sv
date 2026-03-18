// =============================================================================
// Module     : l2_lru_controller
// Description: Pseudo-LRU (PLRU) replacement policy controller.
//              Uses binary tree encoding. Supports 2/4/8/16 ways.
//              Per-set state stored in flop array (not SRAM) for O(1) reset.
// =============================================================================

`ifndef L2_LRU_CONTROLLER_SV
`define L2_LRU_CONTROLLER_SV

`include "l2_cache_pkg.sv"

module l2_lru_controller
  import l2_cache_pkg::*;
#(
  parameter int unsigned NUM_SETS = 512,
  parameter int unsigned WAYS     = 4,

  localparam int unsigned IDX_W   = $clog2(NUM_SETS),
  localparam int unsigned WAY_W   = $clog2(WAYS),
  localparam int unsigned LRU_W   = WAYS - 1  // PLRU tree bits per set
)(
  input  logic              clk,
  input  logic              rst_n,

  // Update port — on every cache access
  input  logic              access_valid,
  input  logic [IDX_W-1:0]  access_set,
  input  logic [WAY_W-1:0]  access_way,

  // Read port — query victim way for eviction
  input  logic [IDX_W-1:0]  victim_set,
  output logic [WAY_W-1:0]  victim_way,

  // Full LRU state array (read by tag array on flush)
  output logic [LRU_W-1:0]  lru_state [NUM_SETS]
);

  // =========================================================================
  // PLRU state register array
  // Reset all to 0 in one cycle via synchronous clear
  // =========================================================================
  logic [LRU_W-1:0] plru_reg [NUM_SETS];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NUM_SETS; i++) begin
        plru_reg[i] <= '0;
      end
    end else if (access_valid) begin
      plru_reg[access_set] <= plru_update(plru_reg[access_set], access_way);
    end
  end

  assign lru_state = plru_reg;

  // =========================================================================
  // Victim selection — combinational
  // =========================================================================
  assign victim_way = plru_victim(plru_reg[victim_set]);

  // =========================================================================
  // Functions: PLRU update and victim selection
  // Parameterized for WAYS = 2, 4, 8, 16
  // =========================================================================

  function automatic logic [LRU_W-1:0] plru_update (
    input logic [LRU_W-1:0]  state,
    input logic [WAY_W-1:0]  way
  );
    logic [LRU_W-1:0] s;
    s = state;

    unique case (WAYS)
      2: begin
        // 1-bit tree: bit points to LRU
        s[0] = ~way[0];
      end
      4: begin
        // 3-bit tree: [2]=root, [1]=left subtree, [0]=right subtree
        case (way[1:0])
          2'd0: begin s[2] = 1'b1; s[1] = 1'b1; end
          2'd1: begin s[2] = 1'b1; s[1] = 1'b0; end
          2'd2: begin s[2] = 1'b0; s[0] = 1'b1; end
          2'd3: begin s[2] = 1'b0; s[0] = 1'b0; end
          default: ;
        endcase
      end
      8: begin
        // 7-bit tree: node indices match binary tree positions
        // Level 0 (root): [6]
        // Level 1: [5][4]
        // Level 2: [3][2][1][0]
        s[6] = way[2];
        if (!way[2]) s[5] = way[1];
        else         s[4] = way[1];
        case (way[2:0])
          3'd0: s[3] = 1'b1;
          3'd1: s[3] = 1'b0;
          3'd2: s[2] = 1'b1;
          3'd3: s[2] = 1'b0;
          3'd4: s[1] = 1'b1;
          3'd5: s[1] = 1'b0;
          3'd6: s[0] = 1'b1;
          3'd7: s[0] = 1'b0;
          default: ;
        endcase
      end
      default: s = state; // unsupported — no change
    endcase

    return s;
  endfunction

  function automatic logic [WAY_W-1:0] plru_victim (
    input logic [LRU_W-1:0] state
  );
    logic [WAY_W-1:0] v;
    v = '0;

    unique case (WAYS)
      2: v = state[0] ? WAY_W'(0) : WAY_W'(1);
      4: begin
        if (!state[2])
          v = state[1] ? WAY_W'(0) : WAY_W'(1);
        else
          v = state[0] ? WAY_W'(2) : WAY_W'(3);
      end
      8: begin
        logic l0, l1, l2;
        l0 = state[6];
        l1 = l0 ? state[4] : state[5];
        if (!l0 && !l1) begin
          l2 = state[3];
          v  = l2 ? WAY_W'(0) : WAY_W'(1);
        end else if (!l0 && l1) begin
          l2 = state[2];
          v  = l2 ? WAY_W'(2) : WAY_W'(3);
        end else if (l0 && !l1) begin
          l2 = state[1];
          v  = l2 ? WAY_W'(4) : WAY_W'(5);
        end else begin
          l2 = state[0];
          v  = l2 ? WAY_W'(6) : WAY_W'(7);
        end
      end
      default: v = '0;
    endcase

    return v;
  endfunction

endmodule

`endif // L2_LRU_CONTROLLER_SV
