# L2 Cache Controller — DFT Architecture Specification

**Document Version:** 1.0  
**Author:** Bibin N Biji  
**Applicable To:** `l2_cache_dft_top` wrapper + `l2_cache_top` core

---

## 1. DFT Strategy Overview

The L2 cache DFT implementation uses a three-pronged test strategy:

| Test Type | Method | Target Fault Coverage |
|---|---|---|
| Logic (flip-flop) faults | Multiplexed scan (MUX-D) | ≥ 98% stuck-at, ≥ 92% transition |
| SRAM faults | Built-In Self-Test (March-C) | ≥ 99% stuck-at (SRAM) |
| I/O pad faults | Boundary scan (JTAG / IEEE 1149.1) | 100% (structural) |

---

## 2. Scan Chain Architecture

### 2.1 Chain Organisation

The design is partitioned into **4 parallel scan chains**, each approximately **2912 FFs** long (estimated post-synthesis):

| Chain | Contents | Approx. FF Count |
|---|---|---|
| 0 | Request pipeline regs, tag array pipeline stage | ~2900 |
| 1 | LRU PLRU state regs (512×3b), MSHR entry state FFs | ~2920 |
| 2 | Coherency FSM state, snoop capture regs, AXI slave FFs | ~2910 |
| 3 | AXI master state, data path regs, performance counters | ~2900 |

Total estimated FF count: **~11 648** (varies with synthesis options).

### 2.2 Scan Cell Style

**Multiplexed flip-flop (MUX-D):**

```
         D ──┐
             ├── 2:1 MUX ──► FF ──► Q
        SI ──┘       ↑
                     SE (scan enable)
                           └──► SO (to next FF)
```

Advantages over clocked-scan:
- No clock constraints between scan cells
- Tool support in DC, Genus
- Compatible with all library FF flavours

### 2.3 Test Ports

| Port | Direction | Function |
|---|---|---|
| `test_clk` | Input | Dedicated test clock (100 MHz typical) |
| `test_se` | Input | Scan enable — 1 = shift mode, 0 = capture mode |
| `test_tm[1:0]` | Input | Test mode: `00`=functional, `01`=scan, `10`=BIST |
| `test_rst_n` | Input | Active-low test reset (initialises all FFs before shift) |
| `scan_in[3:0]` | Input | Scan data input (one per chain) |
| `scan_out[3:0]` | Output | Scan data output (one per chain) |
| `bist_done` | Output | BIST complete pulse |
| `bist_pass` | Output | BIST result — 1 = all macros passed |
| `bist_fail_map[15:0]` | Output | Per-SRAM-macro fail bits (4 banks × 4 ways) |

### 2.4 Clock Gating Bypass

All Integrated Clock Gate (ICG) cells are replaced by **`l2_icg_scan_bypass`** instances that force the clock ungated when `test_se = 1`. This ensures all downstream FFs receive clock during scan shift.

---

## 3. BIST Architecture (SRAM March-C)

### 3.1 Covered Memories

| SRAM Instance | Size | Array Dimensions |
|---|---|---|
| `u_data_array/sram[0..3]` | 4 × 32 KB data banks | 512×4×8 × 72b (w/ ECC) |
| `u_tag_array` (FF-based) | ~7.3 KB tag bits | Covered by scan |

Only **data SRAM macros** use BIST. Tag bits are in flip-flops and are covered by the scan chain.

### 3.2 March-C Algorithm

```
         Address direction
         ──────────────────────────────────────────
M0       ↑  Write 0 to all cells
M1       ↑  Read 0, Write 1
M2       ↑  Read 1, Write 0
M3       ↓  Read 0, Write 1
M4       ↓  Read 1, Write 0
M5       ↓  Read 0
         ──────────────────────────────────────────
Total operations: 11 × N  (N = number of cells)
```

**Fault coverage for March-C:**

| Fault Class | Detected? |
|---|---|
| Stuck-At-0 / Stuck-At-1 | ✔ |
| Transition fault (0→1, 1→0) | ✔ |
| Coupling fault — idempotent | ✔ |
| Coupling fault — state | ✔ |
| Address decoder fault | ✔ |
| Neighbourhood pattern sensitive (NPS0) | Partial ✔ |
| Open/short (neighbourhood) | Partial ✔ |

### 3.3 BIST Timing

At 100 MHz test clock, for 256 KB L2:
```
Total cells: 4 banks × 512 sets × 4 ways × 8 words = 65 536 words
March-C ops: 11 × 65 536 = 720 896 memory operations
At 100 MHz: 720 896 / 100×10⁶ ≈ 7.2 ms per bank
4 banks parallel: ≈ 7.2 ms total BIST time
```

### 3.4 BIST Fail Map

`bist_fail_map[NUM_BANKS × WAYS - 1 : 0]` — one bit per SRAM macro:

```
bit  0: Bank 0, Way 0
bit  1: Bank 0, Way 1
bit  2: Bank 0, Way 2
bit  3: Bank 0, Way 3
bit  4: Bank 1, Way 0
...
bit 15: Bank 3, Way 3
```

---

## 4. ATPG Configuration

### 4.1 Fault Models

| Fault model | Tool option | Coverage target |
|---|---|---|
| Stuck-at | `-fault_type stuck` | ≥ 98% |
| Transition | `-fault_type transition` | ≥ 92% |
| Path delay | `-fault_type path_delay` | ≥ 85% (optional) |

### 4.2 ATPG Constraints

The following pins are constrained to fixed values during ATPG:

| Pin | Constraint | Reason |
|---|---|---|
| `cache_power_down` | 0 (constant) | Power gate open during test |
| `cache_flush_req` | 0 (constant) | No functional activity during scan |
| `ac_valid` | 0 (constant) | No snoop injection during scan |

### 4.3 Untestable (UNT) Fault Analysis

Expected untestable faults (< 2% of total):

- **ICG output faults**: gated clock outputs are structurally untestable from PIs in some paths — mitigated by ICG bypass in scan mode
- **Reset-dependent FFs**: FFs with only reset as observable path — covered by reset sequence verification
- **BIST controller internal nodes**: tested via BIST pass/fail output

---

## 5. Boundary Scan (IEEE 1149.1 / JTAG)

The DFT wrapper provides stubs for JTAG integration at the SoC level:

| JTAG Signal | Pin Name | Function |
|---|---|---|
| TCK | `jtag_tck` | JTAG clock |
| TMS | `jtag_tms` | TAP controller state |
| TDI | `jtag_tdi` | Serial data in |
| TDO | `jtag_tdo` | Serial data out |
| TRST_N | `jtag_trst_n` | JTAG reset |

Boundary scan cells are inserted at all I/O pads of the `l2_cache_dft_top` module by the DFT tool. This enables:
- Interconnect testing between L2 and the SoC interconnect fabric
- At-speed I/O testing
- EXTEST and INTEST modes per IEEE 1149.1

---

## 6. DFT Sign-Off Checklist

- [ ] Scan insertion complete — DC `insert_dft` run without errors
- [ ] DFT DRC: 0 errors (`check_dft` in DC)
- [ ] Scan chain continuity: all 4 chains intact (GLS simulation)
- [ ] Scan shift coverage: 100% FFs reachable and observable
- [ ] Stuck-at fault coverage ≥ 98%
- [ ] Transition fault coverage ≥ 92%
- [ ] BIST simulation: bist_pass = 1 on clean netlist
- [ ] BIST fault injection: bist_fail_map correct for injected faults
- [ ] Pattern count ≤ 5000 (test time budget: < 50 ms at 100 MHz)
- [ ] STIL patterns validated on GLS testbench
- [ ] No X propagation in scan shift mode (check SDF back-annotation)

---

## 7. File Map

```
dft/
├── rtl/
│   ├── l2_cache_dft_top.sv      ← DFT wrapper (scan ports, BIST, clock mux)
│   ├── l2_bist_ctrl.sv          ← March-C BIST controller
│   └── l2_scan_wrapper.sv       ← ICG bypass, scan mux, observation point cells
├── atpg/
│   ├── run_atpg.tcl             ← TetraMAX ATPG flow (stuck-at + transition)
│   └── gls_atpg_tb.v            ← Gate-level simulation testbench for patterns
├── patterns/
│   └── l2_scan_continuity.stil  ← Scan continuity STIL patterns (reference)
│       (l2_stuck_at.stil)       ← Generated by TetraMAX (not committed)
│       (l2_transition.stil)     ← Generated by TetraMAX (not committed)
└── docs/
    └── dft_architecture.md      ← This document
```

---

*Bibin N Biji — ASIC RTL / DFT Design Engineer*
