# L2 Cache Controller — Formal Verification Plan

**Version:** 1.0  
**Author:** Bibin N Biji  
**Tool:** Cadence JasperGold FPV (Formal Property Verification)

---

## 1. Overview

Formal verification complements simulation by providing **exhaustive proof** of key properties over all possible input sequences. For the L2 cache controller, formal targets three areas where simulation coverage is insufficient:

| Area | Why Simulation Is Not Enough |
|---|---|
| MESI invariants | 2^(512×4×2) states — impossible to enumerate |
| Deadlock freedom | Rare input sequences; simulation may not hit them |
| Protocol compliance | Subtle race conditions in low-probability orderings |

---

## 2. Formal Folder Structure

```
formal/
├── l2_mesi_properties.tcl       ← Original monolithic proof script (kept for reference)
│
├── props/                        ← SVA property modules (one per design block)
│   ├── props_axi_slave.sv        ← AXI4 slave port: 14 asserts + 6 covers
│   ├── props_mesi_coherency.sv   ← MESI protocol: 12 asserts + 7 covers
│   ├── props_mshr.sv             ← MSHR: 11 asserts + 7 covers
│   └── props_lru.sv              ← LRU controller: 5 asserts + 5 covers
│
├── scripts/                      ← JasperGold run scripts per proof goal
│   ├── run_all_proofs.tcl        ← Master orchestrator (sequential or parallel)
│   ├── run_axi_slave.tcl         ← AXI compliance proof (~20 min)
│   ├── run_mesi.tcl              ← MESI invariants + deadlock (~90 min)
│   ├── run_mshr.tcl              ← MSHR correctness (~45 min)
│   └── run_lru.tcl               ← LRU replacement (~10 min)
│
├── constraints/                  ← Formal assumption files (environment model)
│   ├── axi_env_constraints.tcl   ← Legal AXI4 stimulus space
│   ├── mesi_env_constraints.tcl  ← Legal ACE snoop stimulus
│   ├── mshr_env_constraints.tcl  ← MSHR stimulus constraints
│   └── lru_env_constraints.tcl   ← LRU access constraints
│
├── cov/
│   └── run_coverage.tcl          ← Cover property closure script
│
└── waivers/
    └── formal_waivers.tcl        ← Justified waivers with ticket references
```

---

## 3. Property Inventory

### 3.1 AXI Slave Properties (`props_axi_slave.sv`)

| Property | Category | Expected |
|---|---|---|
| `P_AXS_AR_VALID_STABLE` | Safety | PROVEN |
| `P_AXS_AR_ADDR_STABLE` | Safety | PROVEN |
| `P_AXS_AW_VALID_STABLE` | Safety | PROVEN |
| `P_AXS_AW_ADDR_STABLE` | Safety | PROVEN |
| `P_AXS_W_VALID_STABLE` | Safety | PROVEN |
| `P_AXS_W_DATA_STABLE` | Safety | PROVEN |
| `P_AXS_R_VALID_STABLE` | Safety | PROVEN |
| `P_AXS_R_DATA_STABLE` | Safety | PROVEN |
| `P_AXS_B_VALID_STABLE` | Safety | PROVEN |
| `P_AXS_B_RESP_STABLE` | Safety | PROVEN |
| `P_AXO_RVALID_AFTER_AR` | Ordering | PROVEN |
| `P_AXO_BVALID_AFTER_AW` | Ordering | PROVEN |
| `P_AXD_RLAST_ON_LAST_BEAT` | Data | PROVEN |
| `P_AXD_NO_RLAST_BEFORE_LAST` | Data | PROVEN |
| `P_AXD_RRESP_VALID` | Data | PROVEN |
| `P_AXD_BRESP_VALID` | Data | PROVEN |
| `P_AXS_NO_ARREADY_WHEN_MSHR_FULL` | Safety | PROVEN |
| `P_AXO_READ_LIVENESS` | Liveness | PROVEN |
| `P_AXO_WRITE_LIVENESS` | Liveness | PROVEN |
| `P_AXD_HIT_MISS_EXCL` | Safety | PROVEN |

### 3.2 MESI Coherency Properties (`props_mesi_coherency.sv`)

| Property | Category | Expected |
|---|---|---|
| `P_MESI_INV_ONE_MODIFIED` | Invariant | PROVEN (waived at N=512) |
| `P_MESI_INV_DIRTY_IFF_MODIFIED` | Invariant | PROVEN |
| `P_MESI_INV_VALID_FOR_NONI` | Invariant | PROVEN |
| `P_MESI_TRANS_S_TO_M_UPGRADE` | Transition | PROVEN |
| `P_MESI_SNOOP_PASSDIRTY_HAS_CD` | Protocol | PROVEN |
| `P_MESI_SNOOP_PASSDIRTY_NEEDS_M` | Protocol | PROVEN |
| `P_MESI_SNOOP_CR_STABLE` | Safety | PROVEN |
| `P_MESI_SNOOP_CD_STABLE` | Safety | PROVEN |
| `P_MESI_DEAD_SNOOP_RESPONSE` | Liveness | PROVEN |
| `P_MESI_DEAD_AC_ACCEPTED` | Liveness | PROVEN |
| `P_MESI_RESET_INVALID` | Safety | PROVEN |

### 3.3 MSHR Properties (`props_mshr.sv`)

| Property | Category | Expected |
|---|---|---|
| `P_MSHR_SAF_COUNT_BOUNDED` | Safety | PROVEN |
| `P_MSHR_SAF_FULL_CORRECT` | Safety | PROVEN |
| `P_MSHR_SAF_NO_ALLOC_FULL` | Safety | PROVEN |
| `P_MSHR_SAF_FILL_HAS_ENTRY` | Safety | PROVEN |
| `P_MSHR_SAF_FILL_ADDR_MATCH` | Safety | PROVEN |
| `P_MSHR_SAF_STATE_LEGAL` | Safety | PROVEN |
| `P_MSHR_SAF_NO_DUPLICATE_ADDR` | Safety | PROVEN (waived at D=16) |
| `P_MSHR_SAF_RESP_VALID_ENTRY` | Safety | PROVEN |
| `P_MSHR_LIV_ENTRY_COMPLETES` | Liveness | PROVEN (waived bound) |
| `P_MSHR_LIV_FILL_TO_RESP` | Liveness | PROVEN |
| `P_MSHR_ORD_WB_BEFORE_FILL` | Ordering | PROVEN |
| `P_MSHR_SAF_RESET_CLEAN` | Safety | PROVEN |

### 3.4 LRU Properties (`props_lru.sv`)

| Property | Category | Expected |
|---|---|---|
| `P_LRU_SAF_VICTIM_RANGE` | Safety | PROVEN |
| `P_LRU_SAF_NO_MRU_VICTIM` | Safety | PROVEN |
| `P_LRU_SAF_STATE_CHANGES_ON_ACCESS` | Safety | PROVEN |
| `P_LRU_SAF_NO_SPURIOUS_UPDATE` | Safety | PROVEN (waived N=512) |
| `P_LRU_SAF_RESET` | Safety | PROVEN |

---

## 4. How to Run

```bash
# Run all proof goals sequentially
make formal

# Run a specific goal
jg -fpv formal/scripts/run_mesi.tcl

# Run all goals (parallel engines)
jg -fpv formal/scripts/run_all_proofs.tcl

# Cover closure only
jg -cover formal/cov/run_coverage.tcl

# With waivers applied
jg -fpv formal/scripts/run_all_proofs.tcl \
   -init formal/waivers/formal_waivers.tcl
```

---

## 5. Constraint Philosophy

**The formal environment must be neither too tight nor too loose:**

- **Too tight** (over-constrained): proof passes but some real bugs are excluded from the search space — false sense of security
- **Too loose** (under-constrained): tool explores illegal states — vacuous proofs or spurious failures

Each constraint file is kept minimal: only the assumptions strictly required by the AXI4 / ACE specification are added. Design-specific assumptions (e.g., memory latency bounds) are added only where needed to achieve convergence, and are documented with the reason.

---

## 6. Sign-Off Criteria

| Criterion | Target |
|---|---|
| All `assert` properties | PROVEN or WAIVED (with ticket) |
| All `cover` properties | COVERED or WAIVED (with ticket) |
| Waived properties | ≤ 5 (all documented in `waivers/formal_waivers.tcl`) |
| Zero vacuous proofs | Confirmed via witness inspection |
| Undetermined properties | 0 (increase bound or add constraints) |

---

*Bibin N Biji — ASIC RTL / Formal Verification Engineer*
