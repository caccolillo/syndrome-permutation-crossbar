##############################################################################
# aurora_zcu111.xdc
#
# I/O + timing constraints for:
#   ZCU111 (XCZU28DR-2FFVG1517E)
#   1-lane Aurora 64B/66B @ 25.78125 Gbps
#   SFP28 port 0  →  GTY Bank 128, Channel 0
#
# Sources / cross-references:
#   UG1271 (ZCU111 Board User Guide v1.2)
#   XCZU28DR pinout (package FFVG1517)
#   Aurora 64B/66B PG074
#
# IMPORTANT: Pin assignments below are derived from UG1271 Appendix B
# and community-verified designs. Always cross-check against your
# specific board revision schematic (0381811) before taping out.
##############################################################################

##############################################################################
# 1. GTY Reference Clock — USER_MGT_SI570 (U49)
#    Default: 156.250 MHz  →  must be reprogrammed to 161.1328125 MHz
#    for exact 25.78125 Gbps.  Connect to Bank 128 MGTREFCLK0.
##############################################################################
set_property PACKAGE_PIN V31 [get_ports mgt_refclk_p_0]
set_property PACKAGE_PIN V32 [get_ports mgt_refclk_n_0]

# GTY refclk pins do not use an I/O standard — no set_property IOSTANDARD needed.
# The IBUFDS_GTE4 in the RTL handles these pins.

# Timing constraint for the refclk (161.1328125 MHz period = 6.206 ns)
create_clock -period 6.206 \
             -name mgt_refclk \
             [get_ports mgt_refclk_p]

##############################################################################
# 2. GTY Serial Data — Bank 128, Channel 0  (SFP28 J0 / leftmost port)
#    RX: MGTYRXP/N0_128   TX: MGTYTXP/N0_128
#
#    Pin assignments from UG1271 Table B-xx / schematic page referencing
#    Bank 128 quad connectivity.
#    NOTE: GTY TX/RX serial pins do not require IOSTANDARD or SLEW
#    constraints — they are managed entirely by the GTY transceiver.
##############################################################################
set_property PACKAGE_PIN AA45 [get_ports sfp0_rx_p]
set_property PACKAGE_PIN AA46 [get_ports sfp0_rx_n]
set_property PACKAGE_PIN Y42  [get_ports sfp0_tx_p]
set_property PACKAGE_PIN Y43  [get_ports sfp0_tx_n]

##############################################################################
# 3. Init clock — 100 MHz
#    Connect to a free GC-capable input or PS-derived fabric clock.
#    Example below uses the USER_SI570 (U47) GC input on bank 69,
#    which defaults to 300 MHz — drive through an MMCM to get 100 MHz,
#    or use PS pl_clk0 (typically 100 MHz after Zynq PS configuration).
#
#    If sourcing from PS pl_clk0, no package pin constraint is needed;
#    the PS IP drives this net directly.  Uncomment the section below
#    only if you are using a discrete oscillator for init_clk.
##############################################################################
# -- Uncomment if init_clk comes from an external pin rather than PS: --
# set_property PACKAGE_PIN J19          [get_ports init_clk]
# set_property IOSTANDARD   LVDS        [get_ports init_clk]
# create_clock -period 10.000 -name init_clk [get_ports init_clk]

# When driven by PS pl_clk0 (recommended), add this instead:
create_clock -period 10.000 -name init_clk [get_pins -hier -filter {NAME =~ */zynq_ultra_ps_e_0/inst/PS8_i/PLCLK[0]}]

##############################################################################
# 4. SFP28 control signals (GPIO, Bank 65, 1.8 V LVCMOS)
#    These control TX disable, module present detect, loss-of-signal,
#    and TX fault.  Net names from UG1271 Table 3-17.
#
#    Connect to your top-level ports if you need to enable/monitor the
#    SFP28 module.  Pins shown for SFP28 port 0.
##############################################################################

# SFP0_TX_DISABLE  — drive high to disable laser, drive low to enable
set_property PACKAGE_PIN AL12 [get_ports sfp0_tx_disable]
set_property IOSTANDARD LVCMOS18 [get_ports sfp0_tx_disable]

# SFP0_PRESENT_B   — active-low module present (input)
set_property PACKAGE_PIN AM12 [get_ports sfp0_present_b]
set_property IOSTANDARD LVCMOS18 [get_ports sfp0_present_b]

# SFP0_RX_LOS      — active-high loss-of-signal (input)
set_property PACKAGE_PIN AN11 [get_ports sfp0_rx_los]
set_property IOSTANDARD LVCMOS18 [get_ports sfp0_rx_los]

# SFP0_TX_FAULT    — active-high TX fault (input)
set_property PACKAGE_PIN AP11 [get_ports sfp0_tx_fault]
set_property IOSTANDARD LVCMOS18 [get_ports sfp0_tx_fault]

##############################################################################
# 5. Aurora user_clk_out — used as the clock for downstream AXI-Stream logic
#    Aurora 64B/66B 1-lane @ 25.78125 Gbps:
#      user_clk = line_rate / (64 * 66/64) / 1 lane = ~391.0 MHz
#    (The core drives this from an internal BUFG — no external pin needed.)
#    Declare as a generated clock so timing analysis works downstream.
##############################################################################
create_generated_clock -name user_clk_out \
    -source [get_pins -hier -filter {NAME =~ */aurora_64b66b_0/*/TXOUTCLK}] \
    -multiply_by 1 \
    [get_pins -hier -filter {NAME =~ */aurora_64b66b_0/*/user_clk_out_BUFG/O}]

##############################################################################
# 6. False paths between unrelated clock domains
##############################################################################
set_false_path -from [get_clocks init_clk] \
               -to   [get_clocks user_clk_out]
set_false_path -from [get_clocks user_clk_out] \
               -to   [get_clocks init_clk]
set_false_path -from [get_clocks mgt_refclk] \
               -to   [get_clocks init_clk]
set_property LOC IBUFDS_GTE4_X0Y0 [get_cells aurora_bd_i/aurora_top_0/inst/u_aurora/inst/IBUFDS_GTE4_refclk1]

##############################################################################
# 7. Output timing for AXI-Stream RX bus
#    Relax output delay: downstream logic runs on user_clk_out (same domain).
#    If crossing to a slower domain add proper CDC (async FIFO recommended).
##############################################################################
# No output delay constraints needed — m_axis_rx_* driven by user_clk_out
# and consumed in the same clock domain.

##############################################################################
# 8. Bitstream / configuration settings
##############################################################################
set_property BITSTREAM.GENERAL.COMPRESS   TRUE      [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4        [current_design]
set_property CONFIG_VOLTAGE               1.8       [current_design]
set_property CFGBVS                       GND       [current_design]

##############################################################################
# END of aurora_zcu111.xdc
#
# Checklist before building:
#  [ ] Cross-check GTY serial pin locations against your board revision
#      schematic (0381811) — especially AA45/AA46/Y42/Y43.
#  [ ] Confirm SFP28 GPIO pin locations from Appendix B of UG1271.
#  [ ] Program USER_MGT_SI570 (U49) to 161.1328125 MHz at startup.
#  [ ] Tie sfp0_tx_disable = 0 in RTL after channel_up to enable laser.
##############################################################################
