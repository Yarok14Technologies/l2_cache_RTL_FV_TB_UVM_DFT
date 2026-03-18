# Changelog

All significant design and verification changes are documented here.

---

## [1.1.0] — 2025-07  Repository Reorganisation & Completion

### Added
- `rtl/cache/l2_request_pipeline.sv` — AXI AR/AW arbitration with read-priority
  and starvation-prevention streak counter; replaces inline logic in top
- `rtl/common/sync_fifo.sv`  — Extra-bit full/empty parameterized FIFO
- `rtl/common/async_fifo.sv` — Gray-coded 2-FF async FIFO for CDC paths
- `rtl/common/rr_arbiter.sv` — Round-robin N-requestor arbiter
- `tb/uvm_tb/agents/axi_agent/axi_master_agent.sv` — Memory-side UVM agent:
  responds to DUT fill reads with configurable latency, absorbs write-backs,
  maintains internal memory model for scoreboard consistency
- `tb/uvm_tb/agents/ace_snoop_agent/ace_snoop_agent.sv` — ACE AC/CR/CD agent
  with dedicated clocking blocks and per-transaction response timing
- `tb/uvm_tb/ref_model/l2_ref_model.sv` — Behavioral golden model: tracks
  PLRU state, MESI transitions, write-back queue; feeds expected_ap to SB
- `tb/top/l2_cache_tb_top.sv` — Unified testbench top with `bind` assertions,
  `uvm_config_db` registration, timeout watchdog, and VPD waveform dump
- `scripts/primetime/pt_signoff.tcl` — PrimeTime PX STA signoff (slow + fast)
- `scripts/dft/dft_scan_config.tcl` — Scan insertion: 4 chains × 512 FFs
- `docs/verification_plan/verification_plan.md` — Coverage targets, test plan
  summary, formal goals, and signoff checklist
- `requirements.txt` — Python dependencies for regression runner

### Changed
- **Repository re-organised** into canonical flat structure (no duplicate trees)
- `Makefile` — complete rewrite referencing all correct paths; added `sta`,
  `synth_sweep`, `distclean`, and improved `help` banner
- `tb/uvm_tb/env/l2_cache_env.sv` — removed stale `\`include` directives;
  all types resolved via `+incdir` at compile time; added `mem_agent` config
- `sim/vcs/vcs_filelist.f` + `sim/xcelium/xm_filelist.f` — updated include
  order and added `axi_master_agent.sv`
- `.gitignore` — expanded: covers JasperGold, SpyGlass, Xcelium, waveforms

### Fixed
- `l2_coherency_fsm.sv` — `snoop_rd_data` port wired correctly to data array
  snoop port; previously unconnected in tb_top
- `l2_mshr.sv` — MSHR PENDING→FILL_ACTIVE transition was unconditional; now
  gated on AXI master acceptance signal
- `l2_lru_controller.sv` — 8-way PLRU victim function had inverted left/right
  subtree selection for ways 4–7; corrected

---

## [1.0.0] — 2025-06  Initial Release

### Added
- `rtl/cache/l2_cache_pkg.sv`      — Package: MESI enum, MSHR struct, ECC fn
- `rtl/cache/l2_cache_top.sv`      — Top-level integration
- `rtl/cache/l2_tag_array.sv`      — Tag FF array with flush FSM
- `rtl/cache/l2_data_array.sv`     — Multi-bank SRAM model + SECDED ECC
- `rtl/cache/l2_hit_miss_detect.sv`— N-way parallel comparators
- `rtl/cache/l2_lru_controller.sv` — PLRU binary tree (2/4/8/16-way)
- `rtl/cache/l2_coherency_fsm.sv`  — MESI protocol + ACE snoop handler
- `rtl/cache/l2_mshr.sv`           — 16-entry MSHR with address merge
- `rtl/cache/l2_axi_master.sv`     — AXI4 master (fills + write-backs)
- `tb/uvm_tb/sequences/l2_seq_items.sv` — Seq items + 6 directed sequences
- `tb/uvm_tb/scoreboard/l2_scoreboard.sv`
- `tb/uvm_tb/coverage/l2_coverage.sv`   — 5 covergroups
- `tb/uvm_tb/tests/l2_tests.sv`         — 14 test classes
- `tb/assertions/l2_cache_assertions.sv`— 12 SVA + 5 cover properties
- `constraints/l2_cache.sdc`
- `scripts/dc_synthesis/dc_synthesis.tcl`
- `scripts/spyglass/spyglass_lint.prj`
- `scripts/regression/run_regression.py`
- `scripts/regression/test_plan.yaml`   — 30+ tests with tags + plusargs
- `formal/l2_mesi_properties.tcl`       — 9 JasperGold prove goals
- `docs/microarch/l2_cache_microarch.md`

---

## [1.2.0] — 2025-07  CI, UPF, P&R, CDC, ECC Tests, FV Completion

### Added
- `.github/workflows/ci.yml` — GitHub Actions CI: lint → compile → smoke → nightly regression + formal + synthesis check
- `constraints/upf/l2_cache.upf` — IEEE 1801 UPF: 3 power domains (PD_ALWAYS_ON, PD_CACHE_LOGIC, PD_DATA_SRAM), MTCMOS switches, isolation cells, retention registers, power state table
- `scripts/innovus/run_pnr.tcl` — Cadence Innovus P&R flow: floorplan, power grid, SRAM macro placement, CTS, routing, RC extraction, GDSII output
- `scripts/innovus/mmmc.tcl` — Multi-Mode Multi-Corner setup: slow/fast/typ corners, 4 analysis views
- `scripts/cdc/run_cdc.tcl` — SpyGlass CDC analysis; verifies single-clock assumption, documents quasi-static signals
- `scripts/cdc/props_cdc_async_fifo.sv` — Formal properties for Gray-coded async FIFO (monotone Gray, conservative flags, no simultaneous full+empty)
- `scripts/coverage_closure/check_coverage.py` — Coverage closure tool: parses URG/regression JSON, checks thresholds, generates HTML gap report
- `formal/props/props_axi_master.sv` — FV properties for AXI4 master port: 15 asserts (alignment, burst correctness, no fill+WB conflict, liveness) + 5 covers
- `formal/scripts/run_axi_master.tcl` — JasperGold run script for AXI master proof
- `tb/uvm_tb/tests/directed/l2_ecc_test.sv` — ECC tests: single-bit correction, double-bit SLVERR, no-false-alarm, BIST simulation
- `tb/uvm_tb/tests/directed/l2_cdc_power_test.sv` — CDC/power tests: async FIFO stress, flush+power-down+wakeup, isolation cell verification

### Changed
- `Makefile` — added: `pa_sim`, `cdc_full`, `pnr`, `cov_check`, `signoff` (complete sign-off flow)
- `scripts/regression/test_plan.yaml` — added 7 new tests (ecc, bist, cdc, power); total 35 tests
- `formal/scripts/run_all_proofs.tcl` — added axi_master proof goal
- Both filelists updated with new directed test and CDC prop files

### Fixed
- `formal/scripts/run_all_proofs.tcl` — GOAL list now complete (5 goals)
