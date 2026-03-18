# L2 Cache — Verification Plan

**Version:** 1.0  
**Author:** Bibin N Biji  

---

## 1. Verification Objectives

| Objective | Method | Signoff Criteria |
|---|---|---|
| Functional correctness (hit/miss) | UVM simulation + scoreboard | 0 scoreboard errors across all tests |
| MESI coherency protocol | Directed tests + constrained-random | All 12 legal transitions covered 100% |
| AXI4 protocol compliance | SVA + UVM monitor | 0 assertion failures |
| MSHR correctness | Directed + stress | MSHR full back-pressure verified; all fills complete |
| ECC correction | Directed fault injection | Single-bit corrected; double-bit flagged as SLVERR |
| Deadlock freedom | Formal (JasperGold) | All 9 formal goals: PROVEN |
| MESI invariants | Formal (JasperGold) | one-M-per-set, dirty↔modified proven |
| Power (flush, power-down) | Directed simulation | cache_flush_done asserted; WBs verified |
| Code coverage | Simulation | Line 100%, Branch 100%, Toggle 95%, FSM 100% |
| Functional coverage | Covergroups | All coverpoints at target % |

---

## 2. Test Plan Summary

### 2.1 Smoke (CI gate — 2 tests, ~1 min)

| Test | Verifies |
|---|---|
| `l2_smoke_read_test` | Basic read hit path; 1 transaction |
| `l2_smoke_write_test` | Basic write path; B response received |

### 2.2 Directed Functional (15 tests)

| Test | Scenario | Key Check |
|---|---|---|
| `l2_read_hit_test` | Write then read same line | Latency ≤ 4 cycles |
| `l2_write_hit_test` | Write hit → dirty | MESI→M, dirty=1 |
| `l2_read_miss_fill_test` | Cold read miss | AXI fill issued; data correct |
| `l2_write_allocate_test` | Write miss → RFO | Line allocated, write applied |
| `l2_eviction_dirty_test` | 5 fills into 4-way set | WB before fill |
| `l2_eviction_clean_test` | Silent clean eviction | No WB issued |
| `l2_flush_test` | Software cache flush | All dirty WBs verified |
| `l2_mesi_exclusive_upgrade_test` | S→M upgrade | Upgrade req+ack sequence |
| `l2_mesi_snoop_read_shared_test` | Snoop on M line | PassDirty=1, M→S |
| `l2_mesi_snoop_invalidate_test` | CleanInvalid snoop | Line→I, next access miss |
| `l2_mesi_snoop_exclusive_test` | ReadUnique on M | Dirty forwarded, M→I |
| `l2_false_sharing_test` | Two words, same line | Ping-pong; no deadlock |
| `l2_snoop_during_miss_test` | Snoop while fill in-flight | Ordered correctly |
| `l2_mshr_full_test` | Fill MSHR to depth-1 | ARREADY deasserted |
| `l2_power_down_wakeup_test` | Power-gate + wakeup | Post-wakeup: cold misses |

### 2.3 Constrained-Random (5 test classes × N seeds)

| Test Class | Ops | Write% | Seeds (regression) |
|---|---|---|---|
| `l2_random_traffic_test` (light) | 100 | 30% | 10 |
| `l2_random_traffic_test` (heavy) | 1000 | 50% | 10 |
| `l2_random_traffic_test` (write-heavy) | 500 | 80% | 5 |
| `l2_outstanding_16_test` | 16 parallel | 0% | 3 |
| `l2_stress_test` | 5000 | 40% | 20 (nightly) |

---

## 3. Functional Coverage Plan

### 3.1 MESI Transitions (target: 100%)

All 12 legal state×event combinations must be covered:

```
I + local_read  → E
I + local_write → M  (via RFO)
S + local_read  → S
S + local_write → M  (via upgrade)
S + snoop_ReadShared  → S
S + snoop_CleanInvalid→ I
E + local_read  → E
E + local_write → M  (silent)
E + snoop_ReadShared  → S
E + snoop_ReadUnique  → I
M + local_rw    → M
M + snoop_ReadShared  → S  (+ dirty WB)
M + snoop_ReadUnique  → I  (+ dirty forward)
M + snoop_CleanInvalid→ I  (+ WB)
```

### 3.2 AXI Transaction Properties (target: 95%)

- Read × Write × Burst len {1,4,8,16}
- Latency bins: hit (<4 cycles), L3 fill (10–30), DRAM fill (30–100)
- BRESP/RRESP: OKAY, SLVERR (ECC error injection)

### 3.3 Snoop Coverage (target: 100%)

- All 5 snoop types: ReadShared, ReadUnique, CleanInvalid, CleanUnique, MakeInvalid
- Each snoop type × hit state (I/S/E/M)
- PassDirty=1 and PassDirty=0 for each applicable type

### 3.4 MSHR Coverage (target: 90%)

- MSHR empty (0 entries used)
- MSHR single entry
- MSHR half-full (8 entries)
- MSHR full (16 entries) → back-pressure
- Address merge (two misses to same line)

---

## 4. Formal Verification Plan

Tool: Cadence JasperGold FPV

| Property | Type | Expected Result |
|---|---|---|
| `p_one_modified_per_set` | Invariant | PROVEN |
| `p_dirty_iff_modified` | Invariant | PROVEN |
| `p_valid_for_mesi` | Invariant | PROVEN |
| `p_snoop_no_deadlock` | Liveness | PROVEN |
| `p_miss_completes` | Liveness | PROVEN |
| `p_rvalid_ordered` | Order | PROVEN |
| `p_bvalid_ordered` | Order | PROVEN |
| `p_mshr_bounded` | Bound | PROVEN |
| `p_lru_victim_valid` | Bound | PROVEN |

Estimated convergence: 2–4 hours with 16 engines.

---

## 5. Code Coverage Exclusions

Excluded from 100% line/branch coverage requirement:

| Location | Exclusion Reason |
|---|---|
| `// pragma coverage off` regions | Tool-specific tie-offs |
| `default:` in case with `unique` keyword | Unreachable by design |
| `$fatal` and `$error` bodies | Simulation-only; synthesis removes |
| ECC double-bit error path | Requires fault injection test (separate) |
| `MOESI_OWNED` state in `moesi_state_t` | Not yet implemented (future) |

---

## 6. Sign-off Checklist

- [ ] All directed tests: PASS (0 SB errors)
- [ ] Constrained-random regression: PASS (≥50 seeds per class)  
- [ ] Line coverage ≥ 100%
- [ ] Branch coverage ≥ 100%
- [ ] Toggle coverage ≥ 95%
- [ ] FSM state + transition coverage = 100%
- [ ] MESI transition coverage = 100%
- [ ] Snoop type coverage = 100%
- [ ] All formal properties: PROVEN
- [ ] SpyGlass lint: 0 errors, 0 unwaived warnings
- [ ] SpyGlass CDC: 0 errors
- [ ] Synthesis timing clean (WNS ≥ 0) at 500 MHz, slow corner
- [ ] Hold timing clean (WNS ≥ 0), fast corner

---

*Bibin N Biji — ASIC RTL Design Engineer*
