`timescale 1ns / 1ps
// =============================================================================
// mux_f789_tree  -  Pipelined WIDTH-to-1 bit multiplexer
// Optimized for Xilinx UltraScale+
//
// Constraints:
//   - WIDTH must be a power of 2
//   - WIDTH must be a multiple of 16
//   - WIDTH must be >= 16 and <= 1024
// Valid values: 16, 32, 64, 128, 256, 512, 1024
// =============================================================================
module mux_f789_tree #(
    parameter  int WIDTH    = 1024,
    localparam int SEL_BITS = $clog2(WIDTH),  // 10 for WIDTH=1024, 7 for WIDTH=128
    localparam int S1_OUT   = WIDTH / 16,      // 64 for WIDTH=1024, 8 for WIDTH=128
    localparam int S1_BITS  = $clog2(S1_OUT)   //  6 for WIDTH=1024, 3 for WIDTH=128
)(
    input  logic                 clk,
    input  logic [WIDTH-1:0]     data_in,
    input  logic [SEL_BITS-1:0]  select_bin,
    output logic                 data_out
);

    // -------------------------------------------------------------------------
    // Parameter validation - caught at elaboration in simulation and synthesis
    // -------------------------------------------------------------------------
    initial begin
        if (WIDTH < 16)
            $fatal(1, "mux_f789_tree: WIDTH=%0d must be >= 16", WIDTH);
        if (WIDTH > 1024)
            $fatal(1, "mux_f789_tree: WIDTH=%0d must be <= 1024", WIDTH);
        if ((WIDTH & (WIDTH-1)) != 0)
            $fatal(1, "mux_f789_tree: WIDTH=%0d must be a power of 2", WIDTH);
        if (WIDTH % 16 != 0)
            $fatal(1, "mux_f789_tree: WIDTH=%0d must be a multiple of 16", WIDTH);
    end

    // -------------------------------------------------------------------------
    // CYCLE 0: Input Registration
    // (* dont_touch *) prevents merging with upstream logic or retiming.
    // -------------------------------------------------------------------------
    (* dont_touch = "true" *) logic [WIDTH-1:0]    data_in_r;
    (* dont_touch = "true" *) logic [SEL_BITS-1:0] select_r0;

    always_ff @(posedge clk) begin
        data_in_r <= data_in;
        select_r0 <= select_bin;
    end

    // -------------------------------------------------------------------------
    // STAGE 1: WIDTH -> S1_OUT (Combinational)
    // Each 16-to-1 mux maps to LUT6 + MUXF7 + MUXF8 logic in a slice.
    // select_r0[3:0] selects one of 16 bits within each group.
    // -------------------------------------------------------------------------
    logic [S1_OUT-1:0] s1_out_comb;

    always_comb begin
        for (int i = 0; i < S1_OUT; i++) begin
            s1_out_comb[i] = data_in_r[(i * 16) + select_r0[3:0]];
        end
    end

    // -------------------------------------------------------------------------
    // CYCLE 1: Pipeline Register
    // Cuts the path between the WIDTH->S1_OUT and S1_OUT->1 stages.
    // select_r0[3:0] is consumed by Stage 1 above; only upper bits needed next.
    // -------------------------------------------------------------------------
    (* dont_touch = "true" *) logic [S1_OUT-1:0]  s1_reg;
    (* dont_touch = "true" *) logic [S1_BITS-1:0] select_r1;

    always_ff @(posedge clk) begin
        s1_reg    <= s1_out_comb;
        select_r1 <= select_r0[SEL_BITS-1:4];  // upper S1_BITS bits
    end

    // -------------------------------------------------------------------------
    // STAGE 2 & 3: S1_OUT -> 1 (Combinational)
    // select_r1 indexes directly into s1_reg.
    // Vivado maps this to a MUXF7/F8/F9 chain.
    // -------------------------------------------------------------------------
    logic s3_out_comb;

    always_comb begin
        s3_out_comb = s1_reg[select_r1];
    end

    // -------------------------------------------------------------------------
    // CYCLE 2: Output Registration
    // (* dont_touch *) prevents merging with downstream logic.
    // -------------------------------------------------------------------------
    (* dont_touch = "true" *) logic data_out_r;

    always_ff @(posedge clk) begin
        data_out_r <= s3_out_comb;
    end

    assign data_out = data_out_r;

endmodule