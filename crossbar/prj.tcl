##############################################################################
# prj.tcl  -  runtime_configurable_crossbar standalone SIZING EXPERIMENT
#
# Purpose: find how large DATA_WIDTH can get before the crossbar's mux-tree
#          routing logic stops fitting / routing on the XCZU28DR fabric.
#
# This build is OUT-OF-CONTEXT (OOC). In OOC mode the module's ports are NOT
# turned into physical FPGA pins - they stay as internal nets. That is
# essential here: the crossbar has ~2*DATA_WIDTH + CONFIG_WIDTH ports, so an
# in-context build fails I/O placement (device has only 347 pins) long before
# the fabric/routing limit is reached. OOC exercises only fabric + routing,
# which is exactly what this experiment measures.
#
# Usage - sweep DATA_WIDTH by editing the one line below and re-running:
#   vivado -mode batch -source prj.tcl
#
# Suggested sweep: 64 -> 128 -> 192 -> 256 -> 384 -> 512 ...
# Stop when place_design or route_design fails, or congestion hits level 6.
##############################################################################

#--------------------------------------------------------------------
# EXPERIMENT KNOB - set the width to test here.
# ADDR_WIDTH must satisfy 2^ADDR_WIDTH >= DATA_WIDTH.
#--------------------------------------------------------------------
set DW   256
set AW   8
set CW   64
# Width / ADDR_WIDTH reference:
#   DATA_WIDTH  64 -> ADDR_WIDTH 6
#   DATA_WIDTH 128 -> ADDR_WIDTH 7
#   DATA_WIDTH 192 -> ADDR_WIDTH 8   (2^8=256 >= 192)
#   DATA_WIDTH 256 -> ADDR_WIDTH 8
#   DATA_WIDTH 384 -> ADDR_WIDTH 9
#   DATA_WIDTH 512 -> ADDR_WIDTH 9
#   DATA_WIDTH 1024-> ADDR_WIDTH 10

set origin_dir       "."
set _xil_proj_name_  "project_1"
set part_name        "xczu28dr-ffvg1517-2-e"

#--------------------------------------------------------------------
# Project setup
#--------------------------------------------------------------------
create_project ${_xil_proj_name_} ./${_xil_proj_name_} -part ${part_name} -force
set proj_dir [get_property directory [current_project]]

set obj [current_project]
set_property -name "default_lib"          -value "xil_defaultlib" -objects $obj
set_property -name "enable_vhdl_2008"     -value "1"              -objects $obj
set_property -name "target_language"      -value "Verilog"        -objects $obj
set_property -name "simulator_language"   -value "Mixed"          -objects $obj

#--------------------------------------------------------------------
# Design sources
#--------------------------------------------------------------------
add_files -norecurse ./runtime_configurable_crossbar.sv
add_files -norecurse ./mux_f789_tree.sv
update_compile_order -fileset sources_1

# Constraints (the clock definition; the I/O-pin constraints in here are
# harmless in OOC mode since there are no physical pins).
add_files -fileset constrs_1 ./constraints.xdc
set_property target_constrs_file ./constraints.xdc [current_fileset -constrset]

#--------------------------------------------------------------------
# Top module + OOC synthesis
#
# synth_design is run directly (non-project flow) with -mode out_of_context
# so no I/O buffers are inserted. This is the whole point - it lets the
# crossbar be placed/routed as fabric logic without needing 2*DW+CW pins.
#--------------------------------------------------------------------
puts ""
puts "=============================================="
puts " CROSSBAR SIZING RUN: DATA_WIDTH=$DW ADDR_WIDTH=$AW CONFIG_WIDTH=$CW"
puts "=============================================="
puts ""

synth_design -top runtime_configurable_crossbar \
             -part ${part_name} \
             -mode out_of_context \
             -generic DATA_WIDTH=$DW \
             -generic ADDR_WIDTH=$AW \
             -generic CONFIG_WIDTH=$CW

write_checkpoint -force "$proj_dir/../sizing_${DW}_synth.dcp"
report_utilization        -file "$proj_dir/../sizing_${DW}_util_synth.txt"
report_timing_summary -max_paths 10 \
                      -file "$proj_dir/../sizing_${DW}_timing_synth.txt"

#--------------------------------------------------------------------
# Implementation - congestion-managed (same directives as before).
#
# In non-project mode the steps are run as explicit commands rather than
# via launch_runs. Each is wrapped so a failure is reported clearly with
# the width that caused it - that failing width IS the experiment's answer.
#--------------------------------------------------------------------
opt_design

# Floorplan pblock - confine the mux tree. Optional for the experiment;
# it makes larger widths route a bit further before failing. The catch
# block lets the sweep continue if the cells don't match at some widths.
if {[catch {
    create_pblock pblock_crossbar
    add_cells_to_pblock pblock_crossbar [get_cells -hierarchical -filter {NAME =~ *u_xbar*}] -quiet
    resize_pblock pblock_crossbar -add {SLICE_X40Y0:SLICE_X79Y299}
} pb_err]} {
    puts "NOTE: pblock setup skipped ($pb_err) - continuing without floorplan."
}

# --- place_design ---
if {[catch {place_design -directive AltSpreadLogic_high} place_err]} {
    puts ""
    puts "############################################################"
    puts " RESULT: DATA_WIDTH=$DW FAILED AT place_design"
    puts " $place_err"
    puts " => The fabric limit for the flat crossbar is below $DW bits."
    puts "############################################################"
    report_utilization -file "$proj_dir/../sizing_${DW}_util_placefail.txt"
    exit 0
}
write_checkpoint -force "$proj_dir/../sizing_${DW}_placed.dcp"
report_utilization -file "$proj_dir/../sizing_${DW}_util_placed.txt"

# --- route_design ---
if {[catch {route_design -directive AggressiveExplore} route_err]} {
    puts ""
    puts "############################################################"
    puts " RESULT: DATA_WIDTH=$DW FAILED AT route_design"
    puts " $route_err"
    puts " => Placed OK but the routing logic does NOT route at $DW bits."
    puts "    (Look for [Route 35-3] congestion level 6 above.)"
    puts "############################################################"
    exit 0
}

#--------------------------------------------------------------------
# Success for this width - emit the data point.
#--------------------------------------------------------------------
write_checkpoint -force "$proj_dir/../sizing_${DW}_routed.dcp"
report_utilization     -file "$proj_dir/../sizing_${DW}_util_routed.txt"
report_route_status    -file "$proj_dir/../sizing_${DW}_route_status.txt"
report_timing_summary -max_paths 10 \
                      -file "$proj_dir/../sizing_${DW}_timing_routed.txt"
report_design_analysis -congestion \
                      -file "$proj_dir/../sizing_${DW}_congestion.txt"

puts ""
puts "############################################################"
puts " RESULT: DATA_WIDTH=$DW ROUTED SUCCESSFULLY"
puts ""
puts " Reports written (prefix sizing_${DW}_):"
puts "   util_routed     - LUT/MUXF7/MUXF8 counts and %"
puts "   route_status    - 0 routing errors expected"
puts "   timing_routed   - WNS/WHS"
puts "   congestion      - per-direction congestion levels"
puts ""
puts " If util is still low and congestion < level 5, raise DW and"
puts " re-run. The largest DW that reaches THIS message is the answer."
puts "############################################################"
puts ""

exit 0
