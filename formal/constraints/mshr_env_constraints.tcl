###############################################################################
# File       : mshr_env_constraints.tcl
# Description: Formal environment assumptions for the MSHR proof.
###############################################################################

# Allocation only when DUT is not full OR when merging
assume -name asm_mshr_alloc_legal {
  alloc_req |-> (!full || alloc_merged)
}

# Fill valid implies a prior alloc_req was accepted
assume -name asm_fill_after_alloc {
  fill_valid |-> $past(alloc_req, 1, 1'b1, @(posedge clk))
}

# Fill eventually follows every allocation (bounded)
assume -name asm_fill_bounded {
  (alloc_req && !alloc_merged) |-> ##[1:256] fill_valid
}

# Response accepted within 4 cycles of becoming valid
assume -name asm_resp_accepted_bounded {
  resp_valid |-> ##[0:4] resp_accepted
}

# Write-back completes within 32 cycles
assume -name asm_wb_done_bounded {
  wb_valid |-> ##[1:32] wb_done
}

# Alloc address is cache-line aligned
assume -name asm_alloc_addr_aligned {
  alloc_req |-> (alloc_addr[5:0] == 6'b0)
}
