##############################################################################
# create_aurora_zcu111.tcl
#
# Vivado project creation script for:
#   - ZCU111 (XCZU28DR-2FFVG1517E)
#   - 1-lane Aurora 64B/66B @ 25.78125 Gbps
#   - SFP28 port 0 via GTY Bank 128, Channel 0
#   - 256-bit permutation crossbar (congestion-managed via pblock)
#
# Usage:
#   vivado -mode batch -source prj.tcl
#
# Vivado version tested: 2022.2+
##############################################################################

#--------------------------------------------------------------------
# 1. Project / part setup
#--------------------------------------------------------------------
set proj_name  "zcu111_aurora_sfp28"
set proj_dir   "./vivado_proj"
set part_name  "xczu28dr-ffvg1517-2-e"

# -force recreates the project. Clean .gen and .runs subdirectories
# externally (rm -rf vivado_proj/ .Xil/) before running this script
# for a guaranteed clean rebuild.
create_project ${proj_name} ${proj_dir} -part ${part_name} -force
set_property board_part xilinx.com:zcu111:part0:1.2 [current_project]

#--------------------------------------------------------------------
# 2. Create block design
#--------------------------------------------------------------------
create_bd_design "aurora_bd"
update_compile_order -fileset sources_1

#--------------------------------------------------------------------
# 3. Instantiate Aurora 64B/66B IP
#--------------------------------------------------------------------
create_ip -name aurora_64b66b \
          -vendor xilinx.com \
          -library ip \
          -version 12.0 \
          -module_name aurora_64b66b_0

set_property -dict [list \
  CONFIG.C_AURORA_LANES          {1}              \
  CONFIG.C_LINE_RATE             {25.78125}       \
  CONFIG.C_REFCLK_FREQUENCY      {161.1328125}    \
  CONFIG.C_INIT_CLK              {100}            \
  CONFIG.interface_mode          {Streaming}      \
  CONFIG.flow_mode               {None}           \
  CONFIG.drp_mode                {Native}         \
  CONFIG.SupportLevel            {1}              \
  CONFIG.C_GT_LOC_1              {X0Y0}           \
] [get_ips aurora_64b66b_0]

generate_target all [get_ips aurora_64b66b_0]

#--------------------------------------------------------------------
# 4. Create a top-level RTL wrapper
#--------------------------------------------------------------------
set top_file "${proj_dir}/${proj_name}.srcs/sources_1/new/aurora_top.v"
file mkdir [file dirname $top_file]

set fp [open $top_file w]
puts $fp {
// aurora_top.v - ZCU111 Aurora 64B/66B top-level wrapper
`timescale 1ns/1ps

module aurora_top (
    input  wire         sfp0_rx_p,
    input  wire         sfp0_rx_n,
    output wire         sfp0_tx_p,
    output wire         sfp0_tx_n,

    input  wire         mgt_refclk_p,
    input  wire         mgt_refclk_n,

    input  wire         init_clk,
    input  wire         reset,

    output wire [63:0]  m_axis_rx_tdata,
    output wire [7:0]   m_axis_rx_tkeep,
    output wire         m_axis_rx_tvalid,
    output wire         m_axis_rx_tlast,
    input  wire         m_axis_rx_tready,

    input  wire [63:0]  s_axis_tx_tdata,
    input  wire [7:0]   s_axis_tx_tkeep,
    input  wire         s_axis_tx_tvalid,
    input  wire         s_axis_tx_tlast,
    output wire         s_axis_tx_tready,

    output wire         user_clk_out,

    output wire         channel_up,
    output wire         lane_up,
    output wire         hard_err,
    output wire         soft_err,
    output wire         frame_err,
    output wire         tx_lock
);

    wire gt_refclk;
    wire gt_refclk_out;
    wire sys_reset_out;

    IBUFDS_GTE4 #(
        .REFCLK_EN_TX_PATH (1'b0),
        .REFCLK_HROW_CK_SEL(2'b00),
        .REFCLK_ICNTL_RX   (2'b00)
    ) u_ibufds_gte4 (
        .I    (mgt_refclk_p),
        .IB   (mgt_refclk_n),
        .CEB  (1'b0),
        .O    (gt_refclk),
        .ODIV2(gt_refclk_out)
    );

    aurora_64b66b_0 u_aurora (
        .rxp                (sfp0_rx_p),
        .rxn                (sfp0_rx_n),
        .txp                (sfp0_tx_p),
        .txn                (sfp0_tx_n),

        .gt_refclk1_p       (mgt_refclk_p),
        .gt_refclk1_n       (mgt_refclk_n),

        .init_clk           (init_clk),
        .reset_pb           (reset),
        .pma_init           (1'b0),

        .s_axi_tx_tdata     (s_axis_tx_tdata),
        .s_axi_tx_tvalid    (s_axis_tx_tvalid),
        .s_axi_tx_tready    (s_axis_tx_tready),

        .m_axi_rx_tdata     (m_axis_rx_tdata),
        .m_axi_rx_tvalid    (m_axis_rx_tvalid),

        .user_clk_out       (user_clk_out),
        .sync_clk_out       (),

        .channel_up         (channel_up),
        .lane_up            (lane_up),
        .hard_err           (hard_err),
        .soft_err           (soft_err),

        .loopback           (3'd0),
        .power_down         (1'b0),

        .sys_reset_out      (sys_reset_out)
    );

endmodule
}
close $fp

add_files -norecurse $top_file
update_compile_order -fileset sources_1

#--------------------------------------------------------------------
# 5. Add XDC constraint files
#
# pblocks.xdc carries the crossbar floorplan that keeps the 256-bit
# design routable. It must be added to constrs_1 here.
#
# NOTE: 'set_property top' is intentionally NOT here - the BD wrapper
# file does not exist until make_wrapper runs (section 8). Setting top
# early makes Vivado fall back to synthesizing aurora_top, which exposes
# 149 internal signals as physical pins. Moved to section 8a.
#--------------------------------------------------------------------
add_files -fileset constrs_1 -norecurse \
    [file normalize "./aurora_zcu111.xdc"]
add_files -fileset constrs_1 -norecurse ./constraints.xdc
add_files -fileset constrs_1 -norecurse ./pblocks.xdc

#--------------------------------------------------------------------
# 6. Set up IP repo folder
#--------------------------------------------------------------------
set_property ip_repo_paths ../ [current_project]
update_ip_catalog

#--------------------------------------------------------------------
# 7. Add source files needed by block design
#--------------------------------------------------------------------
add_files -norecurse {
    ../axis_wrapper/crossbar_axis_wrapper.sv
    ../crossbar/mux_f789_tree.sv
    ../crossbar/runtime_configurable_crossbar.sv
    ./crossbar_axis_wrapper.vhd
}
update_compile_order -fileset sources_1

#--------------------------------------------------------------------
# 8. Create block design and generate the HDL wrapper
#--------------------------------------------------------------------
source ./bd.tcl
make_wrapper -files [get_files ./vivado_proj/zcu111_aurora_sfp28.srcs/sources_1/bd/aurora_bd/aurora_bd.bd] -top
add_files -norecurse ./vivado_proj/zcu111_aurora_sfp28.gen/sources_1/bd/aurora_bd/hdl/aurora_bd_wrapper.v
update_compile_order -fileset sources_1

#--------------------------------------------------------------------
# 8a. Set the synthesis top AFTER the wrapper file exists.
#--------------------------------------------------------------------
set_property top aurora_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

set actual_top [get_property top [current_fileset]]
puts ""
puts "=== Top module check ==="
puts "  Expected top: aurora_bd_wrapper"
puts "  Actual top:   $actual_top"
puts "========================"
puts ""
if {$actual_top ne "aurora_bd_wrapper"} {
    puts "ERROR: Top module is '$actual_top', not 'aurora_bd_wrapper'."
    puts "       Synthesis would build the wrong design."
    exit 1
}

#--------------------------------------------------------------------
# 8b. Sanity check - verify the crossbar wrapper DATA_WIDTH override.
#--------------------------------------------------------------------
set xbar_cell [get_bd_cells -quiet -filter {VLNV =~ *crossbar_axis_wrapper*} -hierarchical]
if {$xbar_cell ne ""} {
    set dw [get_property CONFIG.DATA_WIDTH $xbar_cell]
    puts ""
    puts "=== Crossbar wrapper parameter check ==="
    puts "  Cell:       $xbar_cell"
    puts "  DATA_WIDTH: $dw"
    puts "========================================"
    puts ""
    if {$dw eq "1024"} {
        puts "WARNING: DATA_WIDTH=1024 will not fit on this device."
    }
}

#--------------------------------------------------------------------
# 9. Run strategy - CONGESTION-AWARE for the 256-bit crossbar
#
# The 256-bit permutation crossbar is routing-dense. A Performance_*
# strategy optimizes for timing and ignores routability, which produced
# the prior 9.5 hr route / 250k overlaps / RTSTAT-13 failure.
#
# Here: a Congestion_SpreadLogic base strategy, with explicit per-step
# directives that spread placement and do aggressive rip-up/reroute.
# Per-step set_property calls override the named strategy's defaults
# for those steps - this is intentional.
#--------------------------------------------------------------------
set_property strategy "Vivado Synthesis Defaults" [get_runs synth_1]

# Flatten hierarchy 'rebuilt' (default) - lets the placer/router see across
# module boundaries for the mux fabric without making reports unreadable.
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]

set_property strategy "Congestion_SpreadLogic_high" [get_runs impl_1]

set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE              Explore             [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE            AltSpreadLogic_high [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED            true                 [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE         Explore             [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE            AggressiveExplore   [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true                 [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore          [get_runs impl_1]

#--------------------------------------------------------------------
# 10. Reset runs so launch_runs can re-execute them.
#--------------------------------------------------------------------
if {[get_property STATUS [get_runs synth_1]] ne "Not started"} {
    reset_run synth_1
}
if {[get_property STATUS [get_runs impl_1]] ne "Not started"} {
    reset_run impl_1
}

#--------------------------------------------------------------------
# 11. Synthesis
#--------------------------------------------------------------------
launch_runs synth_1 -jobs 6
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
if {[string first "synth_design Complete" $synth_status] < 0} {
    puts "ERROR: synth_1 did not complete successfully."
    puts "       Status: $synth_status"
    puts "       See:    [get_property DIRECTORY [get_runs synth_1]]/runme.log"
    exit 1
}

open_run synth_1
report_timing \
    -max_paths 10 \
    -delay_type max \
    -path_type full_clock \
    -file "$proj_dir/../post_synth_timing_top10.txt"
close_design

#--------------------------------------------------------------------
# 12. Implementation + bitstream generation
#--------------------------------------------------------------------
launch_runs impl_1 -to_step write_bitstream -jobs 6
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
if {[string first "write_bitstream Complete" $impl_status] < 0} {
    puts "ERROR: impl_1 did not complete bitstream generation."
    puts "       Status: $impl_status"
    puts "       See:    [get_property DIRECTORY [get_runs impl_1]]/runme.log"
    puts ""
    puts "If the failure is DRC RTSTAT-13 (insufficient routing), the"
    puts "256-bit crossbar did not route cleanly even with the pblock."
    puts "Tune the pblock_xbar rectangle in pblocks.xdc, or drop to"
    puts "DATA_WIDTH=128 in bd.tcl."
    exit 1
}

open_run impl_1
report_timing_summary -file "$proj_dir/../post_impl_timing_summary.txt"
report_utilization     -file "$proj_dir/../post_impl_utilization.txt"
report_drc             -file "$proj_dir/../post_impl_drc.txt"
report_route_status    -file "$proj_dir/../post_impl_route_status.txt"
close_design

#--------------------------------------------------------------------
# 13. Copy bitstream to a convenient location
#--------------------------------------------------------------------
set bit_src "${proj_dir}/${proj_name}.runs/impl_1/aurora_bd_wrapper.bit"
set bit_dst "./aurora_bd_wrapper.bit"
if {[file exists $bit_src]} {
    file copy -force $bit_src $bit_dst
    puts ""
    puts "==================================================================="
    puts " BITSTREAM GENERATED: $bit_dst"
    puts ""
    puts " Reports:"
    puts "   timing summary : ./post_impl_timing_summary.txt"
    puts "   utilization    : ./post_impl_utilization.txt"
    puts "   route status   : ./post_impl_route_status.txt"
    puts "   DRC            : ./post_impl_drc.txt"
    puts "==================================================================="
} else {
    puts "WARNING: Expected bitstream $bit_src not found."
}

exit 0
