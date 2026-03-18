// ============================================================
// VCS Compile Filelist — L2 Cache RTL + UVM Testbench
// Tool : Synopsys VCS 2023.03+
// Usage: vcs -full64 -sverilog -f sim/vcs/vcs_filelist.f \
//            -o sim/vcs/l2_sim -Mdir sim/vcs/csrc
// ============================================================

-full64
-sverilog
-timescale=1ns/1ps
+vcs+lic+wait
-ntb_opts uvm-1.2
+define+SIMULATION
+define+UVM_NO_DEPRECATED

+incdir+rtl/cache
+incdir+rtl/common
+incdir+tb/uvm_tb/agents/axi_agent
+incdir+tb/uvm_tb/agents/ace_snoop_agent
+incdir+tb/uvm_tb/ref_model
+incdir+tb/uvm_tb/sequences
+incdir+tb/uvm_tb/scoreboard
+incdir+tb/uvm_tb/coverage
+incdir+tb/uvm_tb/env
+incdir+tb/uvm_tb/tests
+incdir+tb/assertions

rtl/cache/l2_cache_pkg.sv
rtl/cache/l2_lru_controller.sv
rtl/cache/l2_tag_array.sv
rtl/cache/l2_data_array.sv
rtl/cache/l2_hit_miss_detect.sv
rtl/cache/l2_request_pipeline.sv
rtl/cache/l2_mshr.sv
rtl/cache/l2_coherency_fsm.sv
rtl/cache/l2_axi_master.sv
rtl/cache/l2_cache_top.sv
rtl/cache/l2_ecc_engine.sv
rtl/cache/l2_perf_counters.sv
rtl/cache/l2_prefetch_engine.sv
rtl/common/sync_fifo.sv
rtl/common/async_fifo.sv
rtl/common/rr_arbiter.sv
tb/uvm_tb/agents/axi_agent/axi_slave_agent.sv
tb/uvm_tb/agents/axi_agent/axi_master_agent.sv
tb/uvm_tb/agents/ace_snoop_agent/ace_snoop_agent.sv
tb/uvm_tb/sequences/l2_seq_items.sv
tb/uvm_tb/ref_model/l2_ref_model.sv
tb/uvm_tb/scoreboard/l2_scoreboard.sv
tb/uvm_tb/coverage/l2_coverage.sv
tb/uvm_tb/env/l2_cache_env.sv
tb/uvm_tb/tests/l2_tests.sv
tb/assertions/l2_cache_assertions.sv
tb/top/l2_cache_tb_top.sv

// ── DFT RTL (compile for BIST/scan simulation) ─────────────────────
+define+SIMULATION
+incdir+dft/rtl
dft/rtl/l2_scan_wrapper.sv
dft/rtl/l2_bist_ctrl.sv
dft/rtl/l2_cache_dft_top.sv

// ── Directed tests ──────────────────────────────────────────────────
tb/uvm_tb/tests/directed/l2_ecc_test.sv
tb/uvm_tb/tests/directed/l2_cdc_power_test.sv

// ── CDC formal props ────────────────────────────────────────────────
+incdir+scripts/cdc
scripts/cdc/props_cdc_async_fifo.sv

// ── New sequences ──────────────────────────────────────────────────
tb/uvm_tb/sequences/l2_coherency_seq.sv

// ── New directed tests ─────────────────────────────────────────────
tb/uvm_tb/tests/directed/l2_performance_test.sv

// ── DPI ────────────────────────────────────────────────────────────
-sv_liblist tb/dpi/ecc_inject

// ── Extended test classes (plan gap fill) ──────────────────────────
tb/uvm_tb/tests/l2_tests_extended.sv
