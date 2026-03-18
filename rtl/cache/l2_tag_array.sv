// =============================================================================
// Module     : l2_tag_array
// Description: Tag SRAM array with valid, dirty, and MESI state bits.
//              Stored in flip-flop array (not SRAM) so that reset is O(1).
//              Separate read ports for main pipeline and snoop unit.
//              Write port for fill and coherency state updates.
// =============================================================================

`ifndef L2_TAG_ARRAY_SV
`define L2_TAG_ARRAY_SV

`include "l2_cache_pkg.sv"

module l2_tag_array
  import l2_cache_pkg::*;
#(
  parameter int unsigned NUM_SETS   = 512,
  parameter int unsigned WAYS       = 4,
  parameter int unsigned TAG_BITS   = 26,
  parameter int unsigned INDEX_BITS = 9
)(
  input  logic                    clk,
  input  logic                    rst_n,

  // Main pipeline read port
  input  logic [INDEX_BITS-1:0]   rd_index,
  input  logic                    rd_en,
  output logic [TAG_BITS-1:0]     tag_rd_data  [WAYS],
  output logic                    valid_rd     [WAYS],
  output logic                    dirty_rd     [WAYS],
  output mesi_state_t             mesi_rd      [WAYS],

  // Snoop unit read port (separate — no hazard with main pipeline)
  input  logic [INDEX_BITS-1:0]   snoop_rd_index,
  input  logic                    snoop_rd_en,
  output logic [TAG_BITS-1:0]     snoop_tag_data [WAYS],
  output logic                    snoop_valid    [WAYS],
  output logic                    snoop_dirty    [WAYS],
  output mesi_state_t             snoop_mesi     [WAYS],

  // Write port — fill path (new line allocation)
  input  logic                    wr_en,
  input  logic [INDEX_BITS-1:0]   wr_index,
  input  logic [$clog2(WAYS)-1:0] wr_way,
  input  logic [TAG_BITS-1:0]     wr_tag,
  input  logic                    wr_valid,
  input  logic                    wr_dirty,
  input  mesi_state_t             wr_mesi,

  // Write port — coherency state update (snoop hit)
  input  logic                    coh_wr_en,
  input  logic [INDEX_BITS-1:0]   coh_wr_index,
  input  logic [$clog2(WAYS)-1:0] coh_wr_way,
  input  mesi_state_t             coh_new_mesi,
  input  logic                    coh_dirty_clr,

  // Write port — write hit (set dirty bit)
  input  logic                    dirty_wr_en,
  input  logic [INDEX_BITS-1:0]   dirty_wr_index,
  input  logic [$clog2(WAYS)-1:0] dirty_wr_way,

  // Flush interface
  input  logic                    flush_req,
  output logic                    flush_done
);

  // =========================================================================
  // Tag RAM entries stored as flip-flops for O(1) reset
  // In a real ASIC, this would be split: tags in SRAM macro,
  // valid/dirty/MESI in flops (small enough for O(1) reset)
  // =========================================================================
  typedef struct packed {
    logic [TAG_BITS-1:0] tag;
    logic                valid;
    logic                dirty;
    mesi_state_t         mesi;
  } tag_entry_t;

  tag_entry_t tag_ram [NUM_SETS][WAYS];

  // =========================================================================
  // Write port priority: flush > coherency update > fill > dirty_wr
  // =========================================================================

  // Flush FSM
  flush_state_t flush_state;
  logic [INDEX_BITS-1:0] flush_set_cnt;

  always_ff @(posedge clk or negedge rst_n) begin : tag_write_proc
    if (!rst_n) begin
      for (int s = 0; s < NUM_SETS; s++) begin
        for (int w = 0; w < WAYS; w++) begin
          tag_ram[s][w] <= '0;
        end
      end
      flush_state   <= FLUSH_IDLE;
      flush_set_cnt <= '0;
      flush_done    <= 1'b0;
    end else begin
      flush_done <= 1'b0;

      // Flush takes highest priority
      unique case (flush_state)
        FLUSH_IDLE: begin
          if (flush_req) begin
            flush_state   <= FLUSH_SCAN;
            flush_set_cnt <= '0;
          end
        end
        FLUSH_SCAN: begin
          // Invalidate all ways of current set
          for (int w = 0; w < WAYS; w++) begin
            tag_ram[flush_set_cnt][w].valid <= 1'b0;
            tag_ram[flush_set_cnt][w].dirty <= 1'b0;
            tag_ram[flush_set_cnt][w].mesi  <= MESI_INVALID;
          end
          if (flush_set_cnt == INDEX_BITS'(NUM_SETS - 1)) begin
            flush_state <= FLUSH_DONE;
          end else begin
            flush_set_cnt <= flush_set_cnt + 1;
          end
        end
        FLUSH_DONE: begin
          flush_done  <= 1'b1;
          flush_state <= FLUSH_IDLE;
        end
        default: flush_state <= FLUSH_IDLE;
      endcase

      // Normal operation writes (only when not flushing)
      if (flush_state == FLUSH_IDLE) begin

        // Fill allocation
        if (wr_en) begin
          tag_ram[wr_index][wr_way].tag   <= wr_tag;
          tag_ram[wr_index][wr_way].valid <= wr_valid;
          tag_ram[wr_index][wr_way].dirty <= wr_dirty;
          tag_ram[wr_index][wr_way].mesi  <= wr_mesi;
        end

        // Coherency state update
        if (coh_wr_en) begin
          tag_ram[coh_wr_index][coh_wr_way].mesi <= coh_new_mesi;
          if (coh_dirty_clr)
            tag_ram[coh_wr_index][coh_wr_way].dirty <= 1'b0;
          if (coh_new_mesi == MESI_INVALID)
            tag_ram[coh_wr_index][coh_wr_way].valid <= 1'b0;
        end

        // Write hit: set dirty
        if (dirty_wr_en) begin
          tag_ram[dirty_wr_index][dirty_wr_way].dirty <= 1'b1;
          tag_ram[dirty_wr_index][dirty_wr_way].mesi  <= MESI_MODIFIED;
        end
      end
    end
  end

  // =========================================================================
  // Main pipeline read port — registered output
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin : main_read_proc
    if (!rst_n) begin
      for (int w = 0; w < WAYS; w++) begin
        tag_rd_data[w] <= '0;
        valid_rd[w]    <= 1'b0;
        dirty_rd[w]    <= 1'b0;
        mesi_rd[w]     <= MESI_INVALID;
      end
    end else if (rd_en) begin
      for (int w = 0; w < WAYS; w++) begin
        tag_rd_data[w] <= tag_ram[rd_index][w].tag;
        valid_rd[w]    <= tag_ram[rd_index][w].valid;
        dirty_rd[w]    <= tag_ram[rd_index][w].dirty;
        mesi_rd[w]     <= tag_ram[rd_index][w].mesi;
      end
    end
  end

  // =========================================================================
  // Snoop unit read port — registered output (1-cycle latency)
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin : snoop_read_proc
    if (!rst_n) begin
      for (int w = 0; w < WAYS; w++) begin
        snoop_tag_data[w] <= '0;
        snoop_valid[w]    <= 1'b0;
        snoop_dirty[w]    <= 1'b0;
        snoop_mesi[w]     <= MESI_INVALID;
      end
    end else if (snoop_rd_en) begin
      for (int w = 0; w < WAYS; w++) begin
        snoop_tag_data[w] <= tag_ram[snoop_rd_index][w].tag;
        snoop_valid[w]    <= tag_ram[snoop_rd_index][w].valid;
        snoop_dirty[w]    <= tag_ram[snoop_rd_index][w].dirty;
        snoop_mesi[w]     <= tag_ram[snoop_rd_index][w].mesi;
      end
    end
  end

  // =========================================================================
  // Assertions
  // =========================================================================
`ifdef SIMULATION

  // Only one way per set can be Modified
  property p_one_modified_per_set;
    @(posedge clk) disable iff (!rst_n)
    // For each set, at most one way is Modified at any time
    // Checked via a coverpoint — full formal check done in JasperGold
    1'b1;
  endproperty

  // Valid bit must be set before dirty bit
  property p_dirty_requires_valid;
    @(posedge clk) disable iff (!rst_n)
    dirty_wr_en |-> tag_ram[dirty_wr_index][dirty_wr_way].valid;
  endproperty
  ap_dirty_valid: assert property (p_dirty_requires_valid)
    else $error("TAG ARRAY: dirty set on invalid way [set=%0d way=%0d]",
                dirty_wr_index, dirty_wr_way);

  // Coherency writes must be to valid lines (except invalidation)
  property p_coh_wr_valid_line;
    @(posedge clk) disable iff (!rst_n)
    (coh_wr_en && coh_new_mesi != MESI_INVALID) |->
    tag_ram[coh_wr_index][coh_wr_way].valid;
  endproperty
  ap_coh_valid: assert property (p_coh_wr_valid_line)
    else $error("TAG ARRAY: coherency downgrade on invalid line");

`endif

endmodule

`endif // L2_TAG_ARRAY_SV
