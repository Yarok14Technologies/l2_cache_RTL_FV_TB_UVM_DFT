###############################################################################
# File       : mesi_env_constraints.tcl
# Description: Formal environment assumptions for the MESI coherency proof.
#              These constrain the snoop stimulus space to legal ACE transactions
#              and restrict AXI traffic to keep state space manageable.
###############################################################################

###############################################################################
# AXI slave — restrict to cache-line-sized reads only
###############################################################################
assume -name asm_mesi_arvalid_stable {
  (s_axi_arvalid && !s_axi_arready) |=> s_axi_arvalid
}
assume -name asm_mesi_awvalid_stable {
  (s_axi_awvalid && !s_axi_awready) |=> s_axi_awvalid
}

# Limit burst lengths for state space reduction
assume -name asm_mesi_arlen_limit {
  s_axi_arvalid |-> (s_axi_arlen inside {8'h00, 8'h07})
}

# Memory always responds OK
assume -name asm_mesi_mem_responds {
  (m_axi_arvalid && m_axi_arready) |-> ##[1:32] m_axi_rvalid
}
assume -name asm_mesi_mem_bresp_ok {
  m_axi_bvalid |-> (m_axi_bresp == 2'b00)
}

###############################################################################
# ACE snoop — legal snoop types only
###############################################################################
assume -name asm_snoop_type_legal {
  ac_valid |-> (ac_snoop inside {4'h1, 4'h7, 4'h9, 4'hB, 4'hD})
}

# Snoop address must be cache-line aligned
assume -name asm_snoop_addr_aligned {
  ac_valid |-> (ac_addr[5:0] == 6'b0)
}

# Snoop valid must be stable until ready
assume -name asm_snoop_valid_stable {
  (ac_valid && !ac_ready) |=> ac_valid
}

# Snoop stable while valid
assume -name asm_snoop_data_stable {
  (ac_valid && !ac_ready) |=>
  ($stable(ac_addr) && $stable(ac_snoop))
}

# CR and CD ready eventually asserted (initiator won't stall forever)
assume -name asm_cr_ready_liveness {
  cr_valid |-> ##[0:8] cr_ready
}
assume -name asm_cd_ready_liveness {
  cd_valid |-> ##[0:8] cd_ready
}

# Only one snoop outstanding at a time (simplify for formal convergence)
assume -name asm_one_snoop_at_a_time {
  ac_valid |-> !$past(ac_valid && !ac_ready, 1)
}

###############################################################################
# Upgrade acknowledgement — bounded response from interconnect
###############################################################################
assume -name asm_upgrade_ack_bounded {
  upgrade_req_sent |-> ##[1:16] upgrade_ack_received
}

###############################################################################
# Power/flush — inactive for MESI proof
###############################################################################
assume -name asm_mesi_no_flush   { !cache_flush_req  }
assume -name asm_mesi_no_powerdn { !cache_power_down }
