# =============================================================================
# pblocks.xdc
#
# Floorplan constraints for the end-system build, used to keep the 256-bit
# permutation crossbar routable.
#
# Background:
#   The crossbar's mux-tree fabric is routing-dense. Without a floorplan the
#   placer spreads it across the whole die and the router cannot resolve the
#   resulting congestion (observed: 9.5 hr route, ~250k node overlaps,
#   DRC RTSTAT-13 "insufficient routing"). Confining the crossbar to a
#   contiguous region keeps mux instances near their broadcast-register
#   sources and gives the router a fighting chance.
#
# Add this file to constrs_1 (the end-system prj.tcl does this).
#
# TUNING:
#   The SLICE rectangle below is a starting estimate. After the first
#   implementation run:
#     1. open_run impl_1
#     2. In the Device view, select the crossbar cells:
#          select_objects [get_cells -hier -filter {NAME =~ *u_xbar*}]
#     3. Read the bounding box of the highlighted cells.
#     4. Resize this pblock to ~20-30% larger than that bounding box.
#   If resize_pblock errors with an invalid-site message, the rectangle
#   overlaps a hard-block region (PS, RFSoC tiles, GT columns) - shift it.
# =============================================================================

create_pblock pblock_xbar

# --- Cells to confine -------------------------------------------------------
# The crossbar core (u_xbar) wherever it sits in the BD hierarchy.
add_cells_to_pblock pblock_xbar \
    [get_cells -hierarchical -filter {NAME =~ *u_xbar*}] -quiet

# The AXIS wrapper's skid-buffer pipeline registers, so they stay next to
# the crossbar they feed/drain (reduces long routes on the AXIS handshake).
add_cells_to_pblock pblock_xbar \
    [get_cells -hierarchical -filter {NAME =~ *crossbar_axis_wrappe*g_rx_pipe*}] -quiet
add_cells_to_pblock pblock_xbar \
    [get_cells -hierarchical -filter {NAME =~ *crossbar_axis_wrappe*g_tx_pipe*}] -quiet

# --- Region -----------------------------------------------------------------
# ~50 SLICE columns x ~300 rows in the upper-middle of the die. Left edge
# kept clear for the PS; lower-left kept clear for the Aurora GT quad.
resize_pblock pblock_xbar -add {SLICE_X40Y60:SLICE_X89Y359}

# --- Properties -------------------------------------------------------------
# SOFT pblock: the placer may spill trivial glue logic outside the region
# if that helps. For a congested design a soft pblock routes much better
# than a hard one, which can strand the router with no escape path.
set_property IS_SOFT TRUE [get_pblocks pblock_xbar]

# Deliberately NOT setting CONTAIN_ROUTING. Forcing routing to stay inside
# the rectangle makes congestion worse for a design this dense.
