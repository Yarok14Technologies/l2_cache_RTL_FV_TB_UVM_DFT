// =============================================================================
// Module     : sync_fifo
// Description: Parameterized synchronous FIFO using the extra-bit
//              full/empty detection method.
//              DEPTH must be a power of 2.
//              Supports simultaneous read and write (when not full/empty).
// =============================================================================

`ifndef SYNC_FIFO_SV
`define SYNC_FIFO_SV

module sync_fifo #(
  parameter int unsigned DEPTH = 8,
  parameter int unsigned WIDTH = 8,
  localparam int unsigned PTR_W = $clog2(DEPTH)
)(
  input  logic             clk,
  input  logic             rst_n,
  // Write port
  input  logic             wr_en,
  input  logic [WIDTH-1:0] din,
  output logic             full,
  // Read port
  input  logic             rd_en,
  output logic [WIDTH-1:0] dout,
  output logic             empty,
  // Status
  output logic [PTR_W:0]   count
);

  logic [WIDTH-1:0]  mem [DEPTH];
  logic [PTR_W:0]    wr_ptr, rd_ptr;  // extra MSB for full/empty distinguish

  assign empty = (wr_ptr == rd_ptr);
  assign full  = (wr_ptr[PTR_W] != rd_ptr[PTR_W]) &&
                 (wr_ptr[PTR_W-1:0] == rd_ptr[PTR_W-1:0]);
  assign count = wr_ptr - rd_ptr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) wr_ptr <= '0;
    else if (wr_en && !full) begin
      mem[wr_ptr[PTR_W-1:0]] <= din;
      wr_ptr <= wr_ptr + 1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rd_ptr <= '0;
    else if (rd_en && !empty) rd_ptr <= rd_ptr + 1;
  end

  assign dout = mem[rd_ptr[PTR_W-1:0]];

`ifdef SIMULATION
  // Write-when-full is a bug
  property p_no_wr_full;
    @(posedge clk) disable iff (!rst_n) !(wr_en && full);
  endproperty
  ap_wr_full: assert property (p_no_wr_full)
    else $error("SYNC_FIFO: write when full");

  property p_no_rd_empty;
    @(posedge clk) disable iff (!rst_n) !(rd_en && empty);
  endproperty
  ap_rd_empty: assert property (p_no_rd_empty)
    else $error("SYNC_FIFO: read when empty");
`endif

endmodule

`endif // SYNC_FIFO_SV
