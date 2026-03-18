## Pull Request Summary

**Type:** <!-- RTL / Verification / Scripts / Documentation / Bug Fix -->  
**Jira ticket:** <!-- e.g. L2CACHE-123 -->

---

### What does this PR do?

<!-- Clear 2-3 sentence description of the change -->

---

### RTL changes (if applicable)

- [ ] Only combinational changes (no new state)
- [ ] New/modified sequential logic
- [ ] New module added  
- [ ] Parameter/interface change (check all instantiations)
- [ ] Bug fix — describe root cause: 

**Modules changed:**
```
rtl/cache/
```

---

### Verification

- [ ] Unit simulation run locally (`make sim TEST=...`)
- [ ] CI smoke tests pass (auto-checked on PR)
- [ ] Regression tests added/updated for new functionality
- [ ] Assertions added for new logic
- [ ] Coverage impact assessed

**Test added/modified:** <!-- e.g. l2_mesi_snoop_test -->

---

### Formal verification

- [ ] Not required (no control-path change)
- [ ] Existing proofs still pass
- [ ] New properties added: `formal/props/...`
- [ ] Waivers updated: `formal/waivers/formal_waivers.tcl`

---

### Synthesis / Timing

- [ ] Not required (TB/docs only)
- [ ] Quick synthesis run — WNS: ___ ns (target ≥ 0 at 500 MHz)
- [ ] Area delta: ___ gates (+/-)
- [ ] Power delta: ___ mW (+/-)

---

### Reviewer checklist

- [ ] RTL coding style follows guidelines (always_ff/comb, no latches)
- [ ] All new signals have reset values
- [ ] No synthesis warnings introduced
- [ ] SDC updated if new paths introduced
- [ ] README / docs updated if interface changed
