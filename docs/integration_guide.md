# L2 Cache Controller — SoC Integration Guide

**Version:** 1.0  
**Author:** Bibin N Biji  
**Audience:** SoC integration engineers, DV leads, physical design engineers

---

## 1. Integration Overview

The L2 cache controller integrates between the CPU cluster (L1 caches) and the SoC memory subsystem (L3/DRAM). It exposes three external interfaces:

```
CPU Cluster (L1 Miss Interface)
  │
  │  AXI4 Slave  (AR/AW/W/R/B)  ← CPU-side, 40-bit addr, 64-bit data
  ▼
l2_cache_top  ←──  ACE Snoop (AC/CR/CD)  ←── Coherency Interconnect
  │
  │  AXI4 Master (AR/AW/W/R/B)  → Memory-side, 40-bit addr, 64-bit data
  ▼
L3 Cache / DRAM Controller
```

---

## 2. Interface Checklist

### 2.1 CPU-Side AXI4 Slave

| Signal | Width | Notes |
|---|---|---|
| `s_axi_araddr[39:0]` | 40b | Physical address — MMU must translate VA→PA before this port |
| `s_axi_arlen[7:0]` | 8b | 0–255 (burst length − 1). Cache fill = 7 (8 beats × 8B = 64B) |
| `s_axi_arsize[2:0]` | 3b | Must be 3'b011 (8 bytes) for cacheable transactions |
| `s_axi_arburst[1:0]` | 2b | Must be 2'b01 (INCR) for cache line fills |
| `ARCACHE[3:0]` | 4b | **Not connected in this design** — caller must ensure cacheable |
| `s_axi_arid[7:0]` | 8b | ID width configurable via `ID_WIDTH` parameter |

**Connection requirements:**
- Address must be **physical** (post-MMU)
- All transactions must be cacheable — non-cacheable transactions should be routed directly to memory via the coherency interconnect, bypassing this cache
- Maximum outstanding reads: `MSHR_DEPTH` (default 16)
- Burst type must be INCR only

### 2.2 Memory-Side AXI4 Master

| Concern | Requirement |
|---|---|
| Address alignment | All fill reads and write-backs are **64-byte cache-line aligned** — guaranteed by design |
| Burst characteristics | ARLEN=7, ARSIZE=3, ARBURST=INCR for all reads |
| Write-back ordering | Write-back always completes (BVALID received) before fill of same line begins |
| Maximum outstanding | 1 fill read + 1 write-back simultaneously (serialised per address) |
| `m_axi_arid` | Fixed to `ID_WIDTH'(0)` for fills; `ID_WIDTH'(0xFF)` for write-backs |

### 2.3 ACE Snoop Interface

The ACE snoop interface requires connection to the SoC **coherency interconnect** (e.g., ARM CCI-550, CCN-512, or CMN-700).

| Signal | Notes |
|---|---|
| `ac_valid / ac_ready` | Handshake — `ac_ready` deasserts when coherency FSM busy |
| `ac_snoop[3:0]` | Must carry valid ACE snoop type encodings per ARM IHI0022H |
| `ac_addr[39:0]` | Must be 64-byte aligned (bit [5:0] = 0) |
| `cr_resp[4:0]` | Decode: [0]=WasUnique [1]=IsShared [2]=Error [3]=PassDirty [4]=DataTransfer |
| `cd_data / cd_last` | Present only when `cr_resp[3]` (PassDirty) = 1 |

**Snoop response latency SLA:** ≤ 32 cycles from `ac_valid && ac_ready` to `cr_valid && cr_ready`.

---

## 3. Parameter Configuration Guide

### Sizing for common platforms

| Platform | `CACHE_SIZE_KB` | `WAYS` | `MSHR_DEPTH` | Notes |
|---|---|---|---|---|
| Mobile AP (mid-range) | 256 | 4 | 8 | Area-optimised |
| Mobile AP (flagship) | 512 | 8 | 16 | Default |
| Server/HPC | 1024 | 16 | 32 | Max configuration |
| IoT / embedded | 64 | 2 | 4 | Minimum configuration |

### Parameter constraints

```systemverilog
// All of these must be powers of 2:
CACHE_SIZE_KB ∈ {64, 128, 256, 512, 1024}
WAYS          ∈ {2, 4, 8, 16}
MSHR_DEPTH    ∈ {4, 8, 16, 32}
NUM_BANKS     ∈ {2, 4, 8}        // NUM_BANKS must divide NUM_SETS
LINE_SIZE_B   ∈ {32, 64}         // 64 recommended (matches DRAM burst)
DATA_WIDTH    ∈ {64, 128}        // must match SoC data bus width
```

---

## 4. Power Domain Integration

The UPF file (`constraints/upf/l2_cache.upf`) defines three power domains:

| Domain | Supplies | Switchable? | Retention |
|---|---|---|---|
| `PD_ALWAYS_ON` | `VDD_AO` (0.75V) | No | N/A |
| `PD_CACHE_LOGIC` | `VDD_LOGIC` (0.75V) | Yes (MTCMOS) | FSM state + MSHR |
| `PD_DATA_SRAM` | `VDD_SRAM` (0.75V) | Yes (SRAM SD pin) | None — flush required |

**Power-down sequence (SoC PMU responsibility):**

```
1. Assert cache_flush_req
2. Poll cache_flush_done (all dirty lines written back)
3. Assert cache_power_down → MTCMOS switches open
4. Verify cache_power_ack (from SW_CACHE_LOGIC)
5. Optional: independently gate VDD_SRAM for deeper power saving
```

**Wakeup sequence:**

```
1. Deassert cache_power_down
2. Wait for cache_power_ack deasserts (MTCMOS settled, ≥ 64 cycles)
3. Assert rst_n to reinitialise (optional — retention regs preserve FSM state)
4. All cache accesses will be cold misses until warm-up
```

---

## 5. Clocking

| Clock | Frequency | Source | Notes |
|---|---|---|---|
| `clk` | Up to 667 MHz | SoC PLL | Single functional clock domain |
| `test_clk` | 100 MHz | Scan test infrastructure | Active only when `test_tm != 2'b00` |

**Clock mux:** The DFT wrapper (`l2_cache_dft_top`) selects between `clk` and `test_clk` via a library clock mux cell. In functional mode `test_tm = 2'b00` and the mux is transparent.

**No CDC paths** exist within the L2 cache controller itself. The only CDC component is `rtl/common/async_fifo.sv`, which is used internally for the prefetch engine (if enabled).

---

## 6. Reset

| Signal | Type | Notes |
|---|---|---|
| `rst_n` | Async assert, synchronous deassert | SoC reset controller must synchronise release to `clk` |
| `test_rst_n` | Active-low | Used only in DFT test mode |

Reset completion: all MSHR entries cleared, all tag valid bits 0, all performance counters 0. Minimum reset pulse width: 2 `clk` cycles.

---

## 7. DFT Integration at SoC Level

The DFT wrapper (`l2_cache_dft_top`) exposes:
- 4 scan chain I/O pairs (`scan_in[3:0]`, `scan_out[3:0]`)
- BIST control (`test_tm`, `bist_done`, `bist_pass`, `bist_fail_map`)

**SoC scan stitching:** Connect `scan_out[N]` of this cache to `scan_in[N]` of the next tile in the SoC scan chain. The scan chains should be driven by the SoC DFT controller via a TAP (JTAG) interface.

**BIST integration:** The SoC PMU or test controller should assert `test_tm = 2'b10` and monitor `bist_done`. `bist_fail_map[15:0]` provides per-SRAM-macro diagnostic resolution for failure analysis.

---

## 8. Integration Verification Checklist

- [ ] AXI address width (`ADDR_WIDTH`) matches SoC physical address width
- [ ] AXI data width (`DATA_WIDTH`) matches SoC data bus width (64 or 128 bit)
- [ ] MSHR_DEPTH ≥ number of outstanding L1 miss transactions
- [ ] Coherency interconnect drives correct `ac_snoop` encodings per IHI0022H
- [ ] Power domain supply levels match SoC power grid (default 0.75V at 28nm)
- [ ] UPF loaded into all downstream EDA tools (DC, Innovus, Questa PA)
- [ ] SDC `constraints/l2_cache.sdc` loaded in all timing analysis steps
- [ ] DFT scan chains stitched into SoC scan chain (**chain 0 input → L2 `scan_in[0]`**)
- [ ] `cache_flush_req / cache_power_down` driven from SoC PMU register block
- [ ] L2 hit/miss performance counters (`perf_hit_count` etc.) routed to PMU
- [ ] Physical address from MMU validated before driving `s_axi_araddr` / `s_axi_awaddr`
- [ ] ARCACHE / AWCACHE encoding verified (non-cacheable traffic bypasses L2)
- [ ] IR drop analysis on VDD_AO domain (must be < 50 mV during peak SRAM activity)

---

## 9. Known Integration Issues

| Issue | Workaround |
|---|---|
| ACE snoop latency > 32 cycles under heavy load | Ensure coherency interconnect does not stall ACE channels; add `ACE_OUTSTANDING_DEPTH` ≥ 2 in interconnect config |
| MSHR full under sustained bandwidth pressure | Increase `MSHR_DEPTH` to 32; alternatively add a request FIFO at L1 miss interface |
| SRAM macro placement conflicts with power stripes | Use `SRAM_HALO = 10µm` in Innovus floorplan; adjust power stripe pitch |
| Performance counter overflow at high frequency | 32-bit saturating counters — PMU should poll and clear every 100 ms at 500 MHz |

---

*Bibin N Biji — ASIC RTL Design Engineer*
