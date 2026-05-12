# 400 MHz system clock (2.500 ns period)
# Configuration load time: 343 cycles x 2.500 ns = ~858 ns (sequential)
#                          172 cycles x 2.500 ns = ~430 ns (parallel)
# CONFIG_WIDTH=64, BEATS_TOTAL=171, DATA_WIDTH=1024, ADDR_WIDTH=10
create_clock -period 2.500 -name clk_400 -waveform {0.000 1.250} [get_ports clk]

# Multicycle path constraint for inv_orig write address decode.
#
# During S_LOAD the cfg_data write address fans out to 1024 LUTRAM write
# enables, creating a path that violates the clock period. This path is purely a configuration-phase operation.
# It is never active during S_READY (datapath) — so relaxing it to 2 cycles
# is functionally safe. The hold constraint is tightened by 1 to compensate.
# final_req_reg write enable decode (count_b address comparator)
set_multicycle_path -setup 2 \
    -to [get_cells {aurora_bd_i/crossbar_axis_wrapper_0/inst/u_xbar/inst/final_req_reg_reg[*][*]}]
set_multicycle_path -hold 1 \
    -to [get_cells {aurora_bd_i/crossbar_axis_wrapper_0/inst/u_xbar/inst/final_req_reg_reg[*][*]}]

# inv_orig_reg write address decode (data-dependent cfg_data address)
set_multicycle_path -setup 2 \
    -to [get_cells {aurora_bd_i/crossbar_axis_wrapper_0/inst/u_xbar/inst/inv_orig_reg_reg[*][*]}]
set_multicycle_path -hold 1 \
    -to [get_cells {aurora_bd_i/crossbar_axis_wrapper_0/inst/u_xbar/inst/inv_orig_reg_reg[*][*]}]

# src_for_out composition (double LUTRAM read through resolving)
set_multicycle_path -setup 2 \
    -to [get_cells {aurora_bd_i/crossbar_axis_wrapper_0/inst/u_xbar/inst/src_for_out_reg[*][*]}]
set_multicycle_path -hold 1 \
    -to [get_cells {aurora_bd_i/crossbar_axis_wrapper_0/inst/u_xbar/inst/src_for_out_reg[*][*]}]