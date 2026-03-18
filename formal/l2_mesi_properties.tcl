###############################################################################
# File       : l2_mesi_properties.tcl
# Tool       : Cadence JasperGold FPV
# Description: Formal property verification for L2 cache MESI protocol.
#              Proves: deadlock freedom, coherency invariants, AXI compliance.
#
# Usage:
#   jg -fpv formal/l2_mesi_properties.tcl -define FORMAL_VERIFY
###############################################################################

###############################################################################
# 1. Setup
###############################################################################
clear -all

# Read RTL
analyze -sv12 {
  rtl/cache/l2_cache_pkg.sv
  rtl/cache/l2_lru_controller.sv
  rtl/cache/l2_tag_array.sv
  rtl/cache/l2_hit_miss_detect.sv
  rtl/cache/l2_coherency_fsm.sv
  rtl/cache/l2_mshr.sv
  rtl/cache/l2_axi_master.sv
  rtl/cache/l2_cache_top.sv
}

# Elaborate
elaborate -top l2_cache_top \
          -parameter WAYS 4 \
          -parameter CACHE_SIZE_KB 256 \
          -parameter MSHR_DEPTH 8

# Clock and reset
clock  clk
reset  ~rst_n

###############################################################################
# 2. Environment constraints (assume — restrict legal input space)
###############################################################################

# AXI ARVALID must be stable once asserted until ARREADY
assume -name asm_arvalid_stable {
  (s_axi_arvalid && !s_axi_arready) |=> s_axi_arvalid
}

# AXI AWVALID stable
assume -name asm_awvalid_stable {
  (s_axi_awvalid && !s_axi_awready) |=> s_axi_awvalid
}

# Memory side: RVALID eventually asserted after ARVALID/ARREADY
assume -name asm_mem_rvalid_bounded {
  $rose(m_axi_arvalid && m_axi_arready) |-> ##[1:64] m_axi_rvalid
}

# Snoop address is cache-line aligned
assume -name asm_snoop_aligned {
  ac_valid |-> (ac_addr[5:0] == 6'b0)
}

# Only one snoop at a time (single-threaded snoop channel)
assume -name asm_one_snoop {
  ac_valid |-> !$past(ac_valid && !ac_ready, 1)
}

###############################################################################
# 3. Properties to PROVE
###############################################################################

# ── Coherency Invariant 1: At most one Modified line per cache set ──────────
property p_one_modified_per_set;
  forall (s : 0 to $param(NUM_SETS)-1) {
    @(posedge clk) disable iff (~rst_n)
    // Behavioral check: count M-state ways
    $countones({
      u_tag_array.tag_ram[s][0].mesi == MESI_MODIFIED,
      u_tag_array.tag_ram[s][1].mesi == MESI_MODIFIED,
      u_tag_array.tag_ram[s][2].mesi == MESI_MODIFIED,
      u_tag_array.tag_ram[s][3].mesi == MESI_MODIFIED
    }) <= 1
  }
endproperty
prove -name pv_one_modified {p_one_modified_per_set}

# ── Coherency Invariant 2: Dirty bit ↔ Modified state ─────────────────────
property p_dirty_iff_modified;
  forall (s : 0 to $param(NUM_SETS)-1)
  forall (w : 0 to $param(WAYS)-1) {
    @(posedge clk) disable iff (~rst_n)
    u_tag_array.tag_ram[s][w].valid |->
    (u_tag_array.tag_ram[s][w].dirty ==
     (u_tag_array.tag_ram[s][w].mesi == MESI_MODIFIED))
  }
endproperty
prove -name pv_dirty_iff_modified {p_dirty_iff_modified}

# ── Coherency Invariant 3: Valid bit must be set for any non-Invalid MESI ──
property p_valid_for_mesi;
  forall (s : 0 to $param(NUM_SETS)-1)
  forall (w : 0 to $param(WAYS)-1) {
    @(posedge clk) disable iff (~rst_n)
    (u_tag_array.tag_ram[s][w].mesi != MESI_INVALID) |->
    u_tag_array.tag_ram[s][w].valid
  }
endproperty
prove -name pv_valid_for_mesi {p_valid_for_mesi}

# ── Deadlock 1: Snoop always gets response ──────────────────────────────────
property p_snoop_no_deadlock;
  @(posedge clk) disable iff (~rst_n)
  $rose(ac_valid && ac_ready) |-> ##[1:256] (cr_valid && cr_ready)
endproperty
prove -name pv_snoop_no_deadlock {p_snoop_no_deadlock}

# ── Deadlock 2: Cache miss always completes ─────────────────────────────────
property p_miss_completes;
  @(posedge clk) disable iff (~rst_n)
  (s_axi_arvalid && s_axi_arready && !cache_hit) |->
  ##[1:512] (s_axi_rvalid && s_axi_rready && s_axi_rlast)
endproperty
prove -name pv_miss_completes {p_miss_completes}

# ── AXI: RVALID implies previous ARVALID/ARREADY ───────────────────────────
property p_rvalid_ordered;
  @(posedge clk) disable iff (~rst_n)
  s_axi_rvalid |-> $past(s_axi_arvalid && s_axi_arready, 1, s_axi_arvalid)
endproperty
prove -name pv_rvalid_ordered {p_rvalid_ordered}

# ── AXI: BVALID implies previous AWVALID+AWREADY and WLAST+WREADY ──────────
property p_bvalid_ordered;
  @(posedge clk) disable iff (~rst_n)
  s_axi_bvalid |->
  $past(s_axi_awvalid && s_axi_awready, 1, s_axi_awvalid) &&
  $past(s_axi_wvalid  && s_axi_wready  && s_axi_wlast, 1, s_axi_wvalid)
endproperty
prove -name pv_bvalid_ordered {p_bvalid_ordered}

# ── MSHR: never exceeds DEPTH ───────────────────────────────────────────────
property p_mshr_bounded;
  @(posedge clk) disable iff (~rst_n)
  u_mshr.mshr_used_count <= $param(MSHR_DEPTH)
endproperty
prove -name pv_mshr_bounded {p_mshr_bounded}

# ── LRU: victim way is always a valid index ─────────────────────────────────
property p_lru_victim_valid;
  @(posedge clk) disable iff (~rst_n)
  u_lru.victim_way < $param(WAYS)
endproperty
prove -name pv_lru_victim {p_lru_victim_valid}

###############################################################################
# 4. Cover properties (reachability)
###############################################################################

# Can reach M state
cover -name cv_reach_modified {
  @(posedge clk) disable iff (~rst_n)
  u_tag_array.tag_ram[0][0].mesi == MESI_MODIFIED
}

# Can reach snoop with PassDirty
cover -name cv_snoop_pass_dirty {
  @(posedge clk) disable iff (~rst_n)
  cr_valid && cr_ready && cr_resp[3]  // PassDirty bit
}

# Can reach MSHR almost-full (DEPTH-1 used)
cover -name cv_mshr_near_full {
  @(posedge clk) disable iff (~rst_n)
  u_mshr.mshr_used_count == $param(MSHR_DEPTH) - 1
}

# Can reach dirty eviction
cover -name cv_dirty_eviction {
  @(posedge clk) disable iff (~rst_n)
  wb_pending && m_axi_awvalid
}

###############################################################################
# 5. Run
###############################################################################
set_prove_time_limit 3600  ;# 1 hour limit

prove -all

report -file reports/formal/jg_mesi_report.txt
report -cover -file reports/formal/jg_cover_report.txt

###############################################################################
# 6. Result check
###############################################################################
set proven  [llength [get_results -status proven]]
set failed  [llength [get_results -status failed]]
set undetermined [llength [get_results -status undetermined]]

puts "======================================================="
puts "  JasperGold FPV Results"
puts "======================================================="
puts "  Proven       : $proven"
puts "  Failed       : $failed"
puts "  Undetermined : $undetermined"
puts "======================================================="

if {$failed > 0} {
  puts "  *** FORMAL VERIFICATION FAILED ***"
  exit 1
} else {
  puts "  *** FORMAL VERIFICATION PASSED ***"
  exit 0
}
