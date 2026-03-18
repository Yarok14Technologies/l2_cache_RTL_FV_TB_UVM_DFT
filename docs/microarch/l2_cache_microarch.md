# L2 Cache Controller — Detailed Micro-Architecture Specification

**Document Version:** 1.0  
**Author:** Bibin N Biji  
**Status:** Released  

---

## 1. Overview

This document describes the internal micro-architecture of the L2 cache controller. It is intended to be read alongside the RTL source code and serves as the authoritative reference for implementation decisions.

---

## 2. Cache Organisation

### 2.1 Address Partitioning

For the default configuration (256 KB, 4-way, 64B line, 40-bit address):

```
Physical Address [39:0]
──────────────────────────────────────────────────
[39:15]  TAG     (25 bits)
[14: 6]  INDEX   ( 9 bits → 512 sets)
[ 5: 3]  WORD    ( 3 bits → 8 words per line)
[ 2: 0]  BYTE    ( 3 bits → byte within word)
```

### 2.2 Tag Entry Format

Each way in the tag array stores:

```
Bit field    Width   Description
─────────────────────────────────────────────────
tag[24:0]      25    Address tag
valid           1    Line is present
dirty           1    Line has been modified (write-back needed)
mesi[1:0]       2    MESI coherency state
─────────────────────────────────────────────────
Total:         29 bits per way
```

For 512 sets × 4 ways = 512 × 4 × 29 = 59,392 bits ≈ 7.3 KB tag storage.

---

## 3. Pipeline Stages

### Stage 0 — Request Decode (Cycle 0)
- AXI AR/AW address received and registered
- Set index and tag extracted from address
- Tag RAM read address driven (registered SRAM — latency = 1 cycle)
- Data RAM read address driven speculatively for all ways

### Stage 1 — Tag Compare + Hit Resolve (Cycle 1)
- Tag RAM output available
- All `WAYS` tag comparators run in parallel
- `hit_any` determined: OR of per-way (valid ∧ tag_match)
- `hit_way_bin` encoded from one-hot result
- PLRU state updated for hit way

### Hit Path (Cycles 1–2)
- Data RAM output (from speculative all-way read) MUX'd to hit way
- AXI R channel driven: `RDATA = data_ram[hit_way][word_sel]`
- RRESP = OKAY if no ECC error; SLVERR on double-bit ECC error

### Miss Path (Cycle 1 onwards)
- MSHR checked for address merge; if no merge and not full, new entry allocated
- AXI master issues `ARVALID` to memory
- `ARREADY/AWREADY` deasserted to CPU until MSHR entry available
- On fill complete: tag/data arrays updated, MSHR entry released, response sent

---

## 4. Write Policy

The L2 cache implements **write-back with write-allocate**:

| Scenario | Action |
|---|---|
| Write hit (E or M state) | Update data in cache, set dirty=1, MESI→M |
| Write hit (S state) | Issue upgrade request, wait for ACK, then write |
| Write miss | Allocate (RFO — Read For Ownership), fill line, then write |
| Eviction (dirty) | Write-back to memory before replacing |
| Eviction (clean) | Silent replacement, no memory write |

---

## 5. Coherency Protocol Detail

### 5.1 Upgrade Protocol (S → M)

When a cache line in Shared state needs to be written:

```
Cycle  Action
────────────────────────────────────────────────────────────
  0    Write miss detected (state=S, need M for write)
  1    MSHR allocated with UPGRADE state
  2    Coherency FSM transitions to COH_UPGRADE_PEND
       AXI-ACE: CleanUnique sent on AW channel to interconnect
  2+   Interconnect broadcasts InvalidateReq to all peer caches
       Peer caches transition S→I, send ACK
  N    All ACKs received → upgrade_ack_received asserted
  N+1  L2 transitions S→M, write proceeds
```

### 5.2 Snoop Handling Pipeline

```
Cycle  Action
────────────────────────────────────────────────────────────
  0    AC channel: ac_valid sampled, ac_ready asserted (if FSM idle)
       snoop_addr_r, snoop_type_r registered
  1    Tag array snoop port reads set indexed by snoop_addr_r
       (dedicated read port, no stall to main pipeline)
  2    Tag comparison: find hit way, check state and dirty bit
  3    CR response generated:
         - If Modified hit and ReadShared: PassDirty=1, IsShared=1
         - If Modified hit and CleanInvalid: PassDirty=1, IsShared=0
         - If Shared hit and ReadShared: IsShared=1, no data
         - If miss: all zeros
  4+   If PassDirty: data array read → CD channel beat transfer
  N    CR_VALID asserted; state update applied to tag array
```

---

## 6. MSHR Operation

### 6.1 Allocation Algorithm

```
on cache miss {
  line_addr = addr[39:6]

  // Check for merge
  foreach entry in mshr {
    if (entry.valid && entry.addr[39:6] == line_addr) {
      MERGE: update entry's write data if needed; done
    }
  }

  // Allocate new entry
  if (any entry.valid == 0) {
    alloc_idx = lowest free entry
    mshr[alloc_idx] = {addr, id, state=PENDING, ...}
  } else {
    full = 1  // back-pressure to L1
  }
}
```

### 6.2 State Machine

```
IDLE ──alloc_req──► PENDING ──AR_issued──► FILL_ACTIVE
                                               │
                    WB_PENDING ◄──dirty_evict──┘
                        │
                        │wb_done
                        ▼
                   FILL_ACTIVE ──fill_complete──► COMPLETE ──resp_accepted──► IDLE
```

---

## 7. ECC

### 7.1 SECDED Encoding

The SECDED code used is a (72,64) Hamming code with overall parity:

- 64 data bits
- 6 Hamming parity bits (cover bit positions 1, 2, 4, 8, 16, 32)
- 1 overall parity bit (XOR of all 71 bits)
- 1 reserved / future use

**Error detection/correction:**

| Syndrome | Overall Parity | Error Type | Action |
|---|---|---|---|
| 0 | 0 | No error | Return data as-is |
| non-zero | 1 | Single-bit error | Correct bit, return |
| non-zero | 0 | Double-bit error | Signal SLVERR |
| 0 | 1 | Overall parity bit flip | Ignore (benign) |

---

## 8. Power Architecture

### 8.1 Clock Gate Hierarchy

```
clk (global)
  ├── clk_tag     ICG enabled by: any_request
  ├── clk_data    ICG enabled by: any_request | fill_valid
  ├── clk_lru     ICG enabled by: hit_any | fill_valid
  ├── clk_mshr    ICG enabled by: !mshr_idle
  ├── clk_coh     ICG enabled by: ac_valid | snoop_pending
  └── clk_perf    ICG enabled by: enable_perf_counters (CSR)
```

Estimated clock gating savings: 28–35% dynamic power at typical activity.

### 8.2 Retention Strategy

On `cache_power_down`:
1. Software must first issue `cache_flush_req` and wait for `cache_flush_done`
2. All dirty lines are written back
3. `cache_power_down` asserted → MTCMOS header switches off data domain
4. Tag valid bits (in always-on flops) are already 0 after flush
5. On wakeup: all accesses are cold misses — no explicit invalidation needed

---

## 9. Performance Model

### 9.1 Hit Rate Model

```
Effective CPI = CPI_ideal + miss_rate × fill_latency
             = CPI_ideal + miss_rate × 30 cycles  (L3 hit)
             = CPI_ideal + miss_rate × 200 cycles (DRAM)
```

For a 256 KB L2 with typical workload:
- Instruction stream: ~2% miss rate → ~0.6 CPI penalty
- Data stream: ~5% miss rate → ~1.5 CPI penalty

### 9.2 Bandwidth Analysis

At 500 MHz, 64-bit data bus:
- Peak bandwidth: 500 MHz × 8 B = **4 GB/s** per direction
- Fill bandwidth: 64B/line × (1/30 cycles/line × 500 MHz) = **~1 GB/s** at typical miss rate

---

## 10. Known Micro-architecture Constraints

1. **Snoop stalls main pipeline** if both access the same set index in the same cycle. The snoop has priority (worst case: 2-cycle stall of main pipeline per snoop).

2. **MSHR merge is tag-only**: merging is based on cache-line address match. A merged write to the same word as a pending fill is handled by forwarding at fill time.

3. **Write-back ordering**: write-backs are not ordered relative to fills to **different** addresses. They are ordered (WB-before-fill) only for the **same** cache-line address.

4. **ECC correction latency**: single-bit ECC correction adds 0 cycles (combinational correction on read output). Double-bit error detection adds 1 cycle (registered output comparison).

---

*Bibin N Biji — ASIC RTL Design Engineer*
