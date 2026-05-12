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
add_files -fileset sim_1 -norecurse ./tb_crossbar_axis_wrapper.sv
#add_files -fileset sim_1 -norecurse ./tb_runtime_configurable_crossbar_behav.wcfg

# Design sources
create_ip -name runtime_configurable_crossbar -vendor user.org -library user -version 1.0 -module_name runtime_configurable_crossbar_0
generate_target all [get_ips runtime_configurable_crossbar_0]
add_files -norecurse ./crossbar_axis_wrapper.sv
update_compile_order -fileset sources_1

# Launch synthesis
#launch_runs synth_1 -jobs 6
#wait_on_run synth_1

# Open synthesized design and save worst 10 timing paths
#open_run synth_1
#report_timing \
#    -max_paths 10 \
#    -delay_type max \
#    -path_type full_clock \
#    -file "$proj_dir/../post_synth_timing_top10.txt"

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
