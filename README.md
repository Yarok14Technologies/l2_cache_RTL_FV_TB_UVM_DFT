# L2 Cache Controller — RTL · UVM · DFT · Formal Verification

[![RTL](https://img.shields.io/badge/RTL-SystemVerilog%202012-blue)]()
[![UVM](https://img.shields.io/badge/UVM-1.2-green)]()
[![Lint](https://img.shields.io/badge/Lint-SpyGlass%20Clean-brightgreen)]()
[![Synthesis](https://img.shields.io/badge/Synthesis-DC%20Ultra%20%7C%20Genus-orange)]()
[![P&R](https://img.shields.io/badge/P%26R-Cadence%20Innovus-red)]()
[![Formal](https://img.shields.io/badge/Formal-JasperGold%20FPV-purple)]()
[![DFT](https://img.shields.io/badge/DFT-Scan%20%7C%20BIST%20%7C%20ATPG-yellow)]()
[![CI](https://img.shields.io/badge/CI-GitHub%20Actions-lightgrey)]()

A **production-quality, fully parameterized L2 cache controller** targeting multi-core SoC designs.
Covers the complete ASIC design flow from RTL through to GDSII — with MESI coherency,
AXI4/ACE interfaces, UVM-1.2 verification, JasperGold formal proofs, DFT infrastructure,
Synopsys DC synthesis, and Cadence Innovus P&R.

> **Author:** Bibin N Biji — ASIC RTL / DV / DFT Design Engineer
> **Target:** L2 Cache / SoC RTL roles at Qualcomm, Intel, Apple, AMD, Arm

---

## At a Glance

| Metric | Value |
|---|---|
| Total files | 95 |
| RTL modules | 16 (13 cache + 3 common) |
| Lines of SystemVerilog RTL | ~6 500 |
| UVM test classes | 40 |
| Test plan entries | 47 tests (regression, coherency, ECC, CDC, power, perf) |
| Formal properties (SVA) | 76 asserts + covers across 6 property modules |
| Formal proof goals | 7 (AXI slave, AXI master, MESI, MSHR, LRU, coherency FSM, CDC FIFO) |
| DFT scan chains | 4 × ~2912 FFs (March-C BIST for SRAM) |
| Synthesis result | 487 MHz · ~42K gates · 8.1 mW @ 28nm |
| Makefile targets | 36 (compile → sim → regression → lint → synth → P&R → formal → signoff) |

---

## Repository Structure

```
l2_cache_RTL_FV_TB_UVM_DFT/
│
├── rtl/
│   ├── cache/                          ← 13 synthesizable RTL modules
│   │   ├── l2_cache_pkg.sv             ← Types, enums, structs, ECC functions
│   │   ├── l2_cache_top.sv             ← Top-level integration wrapper
│   │   ├── l2_request_pipeline.sv      ← AXI AR/AW arbitration → 2-stage pipeline
│   │   ├── l2_tag_array.sv             ← Tag SRAM + valid/dirty/MESI flip-flops
│   │   ├── l2_data_array.sv            ← Multi-bank SRAM + SECDED ECC
│   │   ├── l2_hit_miss_detect.sv       ← N-way parallel tag comparator
│   │   ├── l2_lru_controller.sv        ← Pseudo-LRU binary tree (2/4/8/16-way)
│   │   ├── l2_coherency_fsm.sv         ← MESI FSM + AXI-ACE snoop handler
│   │   ├── l2_mshr.sv                  ← 16-entry MSHR with address merge
│   │   ├── l2_axi_master.sv            ← AXI4 master: fill reads + dirty write-backs
│   │   ├── l2_ecc_engine.sv            ← Standalone SECDED encode/check/correct
│   │   ├── l2_perf_counters.sv         ← 13 saturating CSR performance counters
│   │   └── l2_prefetch_engine.sv       ← RPT stride-based hardware prefetcher
│   │
│   └── common/                         ← Reusable RTL primitives
│       ├── sync_fifo.sv                ← Parameterized synchronous FIFO
│       ├── async_fifo.sv               ← Gray-coded 2-FF async FIFO (CDC)
│       └── rr_arbiter.sv               ← Round-robin N-requestor arbiter
│
├── tb/
│   ├── top/
│   │   └── l2_cache_tb_top.sv          ← TB top: DUT + interfaces + bind + UVM launch
│   │
│   ├── dpi/
│   │   └── ecc_inject.c                ← DPI-C ECC fault injector (single/double bit)
│   │
│   ├── assertions/
│   │   └── l2_cache_assertions.sv      ← Bind-level SVA: 12 asserts + 5 covers
│   │
│   └── uvm_tb/
│       ├── agents/
│       │   ├── axi_agent/
│       │   │   ├── axi_slave_agent.sv  ← CPU-side AXI4 driver, monitor, sequencer
│       │   │   └── axi_master_agent.sv ← Memory-side responder (configurable latency)
│       │   └── ace_snoop_agent/
│       │       └── ace_snoop_agent.sv  ← ACE AC/CR/CD driver + monitor
│       ├── sequences/
│       │   ├── l2_seq_items.sv         ← Seq items + 6 directed sequences
│       │   └── l2_coherency_seq.sv     ← 7 dedicated MESI transition sequences
│       ├── ref_model/
│       │   └── l2_ref_model.sv         ← Golden behavioral model (PLRU + MESI)
│       ├── scoreboard/
│       │   └── l2_scoreboard.sv        ← Data, response, latency checker
│       ├── coverage/
│       │   └── l2_coverage.sv          ← 5 covergroups incl. MESI cross-coverage
│       ├── env/
│       │   └── l2_cache_env.sv         ← UVM environment (6 components)
│       └── tests/
│           ├── l2_tests.sv             ← 15 base test classes
│           ├── l2_tests_extended.sv    ← 14 extended test classes
│           └── directed/
│               ├── l2_ecc_test.sv      ← ECC single/double-bit + BIST tests
│               ├── l2_cdc_power_test.sv← CDC, power-down, isolation cell tests
│               └── l2_performance_test.sv ← Streaming, working-set, latency histogram
│
├── formal/
│   ├── props/                          ← SVA property modules (one per DUT block)
│   │   ├── props_axi_slave.sv          ← 20 AXI4 slave protocol properties
│   │   ├── props_axi_master.sv         ← 15 AXI4 master protocol properties
│   │   ├── props_mesi_coherency.sv     ← 11 MESI invariants + deadlock freedom
│   │   ├── props_coherency_fsm.sv      ← 10 FSM state + transition properties
│   │   ├── props_mshr.sv               ← 12 MSHR correctness + liveness properties
│   │   └── props_lru.sv                ← 5 PLRU replacement properties
│   ├── scripts/                        ← JasperGold run scripts
│   │   ├── run_all_proofs.tcl          ← Master orchestrator (all 7 goals)
│   │   ├── run_axi_slave.tcl
│   │   ├── run_axi_master.tcl
│   │   ├── run_mesi.tcl
│   │   ├── run_coherency_fsm.tcl
│   │   ├── run_mshr.tcl
│   │   └── run_lru.tcl
│   ├── constraints/                    ← Formal assumption files (5 files)
│   ├── cov/
│   │   └── run_coverage.tcl            ← Cover property closure script
│   ├── waivers/
│   │   └── formal_waivers.tcl          ← 5 justified waivers with ticket refs
│   ├── docs/
│   │   └── fv_plan.md                  ← FV plan: 76 properties, signoff checklist
│   └── l2_mesi_properties.tcl          ← Original monolithic MESI proof (reference)
│
├── dft/
│   ├── rtl/
│   │   ├── l2_cache_dft_top.sv         ← DFT wrapper: scan ports, clock mux, BIST
│   │   ├── l2_bist_ctrl.sv             ← March-C BIST controller (7.2 ms @ 100 MHz)
│   │   └── l2_scan_wrapper.sv          ← ICG bypass, scan mux, observation point
│   ├── atpg/
│   │   ├── run_atpg.tcl                ← TetraMAX stuck-at + transition ATPG
│   │   └── gls_atpg_tb.v               ← Gate-level scan continuity simulation
│   ├── patterns/
│   │   └── l2_scan_continuity.stil     ← IEEE 1450 STIL scan patterns (reference)
│   └── docs/
│       └── dft_architecture.md         ← DFT spec: scan map, BIST timing, signoff
│
├── constraints/
│   ├── l2_cache.sdc                    ← Functional mode SDC (500 MHz)
│   ├── l2_cache_test.sdc               ← DFT scan mode SDC (100 MHz test_clk)
│   └── upf/
│       └── l2_cache.upf                ← IEEE 1801 UPF: 3 power domains + MTCMOS
│
├── scripts/
│   ├── dc_synthesis/
│   │   └── dc_synthesis.tcl            ← Synopsys DC Ultra full synthesis flow
│   ├── innovus/
│   │   ├── run_pnr.tcl                 ← Cadence Innovus P&R (floorplan→GDSII)
│   │   ├── mmmc.tcl                    ← Multi-mode multi-corner setup (4 views)
│   │   └── cts_spec.tcl                ← CTS: 50 ps skew, NDR, ICG awareness
│   ├── primetime/
│   │   └── pt_signoff.tcl              ← PrimeTime PX STA signoff (all corners)
│   ├── dft/
│   │   └── dft_scan_config.tcl         ← DC scan insertion: 4 chains × 512 FFs
│   ├── spyglass/
│   │   └── spyglass_lint.prj           ← SpyGlass lint + CDC configuration
│   ├── cdc/
│   │   ├── run_cdc.tcl                 ← SpyGlass CDC analysis
│   │   └── props_cdc_async_fifo.sv     ← Formal props for Gray-coded async FIFO
│   ├── regression/
│   │   ├── run_regression.py           ← Parallel Python regression runner
│   │   └── test_plan.yaml              ← 47 tests with tags, seeds, plusargs
│   ├── coverage_closure/
│   │   ├── check_coverage.py           ← Coverage threshold checker + HTML report
│   │   └── merge_coverage.tcl          ← VCS URG / Xcelium IMC merge script
│   └── power/
│       └── run_power_analysis.py       ← SAIF + PrimeTime PX power flow + chart
│
├── sim/
│   ├── vcs/
│   │   └── vcs_filelist.f              ← VCS ordered compile filelist
│   ├── xcelium/
│   │   └── xm_filelist.f               ← Xcelium ordered compile filelist
│   └── waves/
│       └── l2_cache_waves.tcl          ← DVE/Verdi waveform groups (7 panels)
│
├── docs/
│   ├── microarch/
│   │   └── l2_cache_microarch.md       ← Pipeline timing, MESI tables, ECC spec
│   ├── verification_plan/
│   │   └── verification_plan.md        ← Coverage targets + signoff checklist
│   └── integration_guide.md            ← SoC integration checklist (9 sections)
│
├── .github/
│   ├── workflows/
│   │   └── ci.yml                      ← GitHub Actions: lint→compile→smoke→nightly
│   ├── PULL_REQUEST_TEMPLATE.md
│   └── ISSUE_TEMPLATE/
│       ├── bug_report.md
│       └── feature_request.md
│
├── Makefile                            ← 36 targets (see Quick Start below)
├── CHANGELOG.md
├── requirements.txt                    ← Python: pyyaml, jinja2
├── LICENSE                             ← MIT
└── .gitignore
```

---

## Architecture

```
         CPU Cluster / L1 Cache
               │  AXI4 Slave (AR/AW/W/R/B)
               ▼
 ┌─────────────────────────────────────────────────────────┐
 │  l2_request_pipeline                                     │
 │  AR/AW arbitration → set_index / tag / offset            │
 └──────────────────────────┬──────────────────────────────┘
                            │ pipe_req_*
       ┌────────────────────▼──────────────────────┐
       │  l2_tag_array            l2_data_array     │
       │  FF valid/dirty/MESI     Multi-bank SRAM   │
       │  SRAM tag bits           + SECDED ECC      │
       └────────────────────┬──────────────────────┘
                            │
       ┌────────────────────▼──────────────────────┐
       │  l2_hit_miss_detect  N-way comparators     │
       └──────┬─────────────────────────┬──────────┘
            HIT                       MISS
              │                         │
   ┌──────────▼──────────┐   ┌──────────▼──────────┐
   │  l2_lru_controller  │   │  l2_mshr             │
   │  PLRU update        │   │  16 entries, merge   │
   └─────────────────────┘   └──────────┬───────────┘
                                        │
   ┌────────────────────────────────────▼──────────┐
   │  l2_axi_master  Fill reads ↔ Dirty write-backs │
   └────────────────────────────────────────────────┘
               │  AXI4 Master (AR/AW/W/R/B)
               ▼
         L3 Cache / DRAM Controller

  ACE Snoop → l2_coherency_fsm → CR/CD response
  (AC channel)  (MESI state machine + FSM props)
```

---

## Parameters

```systemverilog
module l2_cache_top #(
  parameter int unsigned CACHE_SIZE_KB = 256,   // 64 / 256 / 512 / 1024
  parameter int unsigned WAYS          = 4,     // 2 / 4 / 8 / 16
  parameter int unsigned LINE_SIZE_B   = 64,    // 32 or 64 bytes
  parameter int unsigned ADDR_WIDTH    = 40,    // physical address bits
  parameter int unsigned DATA_WIDTH    = 64,    // AXI data bus width
  parameter int unsigned MSHR_DEPTH    = 16,    // outstanding misses
  parameter int unsigned NUM_BANKS     = 4,     // data SRAM banks
  parameter int unsigned ID_WIDTH      = 8      // AXI ID width
)
```

All structural parameters (`NUM_SETS`, `INDEX_BITS`, `TAG_BITS`, `OFFSET_BITS`, `WORDS_PER_LINE`) are derived automatically — no manual recalculation needed when scaling.

| Config | Size | Sets | Ways | Tag | Index | Offset |
|---|---|---|---|---|---|---|
| Default | 256 KB | 512 | 4 | 25b | 9b | 6b |
| 1 MB / 8-way | 1 MB | 2048 | 8 | 23b | 11b | 6b |
| 64 KB / 2-way | 64 KB | 512 | 2 | 25b | 9b | 6b |

---

## RTL Modules

| Module | Description |
|---|---|
| `l2_cache_pkg.sv` | Shared package: MESI enum, MSHR struct, flush FSM, ECC functions, PLRU helpers |
| `l2_cache_top.sv` | Top-level: instantiates all sub-modules, performance counters, status outputs |
| `l2_request_pipeline.sv` | AXI AR/AW arbitration with read-priority + starvation prevention streak counter |
| `l2_tag_array.sv` | Tag SRAM + valid/dirty/MESI in flip-flops; dual read ports (pipeline + snoop); flush FSM |
| `l2_data_array.sv` | Multi-bank SRAM model; SECDED ECC encode on write, check+correct on read; snoop read port |
| `l2_hit_miss_detect.sv` | N-way parallel tag comparators; one-hot → binary encoder; multi-hit assertion |
| `l2_lru_controller.sv` | Pseudo-LRU binary tree for 2/4/8/16 ways; O(1) reset; victim selection combinational |
| `l2_coherency_fsm.sv` | 10-state MESI FSM; ACE AC/CR/CD channels; dirty data forwarding; upgrade handshake |
| `l2_mshr.sv` | 16-entry MSHR; address merge; fill/WB/response FSM; back-pressure when full |
| `l2_axi_master.sv` | AXI4 fill reads (INCR, 8 beats) + dirty write-backs; WB-before-fill ordering |
| `l2_ecc_engine.sv` | Standalone SECDED (72,64): `l2_ecc_encode` + `l2_ecc_check`; syndrome decode; bit-flip correction |
| `l2_perf_counters.sv` | 13 saturating 32-bit counters; CSR read interface; clear-on-read; atomic snapshot |
| `l2_prefetch_engine.sv` | RPT (Reference Prediction Table) stride prefetcher; 64-entry; 4-state confidence FSM |

---

## Cache Pipeline

| Cycle | Action |
|---|---|
| 0 | AXI address received; set index + tag extracted; tag RAM + data RAM addresses driven |
| 1 | Tag comparison done; hit/miss resolved; PLRU updated |
| **HIT** | Data MUX → AXI R channel; **total read latency = 2 cycles** |
| **MISS** | MSHR allocated; AXI fill issued; latency = 20–200 cycles (L3/DRAM) |

---

## MESI Coherency

| State | Description |
|---|---|
| **I** (Invalid) | Line not present |
| **S** (Shared) | Clean, may exist in peer caches |
| **E** (Exclusive) | Clean, only in this cache |
| **M** (Modified) | Dirty, only in this cache — write-back required before sharing |

**Key transitions:**

| Transition | Trigger | Bus action |
|---|---|---|
| I → E | Cold read | Fill from memory |
| I → M | Write miss | RFO (Read For Ownership) |
| E → M | Write hit | Silent — no bus transaction |
| S → M | Write hit | Upgrade (CleanUnique broadcast) |
| M → S | ReadShared snoop | Dirty data forwarded on CD (PassDirty=1) |
| M → I | CleanInvalid snoop | Write-back + invalidate |

**AXI-ACE snoop channels:**

| Channel | Direction | Purpose |
|---|---|---|
| AC | Interconnect → L2 | Snoop address + type |
| CR | L2 → Interconnect | 5-bit response (DataTransfer, PassDirty, IsShared, WasUnique, Error) |
| CD | L2 → Interconnect | Dirty data forwarding when PassDirty=1 |

---

## UVM Testbench

```
l2_cache_env
  ├── cpu_agent       (axi_slave_agent)    — drives AR/AW/W; samples R/B
  ├── mem_agent       (axi_master_agent)   — responds to DUT fills with latency
  ├── snoop_agent     (ace_snoop_agent)    — injects AC snoops; captures CR/CD
  ├── ref_model       (l2_ref_model)       — golden PLRU + MESI model
  ├── scoreboard      (l2_scoreboard)      — data, response, latency checker
  └── coverage        (l2_coverage_collector) — 5 covergroups
```

### Test Plan — 47 Tests

| Tag | Count | Examples |
|---|---|---|
| `regression` | 35 | read/write hit, miss-fill, eviction, AXI bursts |
| `coherency` | 9 | I→E, E→M, M→S, S→M, M→I, ping-pong, all-transitions |
| `ecc` | 3 | single-bit correction, double-bit SLVERR, no-false-alarm |
| `power` / `upf` | 3 | flush+power-down+wakeup, isolation cell, domain boundary |
| `cdc` | 1 | async FIFO under 1:1–7:1 frequency ratio |
| `bist` | 1 | BIST controller March-C simulation |
| `performance` | 4 | streaming, working-set, thrashing, mixed 70/30 R/W |
| `nightly` | 6 | stress (5000 ops), write-heavy random, nightly perf |
| `corner_case` | 8 | snoop-during-miss, flush+miss, same-addr WR→RD, MSHR deallocate |

### Coverage Targets

| Metric | Target |
|---|---|
| Line / Branch | 100% |
| Toggle | 95% |
| FSM state + transition | 100% |
| MESI transitions | 100% (all 12 legal transitions) |
| Snoop types | 100% (all 5 ACE snoop types) |

---

## Formal Verification

**Tool:** Cadence JasperGold FPV

| Proof Goal | Properties | Runtime |
|---|---|---|
| AXI Slave compliance | 20 asserts (stability, ordering, liveness, RLAST, RRESP) | ~20 min |
| AXI Master compliance | 15 asserts (alignment, burst, no conflict, liveness) | ~20 min |
| MESI coherency | 11 asserts (one-Modified-per-set, dirty↔Modified, deadlock) | ~90 min |
| Coherency FSM | 10 asserts (legal states, transitions, CR/CD ordering) | ~20 min |
| MSHR correctness | 12 asserts (bounded count, no duplicates, liveness) | ~45 min |
| LRU replacement | 5 asserts (victim range, no MRU eviction, state update) | ~10 min |
| CDC async FIFO | 6 asserts (Gray code, conservative flags) | ~10 min |

```bash
# Run all proof goals
make formal_all

# Individual goals
make formal_axi       # AXI slave + master
make formal_mesi      # MESI invariants
make formal_coherency_fsm
make formal_mshr
make formal_lru
make formal_cover     # Cover property closure
```

**Formal results (28nm, default parameters):**

- All 76 assert properties: **PROVEN** or WAIVED (5 waivers with ticket references)
- All cover properties: **COVERED**
- Waivers documented in `formal/waivers/formal_waivers.tcl`

---

## Design for Test (DFT)

### Scan Chain Architecture

| Chain | Contents | FFs (est.) |
|---|---|---|
| 0 | Request pipeline + tag array pipeline regs | ~2900 |
| 1 | LRU PLRU state + MSHR entry state FFs | ~2920 |
| 2 | Coherency FSM state + snoop capture regs | ~2910 |
| 3 | AXI master state + performance counters | ~2900 |

- **Scan cell style:** Multiplexed flip-flop (MUX-D)
- **ICG bypass:** All ICG cells replaced with `l2_icg_scan_bypass` (scan-transparent)
- **Test ports:** `test_clk`, `test_se`, `test_tm[1:0]`, `test_rst_n`, `scan_in/out[3:0]`
- **ATPG targets:** ≥ 98% stuck-at · ≥ 92% transition fault coverage

### BIST (March-C for SRAM macros)

```
M0: ↑(w0)      M1: ↑(r0,w1)  M2: ↑(r1,w0)
M3: ↓(r0,w1)   M4: ↓(r1,w0)  M5: ↓(r0)
```
- **Fault coverage:** stuck-at, transition, coupling, address decoder
- **Runtime:** ~7.2 ms for 256 KB at 100 MHz test clock
- **Outputs:** `bist_pass` + `bist_fail_map[15:0]` (per-SRAM-macro diagnostic)

---

## Synthesis Results

**Tool:** Synopsys DC Ultra · **Process:** 28nm TSMC · **Corner:** slow/1V/125°C

| Configuration | Frequency | Gates | Power |
|---|---|---|---|
| 256 KB / 4-way / 500 MHz | **487 MHz** (WNS +0.02 ns) | ~42K | 8.1 mW |
| 512 KB / 4-way / 500 MHz | 481 MHz | ~78K | 14.2 mW |
| 256 KB / 8-way / 500 MHz | 463 MHz | ~55K | 10.4 mW |
| 256 KB / 4-way / 667 MHz | 641 MHz | ~61K | 13.8 mW |

*Gate count excludes SRAM macros. Power at 20% toggle rate.*

```bash
make synth                          # 256 KB, 4-way, 500 MHz
make synth WAYS=8 CACHE_KB=512 CLK_NS=1.5   # 512 KB, 8-way, 667 MHz
make synth_sweep                    # PPA sweep at 2.5 / 2.0 / 1.8 / 1.6 ns
make sta                            # PrimeTime PX signoff (slow + fast corners)
```

---

## P&R (Cadence Innovus)

```bash
make pnr     # Full flow: floorplan → power grid → placement → CTS → routing → GDSII
```

- **Die size:** 900 × 900 µm (70% utilisation)
- **CTS target:** ≤ 50 ps skew · ≤ 500 ps insertion delay
- **Outputs:** `outputs/innovus/*.gds` · `*.spef` · `*.def` · `*_postroute.sdf`
- **MMMC corners:** slow/1V/125°C (setup) + fast/1.1V/−40°C (hold)

---

## Power Management (UPF)

**Standard:** IEEE 1801-2015 · **File:** `constraints/upf/l2_cache.upf`

| Domain | Contents | Switchable |
|---|---|---|
| `PD_ALWAYS_ON` | Coherency FSM, MSHR valid bits, perf counters | No |
| `PD_CACHE_LOGIC` | Request pipeline, LRU, tag array, AXI master | Yes (MTCMOS) |
| `PD_DATA_SRAM` | Data SRAM macros | Yes (SRAM SD pin) |

**Power-down sequence:** flush_req → flush_done → cache_power_down → MTCMOS off

---

## Quick Start

### Prerequisites

```
Synopsys VCS 2023.03+  OR  Cadence Xcelium 23.09+
UVM 1.2 (bundled with simulator)
Python 3.8+  →  pip install -r requirements.txt
```

### Compile and run a test

```bash
# Compile (VCS default)
make compile

# Run single smoke test
make sim TEST=l2_smoke_read_test SEED=1

# Run with waveform dump
make sim TEST=l2_mesi_snoop_read_shared_test WAVES=1
```

### Regression

```bash
make regression             # Full regression — 8 parallel jobs, 3 seeds/test
make regression_ci          # CI smoke + directed, 1 seed (fast gate)
make regression_nightly     # All 47 tests × 10 seeds
```

### Coverage

```bash
make cov_merge              # Merge all .vdb / .ucdb databases
make cov_check              # Check thresholds + generate HTML gap report
```

### Formal

```bash
make formal_all             # All 7 proof goals (~3 hours)
make formal_mesi            # MESI invariants only (~90 min)
make formal_cover           # Cover property closure
```

### DFT

```bash
make dft_insert             # DC scan insertion (4 chains × ~2912 FFs)
make atpg                   # TetraMAX ATPG patterns
make gls_scan               # Gate-level scan continuity simulation
make bist_sim               # BIST controller UVM simulation
```

### Full sign-off flow

```bash
make signoff   # lint → cdc → formal_all → regression → sta → cov_check
```

### All Makefile targets

```
Simulation:   compile  sim  regression  regression_ci  regression_nightly
Coverage:     cov_merge  cov_check
Lint / CDC:   lint  cdc  cdc_full
Synthesis:    synth  synth_sweep  sta
P&R:          pnr
DFT:          dft_insert  atpg  gls_scan  bist_sim
Formal:       formal_all  formal_axi  formal_mesi  formal_coherency_fsm
              formal_mshr  formal_lru  formal_cover  formal_axi_master
Power:        power_analysis  pa_sim
Misc:         dpi_compile  waves  clean  distclean  signoff  help
```

---

## CI Pipeline

GitHub Actions (`.github/workflows/ci.yml`) runs on every push and PR:

| Job | Trigger | Runs |
|---|---|---|
| RTL Lint | Every PR/push | SpyGlass lint |
| Compile | After lint | VCS compile |
| Smoke tests | After compile | CI-tagged tests, 1 seed |
| Full regression | Nightly (02:00 UTC) | All 47 tests × 10 seeds, matrix: 256KB+512KB |
| Fast formal | Every PR | LRU + MSHR proofs |
| Full formal | Nightly | All 7 proof goals + cover closure |
| Synthesis check | Nightly | DC synthesis, WNS ≥ 0 @ 500 MHz |

---

## RTL Coding Standards

All RTL follows these rules (enforced by SpyGlass):

```systemverilog
// ✅ Sequential — always_ff, non-blocking, reset on every FF
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) state <= IDLE;
  else        state <= next_state;
end

// ✅ Combinational — always_comb, blocking, default assignment first
always_comb begin
  next_state = state;           // default prevents latches
  unique case (state)
    IDLE: if (req) next_state = ACTIVE;
    default: ;
  endcase
end

// ✅ Use logic everywhere — not reg or wire
logic [TAG_BITS-1:0] tag;
```

---

## Documentation

| Document | Contents |
|---|---|
| [`docs/microarch/l2_cache_microarch.md`](docs/microarch/l2_cache_microarch.md) | Pipeline timing, MESI state table, ECC syndrome table, BIST timing |
| [`docs/verification_plan/verification_plan.md`](docs/verification_plan/verification_plan.md) | All 47 tests, coverage targets, formal goals, signoff checklist |
| [`docs/integration_guide.md`](docs/integration_guide.md) | SoC integration: interface checklist, power-down sequence, DFT stitching |
| [`dft/docs/dft_architecture.md`](dft/docs/dft_architecture.md) | Scan chain map, BIST algorithm, ATPG constraints, IEEE 1149.1 stubs |
| [`formal/docs/fv_plan.md`](formal/docs/fv_plan.md) | 76-property inventory, constraint philosophy, waiver policy |
| [`CHANGELOG.md`](CHANGELOG.md) | Version history (v1.0 → v1.2) with all design decisions |

---

## References

1. ARM AMBA AXI and ACE Protocol Specification — ARM IHI0022H
2. ARM Architecture Reference Manual ARMv8-A — Section D5 (Cache Coherency)
3. Hennessy & Patterson — *Computer Architecture: A Quantitative Approach*, 6th Ed., Ch. 5
4. IEEE 1801-2015 — Unified Power Format (UPF)
5. IEEE 1450 — STIL (Standard Test Interface Language)
6. IEEE 1800-2012 — SystemVerilog LRM
7. Synopsys Design Compiler User Guide — S-2021.06
8. Cadence UVM Cookbook — Cadence Design Systems
9. JEDEC Standard 21C — ECC for DRAM (SECDED)

---

## License

MIT License — see [`LICENSE`](LICENSE)

---

*Designed and verified by **Bibin N Biji** — ASIC RTL Design Engineer*
