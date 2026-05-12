// =============================================================================
// runtime_configurable_crossbar
//
// PURPOSE
//   Programmable 1024-bit permutation crossbar for Xilinx UltraScale+.
//   Computes data_out[i] = data_in[P[i]] where P is a composition of two
//   user-supplied index maps loaded over a 64-bit configuration bus.
//
// PERMUTATION ALGEBRA
//   The user supplies two maps over the configuration bus:
//     orig_map  (cfg_sel=0): describes the current ordering of the input bits
//     final_map (cfg_sel=1): describes the desired output ordering
//
//   The hardware computes the composed permutation:
//     inv_orig[orig_map[i]] = i          (invert the original map)
//     P[i] = inv_orig[final_map[i]]      (compose with final map)
//     data_out[i] = data_in[P[i]]        (apply permutation)
//
//   Example (8-bit):
//     orig_map  = [0,1,2,3,4,5,6,7]  (identity)
//     final_map = [0,7,1,2,3,5,6,4]
//     P         = [0,7,1,2,3,5,6,4]
//     data_out[1] = data_in[7], data_out[7] = data_in[4], etc.
//
// CONFIGURATION PROTOCOL
//   1. Assert cfg_restart (or rst) to clear internal state
//   2. Load orig_map:  drive cfg_sel=0, cfg_data=indices, cfg_valid=1
//                      for ceil(DATA_WIDTH / (CONFIG_WIDTH/ADDR_WIDTH)) beats
//                      Back-pressure via cfg_ready
//   3. Load final_map: same protocol with cfg_sel=1
//   4. Poll ready_out: asserts ~2 cycles after both maps are loaded
//   5. Drive data_in / data_in_vld; read data_out / data_out_vld
//      Data pipeline latency: 4 clock cycles (fixed)
//
// CONFIGURATION TIMING (DATA_WIDTH=1024, CONFIG_WIDTH=64, ADDR_WIDTH=10)
//   Indices per beat : floor(64/10) = 6
//   Beats per map    : ceil(1024/6) = 171
//   Load time (seq.) : 342 beats x 2.5 ns = 855 ns  < 1 us budget
//
// DATA PIPELINE (4 cycles source to data_out)
//   Cycle 1 : Broadcast register tree  - data_in replicated to 32 clusters
//   Cycle 2 : Mux stage A              - 1024->64 (select[3:0], 16:1 per group)
//   Cycle 3 : Mux stage B              - 64->1    (select[9:4], MUXF7/F8/F9)
//   Cycle 4 : Output register
//
// TIMING TARGET
//   400 MHz (2.5 ns period) on xczu28dr-2e (ZCU111)
//   Post-synthesis WNS: +1.3 ns (standalone); see constraints.xdc for
//   multicycle path constraints required when integrated in a larger design
//   with a high-fanout PS clock tree.
//
// PARAMETERS
//   DATA_WIDTH   : permutation width in bits (power of 2, <= 1024)
//   ADDR_WIDTH   : ceil(log2(DATA_WIDTH)) — index bit width
//   CONFIG_WIDTH : configuration bus width (fixed at 64)
// =============================================================================
module runtime_configurable_crossbar #(
    parameter int DATA_WIDTH   = 1024,
    parameter int ADDR_WIDTH   = 10,
    parameter int CONFIG_WIDTH = 64
)(
    input  logic                    clk,
    input  logic                    rst,         // active-high synchronous reset

    // Configuration bus
    input  logic                    cfg_restart, // pulse to abort and restart config
    input  logic [CONFIG_WIDTH-1:0] cfg_data,    // index payload (6 x 10-bit indices)
    input  logic                    cfg_valid,   // beat valid
    input  logic                    cfg_sel,     // 0=orig_map  1=final_map
    output logic                    cfg_ready,   // back-pressure: 1=beat accepted

    output logic                    ready_out,   // permutation ready; data accepted

    input  logic [DATA_WIDTH-1:0]   data_in,
    input  logic                    data_in_vld,
    output logic [DATA_WIDTH-1:0]   data_out,
    output logic                    data_out_vld
);

    // -------------------------------------------------------------------------
    // Derived parameters
    //   IDXS_PER_BEAT : how many 10-bit indices fit in one 64-bit cfg_data word
    //   BEATS_TOTAL   : cfg beats required to load one complete map
    //   BEAT_BITS     : counter width (one extra bit avoids overflow)
    // -------------------------------------------------------------------------
    localparam int IDXS_PER_BEAT = CONFIG_WIDTH / ADDR_WIDTH;
    localparam int BEATS_TOTAL   = (DATA_WIDTH + IDXS_PER_BEAT - 1) / IDXS_PER_BEAT;
    localparam int BEAT_BITS     = $clog2(BEATS_TOTAL) + 1;

    // -------------------------------------------------------------------------
    // Configuration storage
    //
    //   inv_orig_reg  : inverse of orig_map.  Written with a DATA-DEPENDENT write
    //                   address (cfg_data[...] as address, beat index as value).
    //                   Must be LUTRAM (distributed) — BRAM cannot support
    //                   data-dependent write addresses.
    //                   NOTE: this write pattern creates a wide address-decode
    //                   fanout (~10 LUT levels).  A multicycle path constraint
    //                   is required when the module is instantiated in a design
    //                   with a high-fanout clock tree (see constraints.xdc).
    //
    //   final_req_reg : stores final_map verbatim.  Written with a SEQUENTIAL
    //                   write address (count_b counter).  BRAM-friendly, but
    //                   kept as LUTRAM to allow parallel read during composition.
    //
    //   src_for_out   : composed permutation P[i] = inv_orig[final_map[i]].
    //                   Written once during the resolving cycle.  Plain registers
    //                   (no ram_style attribute) — read in parallel by the mux
    //                   tree so must support 1024 simultaneous reads.
    // -------------------------------------------------------------------------
    (* ram_style = "distributed" *) logic [ADDR_WIDTH-1:0] inv_orig_reg  [DATA_WIDTH];
    (* ram_style = "distributed" *) logic [ADDR_WIDTH-1:0] final_req_reg [DATA_WIDTH];
    logic [ADDR_WIDTH-1:0] src_for_out [DATA_WIDTH];

    initial begin
        for (int i = 0; i < DATA_WIDTH; i++) begin
            inv_orig_reg [i] = ADDR_WIDTH'(i);
            final_req_reg[i] = ADDR_WIDTH'(i);
            src_for_out  [i] = ADDR_WIDTH'(i);
        end
    end

    // -------------------------------------------------------------------------
    // Configuration control registers
    // -------------------------------------------------------------------------
    logic [BEAT_BITS-1:0] count_a;    // beat counter for orig_map  (cfg_sel=0)
    logic [BEAT_BITS-1:0] count_b;    // beat counter for final_map (cfg_sel=1)
    logic                 done_a;     // orig_map  fully loaded
    logic                 done_b;     // final_map fully loaded
    logic                 resolving;  // one-cycle pulse: triggers composition
    logic                 is_ready;   // sticky: permutation valid, data accepted

    // cfg_ready is per-stream: deasserts independently when each map is complete
    assign cfg_ready = (cfg_sel == 1'b0) ? !done_a : !done_b;
    assign ready_out = is_ready;

    // -------------------------------------------------------------------------
    // Configuration FSM
    //
    // On each accepted beat (cfg_valid && cfg_ready):
    //   cfg_sel=0: unpack 6 indices from cfg_data, write inv_orig_reg using
    //              the INDEX VALUE as the write address (builds inverse map)
    //   cfg_sel=1: unpack 6 indices from cfg_data, write final_req_reg using
    //              the BEAT COUNTER as the write address (stores map directly)
    //
    // When both done_a and done_b are set, resolving pulses for one cycle.
    // The following cycle, is_ready asserts and data_in is accepted.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst || cfg_restart) begin
            count_a <= '0; 
            count_b <= '0;
            done_a  <= 1'b0; 
            done_b <= 1'b0;
            resolving <= 1'b0; 
            is_ready <= 1'b0;
        end else begin
            resolving <= 1'b0;
            // --- orig_map (cfg_sel=0): build inverse mapping ---
            // Write address = cfg_data[...] (the index VALUE), not the counter.
            // This is what makes it an inverse: inv_orig[orig[i]] = i.
            if (cfg_valid && cfg_sel == 1'b0 && !done_a) begin
                for (int k = 0; k < IDXS_PER_BEAT; k++) begin
                    int idx = int'(count_a) * IDXS_PER_BEAT + k;
                    if (idx < DATA_WIDTH) inv_orig_reg[cfg_data[k*ADDR_WIDTH +: ADDR_WIDTH]] <= ADDR_WIDTH'(idx);
                end
                if (count_a == BEAT_BITS'(BEATS_TOTAL-1)) done_a <= 1'b1;
                else count_a <= count_a + 1'b1;
            end
            // --- final_map (cfg_sel=1): store verbatim ---
            // Write address = count_b (sequential) — BRAM-friendly pattern.
            if (cfg_valid && cfg_sel == 1'b1 && !done_b) begin
                for (int k = 0; k < IDXS_PER_BEAT; k++) begin
                    int idx = int'(count_b) * IDXS_PER_BEAT + k;
                    if (idx < DATA_WIDTH) final_req_reg[idx] <= cfg_data[k*ADDR_WIDTH +: ADDR_WIDTH];
                end
                if (count_b == BEAT_BITS'(BEATS_TOTAL-1)) done_b <= 1'b1;
                else count_b <= count_b + 1'b1;
            end
            // --- Composition trigger ---
            // Pulse resolving for exactly one cycle once both maps are loaded.
            // is_ready follows one cycle later so the composition write has
            // completed before the first data_in beat is accepted.
            if (done_a && done_b && !is_ready && !resolving) resolving <= 1'b1;
            if (resolving) is_ready <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Permutation composition
    //
    // Executes in a single cycle when resolving pulses.
    // For each output index j: P[j] = inv_orig[ final_map[j] ]
    // Both reads are from LUTRAM (asynchronous) so the result is available
    // combinationally and can be registered in the same cycle.
    //
    // This is a 1024-wide parallel write — only possible because src_for_out
    // is implemented as plain registers, not BRAM.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (resolving) begin
            for (int j = 0; j < DATA_WIDTH; j++)
                src_for_out[j] <= inv_orig_reg[ final_req_reg[j] ];
        end
    end

    // -------------------------------------------------------------------------
    // Broadcast register tree (Pipeline cycle 1)
    //
    // data_in is replicated into CLUSTERS=32 independent register banks.
    // Each bank drives MUX_PER_CLUSTER=32 mux instances.
    // Replication prevents the 1024-bit data_in net from becoming a bottleneck
    // and allows Vivado to place each cluster close to its mux group.
    //
    // s1_phys_idx latches src_for_out when is_ready asserts and holds it
    // stable for the duration of data processing.  It only updates when a new
    // permutation is loaded (is_ready may briefly deassert during cfg_restart).
    //
    // (* dont_touch *) prevents Vivado from merging s1_data_rep across clusters
    // or absorbing s1_vld_rep into downstream logic.
    // -------------------------------------------------------------------------
    localparam int CLUSTERS = 32;
    localparam int MUX_PER_CLUSTER = DATA_WIDTH / CLUSTERS;

    (* dont_touch = "true" *) logic [DATA_WIDTH-1:0] s1_data_rep [CLUSTERS];
    (* dont_touch = "true" *) logic [CLUSTERS-1:0]   s1_vld_rep;
    logic [ADDR_WIDTH-1:0] s1_phys_idx [DATA_WIDTH];

    always_ff @(posedge clk) begin
        for (int i = 0; i < CLUSTERS; i++) begin
            s1_vld_rep[i]  <= (rst) ? 1'b0 : (is_ready && data_in_vld);
            s1_data_rep[i] <= data_in;
        end
        for (int j = 0; j < DATA_WIDTH; j++) begin
            s1_phys_idx[j] <= is_ready ? src_for_out[j] : s1_phys_idx[j];
        end
    end

    // -------------------------------------------------------------------------
    // Pipelined mux grid (Pipeline cycles 2-4, inside mux_f789_tree)
    //
    // 1024 independent mux_f789_tree instances, one per output bit.
    // Each instance performs a 1024:1 selection in 3 pipelined cycles:
    //   Cycle 2: 16:1 first stage  (LUT6 + MUXF7 + MUXF8, select[3:0])
    //   Cycle 3: 64:1 second stage (MUXF7/F8/F9 chain,    select[9:4])
    //   Cycle 4: output register
    //
    // Instances are grouped into CLUSTERS to align with the broadcast tree:
    // cluster c drives mux indices [c*32 .. (c+1)*32-1], all sharing the
    // same s1_data_rep[c] input, improving placement locality.
    // -------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] mux_raw_out;

    generate
        for (genvar c = 0; c < CLUSTERS; c++) begin : gen_clusters
            for (genvar m = 0; m < MUX_PER_CLUSTER; m++) begin : gen_muxes
                localparam int g_idx = c * MUX_PER_CLUSTER + m;
                mux_f789_tree #(.WIDTH(DATA_WIDTH)) mux_inst (
                    .clk        (clk),
                    .data_in    (s1_data_rep[c]),
                    .select_bin (s1_phys_idx[g_idx]),
                    .data_out   (mux_raw_out[g_idx])
                );
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Output registration (Pipeline cycle 4)
    //
    // vld_pipe is a 3-bit shift register that delays data_in_vld to align with
    // mux_raw_out.  Latency breakdown:
    //   Cycle 1 : s1_vld_rep  set   (broadcast stage)
    //   Cycle 2 : vld_pipe[0] set   (mux stage A)
    //   Cycle 3 : vld_pipe[1] set   (mux stage B)
    //   Cycle 4 : vld_pipe[2] set   (output register) -> data_out_vld asserts
    //
    // data_out is registered from mux_raw_out (combinational mux output) to
    // meet timing at 400 MHz.
    // -------------------------------------------------------------------------
    logic [2:0] vld_pipe;

    always_ff @(posedge clk) begin
        if (rst) begin
            vld_pipe     <= '0;
            data_out     <= '0;
            data_out_vld <= 1'b0;
        end else begin
            vld_pipe     <= {vld_pipe[1:0], s1_vld_rep[0]};
            data_out     <= mux_raw_out;
            data_out_vld <= vld_pipe[2];
        end
    end
endmodule
