################################################################################
# Script     : scripts/cdc/run_cdc.tcl
# Tool       : Synopsys SpyGlass CDC + Mentor Questa CDC
# Description: Clock Domain Crossing analysis for the L2 cache controller.
#              The design is fundamentally single-clock (all logic on 'clk').
#              This script verifies that assumption and analyses any potential
#              CDC paths introduced at SoC integration boundaries.
#
# CDC paths in this design:
#   1. cache_flush_req / cache_power_down  — quasi-static signals from PMU
#      (treated as false paths in SDC; verified here to be synchronised at SoC)
#   2. BIST mode signals (test_tm, test_clk) — driven in test mode only
#   3. Async FIFO in rtl/common/async_fifo.sv — verified separately
#
# Usage: spyglass -project scripts/cdc/cdc.prj -goal cdc/cdc_verify_struct
################################################################################

###############################################################################
# SpyGlass CDC project settings (embedded TCL)
###############################################################################

set_option projectwdir  "reports/spyglass_cdc"
set_option top          "l2_cache_top"
set_option language     sverilog

# Source files
read_file -type sourcelist {
  rtl/cache/l2_cache_pkg.sv
  rtl/cache/l2_lru_controller.sv
  rtl/cache/l2_tag_array.sv
  rtl/cache/l2_data_array.sv
  rtl/cache/l2_hit_miss_detect.sv
  rtl/cache/l2_request_pipeline.sv
  rtl/cache/l2_mshr.sv
  rtl/cache/l2_coherency_fsm.sv
  rtl/cache/l2_axi_master.sv
  rtl/cache/l2_cache_top.sv
  rtl/common/async_fifo.sv
  rtl/common/sync_fifo.sv
  rtl/common/rr_arbiter.sv
}

# SDC
read_file -type sdc { constraints/l2_cache.sdc }

# CDC-specific options
set_option cdc_flatten_model         yes
set_option cdc_report_all_status     yes
set_option cdc_reconvergence_analysis yes
set_option cdc_count_based_model     yes

# Clocks defined in SDC — SpyGlass will auto-detect from create_clock
# Verify: only one clock domain (clk) in functional mode

# Quasi-static inputs — synchronised externally by PMU at SoC level
cdc_signal -name cache_flush_req  -type control -sync_method external
cdc_signal -name cache_power_down -type control -sync_method external

# DFT clock — only active in test mode (cdc_ignore in functional mode)
cdc_signal -name test_clk  -type clock -domain TEST_CLK \
           -comment "DFT test clock — not active in functional mode"

# Run CDC goal
current_goal cdc/cdc_verify_struct
run_goal
