// =============================================================================
// Package    : l2_cache_pkg
// Project    : L2 Cache Controller — Industrial Grade RTL
// Description: Shared types, enumerations, and structs for the L2 cache
//              subsystem. Import this package in all submodules.
// =============================================================================

`ifndef L2_CACHE_PKG_SV
`define L2_CACHE_PKG_SV

package l2_cache_pkg;

  // ---------------------------------------------------------------------------
  // MESI coherency states
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    MESI_INVALID   = 2'b00,
    MESI_SHARED    = 2'b01,
    MESI_EXCLUSIVE = 2'b10,
    MESI_MODIFIED  = 2'b11
  } mesi_state_t;

  // MOESI extension (O = Owned)
  typedef enum logic [2:0] {
    MOESI_INVALID   = 3'b000,
    MOESI_SHARED    = 3'b001,
    MOESI_EXCLUSIVE = 3'b010,
    MOESI_MODIFIED  = 3'b011,
    MOESI_OWNED     = 3'b100
  } moesi_state_t;

  // ---------------------------------------------------------------------------
  // AXI snoop type encodings (AXI-ACE ACSNOOP[3:0])
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    SNOOP_READ_ONCE        = 4'b0000,
    SNOOP_READ_SHARED      = 4'b0001,
    SNOOP_READ_CLEAN       = 4'b0010,
    SNOOP_READ_NOT_SHARED  = 4'b0011,
    SNOOP_READ_UNIQUE      = 4'b0111,
    SNOOP_CLEAN_SHARED     = 4'b1000,
    SNOOP_CLEAN_INVALID    = 4'b1001,
    SNOOP_CLEAN_UNIQUE     = 4'b1011,
    SNOOP_MAKE_INVALID     = 4'b1101,
    SNOOP_DVM_COMPLETE     = 4'b1110,
    SNOOP_DVM_MESSAGE      = 4'b1111
  } ace_snoop_t;

  // ---------------------------------------------------------------------------
  // CRRESP encoding (5 bits: DataTransfer|PassDirty|Error|IsShared|WasUnique)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic was_unique;
    logic is_shared;
    logic error;
    logic pass_dirty;
    logic data_transfer;
  } cr_resp_t;

  // ---------------------------------------------------------------------------
  // MSHR (Miss Status Holding Register) entry
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    MSHR_IDLE        = 3'b000,
    MSHR_PENDING     = 3'b001,
    MSHR_FILL_ACTIVE = 3'b010,
    MSHR_WB_PENDING  = 3'b011,
    MSHR_COMPLETE    = 3'b100,
    MSHR_UPGRADE     = 3'b101
  } mshr_state_t;

  typedef struct packed {
    logic        valid;
    mshr_state_t state;
    logic [39:0] addr;      // physical address (parameterize if needed)
    logic [7:0]  req_id;
    logic        is_write;
    logic [63:0] wdata;
    logic [7:0]  wstrb;
    logic        prefetch;  // set for HW prefetch entries
  } mshr_entry_t;

  // ---------------------------------------------------------------------------
  // Cache pipeline stage type
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    PIPE_IDLE       = 3'b000,
    PIPE_TAG_LOOKUP = 3'b001,
    PIPE_HIT        = 3'b010,
    PIPE_MISS       = 3'b011,
    PIPE_FILL       = 3'b100,
    PIPE_WRITEBACK  = 3'b101
  } pipe_stage_t;

  // ---------------------------------------------------------------------------
  // Write policy
  // ---------------------------------------------------------------------------
  typedef enum logic {
    WRITE_BACK    = 1'b0,
    WRITE_THROUGH = 1'b1
  } write_policy_t;

  // ---------------------------------------------------------------------------
  // Replacement policy
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    REPLACE_LRU    = 2'b00,
    REPLACE_PLRU   = 2'b01,
    REPLACE_RANDOM = 2'b10,
    REPLACE_FIFO   = 2'b11
  } replace_policy_t;

  // ---------------------------------------------------------------------------
  // AXI transaction descriptor
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [39:0] addr;
    logic [7:0]  len;
    logic [2:0]  size;
    logic [1:0]  burst;
    logic [7:0]  id;
    logic        is_write;
  } axi_txn_t;

  // ---------------------------------------------------------------------------
  // LRU pseudo-LRU tree (for 4-way: 3 bits; for 8-way: 7 bits)
  // Encoded as binary tree where bit[N] points left (0) or right (1)
  // ---------------------------------------------------------------------------
  // Tree positions for 4-way PLRU:
  //        [2]
  //       /   \
  //     [1]   [0]
  //    / \   / \
  //   W0 W1 W2 W3
  //
  // Access to way W: flip the bits on the path from root to W
  // Evict: follow bits to find LRU leaf

  // ---------------------------------------------------------------------------
  // ECC SECDED syndrome type
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic double_error;
    logic single_error;
    logic [5:0] syndrome;
  } ecc_status_t;

  // ---------------------------------------------------------------------------
  // Flush FSM states
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    FLUSH_IDLE     = 3'b000,
    FLUSH_SCAN     = 3'b001,
    FLUSH_WRITEBACK= 3'b010,
    FLUSH_WAIT_ACK = 3'b011,
    FLUSH_DONE     = 3'b100
  } flush_state_t;

  // ---------------------------------------------------------------------------
  // Functions
  // ---------------------------------------------------------------------------

  // One-hot to binary encoder (up to 16 ways)
  function automatic logic [3:0] oh2bin (input logic [15:0] oh);
    oh2bin = '0;
    for (int i = 0; i < 16; i++) begin
      if (oh[i]) oh2bin = 4'(i);
    end
  endfunction

  // Compute PLRU victim way for 4-way cache
  function automatic logic [1:0] plru4_victim (input logic [2:0] lru_bits);
    // Follow bits: [2] selects left(0)/right(1) subtree
    //              [1] selects within left, [0] within right
    if (!lru_bits[2]) begin  // left subtree
      plru4_victim = lru_bits[1] ? 2'd0 : 2'd1;
    end else begin            // right subtree
      plru4_victim = lru_bits[0] ? 2'd2 : 2'd3;
    end
  endfunction

  // Update PLRU state after access to way W (4-way)
  function automatic logic [2:0] plru4_update (
    input logic [2:0] lru_bits,
    input logic [1:0] accessed_way
  );
    logic [2:0] updated;
    updated = lru_bits;
    case (accessed_way)
      2'd0: begin updated[2] = 1'b1; updated[1] = 1'b1; end
      2'd1: begin updated[2] = 1'b1; updated[1] = 1'b0; end
      2'd2: begin updated[2] = 1'b0; updated[0] = 1'b1; end
      2'd3: begin updated[2] = 1'b0; updated[0] = 1'b0; end
      default: updated = lru_bits;
    endcase
    return updated;
  endfunction

  // SECDED ECC generation for 64-bit data
  // Generates 8 check bits
  function automatic logic [7:0] ecc_generate (input logic [63:0] data);
    logic [7:0] parity;
    parity[0] = ^(data & 64'h5555_5555_5555_5555);
    parity[1] = ^(data & 64'h6666_6666_6666_6666);
    parity[2] = ^(data & 64'h7878_7878_7878_7878);
    parity[3] = ^(data & 64'h7F80_7F80_7F80_7F80);
    parity[4] = ^(data & 64'h7FFF_8000_7FFF_8000);
    parity[5] = ^(data & 64'h7FFF_FFFF_8000_0000);
    parity[6] = ^(data & 64'hFFFF_FFFF_FFFF_FFFF);
    parity[7] = ^{parity[6:0], data};
    return parity;
  endfunction

endpackage

`endif // L2_CACHE_PKG_SV
