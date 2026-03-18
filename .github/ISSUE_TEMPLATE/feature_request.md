---
name: Feature Request
about: Propose a new feature or enhancement to the L2 cache RTL or verification
title: "[FEATURE] "
labels: enhancement, needs-discussion
assignees: ''
---

## Feature Summary

<!-- One-sentence description of the proposed feature -->

## Motivation

<!-- Why is this needed? What problem does it solve?
     What workload or scenario motivated this request? -->

## Proposed Implementation

### RTL changes (if applicable)

<!-- Which modules would change? New parameters? Interface changes?
     Rough design sketch or state machine outline. -->

**Affected modules:**
```
rtl/cache/
```

**New parameters (if any):**
```systemverilog
parameter int unsigned NEW_PARAM = default_value;
```

### Verification additions

- [ ] New UVM test class: `l2_xxx_test`
- [ ] New sequence: `l2_xxx_seq`
- [ ] New covergroup: `cg_xxx`
- [ ] New SVA property
- [ ] Formal proof update

### Documentation

- [ ] Microarch spec update (`docs/microarch/`)
- [ ] Integration guide update
- [ ] README section

---

## PPA Impact Estimate

| Metric | Expected delta | Confidence |
|---|---|---|
| Area | ± ___ gates | Low / Med / High |
| Frequency | ± ___ MHz | Low / Med / High |
| Power | ± ___ mW | Low / Med / High |

---

## Alternatives Considered

<!-- Other approaches evaluated and why this one was chosen -->

---

## Priority

- [ ] P0 — Blocking (required for tapeout)
- [ ] P1 — High (required for next milestone)
- [ ] P2 — Medium (nice to have)
- [ ] P3 — Low (future roadmap)
