###############################################################################
# Script     : run_axi_slave.tcl
# Tool       : Cadence JasperGold FPV
# Proof goal : AXI4 protocol compliance on the CPU-side slave interface
# Usage      : jg -fpv formal/scripts/run_axi_slave.tcl
###############################################################################

clear -all

###############################################################################
# 1. Analyse RTL sources
###############################################################################
analyze -sv12 -f {
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
  formal/props/props_axi_slave.sv
}

###############################################################################
# 2. Elaborate — bind property module to DUT
###############################################################################
elaborate \
  -top l2_cache_top \
  -bbox_m {sram_sp_hd_256x512 sram_sp_hd_256x26} \
  -parameter WAYS 4 \
  -parameter CACHE_SIZE_KB 256 \
  -parameter MSHR_DEPTH 8

# Bind the property module
bind l2_cache_top props_axi_slave #(
  .ADDR_WIDTH (40),
  .DATA_WIDTH (64),
  .ID_WIDTH   (8)
) u_props_axi (
  .clk             (clk),
  .rst_n           (rst_n),
  .s_axi_araddr    (s_axi_araddr),
  .s_axi_arlen     (s_axi_arlen),
  .s_axi_arsize    (s_axi_arsize),
  .s_axi_arburst   (s_axi_arburst),
  .s_axi_arid      (s_axi_arid),
  .s_axi_arvalid   (s_axi_arvalid),
  .s_axi_arready   (s_axi_arready),
  .s_axi_rdata     (s_axi_rdata),
  .s_axi_rresp     (s_axi_rresp),
  .s_axi_rlast     (s_axi_rlast),
  .s_axi_rid       (s_axi_rid),
  .s_axi_rvalid    (s_axi_rvalid),
  .s_axi_rready    (s_axi_rready),
  .s_axi_awaddr    (s_axi_awaddr),
  .s_axi_awlen     (s_axi_awlen),
  .s_axi_awid      (s_axi_awid),
  .s_axi_awvalid   (s_axi_awvalid),
  .s_axi_awready   (s_axi_awready),
  .s_axi_wdata     (s_axi_wdata),
  .s_axi_wstrb     (s_axi_wstrb),
  .s_axi_wlast     (s_axi_wlast),
  .s_axi_wvalid    (s_axi_wvalid),
  .s_axi_wready    (s_axi_wready),
  .s_axi_bresp     (s_axi_bresp),
  .s_axi_bid       (s_axi_bid),
  .s_axi_bvalid    (s_axi_bvalid),
  .s_axi_bready    (s_axi_bready),
  .mshr_full       (u_mshr.full),
  .cache_hit       (cache_hit),
  .cache_miss      (cache_miss)
);

###############################################################################
# 3. Clock / reset
###############################################################################
clock  clk
reset  ~rst_n

###############################################################################
# 4. Source formal constraints (environment assumptions)
###############################################################################
source formal/constraints/axi_env_constraints.tcl

###############################################################################
# 5. Prove / cover settings
###############################################################################
set_prove_time_limit 1800    ;# 30 min per property
set_prove_per_property_time_limit 300

# Use k-induction for liveness properties
set_engine_mode {Hp Ht Hd K I}

###############################################################################
# 6. Run proof
###############################################################################
prove -all

###############################################################################
# 7. Reports
###############################################################################
file mkdir reports/formal

report -results \
  -file reports/formal/axi_slave_results.rpt

report -summary \
  -file reports/formal/axi_slave_summary.rpt

report -cover \
  -file reports/formal/axi_slave_coverage.rpt

###############################################################################
# 8. Pass/fail check
###############################################################################
set proven  [llength [get_results -type assert -status proven]]
set failed  [llength [get_results -type assert -status failed]]
set covered [llength [get_results -type cover  -status covered]]
set uncov   [llength [get_results -type cover  -status uncovered]]

puts "================================================="
puts "  AXI Slave Formal Results"
puts "  Assert PROVEN  : $proven"
puts "  Assert FAILED  : $failed"
puts "  Cover COVERED  : $covered"
puts "  Cover UNCOVERED: $uncov"
puts "================================================="

if {$failed > 0} { exit 1 } else { exit 0 }
