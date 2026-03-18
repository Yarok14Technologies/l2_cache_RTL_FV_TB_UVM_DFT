// =============================================================================
// Module     : async_fifo
// Description: Asynchronous FIFO for clock-domain crossing.
//              Uses Gray-coded pointers synchronized via 2-FF chains.
//              DEPTH must be a power of 2.
// =============================================================================

`ifndef ASYNC_FIFO_SV
`define ASYNC_FIFO_SV

module async_fifo #(
  parameter int unsigned DEPTH = 8,
  parameter int unsigned WIDTH = 8,
  localparam int unsigned PTR_W = $clog2(DEPTH)
)(
  // Write domain
  input  logic             wr_clk,
  input  logic             wr_rst_n,
  input  logic             wr_en,
  input  logic [WIDTH-1:0] wr_data,
  output logic             wr_full,
  // Read domain
  input  logic             rd_clk,
  input  logic             rd_rst_n,
  input  logic             rd_en,
  output logic [WIDTH-1:0] rd_data,
  output logic             rd_empty
);

  logic [WIDTH-1:0]   mem [DEPTH];

  // Binary and Gray pointers (write domain)
  logic [PTR_W:0]     wr_bin, wr_gray;
  logic [PTR_W:0]     wr_gray_sync1, wr_gray_sync2;  // synced to rd_clk

  // Binary and Gray pointers (read domain)
  logic [PTR_W:0]     rd_bin, rd_gray;
  logic [PTR_W:0]     rd_gray_sync1, rd_gray_sync2;  // synced to wr_clk

  // ── Write domain ──────────────────────────────────────────────────────────
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wr_bin  <= '0;
      wr_gray <= '0;
    end else if (wr_en && !wr_full) begin
      wr_bin  <= wr_bin + 1;
      wr_gray <= (wr_bin + 1) ^ ((wr_bin + 1) >> 1);
      mem[wr_bin[PTR_W-1:0]] <= wr_data;
    end
  end

  // Sync rd_gray into write domain (2-FF)
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      rd_gray_sync1 <= '0;  rd_gray_sync2 <= '0;
    end else begin
      rd_gray_sync1 <= rd_gray;
      rd_gray_sync2 <= rd_gray_sync1;
    end
  end

  // Full when wr and rd (synced) Gray pointers MSBs differ, rest equal
  assign wr_full = (wr_gray == {~rd_gray_sync2[PTR_W:PTR_W-1],
                                  rd_gray_sync2[PTR_W-2:0]});

  // ── Read domain ───────────────────────────────────────────────────────────
  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rd_bin  <= '0;
      rd_gray <= '0;
    end else if (rd_en && !rd_empty) begin
      rd_bin  <= rd_bin + 1;
      rd_gray <= (rd_bin + 1) ^ ((rd_bin + 1) >> 1);
    end
  end

  // Sync wr_gray into read domain (2-FF)
  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      wr_gray_sync1 <= '0;  wr_gray_sync2 <= '0;
    end else begin
      wr_gray_sync1 <= wr_gray;
      wr_gray_sync2 <= wr_gray_sync1;
    end
  end

  assign rd_empty = (rd_gray == wr_gray_sync2);
  assign rd_data  = mem[rd_bin[PTR_W-1:0]];

endmodule

`endif // ASYNC_FIFO_SV
