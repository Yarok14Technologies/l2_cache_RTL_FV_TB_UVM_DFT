// =============================================================================
// Module     : l2_request_pipeline
// Description: Accepts AXI4 AR (read) and AW+W (write) transactions from the
//              CPU/L1 side and feeds a unified request into the 2-stage
//              tag-lookup pipeline.  Handles:
//                - AR/AW arbitration (reads preferred to avoid starvation)
//                - Burst-to-word decomposition (len+1 beats, INCR only)
//                - WSTRB capture for write-hit partial updates
//                - Back-pressure: de-asserts ARREADY/AWREADY when MSHR is full
//
//  Stage 0  (this module output):  set_index, req_tag, offset, is_write, id …
//  Stage 1  (in l2_cache_top):     tag compare → hit/miss decision
// =============================================================================

`ifndef L2_REQUEST_PIPELINE_SV
`define L2_REQUEST_PIPELINE_SV

`include "l2_cache_pkg.sv"

module l2_request_pipeline
  import l2_cache_pkg::*;
#(
  parameter int unsigned ADDR_WIDTH  = 40,
  parameter int unsigned DATA_WIDTH  = 64,
  parameter int unsigned INDEX_BITS  = 9,
  parameter int unsigned TAG_BITS    = 25,
  parameter int unsigned OFFSET_BITS = 6,
  parameter int unsigned ID_WIDTH    = 8
)(
  input  logic                     clk,
  input  logic                     rst_n,

  // ── AXI4 Slave read address channel ───────────────────────────────────
  input  logic [ADDR_WIDTH-1:0]    s_axi_araddr,
  input  logic [7:0]               s_axi_arlen,
  input  logic [2:0]               s_axi_arsize,
  input  logic [1:0]               s_axi_arburst,
  input  logic [ID_WIDTH-1:0]      s_axi_arid,
  input  logic                     s_axi_arvalid,
  output logic                     s_axi_arready,

  // ── AXI4 Slave write address channel ──────────────────────────────────
  input  logic [ADDR_WIDTH-1:0]    s_axi_awaddr,
  input  logic [7:0]               s_axi_awlen,
  input  logic [2:0]               s_axi_awsize,
  input  logic [1:0]               s_axi_awburst,
  input  logic [ID_WIDTH-1:0]      s_axi_awid,
  input  logic                     s_axi_awvalid,
  output logic                     s_axi_awready,

  // ── AXI4 Slave write data channel ─────────────────────────────────────
  input  logic [DATA_WIDTH-1:0]    s_axi_wdata,
  input  logic [DATA_WIDTH/8-1:0]  s_axi_wstrb,
  input  logic                     s_axi_wlast,
  input  logic                     s_axi_wvalid,
  output logic                     s_axi_wready,

  // ── Pipeline stage-0 output ───────────────────────────────────────────
  output logic [INDEX_BITS-1:0]    pipe_set_index,
  output logic [TAG_BITS-1:0]      pipe_req_tag,
  output logic [OFFSET_BITS-1:0]   pipe_offset,
  output logic                     pipe_req_valid,
  output logic                     pipe_req_is_write,
  output logic [DATA_WIDTH-1:0]    pipe_req_wdata,
  output logic [DATA_WIDTH/8-1:0]  pipe_req_wstrb,
  output logic [ID_WIDTH-1:0]      pipe_req_id,

  // ── Back-pressure from MSHR ───────────────────────────────────────────
  input  logic                     mshr_full
);

  // =========================================================================
  // Arbitration FSM
  // Priority: reads preferred when both arrive simultaneously
  //           to avoid CPU instruction-fetch starvation.
  //           After N consecutive reads, one write slot is forced.
  // =========================================================================
  typedef enum logic [1:0] {
    ARB_IDLE  = 2'b00,
    ARB_READ  = 2'b01,
    ARB_WRITE = 2'b10
  } arb_state_t;

  arb_state_t arb_state;
  logic [3:0]  read_streak;    // consecutive reads granted
  localparam   MAX_STREAK = 4'd8;

  // Captured AW+W registers (write address is latched when AW accepted)
  logic [ADDR_WIDTH-1:0]   aw_addr_r;
  logic [7:0]              aw_len_r;
  logic [ID_WIDTH-1:0]     aw_id_r;
  logic                    aw_pending;  // AW accepted, waiting for W

  // Beat counter for burst decomposition
  logic [7:0]              burst_cnt;

  // =========================================================================
  // AW capture
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_pending <= 1'b0;
      aw_addr_r  <= '0;
      aw_len_r   <= '0;
      aw_id_r    <= '0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin
        aw_addr_r  <= s_axi_awaddr;
        aw_len_r   <= s_axi_awlen;
        aw_id_r    <= s_axi_awid;
        aw_pending <= 1'b1;
      end
      // Clear when write completes (last W beat accepted by pipeline)
      if (aw_pending && s_axi_wvalid && s_axi_wready && s_axi_wlast) begin
        aw_pending <= 1'b0;
      end
    end
  end

  // =========================================================================
  // Arbitration + pipeline output
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      arb_state       <= ARB_IDLE;
      read_streak     <= '0;
      burst_cnt       <= '0;
      pipe_req_valid  <= 1'b0;
      pipe_req_is_write <= 1'b0;
      pipe_set_index  <= '0;
      pipe_req_tag    <= '0;
      pipe_offset     <= '0;
      pipe_req_wdata  <= '0;
      pipe_req_wstrb  <= '0;
      pipe_req_id     <= '0;
    end else begin
      pipe_req_valid <= 1'b0;  // default: no request this cycle

      unique case (arb_state)
        ARB_IDLE: begin
          if (!mshr_full) begin
            // Read preferred; break streak to serve write
            if (s_axi_arvalid &&
                (read_streak < MAX_STREAK || !aw_pending)) begin
              arb_state <= ARB_READ;
            end else if (aw_pending && s_axi_wvalid) begin
              arb_state <= ARB_WRITE;
            end
          end
        end

        ARB_READ: begin
          pipe_req_valid    <= 1'b1;
          pipe_req_is_write <= 1'b0;
          pipe_set_index    <= s_axi_araddr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
          pipe_req_tag      <= s_axi_araddr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
          pipe_offset       <= s_axi_araddr[OFFSET_BITS-1:0];
          pipe_req_id       <= s_axi_arid;
          read_streak       <= read_streak + 1;
          burst_cnt         <= s_axi_arlen;
          arb_state         <= ARB_IDLE;
        end

        ARB_WRITE: begin
          if (s_axi_wvalid) begin
            pipe_req_valid    <= 1'b1;
            pipe_req_is_write <= 1'b1;
            pipe_set_index    <= aw_addr_r[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
            pipe_req_tag      <= aw_addr_r[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
            pipe_offset       <= aw_addr_r[OFFSET_BITS-1:0];
            pipe_req_wdata    <= s_axi_wdata;
            pipe_req_wstrb    <= s_axi_wstrb;
            pipe_req_id       <= aw_id_r;
            read_streak       <= '0;  // reset read streak
            arb_state         <= ARB_IDLE;
          end
        end

        default: arb_state <= ARB_IDLE;
      endcase
    end
  end

  // =========================================================================
  // READY signals
  // ARREADY: accept when idle + not MSHR full + read selected
  // AWREADY: accept new AW when no AW pending
  // WREADY:  accept W beat when AW pending and pipeline ready for write
  // =========================================================================
  assign s_axi_arready = (arb_state == ARB_IDLE) &&
                         s_axi_arvalid            &&
                         !mshr_full               &&
                         (read_streak < MAX_STREAK || !aw_pending);

  assign s_axi_awready = !aw_pending && !mshr_full;

  assign s_axi_wready  = aw_pending &&
                         (arb_state == ARB_WRITE) &&
                         !mshr_full;

  // =========================================================================
  // Assertions
  // =========================================================================
`ifdef SIMULATION

  property p_arready_not_when_mshr_full;
    @(posedge clk) disable iff (!rst_n)
    mshr_full |-> !s_axi_arready;
  endproperty
  ap_ar_bp: assert property (p_arready_not_when_mshr_full)
    else $error("REQ_PIPE: ARREADY asserted while MSHR full");

  property p_awready_not_when_pending;
    @(posedge clk) disable iff (!rst_n)
    aw_pending |-> !s_axi_awready;
  endproperty
  ap_aw_pending: assert property (p_awready_not_when_pending)
    else $error("REQ_PIPE: AWREADY while AW already pending");

`endif

endmodule

`endif // L2_REQUEST_PIPELINE_SV
