###############################################################################
# File       : lru_env_constraints.tcl
# Description: Formal environment assumptions for the LRU proof.
###############################################################################

# Access set must be within range
assume -name asm_lru_access_set_valid {
  access_valid |-> (access_set < $param(NUM_SETS))
}

# Access way must be within range
assume -name asm_lru_access_way_valid {
  access_valid |-> (access_way < $param(WAYS))
}

# Victim set must be within range
assume -name asm_lru_victim_set_valid {
  victim_set < $param(NUM_SETS)
}

# Access valid is a single-cycle pulse (simplify state space)
assume -name asm_lru_access_pulse {
  access_valid |=> !access_valid
}
