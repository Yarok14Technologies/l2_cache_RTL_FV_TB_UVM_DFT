###############################################################################
# File       : constraints/l2_cache_test.sdc
# Description: SDC constraints for DFT scan test mode.
#              Applied in Innovus during MMMC CM_TEST analysis view.
#              Also used by TetraMAX for timing-aware ATPG.
#
# Test mode assumptions:
#   - Functional clock (clk) is INACTIVE during scan shift
#   - Test clock (test_clk) drives all FFs via clock mux
#   - Scan enable (test_se) is held HIGH during shift phase
#   - test_rst_n is held HIGH (released) during test operation
###############################################################################

###############################################################################
# 1. Test clock definition
###############################################################################

# Test clock: 100 MHz (10 ns period) — slower than functional for stability
create_clock -name test_clk \
  -period 10.0 \
  [get_ports test_clk]

# Clock uncertainty for test mode (higher than functional — test environment)
set_clock_uncertainty -setup 0.200 [get_clocks test_clk]
set_clock_uncertainty -hold  0.100 [get_clocks test_clk]

# Test clock transition (slew)
set_clock_transition 0.10 [get_clocks test_clk]

###############################################################################
# 2. Functional clock — false path in test mode
###############################################################################

# The functional clock is gated OFF in test mode (clock mux selects test_clk)
# Define it to prevent tool from complaining, but false-path from it
create_clock -name clk \
  -period 2.0 \
  [get_ports clk]

set_false_path -from [get_clocks clk]

###############################################################################
# 3. Scan enable and reset — quasi-static during shift
###############################################################################

# scan enable is set before first shift clock — treat as ideal
set_ideal_network [get_ports test_se]
set_false_path    -from [get_ports test_se]

# Test reset — released before shift, quasi-static
set_false_path -from [get_ports test_rst_n]

###############################################################################
# 4. Scan chain I/O timing
###############################################################################
# Allow 40% of test clock period for scan in/out setup/hold

set SCAN_IN_DLY  [expr {10.0 * 0.40}]  ;# 4 ns
set SCAN_OUT_DLY [expr {10.0 * 0.40}]  ;# 4 ns

set_input_delay  -max $SCAN_IN_DLY  -clock test_clk [get_ports {scan_in[*]}]
set_output_delay -max $SCAN_OUT_DLY -clock test_clk [get_ports {scan_out[*]}]

# BIST ports
set_input_delay  -max 2.0 -clock test_clk [get_ports test_tm]
set_output_delay -max 2.0 -clock test_clk [get_ports bist_done]
set_output_delay -max 2.0 -clock test_clk [get_ports bist_pass]
set_output_delay -max 2.0 -clock test_clk [get_ports {bist_fail_map[*]}]

###############################################################################
# 5. Functional ports — false paths in test mode
###############################################################################

# All AXI functional ports are don't-care in test mode
set_false_path -from [get_ports {s_axi_* m_axi_* ac_* cr_* cd_*}]
set_false_path -to   [get_ports {s_axi_* m_axi_* ac_* cr_* cd_*}]
set_false_path -to   [get_ports {cache_hit cache_miss wb_pending}]
set_false_path -to   [get_ports {perf_* cache_flush_done}]

###############################################################################
# 6. SRAM macro test mode
###############################################################################

# SRAM macros use dedicated SD (shutdown) pin — false path in test mode
set_false_path -to [get_pins -filter {name =~ *SD*} \
                             -of_objects [get_cells u_data_array/*]]

###############################################################################
# 7. Lockup latches (at clock domain boundaries in scan chain)
###############################################################################

# Lockup latches are inserted by DFT tool between chains at boundaries.
# They capture data on the falling edge of test_clk to prevent hold violations.
# The setup/hold on lockup latches is automatically handled by the tool.

set_false_path -through [get_cells -filter {ref_name =~ LATCHX*}]

###############################################################################
# Done
###############################################################################
puts "Loaded: l2_cache_test.sdc (DFT scan mode, test_clk=100MHz)"
