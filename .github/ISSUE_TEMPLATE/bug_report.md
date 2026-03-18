---
name: RTL Bug Report
about: Report a functional bug in the L2 cache RTL or testbench
title: "[BUG] "
labels: bug, needs-triage
assignees: ''
---

## Bug Description

<!-- Clear description of what is wrong -->

## How to reproduce

**Test / sequence:**
```
make sim TEST=l2_xxx_test SEED=12345
```

**Failing assertion / scoreboard error:**
```
UVM_ERROR: ...
```

## Expected behaviour

<!-- What should happen -->

## Simulation log snippet

```
<paste relevant log lines>
```

## Environment

- Tool: VCS / Xcelium (version: )
- Branch: 
- Commit: 

## Root cause (if known)

<!-- Leave blank if unknown -->

## Impact

- [ ] Functional correctness
- [ ] Performance regression
- [ ] Coverage closure
- [ ] Formal proof failure
- [ ] Synthesis timing
