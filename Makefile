###############################################################################
# Makefile  —  L2 Cache Controller RTL & UVM Verification
# Author    :  Bibin N Biji
#
# Supported tools: VCS (default), Xcelium
# Targets   : compile  sim  regression  regression_ci  regression_nightly
#             cov_merge  cov_report  lint  cdc  synth  synth_sweep
#             formal  clean  help
###############################################################################

# ── Configuration (override on command line) ──────────────────────────────────
TOOL        ?= vcs          # vcs | xcelium
TEST        ?= l2_smoke_read_test
SEED        ?= 1
VERBOSITY   ?= UVM_MEDIUM
JOBS        ?= 8
TAG         ?= regression
WAVES       ?= 0

# Synthesis knobs
WAYS        ?= 4
CACHE_KB    ?= 256
CLK_NS      ?= 2.0
TOP         ?= l2_cache_top

# ── Derived paths ─────────────────────────────────────────────────────────────
SIM_OUT     := sim/$(TOOL)/$(TOP)_sim
RPT_DIR     := reports
COV_DIR     := $(RPT_DIR)/coverage

WAVE_OPT    := $(if $(filter 1,$(WAVES)),+DUMP_WAVES,)

.PHONY: all compile sim regression regression_ci regression_nightly \
        cov_merge cov_report lint cdc synth synth_sweep formal \
        clean help

# ── Default ───────────────────────────────────────────────────────────────────
all: help

###############################################################################
# Compile
###############################################################################
compile:
	@mkdir -p reports/regression
ifeq ($(TOOL),vcs)
	@echo ">>> [VCS] Compiling..."
	vcs -full64 -sverilog \
	    -f sim/vcs/vcs_filelist.f \
	    -o $(SIM_OUT) \
	    -Mdir sim/vcs/csrc \
	    -l reports/regression/compile.log
else ifeq ($(TOOL),xcelium)
	@echo ">>> [Xcelium] Compiling..."
	xmvlog -64bit -sv \
	    -f sim/xcelium/xm_filelist.f \
	    -log reports/regression/compile_xm.log
endif
	@echo ">>> Compile done."

###############################################################################
# Single test run
###############################################################################
sim: compile
ifeq ($(TOOL),vcs)
	$(SIM_OUT) \
	    +UVM_TESTNAME=$(TEST) \
	    +ntb_random_seed=$(SEED) \
	    +UVM_VERBOSITY=$(VERBOSITY) \
	    $(WAVE_OPT) \
	    -l reports/regression/$(TEST)_$(SEED).log
else ifeq ($(TOOL),xcelium)
	xmsim -64bit \
	    +UVM_TESTNAME=$(TEST) \
	    +ntb_random_seed=$(SEED) \
	    +UVM_VERBOSITY=$(VERBOSITY) \
	    $(WAVE_OPT) \
	    l2_cache_tb_top \
	    -l reports/regression/$(TEST)_$(SEED).log
endif
	@echo ">>> Log: reports/regression/$(TEST)_$(SEED).log"

###############################################################################
# Regression
###############################################################################
regression: compile
	@echo ">>> [Regression] $(JOBS) parallel jobs, 3 seeds/test..."
	python3 scripts/regression/run_regression.py \
	    --plan  scripts/regression/test_plan.yaml \
	    --tool  $(TOOL) \
	    --jobs  $(JOBS) \
	    --seeds 3
	@echo ">>> HTML report: reports/regression/regression_report.html"

regression_ci: compile
	@echo ">>> [Regression CI] smoke + directed, 1 seed..."
	python3 scripts/regression/run_regression.py \
	    --plan  scripts/regression/test_plan.yaml \
	    --tool  $(TOOL) \
	    --jobs  $(JOBS) \
	    --tag   ci \
	    --seeds 1

regression_nightly: compile
	@echo ">>> [Regression Nightly] all tests, 10 seeds..."
	python3 scripts/regression/run_regression.py \
	    --plan  scripts/regression/test_plan.yaml \
	    --tool  $(TOOL) \
	    --jobs  16 \
	    --seeds 10

###############################################################################
# Coverage
###############################################################################
cov_merge:
ifeq ($(TOOL),vcs)
	urg -dir sim/vcs/coverage/*.vdb \
	    -format both \
	    -report $(COV_DIR)/merged
else
	imc -execcmd "merge -out $(COV_DIR)/merged sim/xcelium/coverage/*.ucdb"
endif
	@echo ">>> Coverage merged: $(COV_DIR)/merged"

cov_report: cov_merge
	@echo ">>> Coverage report: $(COV_DIR)/merged/dashboard.html"

###############################################################################
# Lint and CDC (SpyGlass)
###############################################################################
lint:
	@mkdir -p reports/spyglass
	spyglass -project scripts/spyglass/spyglass_lint.prj \
	         -goal lint/lint_rtl \
	         -batch \
	         -log reports/spyglass/lint.log
	@echo ">>> Lint report: reports/spyglass/"

cdc:
	@mkdir -p reports/spyglass
	spyglass -project scripts/spyglass/spyglass_lint.prj \
	         -goal cdc/cdc_verify_struct \
	         -batch \
	         -log reports/spyglass/cdc.log

###############################################################################
# Synthesis (Synopsys DC Ultra)
###############################################################################
synth:
	@mkdir -p reports/synthesis netlist
	dc_shell -f scripts/dc_synthesis/dc_synthesis.tcl \
	    -x "set WAYS $(WAYS); \
	        set CACHE_SIZE_KB $(CACHE_KB); \
	        set CLK_PERIOD_NS $(CLK_NS)" \
	    | tee reports/synthesis/dc_$(WAYS)way_$(CLK_NS)ns.log
	@echo ">>> Netlist:  netlist/$(TOP).v"
	@echo ">>> Timing:   reports/synthesis/timing_setup.rpt"
	@echo ">>> Area:     reports/synthesis/area.rpt"
	@echo ">>> Power:    reports/synthesis/power.rpt"

synth_sweep: ## PPA sweep across {2.5, 2.0, 1.8, 1.6} ns clock targets
	@echo ">>> PPA sweep for $(WAYS)-way, $(CACHE_KB)KB..."
	@for ns in 2.5 2.0 1.8 1.6; do \
	    echo "--- Synthesizing at $${ns} ns ---"; \
	    $(MAKE) synth CLK_NS=$${ns} --no-print-directory; \
	    cp reports/synthesis/qor.rpt \
	       reports/synthesis/qor_$${ns}ns_$(WAYS)way.rpt; \
	done
	@echo ">>> QoR reports in reports/synthesis/"

###############################################################################
# STA signoff (PrimeTime PX)
###############################################################################
sta:
	@mkdir -p reports/synthesis
	pt_shell -f scripts/primetime/pt_signoff.tcl \
	    -x "set CORNER slow; set CLK_PERIOD $(CLK_NS)" \
	    | tee reports/synthesis/sta_slow.log
	pt_shell -f scripts/primetime/pt_signoff.tcl \
	    -x "set CORNER fast; set CLK_PERIOD $(CLK_NS)" \
	    | tee reports/synthesis/sta_fast.log
	@echo ">>> STA complete. Check reports/synthesis/sta_*.rpt"

###############################################################################
# Formal Verification (JasperGold FPV)
###############################################################################
formal:
	@mkdir -p reports/formal
	jg -fpv formal/l2_mesi_properties.tcl \
	   -define FORMAL_VERIFY \
	   -log reports/formal/jg.log
	@echo ">>> Formal report: reports/formal/jg_mesi_report.txt"

###############################################################################
# Clean
###############################################################################
clean:
	rm -rf sim/vcs/csrc sim/vcs/*.daidir sim/vcs/$(TOP)_sim
	rm -rf sim/xcelium/xcelium.d sim/xcelium/*.shm
	rm -rf netlist/
	rm -rf work/ WORK/ AN.DB/ default.svf
	rm -f  reports/regression/*.log
	rm -rf reports/regression/logs/
	rm -f  reports/synthesis/*.log
	@echo ">>> Clean done. (reports preserved)"

distclean: clean
	rm -rf reports/regression/ reports/synthesis/
	rm -rf reports/coverage/ reports/formal/ reports/spyglass/
	find . -name "*.pyc" -delete
	find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null; true
	@echo ">>> Full clean done."

###############################################################################
# Help
###############################################################################
help:
	@echo ""
	@echo "╔══════════════════════════════════════════════════════════╗"
	@echo "║         L2 Cache Controller — Build System               ║"
	@echo "╠══════════════════════════════════════════════════════════╣"
	@echo "║  SIMULATION                                              ║"
	@echo "║    make compile                    Compile RTL + TB      ║"
	@echo "║    make sim TEST=<name>            Run single test       ║"
	@echo "║    make sim TEST=<name> WAVES=1    Run + dump waves      ║"
	@echo "║    make regression                 Full regression (8j)  ║"
	@echo "║    make regression_ci              CI smoke + directed   ║"
	@echo "║    make regression_nightly         All tests × 10 seeds  ║"
	@echo "║    make cov_merge && cov_report    Coverage HTML report  ║"
	@echo "║                                                          ║"
	@echo "║  SYNTHESIS / STA                                         ║"
	@echo "║    make synth                      DC Ultra synthesis    ║"
	@echo "║    make synth WAYS=8 CLK_NS=1.5    8-way / 667 MHz      ║"
	@echo "║    make synth_sweep                PPA sweep 4 corners  ║"
	@echo "║    make sta                        PrimeTime signoff     ║"
	@echo "║                                                          ║"
	@echo "║  VERIFICATION                                            ║"
	@echo "║    make lint                       SpyGlass RTL lint     ║"
	@echo "║    make cdc                        SpyGlass CDC          ║"
	@echo "║    make formal                     JasperGold FPV        ║"
	@echo "║                                                          ║"
	@echo "║  CLEAN                                                   ║"
	@echo "║    make clean                      Remove sim artifacts  ║"
	@echo "║    make distclean                  Remove all generated  ║"
	@echo "╠══════════════════════════════════════════════════════════╣"
	@echo "║  VARIABLES                                               ║"
	@echo "║    TOOL=vcs|xcelium      Simulator         (vcs)        ║"
	@echo "║    TEST=<class_name>     UVM test class                  ║"
	@echo "║    SEED=<int>            Random seed        (1)          ║"
	@echo "║    JOBS=<int>            Parallel jobs      (8)          ║"
	@echo "║    VERBOSITY=UVM_*       UVM verbosity      (MEDIUM)     ║"
	@echo "║    WAVES=0|1             Dump waveforms     (0)          ║"
	@echo "║    WAYS=2|4|8|16         Cache ways         (4)          ║"
	@echo "║    CACHE_KB=<int>        Cache size KB      (256)        ║"
	@echo "║    CLK_NS=<float>        Clock period ns    (2.0)        ║"
	@echo "╚══════════════════════════════════════════════════════════╝"
	@echo ""

###############################################################################
# DFT — Scan insertion, ATPG, GLS
###############################################################################
dft_insert: synth
	@echo ">>> [DFT] Inserting scan chains..."
	dc_shell -f scripts/dc_synthesis/dc_synthesis.tcl \
	    -f scripts/dft/dft_scan_config.tcl \
	    -x "set ENABLE_SCAN 1; set WAYS $(WAYS); \
	        set CACHE_SIZE_KB $(CACHE_KB); set CLK_PERIOD_NS $(CLK_NS)"
	@echo ">>> DFT netlist : netlist/$(TOP).v  (with scan)"
	@echo ">>> Scan report : reports/synthesis/scan_chains.rpt"
	@echo ">>> DFT preview : reports/synthesis/dft_preview.rpt"

atpg:
	@mkdir -p reports/dft dft/patterns
	@echo ">>> [ATPG] TetraMAX stuck-at + transition fault campaign..."
	tmax -shell -run dft/atpg/run_atpg.tcl
	@echo ">>> Patterns : dft/patterns/"
	@echo ">>> Reports  : reports/dft/atpg_*.rpt"

gls_scan:
	@mkdir -p reports/dft
	@echo ">>> [GLS] Gate-level scan simulation..."
	vcs -full64 -v netlist/$(TOP).v \
	    -v libs/28nm/slow_1v0_125c.v \
	    dft/atpg/gls_atpg_tb.v \
	    -o sim/vcs/gls_sim \
	    -Mdir sim/vcs/gls_csrc \
	    -l reports/dft/gls_compile.log
	./sim/vcs/gls_sim +SCAN_TEST \
	    -l reports/dft/gls_sim.log
	@echo ">>> GLS log : reports/dft/gls_sim.log"

bist_sim: compile
	@echo ">>> [BIST] Simulating BIST controller..."
	$(MAKE) sim TEST=l2_bist_test SEED=$(SEED)


###############################################################################
# Formal Verification (JasperGold FPV)
###############################################################################
formal_all:
	@mkdir -p reports/formal
	@echo ">>> [FPV] Running all proof goals..."
	jg -fpv formal/scripts/run_all_proofs.tcl \
	   -init formal/waivers/formal_waivers.tcl \
	   -log  reports/formal/jg_all.log
	@echo ">>> Summary: reports/formal/formal_summary.rpt"

formal_axi:
	@mkdir -p reports/formal
	@echo ">>> [FPV] AXI slave compliance proof..."
	jg -fpv formal/scripts/run_axi_slave.tcl \
	   -init formal/waivers/formal_waivers.tcl \
	   -log  reports/formal/jg_axi.log

formal_mesi:
	@mkdir -p reports/formal
	@echo ">>> [FPV] MESI coherency proof..."
	jg -fpv formal/scripts/run_mesi.tcl \
	   -init formal/waivers/formal_waivers.tcl \
	   -log  reports/formal/jg_mesi.log

formal_mshr:
	@mkdir -p reports/formal
	@echo ">>> [FPV] MSHR correctness proof..."
	jg -fpv formal/scripts/run_mshr.tcl \
	   -init formal/waivers/formal_waivers.tcl \
	   -log  reports/formal/jg_mshr.log

formal_lru:
	@mkdir -p reports/formal
	@echo ">>> [FPV] LRU replacement proof..."
	jg -fpv formal/scripts/run_lru.tcl \
	   -log  reports/formal/jg_lru.log

formal_cover:
	@mkdir -p reports/formal
	@echo ">>> [FPV] Cover property closure..."
	jg -cover formal/cov/run_coverage.tcl \
	   -init  formal/waivers/formal_waivers.tcl \
	   -log   reports/formal/jg_cover.log


###############################################################################
# Power-aware simulation (Mentor Questa PA / Synopsys VC-Formal PA)
###############################################################################
pa_sim: compile
	@echo ">>> [PA-SIM] Power-aware simulation with UPF..."
	qverilog -sv \
	    -f sim/vcs/vcs_filelist.f \
	    -upf constraints/upf/l2_cache.upf \
	    +UVM_TESTNAME=l2_power_flush_test \
	    -l reports/regression/pa_sim.log

###############################################################################
# CDC analysis
###############################################################################
cdc_full:
	@mkdir -p reports/spyglass
	@echo ">>> [CDC] SpyGlass CDC + async FIFO formal..."
	spyglass -project scripts/cdc/run_cdc.tcl \
	         -goal cdc/cdc_verify_struct \
	         -batch \
	         -log reports/spyglass/cdc.log
	jg -fpv scripts/cdc/run_cdc.tcl -define FORMAL_VERIFY \
	   -log reports/formal/cdc_fifo.log 2>/dev/null || true

###############################################################################
# P&R (Cadence Innovus)
###############################################################################
pnr:
	@mkdir -p reports/innovus outputs/innovus
	@echo ">>> [P&R] Running Innovus place-and-route..."
	innovus -batch \
	    -script scripts/innovus/run_pnr.tcl \
	    -log    reports/innovus/innovus.log

###############################################################################
# Coverage closure
###############################################################################
cov_check:
	@echo ">>> [COVERAGE] Checking closure thresholds..."
	python3 scripts/coverage_closure/check_coverage.py \
	    --db          reports/regression/results.json \
	    --min-line    100 \
	    --min-branch  100 \
	    --min-toggle  95 \
	    --min-fsm     100 \
	    --min-func    90 \
	    --html        reports/coverage/gap_report.html \
	    --fail-on-miss
	@echo ">>> Gap report: reports/coverage/gap_report.html"

###############################################################################
# Complete sign-off flow
###############################################################################
signoff: lint cdc formal_all regression sta cov_check
	@echo ""
	@echo "╔══════════════════════════════════════════════════╗"
	@echo "║         SIGN-OFF FLOW COMPLETE                   ║"
	@echo "║  lint ✔  cdc ✔  formal ✔  regression ✔          ║"
	@echo "║  sta ✔   coverage ✔                              ║"
	@echo "╚══════════════════════════════════════════════════╝"

###############################################################################
# Power analysis
###############################################################################
power_analysis:
	@mkdir -p reports/synthesis sim/saif
	@echo ">>> [POWER] Running power analysis..."
	python3 scripts/power/run_power_analysis.py \
	    --test   l2_random_traffic_test \
	    --seed   42 \
	    --corner slow \
	    --budget 15.0 \
	    --chart  reports/synthesis/power_chart.png
	@echo ">>> Chart: reports/synthesis/power_chart.png"

###############################################################################
# DPI compile (needed for ECC fault injection tests)
###############################################################################
dpi_compile:
	@echo ">>> [DPI] Compiling ECC inject library..."
	gcc -fPIC -shared \
	    -o tb/dpi/ecc_inject.so \
	    tb/dpi/ecc_inject.c \
	    -I$$VCS_HOME/include
	@echo ">>> DPI lib: tb/dpi/ecc_inject.so"

###############################################################################
# Waveform viewer
###############################################################################
waves:
	@echo ">>> Opening waveform viewer..."
	dve -vpd sim/vcs/waves/l2_cache.vpd \
	    -script sim/waves/l2_cache_waves.tcl &

formal_coherency_fsm:
	@mkdir -p reports/formal
	@echo ">>> [FPV] Coherency FSM proof..."
	jg -fpv formal/scripts/run_coherency_fsm.tcl \
	   -init formal/waivers/formal_waivers.tcl \
	   -log  reports/formal/jg_coherency_fsm.log
