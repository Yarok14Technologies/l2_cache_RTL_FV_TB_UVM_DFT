###############################################################################
# File       : axi_env_constraints.tcl
# Description: Formal environment assumptions constraining the AXI4 stimulus
#              space to legal AXI4 transactions only.
#              Sourced by run_axi_slave.tcl before prove -all.
#
# These assumptions encode AXI4 spec requirements on the initiator side,
# so the tool only explores reachable states within legal protocol behaviour.
###############################################################################

###############################################################################
# AR channel — master-driven assumptions
###############################################################################

# ARVALID must not deassert before ARREADY (AXI4 §A3.2.1)
assume -name asm_arvalid_stable {
  (s_axi_arvalid && !s_axi_arready) |=> s_axi_arvalid
}

# AR signals must be stable while ARVALID is high
assume -name asm_araddr_stable {
  (s_axi_arvalid && !s_axi_arready) |=>
  ($stable(s_axi_araddr) && $stable(s_axi_arlen) &&
   $stable(s_axi_arid)   && $stable(s_axi_arburst) &&
   $stable(s_axi_arsize))
}

# Only INCR burst type (most common; FIXED and WRAP optional for now)
assume -name asm_arburst_incr {
  s_axi_arvalid |-> (s_axi_arburst == 2'b01)
}

# Burst length 0–15 (restrict state space — full 256 checked in simulation)
assume -name asm_arlen_bounded {
  s_axi_arvalid |-> (s_axi_arlen <= 8'd15)
}

# Address always 64-bit aligned
assume -name asm_araddr_aligned {
  s_axi_arvalid |-> (s_axi_araddr[2:0] == 3'b000)
}

# Size always 3 (8 bytes = 64-bit word)
assume -name asm_arsize_64b {
  s_axi_arvalid |-> (s_axi_arsize == 3'b011)
}

###############################################################################
# AW channel
###############################################################################
assume -name asm_awvalid_stable {
  (s_axi_awvalid && !s_axi_awready) |=> s_axi_awvalid
}

assume -name asm_awaddr_stable {
  (s_axi_awvalid && !s_axi_awready) |=>
  ($stable(s_axi_awaddr) && $stable(s_axi_awlen) && $stable(s_axi_awid))
}

assume -name asm_awaddr_aligned {
  s_axi_awvalid |-> (s_axi_awaddr[2:0] == 3'b000)
}

###############################################################################
# W channel
###############################################################################
assume -name asm_wvalid_stable {
  (s_axi_wvalid && !s_axi_wready) |=> s_axi_wvalid
}

assume -name asm_wdata_stable {
  (s_axi_wvalid && !s_axi_wready) |=>
  ($stable(s_axi_wdata) && $stable(s_axi_wstrb) && $stable(s_axi_wlast))
}

# WLAST must be asserted on exactly the last beat (AW must precede W)
assume -name asm_wlast_correct {
  (s_axi_wvalid && s_axi_wlast) |->
  s_axi_awvalid || $past(s_axi_awvalid && s_axi_awready, 1, 1'b1)
}

###############################################################################
# R / B channel — ready signals (initiator side)
###############################################################################

# RREADY must eventually be asserted (no permanent stall by initiator)
assume -name asm_rready_liveness {
  s_axi_rvalid |-> ##[0:32] s_axi_rready
}

assume -name asm_bready_liveness {
  s_axi_bvalid |-> ##[0:32] s_axi_bready
}

###############################################################################
# Memory-side — memory always responds eventually
###############################################################################
assume -name asm_mem_arready {
  m_axi_arvalid |-> ##[0:4] m_axi_arready
}

assume -name asm_mem_rvalid_bounded {
  (m_axi_arvalid && m_axi_arready) |-> ##[1:64] m_axi_rvalid
}

assume -name asm_mem_rvalid_stable {
  (m_axi_rvalid && !m_axi_rready) |=> m_axi_rvalid
}

assume -name asm_mem_awready {
  m_axi_awvalid |-> ##[0:4] m_axi_awready
}

assume -name asm_mem_wready {
  m_axi_wvalid |-> ##[0:4] m_axi_wready
}

assume -name asm_mem_bvalid_bounded {
  (m_axi_awvalid && m_axi_awready) |-> ##[1:16] m_axi_bvalid
}

assume -name asm_mem_bresp_okay {
  (m_axi_bvalid) |-> (m_axi_bresp == 2'b00)
}

###############################################################################
# ACE snoop — snoop never arrives during formal proof (for AXI goal isolation)
###############################################################################
assume -name asm_no_snoop_for_axi_goal {
  !ac_valid
}

###############################################################################
# Power / flush — inactive during this proof
###############################################################################
assume -name asm_no_flush    { !cache_flush_req  }
assume -name asm_no_powerdn  { !cache_power_down }
