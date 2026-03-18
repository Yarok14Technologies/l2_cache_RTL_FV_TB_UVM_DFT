################################################################################
# File       : sim/waves/l2_cache_waves.tcl
# Tool       : Synopsys DVE / Verdi / Cadence SimVision
# Description: Waveform configuration for L2 cache debug.
#              Pre-groups all key signals for quick debugging.
#
# Usage (DVE):
#   dve -vpd waves/l2_cache.vpd -script sim/waves/l2_cache_waves.tcl
#
# Usage (Verdi):
#   verdi -ssf waves/l2_cache.fsdb -script sim/waves/l2_cache_waves.tcl
################################################################################

################################################################################
# Signal groups
################################################################################

# ── Group 1: AXI Slave (CPU → L2) ────────────────────────────────────────────
set grp_axi_slave [create_group "AXI Slave (CPU)" -open]
add_wave -into $grp_axi_slave {
  l2_cache_tb_top.dut.clk
  l2_cache_tb_top.dut.rst_n
  l2_cache_tb_top.dut.s_axi_arvalid
  l2_cache_tb_top.dut.s_axi_arready
  l2_cache_tb_top.dut.s_axi_araddr
  l2_cache_tb_top.dut.s_axi_arlen
  l2_cache_tb_top.dut.s_axi_rvalid
  l2_cache_tb_top.dut.s_axi_rready
  l2_cache_tb_top.dut.s_axi_rdata
  l2_cache_tb_top.dut.s_axi_rresp
  l2_cache_tb_top.dut.s_axi_rlast
  l2_cache_tb_top.dut.s_axi_awvalid
  l2_cache_tb_top.dut.s_axi_awready
  l2_cache_tb_top.dut.s_axi_awaddr
  l2_cache_tb_top.dut.s_axi_wvalid
  l2_cache_tb_top.dut.s_axi_wready
  l2_cache_tb_top.dut.s_axi_wlast
  l2_cache_tb_top.dut.s_axi_bvalid
  l2_cache_tb_top.dut.s_axi_bready
  l2_cache_tb_top.dut.s_axi_bresp
}

# ── Group 2: Cache pipeline internal ─────────────────────────────────────────
set grp_pipe [create_group "Cache Pipeline" -open]
add_wave -into $grp_pipe {
  l2_cache_tb_top.dut.pipe_req_valid
  l2_cache_tb_top.dut.pipe_req_is_write
  l2_cache_tb_top.dut.pipe_set_index
  l2_cache_tb_top.dut.pipe_req_tag
  l2_cache_tb_top.dut.hit_any
  l2_cache_tb_top.dut.hit_way_oh
  l2_cache_tb_top.dut.hit_way_bin
  l2_cache_tb_top.dut.cache_hit
  l2_cache_tb_top.dut.cache_miss
  l2_cache_tb_top.dut.lru_victim_way
  l2_cache_tb_top.dut.mshr_full
}

# ── Group 3: MSHR ─────────────────────────────────────────────────────────────
set grp_mshr [create_group "MSHR" -open]
add_wave -into $grp_mshr {
  l2_cache_tb_top.dut.u_mshr.mshr_valid_vec
  l2_cache_tb_top.dut.u_mshr.mshr_used_count
  l2_cache_tb_top.dut.u_mshr.full
  l2_cache_tb_top.dut.u_mshr.alloc_req
  l2_cache_tb_top.dut.u_mshr.alloc_merged
  l2_cache_tb_top.dut.u_mshr.fill_valid
  l2_cache_tb_top.dut.u_mshr.resp_valid
  l2_cache_tb_top.dut.u_mshr.resp_accepted
  l2_cache_tb_top.dut.u_mshr.wb_valid
  l2_cache_tb_top.dut.u_mshr.wb_done
}

# ── Group 4: AXI Master (L2 → Memory) ────────────────────────────────────────
set grp_axi_master [create_group "AXI Master (Memory)" -open]
add_wave -into $grp_axi_master {
  l2_cache_tb_top.dut.m_axi_arvalid
  l2_cache_tb_top.dut.m_axi_arready
  l2_cache_tb_top.dut.m_axi_araddr
  l2_cache_tb_top.dut.m_axi_rvalid
  l2_cache_tb_top.dut.m_axi_rready
  l2_cache_tb_top.dut.m_axi_rlast
  l2_cache_tb_top.dut.m_axi_awvalid
  l2_cache_tb_top.dut.m_axi_awready
  l2_cache_tb_top.dut.m_axi_awaddr
  l2_cache_tb_top.dut.m_axi_wvalid
  l2_cache_tb_top.dut.m_axi_wready
  l2_cache_tb_top.dut.m_axi_wlast
  l2_cache_tb_top.dut.m_axi_bvalid
  l2_cache_tb_top.dut.m_axi_bready
  l2_cache_tb_top.dut.fill_valid
  l2_cache_tb_top.dut.fill_addr
  l2_cache_tb_top.dut.wb_pending
}

# ── Group 5: Coherency FSM ────────────────────────────────────────────────────
set grp_coh [create_group "Coherency FSM" -open]
add_wave -into $grp_coh {
  l2_cache_tb_top.dut.u_coherency.coh_state
  l2_cache_tb_top.dut.ac_valid
  l2_cache_tb_top.dut.ac_ready
  l2_cache_tb_top.dut.ac_addr
  l2_cache_tb_top.dut.ac_snoop
  l2_cache_tb_top.dut.cr_valid
  l2_cache_tb_top.dut.cr_ready
  l2_cache_tb_top.dut.cr_resp
  l2_cache_tb_top.dut.cd_valid
  l2_cache_tb_top.dut.cd_ready
  l2_cache_tb_top.dut.cd_last
  l2_cache_tb_top.dut.u_coherency.snoop_hit_r
  l2_cache_tb_top.dut.u_coherency.snoop_dirty_r
  l2_cache_tb_top.dut.u_coherency.snoop_mesi_r
}

# ── Group 6: Performance counters ────────────────────────────────────────────
set grp_perf [create_group "Performance" -open]
add_wave -into $grp_perf {
  l2_cache_tb_top.dut.perf_hit_count
  l2_cache_tb_top.dut.perf_miss_count
  l2_cache_tb_top.dut.perf_wb_count
}

# ── Group 7: Power / Flush ────────────────────────────────────────────────────
set grp_pwr [create_group "Power/Flush" -open]
add_wave -into $grp_pwr {
  l2_cache_tb_top.dut.cache_flush_req
  l2_cache_tb_top.dut.cache_flush_done
  l2_cache_tb_top.dut.cache_power_down
}

################################################################################
# Display settings
################################################################################
waveform hierarchy -expand 1

# Radix settings
waveform set -radix hex -wave {
  l2_cache_tb_top.dut.s_axi_araddr
  l2_cache_tb_top.dut.s_axi_awaddr
  l2_cache_tb_top.dut.m_axi_araddr
  l2_cache_tb_top.dut.m_axi_awaddr
  l2_cache_tb_top.dut.s_axi_rdata
  l2_cache_tb_top.dut.fill_addr
  l2_cache_tb_top.dut.ac_addr
}
waveform set -radix unsigned -wave {
  l2_cache_tb_top.dut.u_mshr.mshr_used_count
  l2_cache_tb_top.dut.perf_hit_count
  l2_cache_tb_top.dut.perf_miss_count
  l2_cache_tb_top.dut.perf_wb_count
}

# Colour coding
waveform set -color green -wave { l2_cache_tb_top.dut.cache_hit  }
waveform set -color red   -wave { l2_cache_tb_top.dut.cache_miss }
waveform set -color yellow -wave {
  l2_cache_tb_top.dut.m_axi_arvalid
  l2_cache_tb_top.dut.m_axi_awvalid
}

# Zoom to show ~100 ns window
waveform zoom -start 0 -end 100ns

puts "L2 Cache waveform groups loaded successfully"
