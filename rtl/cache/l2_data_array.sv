// =============================================================================
// Module     : l2_data_array
// Description: Multi-bank data SRAM array for the L2 cache.
//              Organized as NUM_BANKS independent SRAM macros.
//              Each bank covers a subset of sets.
//              ECC: SECDED per 64-bit word (8 checkbits stored alongside data).
//              Supports: read hit, write hit (partial word with WSTRB),
//                        fill (full cache line write), and power-down.
//
// Bank selection:  bank = set_index[BANK_BITS-1:0]
// Within-bank idx: set_index[INDEX_BITS-1:BANK_BITS]
//
// Simulation model: behavioral SRAM (synthesis replaces with macro instances)
// =============================================================================

`ifndef L2_DATA_ARRAY_SV
`define L2_DATA_ARRAY_SV

`include "l2_cache_pkg.sv"

module l2_data_array
  import l2_cache_pkg::*;
#(
  parameter int unsigned NUM_SETS      = 512,
  parameter int unsigned WAYS          = 4,
  parameter int unsigned DATA_WIDTH    = 64,   // bits per word
  parameter int unsigned WORDS_PER_LINE= 8,    // 8 × 64b = 64B line
  parameter int unsigned NUM_BANKS     = 4,
  parameter int unsigned ECC_BITS      = 8,    // SECDED for 64-bit

  localparam int unsigned IDX_W      = $clog2(NUM_SETS),
  localparam int unsigned WAY_W      = $clog2(WAYS),
  localparam int unsigned WORD_W     = $clog2(WORDS_PER_LINE),
  localparam int unsigned BANK_BITS  = $clog2(NUM_BANKS),
  localparam int unsigned BANK_SETS  = NUM_SETS / NUM_BANKS,
  localparam int unsigned BIDX_W     = $clog2(BANK_SETS),
  localparam int unsigned STRB_W     = DATA_WIDTH / 8,
  localparam int unsigned STORED_W   = DATA_WIDTH + ECC_BITS  // 72 bits
)(
  input  logic              clk,
  input  logic              rst_n,

  // -------------------------------------------------------------------------
  // Read port — main pipeline (hit path)
  // -------------------------------------------------------------------------
  input  logic [IDX_W-1:0]  rd_index,
  input  logic [WAY_W-1:0]  rd_way,
  input  logic [WORD_W-1:0] rd_word_sel,    // which word within line
  input  logic              rd_en,
  output logic [DATA_WIDTH-1:0] rd_data,
  output ecc_status_t       rd_ecc_status,  // single/double error flags

  // -------------------------------------------------------------------------
  // Write port — hit path (partial word update)
  // -------------------------------------------------------------------------
  input  logic [IDX_W-1:0]  wr_index,
  input  logic [WAY_W-1:0]  wr_way,
  input  logic [WORD_W-1:0] wr_word_sel,
  input  logic [DATA_WIDTH-1:0] wr_data,
  input  logic [STRB_W-1:0] wr_strb,        // byte enables
  input  logic              wr_en,

  // -------------------------------------------------------------------------
  // Fill port — full cache line write (on miss fill)
  // -------------------------------------------------------------------------
  input  logic              fill_en,
  input  logic [IDX_W-1:0]  fill_index,
  input  logic [WAY_W-1:0]  fill_way,
  input  logic [DATA_WIDTH-1:0] fill_data [WORDS_PER_LINE],

  // -------------------------------------------------------------------------
  // Snoop read port — for dirty data forwarding on coherency
  // -------------------------------------------------------------------------
  input  logic [IDX_W-1:0]  snoop_rd_index,
  input  logic [WAY_W-1:0]  snoop_rd_way,
  input  logic              snoop_rd_en,
  output logic [DATA_WIDTH-1:0] snoop_rd_data [WORDS_PER_LINE],

  // -------------------------------------------------------------------------
  // Power management
  // -------------------------------------------------------------------------
  input  logic              power_down       // tri-state SRAM outputs when gated
);

  // =========================================================================
  // Behavioral SRAM model
  // In synthesis: replace with SRAM macro instances (e.g., ts1n28hpchb)
  // Each SRAM is: BANK_SETS × WAYS × WORDS_PER_LINE addresses × STORED_W bits
  // Flattened as: addr = {way, word_sel, set_within_bank}
  // =========================================================================

  localparam int unsigned SRAM_DEPTH = BANK_SETS * WAYS * WORDS_PER_LINE;
  localparam int unsigned SRAM_AW    = $clog2(SRAM_DEPTH);

  // Behavioral SRAM storage (synthesis replaces with macros)
  logic [STORED_W-1:0] sram [NUM_BANKS][SRAM_DEPTH];

  // =========================================================================
  // Address formation helpers
  // =========================================================================
  function automatic logic [BANK_BITS-1:0] get_bank (
    input logic [IDX_W-1:0] set_idx
  );
    return set_idx[BANK_BITS-1:0];
  endfunction

  function automatic logic [SRAM_AW-1:0] get_sram_addr (
    input logic [IDX_W-1:0] set_idx,
    input logic [WAY_W-1:0] way,
    input logic [WORD_W-1:0] word
  );
    logic [BIDX_W-1:0] bank_set;
    bank_set = set_idx[IDX_W-1:BANK_BITS];
    return {way, word, bank_set};
  endfunction

  // =========================================================================
  // ECC helpers (from package)
  // =========================================================================
  function automatic logic [STORED_W-1:0] ecc_encode_word (
    input logic [DATA_WIDTH-1:0] data
  );
    logic [ECC_BITS-1:0] check;
    check = ecc_generate(data);
    return {check, data};
  endfunction

  function automatic ecc_status_t ecc_check_word (
    input logic [STORED_W-1:0] stored
  );
    ecc_status_t status;
    logic [DATA_WIDTH-1:0] data;
    logic [ECC_BITS-1:0]   stored_check, calc_check;
    logic [ECC_BITS-1:0]   syndrome;
    data         = stored[DATA_WIDTH-1:0];
    stored_check = stored[STORED_W-1:DATA_WIDTH];
    calc_check   = ecc_generate(data);
    syndrome     = stored_check ^ calc_check;
    status.syndrome      = syndrome[5:0];
    status.single_error  = (syndrome != '0) && stored[STORED_W-1]; // overall parity
    status.double_error  = (syndrome != '0) && !stored[STORED_W-1];
    return status;
  endfunction

  // =========================================================================
  // Write hit path — merge partial word with WSTRB
  // =========================================================================
  logic [DATA_WIDTH-1:0]  wr_merged_data;
  logic [SRAM_AW-1:0]     wr_sram_addr;
  logic [BANK_BITS-1:0]   wr_bank;

  always_comb begin : wr_merge
    logic [STORED_W-1:0] existing;
    wr_bank      = get_bank(wr_index);
    wr_sram_addr = get_sram_addr(wr_index, wr_way, wr_word_sel);
    existing     = sram[wr_bank][wr_sram_addr];
    wr_merged_data = existing[DATA_WIDTH-1:0];
    for (int b = 0; b < STRB_W; b++) begin
      if (wr_strb[b]) begin
        wr_merged_data[b*8 +: 8] = wr_data[b*8 +: 8];
      end
    end
  end

  // =========================================================================
  // Write sequencer — fill has higher priority over hit write
  // =========================================================================
  always_ff @(posedge clk) begin : sram_write
    // Fill: write all words of a cache line
    if (fill_en) begin
      for (int w = 0; w < WORDS_PER_LINE; w++) begin
        automatic logic [BANK_BITS-1:0] fb = get_bank(fill_index);
        automatic logic [SRAM_AW-1:0]  fa = get_sram_addr(fill_index,
                                              fill_way, WORD_W'(w));
        sram[fb][fa] <= ecc_encode_word(fill_data[w]);
      end
    end
    // Hit write (lower priority than fill)
    else if (wr_en) begin
      sram[wr_bank][wr_sram_addr] <= ecc_encode_word(wr_merged_data);
    end
  end

  // =========================================================================
  // Read hit path — registered output
  // =========================================================================
  logic [STORED_W-1:0]    rd_stored;
  logic [DATA_WIDTH-1:0]  rd_data_raw;
  ecc_status_t            rd_ecc_raw;

  always_ff @(posedge clk or negedge rst_n) begin : sram_read
    if (!rst_n) begin
      rd_stored <= '0;
    end else if (rd_en && !power_down) begin
      rd_stored <= sram[get_bank(rd_index)]
                      [get_sram_addr(rd_index, rd_way, rd_word_sel)];
    end
  end

  assign rd_data_raw  = rd_stored[DATA_WIDTH-1:0];
  assign rd_ecc_raw   = ecc_check_word(rd_stored);

  // ECC correction — single-bit error: correct; double-bit error: flag
  always_comb begin : ecc_correct
    rd_data       = rd_data_raw;
    rd_ecc_status = rd_ecc_raw;
    if (rd_ecc_raw.single_error) begin
      // Flip the erroneous bit (syndrome points to bit position)
      rd_data[rd_ecc_raw.syndrome] = ~rd_data_raw[rd_ecc_raw.syndrome];
    end
    // Double error: data is unreliable — AXI response will carry SLVERR
  end

  // =========================================================================
  // Snoop read port — full cache line, combinational (or 1-cycle registered)
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin : snoop_read
    if (!rst_n) begin
      for (int w = 0; w < WORDS_PER_LINE; w++)
        snoop_rd_data[w] <= '0;
    end else if (snoop_rd_en && !power_down) begin
      for (int w = 0; w < WORDS_PER_LINE; w++) begin
        snoop_rd_data[w] <=
          sram[get_bank(snoop_rd_index)]
             [get_sram_addr(snoop_rd_index, snoop_rd_way, WORD_W'(w))]
             [DATA_WIDTH-1:0];
      end
    end
  end

  // =========================================================================
  // Assertions
  // =========================================================================
`ifdef SIMULATION

  // Simultaneous fill and hit-write to same address is illegal
  property p_no_fill_and_wr_conflict;
    @(posedge clk) disable iff (!rst_n)
    (fill_en && wr_en) |->
    !((fill_index == wr_index) && (fill_way == wr_way));
  endproperty
  ap_no_conflict: assert property (p_no_fill_and_wr_conflict)
    else $error("DATA ARRAY: simultaneous fill and hit-write to same set/way");

  // ECC double error should generate an alert
  property p_ecc_double_error_alert;
    @(posedge clk) disable iff (!rst_n)
    rd_ecc_status.double_error |->
    ##[0:2] 1'b1;  // placeholder — real design would signal interrupt
  endproperty

  // Power-down: read should not produce valid data
  property p_no_read_while_powered_down;
    @(posedge clk) disable iff (!rst_n)
    (rd_en && power_down) |=> (rd_data === '0 || rd_data === 'x);
  endproperty

`endif

endmodule

`endif // L2_DATA_ARRAY_SV
