###############################################################################
# File       : formal/constraints/axi_master_env_constraints.tcl
# Description: Formal environment assumptions for the AXI4 master proof.
#              Constrains the memory-side response behaviour to legal AXI4.
###############################################################################

# Memory always accepts AR within 4 cycles
assume -name asm_axm_arready   { m_axi_arvalid |-> ##[0:4] m_axi_arready }

# Memory returns R data within 32 cycles of ARREADY
assume -name asm_axm_rvalid    {
  (m_axi_arvalid && m_axi_arready) |-> ##[1:32] m_axi_rvalid
}

# RVALID stable until RREADY
assume -name asm_axm_rvalid_sta {
  (m_axi_rvalid && !m_axi_rready) |=> m_axi_rvalid
}

# R data stable while RVALID high
assume -name asm_axm_rdata_sta {
  (m_axi_rvalid && !m_axi_rready) |=>
  $stable(m_axi_rdata) && $stable(m_axi_rresp) && $stable(m_axi_rlast)
}

# Memory responds OKAY only
assume -name asm_axm_rresp_ok { m_axi_rvalid |-> (m_axi_rresp == 2'b00) }

# Memory accepts AW within 4 cycles
assume -name asm_axm_awready   { m_axi_awvalid |-> ##[0:4] m_axi_awready }

# Memory accepts W beats within 4 cycles
assume -name asm_axm_wready    { m_axi_wvalid  |-> ##[0:4] m_axi_wready  }

# Memory sends BVALID within 32 cycles of AW+W complete
assume -name asm_axm_bvalid    {
  (m_axi_awvalid && m_axi_awready) |-> ##[2:32] m_axi_bvalid
}

# BVALID stable until BREADY
assume -name asm_axm_bvalid_sta {
  (m_axi_bvalid && !m_axi_bready) |=> m_axi_bvalid
}

# Memory write response is OKAY
assume -name asm_axm_bresp_ok { m_axi_bvalid |-> (m_axi_bresp == 2'b00) }

# Only one fill outstanding at a time (MSHR serialises)
assume -name asm_axm_one_fill {
  m_axi_arvalid |-> !$past(m_axi_arvalid && !m_axi_arready, 1)
}

# No flush or power operations during AXI master proof
assume -name asm_axm_no_flush   { !cache_flush_req  }
assume -name asm_axm_no_powerdn { !cache_power_down }
assume -name asm_axm_no_snoop   { !ac_valid         }
