################################################################################
# File       : scripts/innovus/mmmc.tcl
# Description: Multi-Mode Multi-Corner setup for Innovus P&R.
#              Defines all timing corners used for sign-off analysis.
#
# Corners:
#   func_slow   — functional mode, slow/1V/125°C  (worst setup)
#   func_fast   — functional mode, fast/1.1V/-40°C (worst hold)
#   test_slow   — scan test mode, slow/1V/125°C
#   test_fast   — scan test mode, fast/1.1V/-40°C
################################################################################

################################################################################
# 1. Library sets
################################################################################

# Slow corner (worst case process, nominal voltage, high temperature)
create_library_set LS_SLOW \
  -timing [list \
    libs/28nm/slow_1v0_125c.lib \
    libs/memory/sram_sp_hd_256x512_slow.lib \
    libs/memory/sram_sp_hd_256x26_slow.lib \
  ]

# Fast corner (best case process, high voltage, low temperature)
create_library_set LS_FAST \
  -timing [list \
    libs/28nm/fast_1v1_m40c.lib \
    libs/memory/sram_sp_hd_256x512_fast.lib \
    libs/memory/sram_sp_hd_256x26_fast.lib \
  ]

# Typical corner (nominal process, voltage, temperature)
create_library_set LS_TYP \
  -timing [list \
    libs/28nm/typical_1v0_25c.lib \
    libs/memory/sram_sp_hd_256x512_typ.lib \
    libs/memory/sram_sp_hd_256x26_typ.lib \
  ]

################################################################################
# 2. RC corners (parasitic extraction corners)
################################################################################

create_rc_corner RC_SLOW \
  -temperature  125 \
  -qrc_tech     libs/28nm/rc_tech.qrc \
  -cap_table    libs/28nm/cap_worst.capTbl

create_rc_corner RC_FAST \
  -temperature  -40 \
  -qrc_tech     libs/28nm/rc_tech.qrc \
  -cap_table    libs/28nm/cap_best.capTbl

create_rc_corner RC_TYP \
  -temperature  25 \
  -qrc_tech     libs/28nm/rc_tech.qrc

################################################################################
# 3. Timing conditions
################################################################################

create_timing_condition TC_SLOW \
  -library_sets  { LS_SLOW } \
  -opcond_library libs/28nm/slow_1v0_125c.lib \
  -opcond         slow_1v0_125c

create_timing_condition TC_FAST \
  -library_sets  { LS_FAST } \
  -opcond_library libs/28nm/fast_1v1_m40c.lib \
  -opcond         fast_1v1_m40c

create_timing_condition TC_TYP \
  -library_sets  { LS_TYP } \
  -opcond_library libs/28nm/typical_1v0_25c.lib \
  -opcond         typical_1v0_25c

################################################################################
# 4. Delay corners (timing condition + RC corner)
################################################################################

create_delay_corner DC_SETUP \
  -timing_condition  TC_SLOW \
  -rc_corner         RC_SLOW

create_delay_corner DC_HOLD \
  -timing_condition  TC_FAST \
  -rc_corner         RC_FAST

create_delay_corner DC_TYP \
  -timing_condition  TC_TYP \
  -rc_corner         RC_TYP

################################################################################
# 5. Constraint modes
################################################################################

create_constraint_mode CM_FUNC \
  -sdc_files { netlist/l2_cache_top.sdc } \
  -name       FUNC

create_constraint_mode CM_TEST \
  -sdc_files { constraints/l2_cache_test.sdc } \
  -name       TEST

################################################################################
# 6. Analysis views
################################################################################

# Functional worst-case setup
create_analysis_view AV_FUNC_SETUP \
  -constraint_mode CM_FUNC \
  -delay_corner    DC_SETUP

# Functional best-case hold
create_analysis_view AV_FUNC_HOLD \
  -constraint_mode CM_FUNC \
  -delay_corner    DC_HOLD

# Scan test worst-case
create_analysis_view AV_TEST_SETUP \
  -constraint_mode CM_TEST \
  -delay_corner    DC_SETUP

# Typical (for power estimation)
create_analysis_view AV_TYP \
  -constraint_mode CM_FUNC \
  -delay_corner    DC_TYP

################################################################################
# 7. Set active views
################################################################################

set_analysis_view \
  -setup { AV_FUNC_SETUP AV_TEST_SETUP } \
  -hold  { AV_FUNC_HOLD }
