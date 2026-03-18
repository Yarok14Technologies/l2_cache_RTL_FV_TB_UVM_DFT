###############################################################################
# File       : formal_waivers.tcl
# Tool       : Cadence JasperGold FPV
# Description: Waivers for known undetermined / vacuous formal results.
#              Each waiver must have: ticket reference, root cause, and
#              a review sign-off.
#
# Format:
#   waive -name <property_name> -reason "<TICKET: description>"
#
# IMPORTANT: All waivers require DFE (Design-for-Engineering) review.
#            No waiver should mask a real functional bug.
###############################################################################

###############################################################################
# WAIVER 1: PLRU spurious update check across all sets
# Status   : Undetermined (COI too large for 512-set check)
# Ticket   : L2CACHE-FV-001
# Root cause: The property P_LRU_SAF_NO_SPURIOUS_UPDATE checks all 512 sets
#             simultaneously; the state space (512 × 3 bits = 1536 state bits)
#             exceeds JasperGold's default COI limit for induction.
# Mitigation: Property is verified for a reduced 4-set model via parameter
#             override in the waivered version; coverage closure via simulation
#             confirms no cross-set corruption in 1M random cycles.
# Signed-off: Bibin N Biji, 2025-07
###############################################################################
waive -name P_LRU_SAF_NO_SPURIOUS_UPDATE \
  -reason "L2CACHE-FV-001: COI exceeds 512-set model capacity. \
           Verified on 4-set reduced model. Simulation coverage confirms \
           no cross-set PLRU corruption."

###############################################################################
# WAIVER 2: MSHR no-duplicate address for all 16 entries simultaneously
# Status   : Undetermined (O(DEPTH^2) comparators exceed solver budget)
# Ticket   : L2CACHE-FV-002
# Root cause: P_MSHR_SAF_NO_DUPLICATE_ADDR iterates all C(16,2)=120 pairs.
#             JasperGold exhausts time limit at induction depth 64.
# Mitigation: Property verified for DEPTH=4 via elaboration override;
#             the alloc logic has a single address-merge encoder path that
#             structurally prevents duplicates — verified via code review.
# Signed-off: Bibin N Biji, 2025-07
###############################################################################
waive -name P_MSHR_SAF_NO_DUPLICATE_ADDR \
  -reason "L2CACHE-FV-002: 120 pair-comparisons exceed induction budget. \
           Verified for DEPTH=4. Structural analysis of alloc path confirms \
           address-match check prevents duplicates at D=16."

###############################################################################
# WAIVER 3: MESI one-Modified-per-set across all 512 sets
# Status   : Undetermined for full NUM_SETS=512
# Ticket   : L2CACHE-FV-003
# Root cause: Generating 512 simultaneous invariant assertions exceeds the
#             elaboration memory for the generate block with NUM_SETS=512.
# Mitigation: Verified for NUM_SETS=8 with same logic; formal abstraction
#             argument: the PLRU and tag-array write logic is SET-independent
#             (each set has identical control logic, no cross-set interaction).
# Signed-off: Bibin N Biji, 2025-07
###############################################################################
waive -name P_MESI_INV_ONE_MODIFIED \
  -reason "L2CACHE-FV-003: Full 512-set generate exceeds memory limits. \
           Proved for NUM_SETS=8. Structural argument: sets are independent."

###############################################################################
# WAIVER 4: Liveness — MSHR entry completion for DEPTH=16
# Status   : Undetermined with bound 1024
# Ticket   : L2CACHE-FV-004
# Root cause: Liveness requires proving eventual progress which with 16 MSHR
#             entries and 1024-cycle bound sometimes times out for entries
#             that enter WB_PENDING state (WB can take up to 200 cycles).
# Mitigation: Property passes with bound 2048; current tool license limits
#             trace length to 1024 in batch mode. Verified in interactive mode.
#             Simulation regression with 1M random cycles shows all MSHRs
#             drain correctly.
# Signed-off: Bibin N Biji, 2025-07
###############################################################################
waive -name P_MSHR_LIV_ENTRY_COMPLETES \
  -reason "L2CACHE-FV-004: WB state extends bound beyond 1024. Proved at \
           bound 2048 in interactive mode. Simulation confirms correct drain."

###############################################################################
# WAIVER 5: Cover — RRESP SLVERR (ECC double-bit error path)
# Status   : Uncovered (requires fault injection)
# Ticket   : L2CACHE-FV-005
# Root cause: COV_AX_SLVERR requires a double-bit ECC error to fire SLVERR.
#             The formal environment does not inject ECC errors (SRAM is
#             black-boxed). This is intentional — ECC fault coverage is
#             handled by the UVM directed test suite.
# Mitigation: l2_ecc_double_error_test UVM test covers this path.
# Signed-off: Bibin N Biji, 2025-07
###############################################################################
waive -name COV_AX_SLVERR \
  -reason "L2CACHE-FV-005: Requires ECC double-bit error injection. \
           SRAM is black-boxed in FPV. Covered by l2_ecc_double_error_test \
           UVM directed test."

###############################################################################
# End of waivers
###############################################################################
puts "Loaded [llength [get_waivers]] formal waivers"
