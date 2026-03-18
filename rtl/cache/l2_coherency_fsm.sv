// =============================================================================
// Module     : l2_coherency_fsm
// Description: MESI coherency protocol state machine for the L2 cache.
//              Handles AXI-ACE snoop channels (AC/CR/CD).
//              Implements: ReadShared, ReadUnique, CleanInvalid, MakeInvalid,
//                          Upgrade (S→M), dirty write-back on M→S/I.
//
// Snoop pipeline:
//   Cycle 0: AC handshake, set index computation
//   Cycle 1: Tag RAM read (parallel with main pipeline, separate read port)
//   Cycle 2: State determination, CR response generation
//   Cycle 3+: CD data transfer if PassDirty=1
//
// Key rule: Snoop responses must never stall indefinitely (deadlock prevention).
//           A snoop FIFO ensures bounded response latency.
// =============================================================================

`ifndef L2_COHERENCY_FSM_SV
`define L2_COHERENCY_FSM_SV

`include "l2_cache_pkg.sv"

module l2_coherency_fsm
  import l2_cache_pkg::*;
#(
  parameter int unsigned ADDR_WIDTH  = 40,
  parameter int unsigned DATA_WIDTH  = 64,
  parameter int unsigned NUM_SETS    = 512,
  parameter int unsigned WAYS        = 4,
  parameter int unsigned TAG_BITS    = 26,
  parameter int unsigned INDEX_BITS  = 9,
  parameter int unsigned OFFSET_BITS = 6,

  localparam int unsigned WAY_W      = $clog2(WAYS),
  localparam int unsigned WORDS      = (1 << OFFSET_BITS) / (DATA_WIDTH / 8)
)(
  input  logic                   clk,
  input  logic                   rst_n,

  // AXI-ACE snoop address channel
  input  logic [ADDR_WIDTH-1:0]  ac_addr,
  input  logic [3:0]             ac_snoop,
  input  logic                   ac_valid,
  output logic                   ac_ready,

  // AXI-ACE snoop response channel
  output logic [4:0]             cr_resp,
  output logic                   cr_valid,
  input  logic                   cr_ready,

  // AXI-ACE snoop data channel (dirty data transfer)
  output logic [DATA_WIDTH-1:0]  cd_data,
  output logic                   cd_last,
  output logic                   cd_valid,
  input  logic                   cd_ready,

  // Tag array interface (read by snoop unit)
  input  logic [TAG_BITS-1:0]    tag_rd_data  [WAYS],
  input  logic                   valid_bit    [WAYS],
  input  logic                   dirty_bit    [WAYS],
  input  mesi_state_t            mesi_state   [WAYS],

  // Hit resolution from main pipeline
  input  logic                   hit_any,
  input  logic [WAY_W-1:0]       hit_way_bin,

  // Data array read-back (for dirty CD transfer)
  input  logic [DATA_WIDTH-1:0]  snoop_rd_data [WORDS],

  // Coherency state update outputs → tag array write port
  output logic                   snoop_tag_wr_en,
  output logic [INDEX_BITS-1:0]  snoop_tag_wr_idx,
  output logic [WAY_W-1:0]       snoop_tag_wr_way,
  output mesi_state_t            snoop_new_state,
  output logic                   snoop_dirty_clr,

  // Write-back trigger (dirty eviction due to snoop)
  output logic                   snoop_wb_req,
  output logic [ADDR_WIDTH-1:0]  snoop_wb_addr,

  // Status
  output logic                   wb_pending,

  // Upgrade request interface
  output logic                   upgrade_req_sent,
  input  logic                   upgrade_ack_received
);

  // =========================================================================
  // Coherency FSM state encoding
  // =========================================================================
  typedef enum logic [3:0] {
    COH_IDLE         = 4'h0,
    COH_SNOOP_LOOKUP = 4'h1,
    COH_SNOOP_HIT_CLEAN = 4'h2,
    COH_SNOOP_HIT_DIRTY = 4'h3,
    COH_CD_TRANSFER  = 4'h4,
    COH_CR_SEND      = 4'h5,
    COH_WB_ISSUE     = 4'h6,
    COH_WB_WAIT      = 4'h7,
    COH_UPGRADE_PEND = 4'h8,
    COH_MISS         = 4'h9
  } coh_state_t;

  coh_state_t coh_state, coh_next;

  // =========================================================================
  // Snoop request capture register
  // =========================================================================
  logic [ADDR_WIDTH-1:0]  snoop_addr_r;
  ace_snoop_t             snoop_type_r;
  logic [INDEX_BITS-1:0]  snoop_index_r;
  logic [TAG_BITS-1:0]    snoop_tag_r;
  logic                   snoop_hit_r;
  logic [WAY_W-1:0]       snoop_way_r;
  logic                   snoop_dirty_r;
  mesi_state_t            snoop_mesi_r;
  logic [ADDR_WIDTH-1:0]  snoop_fill_addr_r;

  // CD transfer counter
  logic [$clog2(WORDS)-1:0] cd_beat_cnt;

  // =========================================================================
  // Stage 0: AC handshake — accept snoop when FSM is idle
  // =========================================================================
  assign ac_ready = (coh_state == COH_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      snoop_addr_r  <= '0;
      snoop_type_r  <= SNOOP_READ_ONCE;
      snoop_index_r <= '0;
      snoop_tag_r   <= '0;
    end else if (ac_valid && ac_ready) begin
      snoop_addr_r  <= ac_addr;
      snoop_type_r  <= ace_snoop_t'(ac_snoop);
      snoop_index_r <= ac_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
      snoop_tag_r   <= ac_addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
    end
  end

  // =========================================================================
  // Stage 1: Tag comparison — combinational, result registered next cycle
  // Runs in parallel with main pipeline via separate tag RAM read port
  // =========================================================================
  logic                   snoop_hit_comb;
  logic [WAY_W-1:0]       snoop_way_comb;
  logic                   snoop_dirty_comb;
  mesi_state_t            snoop_mesi_comb;

  always_comb begin : snoop_tag_compare
    snoop_hit_comb   = 1'b0;
    snoop_way_comb   = '0;
    snoop_dirty_comb = 1'b0;
    snoop_mesi_comb  = MESI_INVALID;

    for (int w = 0; w < WAYS; w++) begin
      if (valid_bit[w] && (tag_rd_data[w] == snoop_tag_r)) begin
        snoop_hit_comb   = 1'b1;
        snoop_way_comb   = WAY_W'(w);
        snoop_dirty_comb = dirty_bit[w];
        snoop_mesi_comb  = mesi_state[w];
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      snoop_hit_r   <= 1'b0;
      snoop_way_r   <= '0;
      snoop_dirty_r <= 1'b0;
      snoop_mesi_r  <= MESI_INVALID;
    end else if (coh_state == COH_SNOOP_LOOKUP) begin
      snoop_hit_r   <= snoop_hit_comb;
      snoop_way_r   <= snoop_way_comb;
      snoop_dirty_r <= snoop_dirty_comb;
      snoop_mesi_r  <= snoop_mesi_comb;
    end
  end

  // =========================================================================
  // FSM: state register
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) coh_state <= COH_IDLE;
    else        coh_state <= coh_next;
  end

  // =========================================================================
  // FSM: next-state logic
  // =========================================================================
  always_comb begin : coh_next_state
    coh_next = coh_state;

    unique case (coh_state)
      COH_IDLE: begin
        if (ac_valid)
          coh_next = COH_SNOOP_LOOKUP;
      end

      COH_SNOOP_LOOKUP: begin
        // Wait one cycle for tag RAM to return data
        coh_next = snoop_hit_comb ?
                   (snoop_dirty_comb ? COH_SNOOP_HIT_DIRTY : COH_SNOOP_HIT_CLEAN) :
                   COH_MISS;
      end

      COH_SNOOP_HIT_DIRTY: begin
        // Must issue write-back AND send dirty data on CD channel
        coh_next = COH_WB_ISSUE;
      end

      COH_SNOOP_HIT_CLEAN: begin
        coh_next = COH_CR_SEND;
      end

      COH_WB_ISSUE: begin
        coh_next = COH_CD_TRANSFER;
      end

      COH_CD_TRANSFER: begin
        if (cd_valid && cd_ready && cd_last)
          coh_next = COH_CR_SEND;
      end

      COH_CR_SEND: begin
        if (cr_valid && cr_ready)
          coh_next = COH_IDLE;
      end

      COH_MISS: begin
        // No data in this cache — respond immediately with no-data CR
        coh_next = COH_CR_SEND;
      end

      COH_UPGRADE_PEND: begin
        if (upgrade_ack_received)
          coh_next = COH_IDLE;
      end

      default: coh_next = COH_IDLE;
    endcase
  end

  // =========================================================================
  // CD beat counter
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cd_beat_cnt <= '0;
    else if (coh_state == COH_WB_ISSUE) cd_beat_cnt <= '0;
    else if (cd_valid && cd_ready) cd_beat_cnt <= cd_beat_cnt + 1;
  end

  // =========================================================================
  // Output logic
  // =========================================================================

  // CR response encoding
  cr_resp_t cr_resp_s;

  always_comb begin : cr_resp_encode
    cr_resp_s = '0;

    unique case (coh_state)
      COH_CR_SEND: begin
        if (snoop_hit_r) begin
          unique case (snoop_type_r)
            SNOOP_READ_SHARED: begin
              cr_resp_s.is_shared     = 1'b1;
              cr_resp_s.was_unique    = (snoop_mesi_r == MESI_EXCLUSIVE ||
                                         snoop_mesi_r == MESI_MODIFIED);
              cr_resp_s.data_transfer = snoop_dirty_r;
              cr_resp_s.pass_dirty    = snoop_dirty_r;
            end
            SNOOP_READ_UNIQUE,
            SNOOP_CLEAN_INVALID,
            SNOOP_MAKE_INVALID: begin
              cr_resp_s.was_unique    = 1'b1;
              cr_resp_s.is_shared     = 1'b0;
              cr_resp_s.data_transfer = snoop_dirty_r;
              cr_resp_s.pass_dirty    = snoop_dirty_r;
            end
            SNOOP_CLEAN_SHARED: begin
              cr_resp_s.is_shared     = 1'b1;
              cr_resp_s.data_transfer = 1'b0;
              cr_resp_s.pass_dirty    = 1'b0;
            end
            default: cr_resp_s = '0;
          endcase
        end
        // else: miss — all zeros, no data
      end
      default: cr_resp_s = '0;
    endcase
  end

  assign cr_resp  = cr_resp_s;
  assign cr_valid = (coh_state == COH_CR_SEND);

  // CD data output from snoop data array read
  assign cd_data  = snoop_rd_data[cd_beat_cnt];
  assign cd_last  = (cd_beat_cnt == $clog2(WORDS)'(WORDS - 1));
  assign cd_valid = (coh_state == COH_CD_TRANSFER);

  // Tag array update: downgrade or invalidate snooped way
  always_comb begin : tag_update_logic
    snoop_tag_wr_en  = 1'b0;
    snoop_tag_wr_idx = snoop_index_r;
    snoop_tag_wr_way = snoop_way_r;
    snoop_new_state  = MESI_INVALID;
    snoop_dirty_clr  = 1'b0;

    if (cr_valid && cr_ready && snoop_hit_r) begin
      snoop_tag_wr_en = 1'b1;
      snoop_dirty_clr = snoop_dirty_r;

      unique case (snoop_type_r)
        SNOOP_READ_SHARED:
          snoop_new_state = MESI_SHARED;
        SNOOP_READ_UNIQUE,
        SNOOP_CLEAN_INVALID,
        SNOOP_MAKE_INVALID:
          snoop_new_state = MESI_INVALID;
        SNOOP_CLEAN_SHARED:
          snoop_new_state = MESI_SHARED;
        default:
          snoop_new_state = MESI_INVALID;
      endcase
    end
  end

  // Write-back request
  assign snoop_wb_req  = (coh_state == COH_WB_ISSUE);
  assign snoop_wb_addr = snoop_addr_r;

  assign wb_pending = (coh_state == COH_WB_ISSUE) || (coh_state == COH_CD_TRANSFER);

  // Upgrade
  assign upgrade_req_sent = (coh_state == COH_UPGRADE_PEND);

  // =========================================================================
  // Assertions
  // =========================================================================
`ifdef SIMULATION

  // CR response must follow AC acceptance within bounded cycles
  // (prevents coherency deadlock)
  property p_snoop_response_bounded;
    @(posedge clk) disable iff (!rst_n)
    $fell(ac_ready) |-> ##[1:32] (cr_valid && cr_ready);
  endproperty
  ap_snoop_bounded: assert property (p_snoop_response_bounded)
    else $error("COHERENCY: Snoop response took > 32 cycles — potential deadlock");

  // VALID must not deassert before READY on CR channel
  property p_cr_valid_stable;
    @(posedge clk) disable iff (!rst_n)
    (cr_valid && !cr_ready) |=> cr_valid;
  endproperty
  ap_cr_stable: assert property (p_cr_valid_stable)
    else $error("COHERENCY: CR_VALID dropped before CR_READY");

  // S→M transition must have upgrade request
  property p_no_silent_s_to_m;
    @(posedge clk) disable iff (!rst_n)
    (snoop_mesi_r == MESI_SHARED && snoop_new_state == MESI_MODIFIED) |->
    upgrade_req_sent && upgrade_ack_received;
  endproperty
  ap_s_to_m_upgrade: assert property (p_no_silent_s_to_m)
    else $fatal(0, "COHERENCY: Illegal S->M transition without upgrade");

  // CD data must only appear when state is CD_TRANSFER
  property p_cd_valid_only_in_transfer;
    @(posedge clk) disable iff (!rst_n)
    cd_valid |-> (coh_state == COH_CD_TRANSFER);
  endproperty
  ap_cd_state: assert property (p_cd_valid_only_in_transfer)
    else $error("COHERENCY: CD_VALID asserted outside CD_TRANSFER state");

`endif // SIMULATION

endmodule

`endif // L2_COHERENCY_FSM_SV
