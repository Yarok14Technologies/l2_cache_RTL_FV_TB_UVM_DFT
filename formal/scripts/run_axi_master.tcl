################################################################################
# Script     : formal/scripts/run_axi_master.tcl
# Tool       : Cadence JasperGold FPV
# Proof goal : AXI4 master protocol compliance (memory-side fill/writeback port)
# Usage      : jg -fpv formal/scripts/run_axi_master.tcl
################################################################################

clear -all

analyze -sv12 -f {
  rtl/cache/l2_cache_pkg.sv
  rtl/cache/l2_axi_master.sv
  formal/props/props_axi_master.sv
}

elaborate \
  -top l2_axi_master \
  -parameter ADDR_WIDTH  40 \
  -parameter DATA_WIDTH  64 \
  -parameter ID_WIDTH    8  \
  -parameter LINE_SIZE_B 64

bind l2_axi_master props_axi_master #(
  .ADDR_WIDTH  (40),
  .DATA_WIDTH  (64),
  .ID_WIDTH    (8),
  .LINE_SIZE_B (64)
) u_props_axm (
  .clk             (clk),
  .rst_n           (rst_n),
  .m_axi_araddr    (m_axi_araddr),
  .m_axi_arlen     (m_axi_arlen),
  .m_axi_arsize    (m_axi_arsize),
  .m_axi_arburst   (m_axi_arburst),
  .m_axi_arid      (m_axi_arid),
  .m_axi_arvalid   (m_axi_arvalid),
  .m_axi_arready   (m_axi_arready),
  .m_axi_rdata     (m_axi_rdata),
  .m_axi_rresp     (m_axi_rresp),
  .m_axi_rlast     (m_axi_rlast),
  .m_axi_rvalid    (m_axi_rvalid),
  .m_axi_rready    (m_axi_rready),
  .m_axi_awaddr    (m_axi_awaddr),
  .m_axi_awlen     (m_axi_awlen),
  .m_axi_awid      (m_axi_awid),
  .m_axi_awvalid   (m_axi_awvalid),
  .m_axi_awready   (m_axi_awready),
  .m_axi_wdata     (m_axi_wdata),
  .m_axi_wstrb     (m_axi_wstrb),
  .m_axi_wlast     (m_axi_wlast),
  .m_axi_wvalid    (m_axi_wvalid),
  .m_axi_wready    (m_axi_wready),
  .m_axi_bresp     (m_axi_bresp),
  .m_axi_bid       (m_axi_bid),
  .m_axi_bvalid    (m_axi_bvalid),
  .m_axi_bready    (m_axi_bready),
  .rd_req_valid    (rd_req_valid),
  .wb_req_valid    (wb_req_valid),
  .fill_valid      (fill_valid),
  .wb_done         (wb_done)
);

clock  clk
reset  ~rst_n

# Memory-side environment constraints
assume -name asm_mem_arready    { m_axi_arvalid |-> ##[0:4] m_axi_arready }
assume -name asm_mem_rvalid     { (m_axi_arvalid && m_axi_arready) |-> ##[1:32] m_axi_rvalid }
assume -name asm_mem_rvalid_sta { (m_axi_rvalid && !m_axi_rready) |=> m_axi_rvalid }
assume -name asm_mem_rlast_ok   { m_axi_rvalid |-> (m_axi_rresp == 2'b00) }
assume -name asm_mem_awready    { m_axi_awvalid |-> ##[0:4] m_axi_awready }
assume -name asm_mem_wready     { m_axi_wvalid  |-> ##[0:4] m_axi_wready  }
assume -name asm_mem_bvalid     { (m_axi_awvalid && m_axi_awready) |-> ##[2:32] m_axi_bvalid }
assume -name asm_mem_bvalid_sta { (m_axi_bvalid && !m_axi_bready) |=> m_axi_bvalid }
assume -name asm_mem_bresp_ok   { m_axi_bvalid |-> (m_axi_bresp == 2'b00) }

set_prove_time_limit 1800
set_engine_mode {Hp Ht K I}

prove -all

report -results -file reports/formal/axi_master_results.rpt
report -summary -file reports/formal/axi_master_summary.rpt
report -cover   -file reports/formal/axi_master_coverage.rpt

set proven [llength [get_results -type assert -status proven]]
set failed [llength [get_results -type assert -status failed]]
puts "AXI Master: proven=$proven failed=$failed"
if {$failed > 0} { exit 1 } else { exit 0 }
