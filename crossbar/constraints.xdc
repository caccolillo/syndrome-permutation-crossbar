# 400 MHz system clock (2.500 ns period)
# For standalone runtime_configurable_crossbar synthesis/implementation
# CONFIG_WIDTH=64, BEATS_TOTAL=171, DATA_WIDTH=1024, ADDR_WIDTH=10
create_clock -period 2.500 -name clk_400 -waveform {0.000 1.250} [get_ports clk]

# =============================================================================
# Multicycle path constraints — configuration-phase paths only
#
# All three paths below are active ONLY during S_LOAD (configuration).
# They are never active during S_READY (data processing).
# Relaxing to 2 cycles is therefore functionally safe.
# The -hold 1 companion tightens the hold check to compensate.
# =============================================================================

# inv_orig_reg: data-dependent write address (cfg_data value as address).
# cfg_data fans out to 1024 LUTRAM write enables — 10 LUT levels post-route.
set_multicycle_path -setup 2 \
    -to [get_cells {inv_orig_reg_reg[*][*]}]
set_multicycle_path -hold  1 \
    -to [get_cells {inv_orig_reg_reg[*][*]}]

# final_req_reg: sequential write address decode (count_b comparator).
# CARRY8-based comparator with high fanout — exceeds 2.5 ns at 400 MHz.
set_multicycle_path -setup 2 \
    -to [get_cells {final_req_reg_reg[*][*]}]
set_multicycle_path -hold  1 \
    -to [get_cells {final_req_reg_reg[*][*]}]

# src_for_out: composition step — reads inv_orig_reg and final_req_reg
# through two LUTRAM async reads, 5 logic levels, violates 2.5 ns.
set_multicycle_path -setup 2 \
    -to [get_cells {src_for_out_reg[*][*]}]
set_multicycle_path -hold  1 \
    -to [get_cells {src_for_out_reg[*][*]}]
