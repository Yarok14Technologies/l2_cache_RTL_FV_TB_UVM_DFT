###############################################################################
# Script     : dft_scan_config.tcl
# Tool       : Synopsys DFT Compiler (within DC Ultra)
# Description: DFT configuration for L2 Cache scan insertion.
#              Inserts multiplexed scan chains and configures ATPG modes.
#
# Source this AFTER synthesis compile_ultra and BEFORE insert_dft.
# In dc_synthesis.tcl: source scripts/dft/dft_scan_config.tcl
###############################################################################

###############################################################################
# 1. Scan configuration
###############################################################################
set_scan_configuration \
  -clock_mixing      no_mix          \
  -add_lockup_latch  true            \
  -style             multiplexed_flip_flop \
  -chain_count       4               \
  -max_length        512

# Dedicated test ports
set_dft_signal -view existing_dft \
  -type ScanEnable  -port [get_ports scan_en]
set_dft_signal -view existing_dft \
  -type ScanDataIn  -port [get_ports {scan_in[*]}]
set_dft_signal -view existing_dft \
  -type ScanDataOut -port [get_ports {scan_out[*]}]

# Test clock
set_dft_signal -view existing_dft \
  -type TestClock \
  -timing {45 55} \
  -port [get_ports clk]

###############################################################################
# 2. Exclude cells from scan
###############################################################################
# ICG cells must not be scanned
set_dft_exemption -type clock_gating_element \
  [get_cells -hier -filter {ref_name =~ ICG*}]

# Retention flip-flops handled separately
set_dft_exemption -type retention_register \
  [get_cells -hier -filter {ref_name =~ RFFX*}]

###############################################################################
# 3. Preview scan before insertion
###############################################################################
preview_dft -show all > reports/synthesis/dft_preview.rpt

###############################################################################
# 4. Insert DFT
###############################################################################
insert_dft

###############################################################################
# 5. Incremental compile after DFT insertion
###############################################################################
compile_ultra -scan -incremental

###############################################################################
# 6. DFT reports
###############################################################################
file mkdir reports/synthesis

report_scan_path \
  -view existing_dft \
  -chain all \
  > reports/synthesis/scan_chains.rpt

report_dft_signal > reports/synthesis/dft_signals.rpt

echo "DFT insertion complete. Chains: 4, max length: 512"
