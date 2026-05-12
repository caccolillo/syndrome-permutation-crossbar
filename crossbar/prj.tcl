set origin_dir "."
set _xil_proj_name_ "project_1"
set orig_proj_dir "[file normalize "$origin_dir/project_1"]"

# Create project
create_project ${_xil_proj_name_} ./${_xil_proj_name_} -part xczu28dr-ffvg1517-2-e
set proj_dir [get_property directory [current_project]]

# Set project properties — $obj must be set BEFORE use
set obj [current_project]
set_property -name "board_part"                        -value "xilinx.com:zcu111:part0:1.4" -objects $obj
set_property -name "default_lib"                       -value "xil_defaultlib"               -objects $obj
set_property -name "enable_resource_estimation"        -value "0"                            -objects $obj
set_property -name "enable_vhdl_2008"                  -value "1"                            -objects $obj
set_property -name "ip_cache_permissions"              -value "read write"                   -objects $obj
set_property -name "ip_output_repo"                    -value "$proj_dir/${_xil_proj_name_}.cache/ip" -objects $obj
set_property -name "mem.enable_memory_map_generation"  -value "1"                            -objects $obj
set_property -name "revised_directory_structure"       -value "1"                            -objects $obj
set_property -name "sim.central_dir"                   -value "$proj_dir/${_xil_proj_name_}.ip_user_files" -objects $obj
set_property -name "sim.ip.auto_export_scripts"        -value "1"                            -objects $obj
set_property -name "simulator_language"                -value "Mixed"                        -objects $obj
set_property -name "sim_compile_state"                 -value "1"                            -objects $obj
set_property -name "target_language"                   -value "Verilog"                      -objects $obj

# Set IP repository paths
set obj [get_filesets sources_1]
if { $obj != {} } {
    set_property "ip_repo_paths" "[file normalize "$origin_dir/../"]" $obj
    update_ip_catalog -rebuild
}

# Simulation sources
set_property SOURCE_SET sources_1 [get_filesets sim_1]
add_files -fileset sim_1 -norecurse ./tb_runtime_configurable_crossbar.sv
add_files -fileset sim_1 -norecurse ./tb_runtime_configurable_crossbar_behav.wcfg

# Design sources
add_files -norecurse ./runtime_configurable_crossbar.sv
add_files -norecurse ./mux_f789_tree.sv
update_compile_order -fileset sources_1

# Constraints
add_files -fileset constrs_1 ./constraints.xdc
set_property target_constrs_file ./constraints.xdc [current_fileset -constrset]

# Generics: set the width of the width of the original/final bitstring
#set_property generic {DATA_WIDTH=256 ADDR_WIDTH=8 CONFIG_WIDTH=64} [current_fileset]
#set_property generic {DATA_WIDTH=128 ADDR_WIDTH=7 CONFIG_WIDTH=64} [current_fileset]
set_property generic {DATA_WIDTH=64 ADDR_WIDTH=6 CONFIG_WIDTH=64} [current_fileset]
#set_property generic {DATA_WIDTH=32 ADDR_WIDTH=5 CONFIG_WIDTH=64} [current_fileset]

# Launch synthesis
launch_runs synth_1 -jobs 6
wait_on_run synth_1

# Open synthesized design and save worst 10 timing paths
open_run synth_1
report_timing \
    -max_paths 10 \
    -delay_type max \
    -path_type full_clock \
    -file "$proj_dir/../post_synth_timing_top10.txt"

# =============================================================================
# Implementation strategy — congestion mitigation
#
# The crossbar uses ~50% of the device's CLB fabric for the 1024-wide mux tree.
# Without guidance the router produces level-6 congestion (threshold is 5),
# causing it to prioritise routability over timing.
#
# Three directives are applied:
#   1. AltSpreadLogic_high  — spreads placement evenly across fabric,
#                             reducing hotspots in the central CLB region
#   2. AggressiveExplore    — enables more routing iterations and
#                             aggressive rip-up/reroute passes
#   3. Pblock               — confines crossbar logic to a single region
#                             so the placer keeps mux instances close to
#                             their broadcast register sources
# =============================================================================
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE  AltSpreadLogic_high  [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE  AggressiveExplore    [get_runs impl_1]

# Floorplan: keep the crossbar in the right half of the device fabric.
# This reserves the left half for the AXI/Aurora wrapper logic and
# prevents the placer from interleaving them, which is the main source
# of routing congestion.
# Adjust the SLICE range if the design is instantiated in a larger hierarchy.
create_pblock pblock_crossbar
add_cells_to_pblock pblock_crossbar [get_cells -hierarchical -filter {NAME =~ *u_xbar*}] -quiet
resize_pblock pblock_crossbar -add {SLICE_X40Y0:SLICE_X79Y299}

# Tell Vivado that unconstrained I/O pins are expected (IP core — parent
# design provides the I/O constraints)
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

# Launch implementation
launch_runs impl_1 -to_step route_design
wait_on_run impl_1

# Open implemented design and save worst 10 timing paths
open_run impl_1
report_timing_summary -delay_type min_max \
                      -report_unconstrained \
                      -check_timing_verbose \
                      -max_paths 10 \
                      -input_pins \
                      -routable_nets \
                      -name timing_1 \
                      -file "$proj_dir/../post_impl_timing_top10.txt"

# Package as IP core
update_compile_order -fileset sources_1
ipx::package_project -root_dir ./ -vendor user.org -library user -taxonomy /UserIP
ipx::merge_project_changes hdl_parameters [ipx::current_core]
set_property core_revision 2 [ipx::current_core]
ipx::create_xgui_files [ipx::current_core]
ipx::update_checksums [ipx::current_core]
ipx::check_integrity [ipx::current_core]
ipx::save_core [ipx::current_core]
exit
