// =============================================================================
// Module     : l2_scan_wrapper
// Description: Scan-mode utility cells for the L2 cache DFT infrastructure.
//
//   l2_icg_scan_bypass  — Integrated Clock Gating cell with scan bypass.
//                         In scan-shift mode (se=1) the clock is forced
//                         ungated so scan FFs toggle freely.
//
//   l2_obs_point        — Observation point wrapper.
//                         Inserts a transparent latch that captures a net
//                         for ATPG test point insertion.
//                         Helps ATPG reach low-observability nodes deep in
//                         the tag comparator and MSHR state logic.
//
//   l2_scan_mux         — 2:1 scan mux (MUX-D scan flip-flop front-end).
//                         Selects between functional data (D) and scan input
//                         (SI) under scan enable (SE).
//
// All cells are technology-mapped to library primitives at synthesis.
// These behavioural models are for pre-DFT functional simulation only.
// =============================================================================

`ifndef L2_SCAN_WRAPPER_SV
`define L2_SCAN_WRAPPER_SV

// =============================================================================
// ICG with scan bypass
// =============================================================================
module l2_icg_scan_bypass (
  input  logic CK,    // source clock
  input  logic EN,    // functional enable (active high)
  input  logic SE,    // scan enable — when 1, clock passes ungated
  output logic ECK    // gated clock output
);
  // In scan mode force enable high so clock reaches all FFs
  logic en_muxed;
  assign en_muxed = SE | EN;

  // Behavioural latch-based ICG (synthesis maps to ICGX1 / CKLNQD1)
  logic latch_q;
  always_latch begin
    if (!CK) latch_q <= en_muxed;  // transparent when CK low
  end
  assign ECK = CK & latch_q;

`ifdef SIMULATION
  // ECK must not glitch
  property p_eck_no_glitch;
    @(posedge CK) disable iff (SE)
    !$isunknown(ECK);
  endproperty
  ap_eck: assert property (p_eck_no_glitch)
    else $error("ICG_SCAN: ECK has X in functional mode");
`endif

endmodule

// =============================================================================
// Observation point (test point insertion)
// =============================================================================
module l2_obs_point #(
  parameter int unsigned WIDTH = 1
)(
  input  logic             clk,
  input  logic             se,        // scan enable
  input  logic [WIDTH-1:0] obs_in,    // net under observation
  output logic [WIDTH-1:0] obs_out,   // passes through unchanged
  output logic [WIDTH-1:0] obs_cap    // captured value (connects to scan chain)
);
  // Transparent in functional mode; captures in scan mode
  always_ff @(posedge clk) begin
    if (se) obs_cap <= obs_in;
  end

  assign obs_out = obs_in;  // zero-delay passthrough

endmodule

// =============================================================================
// Scan MUX (front-end for MUX-D scan flip-flop)
// =============================================================================
module l2_scan_mux #(
  parameter int unsigned WIDTH = 1
)(
  input  logic [WIDTH-1:0] D,     // functional data
  input  logic [WIDTH-1:0] SI,    // scan input
  input  logic             SE,    // scan enable
  output logic [WIDTH-1:0] Z      // to flip-flop D input
);
  assign Z = SE ? SI : D;
endmodule

`endif // L2_SCAN_WRAPPER_SV
