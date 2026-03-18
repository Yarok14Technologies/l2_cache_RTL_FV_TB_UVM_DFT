################################################################################
# Script     : scripts/coverage_closure/merge_coverage.tcl
# Tool       : VCS URG / Xcelium IMC
# Description: Merges all coverage databases from the regression run into a
#              single unified database and generates an HTML report.
#
# VCS URG usage:
#   urg -dir sim/vcs/coverage/*.vdb \
#       -format both \
#       -report reports/coverage/merged \
#       -log    reports/coverage/urg_merge.log
#
# Xcelium IMC usage:
#   imc -execcmd "source scripts/coverage_closure/merge_coverage.tcl"
################################################################################

# ── IMC / Xcelium merge commands ─────────────────────────────────────────────

# Load all test databases
set cov_files [glob -nocomplain sim/xcelium/coverage/*.ucdb]

if {[llength $cov_files] == 0} {
    puts "ERROR: No coverage databases found in sim/xcelium/coverage/"
    exit 1
}

puts "Merging [llength $cov_files] coverage databases..."

# Merge
merge -out reports/coverage/merged.ucdb \
      -overwrite \
      {*}$cov_files

# Open merged database
open_db reports/coverage/merged.ucdb

# Generate reports
report_summary  -out reports/coverage/summary.txt
report_details  -out reports/coverage/details.txt \
                -metrics {line branch toggle fsm assertion}

# HTML report
report_html -out reports/coverage/html/index.html \
            -metrics {line branch toggle fsm assertion functional}

puts "Coverage merged: reports/coverage/merged.ucdb"
puts "HTML report:     reports/coverage/html/index.html"

# Print quick summary
set line_cov    [coverage get -metric line    -type aggregate]
set branch_cov  [coverage get -metric branch  -type aggregate]
set toggle_cov  [coverage get -metric toggle  -type aggregate]
set fsm_cov     [coverage get -metric fsm     -type aggregate]
set assert_cov  [coverage get -metric assertion -type aggregate]

puts ""
puts "╔══════════════════════════════════════════╗"
puts "║  Coverage Merge Summary                  ║"
puts [format "║  Line     : %5.1f%%                     ║" $line_cov]
puts [format "║  Branch   : %5.1f%%                     ║" $branch_cov]
puts [format "║  Toggle   : %5.1f%%                     ║" $toggle_cov]
puts [format "║  FSM      : %5.1f%%                     ║" $fsm_cov]
puts [format "║  Assertion: %5.1f%%                     ║" $assert_cov]
puts "╚══════════════════════════════════════════╝"

# Check thresholds
set pass 1
if {$line_cov   < 100.0} { puts "GAP: Line coverage $line_cov% < 100%";  set pass 0 }
if {$branch_cov < 100.0} { puts "GAP: Branch coverage $branch_cov% < 100%"; set pass 0 }
if {$toggle_cov <  95.0} { puts "GAP: Toggle coverage $toggle_cov% < 95%";  set pass 0 }
if {$fsm_cov    < 100.0} { puts "GAP: FSM coverage $fsm_cov% < 100%";    set pass 0 }

if {$pass} { puts "✅ ALL COVERAGE TARGETS MET" } \
else        { puts "❌ COVERAGE GAPS — see details.txt" }
