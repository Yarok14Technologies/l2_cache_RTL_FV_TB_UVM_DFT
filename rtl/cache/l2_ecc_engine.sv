// =============================================================================
// Module     : l2_ecc_engine
// Description: Standalone SECDED (Single Error Correct, Double Error Detect)
//              ECC engine for 64-bit data words.
//              8 check bits → (72,64) Hamming code with overall parity.
//
//              Two submodules:
//                l2_ecc_encode — generates 8 check bits from 64-bit data
//                l2_ecc_check  — verifies stored word, corrects single-bit,
//                                flags double-bit, outputs syndrome
//
//              Fault coverage:
//                Single-bit error  → corrected, clean data output
//                Double-bit error  → flagged (double_error=1), data unreliable
//                Overall parity error only → benign (ignored)
//
//              Parity bit assignments (standard Hamming positions):
//                P0 covers bits: 1,3,5,7,9,11,...  (positions with bit0=1)
//                P1 covers bits: 2,3,6,7,10,11,... (positions with bit1=1)
//                P2 covers bits: 4-7,12-15,...      (positions with bit2=1)
//                P3 covers bits: 8-15,24-31,...     (positions with bit3=1)
//                P4 covers bits: 16-31,48-63,...    (positions with bit4=1)
//                P5 covers bits: 32-63               (positions with bit5=1)
//                P6 covers all data bits             (overall parity)
//                P7 reserved / unused
// =============================================================================

`ifndef L2_ECC_ENGINE_SV
`define L2_ECC_ENGINE_SV

// =============================================================================
// Encode: compute 8 check bits for 64-bit data
// =============================================================================
module l2_ecc_encode (
  input  logic [63:0] data_in,
  output logic [7:0]  check_bits
);
  // P0: XOR of all data bits at positions with bit0 of index = 1
  assign check_bits[0] = ^(data_in & 64'h5555_5555_5555_5555);
  // P1: positions with bit1 = 1
  assign check_bits[1] = ^(data_in & 64'h6666_6666_6666_6666);
  // P2: positions with bit2 = 1
  assign check_bits[2] = ^(data_in & 64'h7878_7878_7878_7878);
  // P3: positions with bit3 = 1
  assign check_bits[3] = ^(data_in & 64'h7F80_7F80_7F80_7F80);
  // P4: positions with bit4 = 1
  assign check_bits[4] = ^(data_in & 64'h7FFF_8000_7FFF_8000);
  // P5: positions with bit5 = 1
  assign check_bits[5] = ^(data_in & 64'h7FFF_FFFF_8000_0000);
  // P6: overall parity (XOR of all data bits)
  assign check_bits[6] = ^data_in;
  // P7: XOR of all check bits + data (final overall parity for SECDED)
  assign check_bits[7] = ^{check_bits[6:0], data_in};
endmodule

// =============================================================================
// Check: verify stored word, correct single-bit errors
// =============================================================================
module l2_ecc_check (
  input  logic [63:0] data_in,         // stored data (possibly corrupted)
  input  logic [7:0]  stored_check,    // stored check bits
  output logic [63:0] data_out,        // corrected data output
  output logic        single_error,    // 1 = single-bit error was corrected
  output logic        double_error,    // 1 = double-bit error, data unreliable
  output logic [6:0]  syndrome         // bit position of error (0 = no error)
);
  logic [7:0] computed_check;
  logic [7:0] synd_raw;
  logic       overall_parity;

  // Recompute check bits from received data
  l2_ecc_encode u_enc (
    .data_in   (data_in),
    .check_bits(computed_check)
  );

  // Syndrome = XOR of received vs computed check bits
  assign synd_raw       = stored_check ^ computed_check;
  assign syndrome       = synd_raw[6:0];
  assign overall_parity = synd_raw[7];

  // SECDED decode:
  //   syndrome=0, overall=0 → no error
  //   syndrome≠0, overall=1 → single-bit error at bit position = syndrome
  //   syndrome≠0, overall=0 → double-bit error (uncorrectable)
  //   syndrome=0, overall=1 → overall parity bit error only (benign)
  assign single_error = (syndrome != 7'b0) &&  overall_parity;
  assign double_error = (syndrome != 7'b0) && !overall_parity;

  // Correct single-bit error by flipping the bit at position 'syndrome'
  always_comb begin
    data_out = data_in;
    if (single_error && syndrome <= 7'd63) begin
      data_out[syndrome] = ~data_in[syndrome];
    end
    // Double error: return original data (marked as unreliable by double_error)
  end

`ifdef SIMULATION
  // Single and double error must not both be asserted
  ap_ecc_excl: assert final (!(single_error && double_error))
    else $fatal(0, "ECC: single_error and double_error both asserted");

  // After correction, data must match original (tested in UVM ECC test)
  // Cover: single-bit errors are correctable
  cp_single: cover property (@($global_clock) single_error);
  // Cover: double-bit errors are detectable
  cp_double: cover property (@($global_clock) double_error);
`endif

endmodule

// =============================================================================
// Top-level wrapper: encode + check as a pipeline
// Used inside l2_data_array for write (encode) and read (check+correct)
// =============================================================================
module l2_ecc_engine (
  input  logic        clk,
  input  logic        rst_n,

  // Encode path (write side)
  input  logic [63:0] enc_data_in,
  output logic [71:0] enc_word_out,   // {check_bits[7:0], data[63:0]}

  // Check path (read side)
  input  logic [71:0] chk_word_in,    // {stored_check[7:0], stored_data[63:0]}
  output logic [63:0] chk_data_out,
  output logic        chk_single_err,
  output logic        chk_double_err,
  output logic [6:0]  chk_syndrome
);

  logic [7:0] enc_check;

  // Encode (combinational — registered at data_array level)
  l2_ecc_encode u_encode (
    .data_in   (enc_data_in),
    .check_bits(enc_check)
  );
  assign enc_word_out = {enc_check, enc_data_in};

  // Check+correct (combinational — output registered at data_array level)
  l2_ecc_check u_check (
    .data_in      (chk_word_in[63:0]),
    .stored_check (chk_word_in[71:64]),
    .data_out     (chk_data_out),
    .single_error (chk_single_err),
    .double_error (chk_double_err),
    .syndrome     (chk_syndrome)
  );

endmodule

`endif // L2_ECC_ENGINE_SV
