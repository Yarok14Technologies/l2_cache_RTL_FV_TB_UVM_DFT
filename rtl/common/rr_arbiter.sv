// =============================================================================
// Module     : rr_arbiter
// Description: Parameterized round-robin arbiter (N requestors).
//              Uses rotating pointer — pointer advances past the winner after
//              each grant so no requestor starves.
//              Supports fixed-priority fallback when only one request active.
// =============================================================================

`ifndef RR_ARBITER_SV
`define RR_ARBITER_SV

module rr_arbiter #(
  parameter int unsigned N = 4
)(
  input  logic         clk,
  input  logic         rst_n,
  input  logic [N-1:0] req,
  output logic [N-1:0] gnt
);

  logic [N-1:0] ptr;   // one-hot rotating priority pointer

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ptr <= N'(1);          // bit 0 has highest priority initially
    else if (|gnt)                     // rotate to one past winner
      ptr <= {gnt[N-2:0], gnt[N-1]};  // left-rotate by 1
  end

  // Masked priority: only requestors at-or-after ptr
  logic [N-1:0] masked_req;
  assign masked_req = req & ~(ptr - 1'b1);

  // Grant = lowest set bit of masked_req; fall back to unmasked if none
  always_comb begin
    if (|masked_req) gnt = masked_req & (-masked_req);
    else             gnt = req        & (-req);
  end

`ifdef SIMULATION
  // Only one grant active at a time
  property p_onehot_gnt;
    @(posedge clk) disable iff (!rst_n) $onehot0(gnt);
  endproperty
  ap_gnt: assert property (p_onehot_gnt)
    else $error("RR_ARBITER: multiple grants asserted simultaneously");

  // Grant only when request present
  property p_gnt_needs_req;
    @(posedge clk) disable iff (!rst_n) (gnt != '0) |-> (req & gnt) != '0;
  endproperty
  ap_gnt_req: assert property (p_gnt_needs_req)
    else $error("RR_ARBITER: grant with no matching request");
`endif

endmodule

`endif // RR_ARBITER_SV
