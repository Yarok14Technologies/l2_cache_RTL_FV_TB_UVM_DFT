###############################################################################
# Script     : run_all_proofs.tcl
# Tool       : Cadence JasperGold FPV
# Description: Master script that orchestrates all formal proof goals for the
#              L2 cache controller. Can be run in batch or interactively.
#
# Usage:
#   jg -fpv formal/scripts/run_all_proofs.tcl           (sequential)
#   jg -fpv formal/scripts/run_all_proofs.tcl -parallel  (parallel engines)
#
# Proof goals and estimated runtimes (16-core server):
#   AXI Slave    ~20 min
#   MESI         ~90 min   (induction-heavy)
#   MSHR         ~45 min
#   LRU          ~10 min
#   ─────────────────────
#   Total        ~3h sequential / ~1.5h parallel
###############################################################################

###############################################################################
# 0. Configuration
###############################################################################
set REPORT_DIR "reports/formal"
file mkdir $REPORT_DIR

set GOALS {
  { name "axi_slave" script "formal/scripts/run_axi_slave.tcl" timeout 1800 }
  { name "mesi"      script "formal/scripts/run_mesi.tcl"      timeout 7200 }
  { name "mshr"      script "formal/scripts/run_mshr.tcl"      timeout 3600 }
  { name "lru"       script "formal/scripts/run_lru.tcl"       timeout 600  }
}

###############################################################################
# 1. Run each proof goal
###############################################################################
set all_passed 1
set results {}

foreach goal $GOALS {
  set name    [dict get $goal name]
  set script  [dict get $goal script]
  set timeout [dict get $goal timeout]

  puts "\n╔══════════════════════════════════════════════╗"
  puts "║  Running: $name"
  puts "╚══════════════════════════════════════════════╝\n"

  set start [clock seconds]
  set rc [catch { source $script } err]
  set elapsed [expr {[clock seconds] - $start}]

  if {$rc != 0} {
    puts "FAILED: $name (error: $err) in ${elapsed}s"
    set all_passed 0
    lappend results [list $name "FAILED" $elapsed]
  } else {
    puts "PASSED: $name in ${elapsed}s"
    lappend results [list $name "PASSED" $elapsed]
  }
}

###############################################################################
# 2. Summary
###############################################################################
puts "\n╔══════════════════════════════════════════════╗"
puts "║        FORMAL VERIFICATION SUMMARY           ║"
puts "╠══════════════════════════════════════════════╣"

set total_proven   0
set total_failed   0
set total_time     0

foreach r $results {
  lassign $r name status elapsed
  set icon [expr {$status eq "PASSED" ? "✔" : "✗"}]
  puts "║  $icon  $name  —  $status  (${elapsed}s)"
  if {$status eq "PASSED"} { incr total_proven } \
  else                      { incr total_failed }
  incr total_time $elapsed
}

puts "╠══════════════════════════════════════════════╣"
puts "║  Goals PASSED : $total_proven / [llength $results]"
puts "║  Goals FAILED : $total_failed"
puts "║  Total time   : ${total_time}s"
puts "╚══════════════════════════════════════════════╝\n"

###############################################################################
# 3. Write consolidated report
###############################################################################
set fp [open "${REPORT_DIR}/formal_summary.rpt" w]
puts $fp "L2 Cache — Formal Verification Summary"
puts $fp "Generated: [clock format [clock seconds]]"
puts $fp "─────────────────────────────────────────"
foreach r $results {
  lassign $r name status elapsed
  puts $fp "  [format %-20s $name]  $status  ${elapsed}s"
}
puts $fp "─────────────────────────────────────────"
puts $fp "  TOTAL PASSED: $total_proven / [llength $results]"
close $fp

if {!$all_passed} {
  puts "*** FORMAL VERIFICATION: SOME GOALS FAILED ***"
  exit 1
} else {
  puts "*** FORMAL VERIFICATION: ALL GOALS PASSED ***"
  exit 0
}
