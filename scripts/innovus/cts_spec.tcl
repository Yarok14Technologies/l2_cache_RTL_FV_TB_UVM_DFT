################################################################################
# File       : scripts/innovus/cts_spec.tcl
# Tool       : Cadence Innovus — Clock Tree Synthesis
# Description: CTS specification for the L2 cache 500 MHz clock tree.
#              Defines target skew, insertion delay, buffer choices, and
#              NDR (Non-Default Routing) rules for clock nets.
################################################################################

################################################################################
# 1. CTS target specification
################################################################################

set_cts_mode -clock_nets         clk \
             -max_skew           0.050  \  ;# 50 ps target skew
             -max_insertion_delay 0.500 \  ;# 500 ps max insertion delay
             -max_fanout          32    \  ;# max 32 loads per buffer
             -target_slew         0.050    ;# 50 ps target slew

################################################################################
# 2. Clock buffer / inverter cell preferences
################################################################################

# Use these cells for the clock tree (from 28nm std cell library)
# Prefer CLKBUF over BUF for better drive strength matching
set_cts_mode -buffer_cells {
  CLKBUF1X  CLKBUF2X  CLKBUF4X  CLKBUF8X
  CLKINVX1  CLKINVX2  CLKINVX4
}

# Preferred cells for leaf level (closest to FF clock pins)
set_cts_mode -leaf_cells {
  CLKBUF1X  CLKBUF2X
}

################################################################################
# 3. ICG cell awareness
################################################################################

# Tell Innovus about ICG cells so it can handle them in CTS
# ICG cells are transparent latches gating the clock — they must be in
# the clock tree but not duplicated
set_cts_mode -icg_cells { ICGX1 ICGX2 ICGX4 }

# ICG enable pin — Innovus must not mess with the enable logic
set_dont_touch_network [get_pins -filter {name == EN} \
                                 -of_objects [get_cells *_cg*]]

################################################################################
# 4. NDR (Non-Default Routing) rules for clock nets
################################################################################

# Double-width, double-spacing on clock metal layers
# Reduces resistance and improves signal integrity for clock distribution
create_ndr -name CLK_NDR \
  -layer { M4 M5 M6 } \
  -width { 0.14 0.14 0.14 } \
  -spacing { 0.14 0.14 0.14 }

assign_ndr -rule CLK_NDR -nets { clk }

################################################################################
# 5. Exclusions
################################################################################

# DFT clock mux output — exclude from main CTS (handled by DFT tool)
set_dont_touch [get_cells u_dut/clk_mux*]

# Scan enable logic — not a clock, don't treat as such
set_cts_mode -exclude_nets { test_clk test_se }

################################################################################
# 6. Post-CTS timing targets
################################################################################

# After CTS, setup slack must be ≥ 0.05 ns (50 ps margin)
# Hold slack must be ≥ 0.02 ns (20 ps margin)
set_cts_mode -setup_slack_threshold  0.05 \
             -hold_slack_threshold   0.02

puts "CTS spec loaded: max_skew=50ps, max_insertion=500ps, NDR=CLK_NDR"
