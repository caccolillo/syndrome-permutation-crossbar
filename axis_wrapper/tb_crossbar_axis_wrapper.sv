// =============================================================================
// tb_crossbar_axis_wrapper.sv
//
// Minimal self-checking testbench for crossbar_axis_wrapper.
// No stalls: tvalid held high back-to-back throughout all three phases.
// Single AXI-S packet: tlast asserted ONLY on the final DATA beat (beat 357).
//
// Timing budget: 400 MHz (2.5 ns period), 1 us = 400 cycles
//
// Minimum cycle count (no stalls):
//   171 (CFG_A) + 171 (CFG_B) + ~2 (RX_WAIT/ready_out) +
//   16  (DATA in) + 5 (crossbar pipeline) + 16 (TX out) = ~381 cycles
//   => ~953 ns @ 400 MHz  - PASS, under 1 us by ~19 cycles / ~48 ns
// =============================================================================

`timescale 1ns/1ps

module tb_crossbar_axis_wrapper;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam int  DATA_WIDTH    = 1024;
    localparam int  ADDR_WIDTH    = 10;
    localparam int  CONFIG_WIDTH  = 64;

    localparam int  IDXS_PER_BEAT = CONFIG_WIDTH / ADDR_WIDTH;   // 6
    localparam int  BEATS_CFG     = (DATA_WIDTH + IDXS_PER_BEAT - 1)
                                     / IDXS_PER_BEAT;            // 171
    localparam int  BEATS_DATA    = DATA_WIDTH / CONFIG_WIDTH;   // 16
    localparam int  BEATS_TOTAL   = 2 * BEATS_CFG + BEATS_DATA;  // 358

    localparam real CLK_PERIOD_NS = 2.5;    // 400 MHz
    localparam real BUDGET_NS     = 1000.0;  // 1 us
    localparam int  BUDGET_CYC    = int'(BUDGET_NS / CLK_PERIOD_NS);  // 400
    localparam int  TIMEOUT_CYC   = 10000;

    // =========================================================================
    // Clock & reset
    // =========================================================================
    logic clk = 0;
    always #(CLK_PERIOD_NS / 2.0) clk = ~clk;

    logic rst = 1;

    // =========================================================================
    // DUT ports
    // =========================================================================
    logic [63:0] s_axis_rx_tdata  = '0;
    logic [7:0]  s_axis_rx_tkeep  = 8'hFF;
    logic        s_axis_rx_tvalid = 0;
    logic        s_axis_rx_tlast  = 0;
    logic        s_axis_rx_tready;
    logic        rx_framing_err;
    logic [63:0] m_axis_tx_tdata;
    logic [7:0]  m_axis_tx_tkeep;
    logic        m_axis_tx_tvalid;
    logic        m_axis_tx_tlast;
    logic        m_axis_tx_tready = 1;

    // =========================================================================
    // DUT
    // =========================================================================
    crossbar_axis_wrapper #(
        .DATA_WIDTH  (DATA_WIDTH),
        .ADDR_WIDTH  (ADDR_WIDTH),
        .CONFIG_WIDTH(CONFIG_WIDTH)
    ) dut (
        .clk              (clk),
        .rst              (rst),
        .s_axis_rx_tdata  (s_axis_rx_tdata),
        .s_axis_rx_tkeep  (s_axis_rx_tkeep),
        .s_axis_rx_tvalid (s_axis_rx_tvalid),
        .s_axis_rx_tlast  (s_axis_rx_tlast),
        .s_axis_rx_tready (s_axis_rx_tready),
        .rx_framing_err   (rx_framing_err),
        .m_axis_tx_tdata  (m_axis_tx_tdata),
        .m_axis_tx_tkeep  (m_axis_tx_tkeep),
        .m_axis_tx_tvalid (m_axis_tx_tvalid),
        .m_axis_tx_tlast  (m_axis_tx_tlast),
        .m_axis_tx_tready (m_axis_tx_tready)
    );

    // =========================================================================
    // Cycle counter
    // =========================================================================
    int cycle_count = 0;
    always_ff @(posedge clk) cycle_count <= cycle_count + 1;

    // =========================================================================
    // Pre-compute the full 358-beat RX packet into a flat array
    // so the driver loop is a single clean sequence with no branching.
    // tlast is set only on beat 357 (the last DATA beat).
    // =========================================================================
    logic [CONFIG_WIDTH-1:0] rx_packet [BEATS_TOTAL];
    logic                    rx_tlast  [BEATS_TOTAL];
    logic [DATA_WIDTH-1:0]   bitstring;
    logic [DATA_WIDTH-1:0]   rx_result = '0;

    int  start_cycle;
    int  end_cycle;
    int  elapsed_cyc;
    real elapsed_ns;
    int  beat_idx;

    initial begin
        $dumpfile("tb_crossbar_axis_wrapper.vcd");
        $dumpvars(0, tb_crossbar_axis_wrapper);

        // ---- Reset -----------------------------------------------------------
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // ---- Build pseudo-random bitstring -----------------------------------
        for (int w = 0; w < DATA_WIDTH/32; w++)
            bitstring[w*32 +: 32] = $urandom();

        // ---- Pre-compute RX packet -------------------------------------------
        // CFG_A: identity original mapping (orig[i] = i)
        // Padding slots in the last beat (where idx >= DATA_WIDTH) are filled
        // with DATA_WIDTH-1 so the crossbar writes inv_orig_reg[DATA_WIDTH-1]
        // twice - harmless duplicate - rather than corrupting inv_orig_reg[0].
        for (int beat = 0; beat < BEATS_CFG; beat++) begin
            rx_packet[beat] = '0;
            for (int k = 0; k < IDXS_PER_BEAT; k++) begin
                int idx = beat * IDXS_PER_BEAT + k;
                rx_packet[beat][k*ADDR_WIDTH +: ADDR_WIDTH] =
                    (idx < DATA_WIDTH) ? ADDR_WIDTH'(idx) : ADDR_WIDTH'(DATA_WIDTH-1);
            end
            rx_tlast[beat] = 1'b0;
        end

        // CFG_B: identity final mapping (final[i] = i)
        // Same padding strategy.
        for (int beat = 0; beat < BEATS_CFG; beat++) begin
            rx_packet[BEATS_CFG + beat] = '0;
            for (int k = 0; k < IDXS_PER_BEAT; k++) begin
                int idx = beat * IDXS_PER_BEAT + k;
                rx_packet[BEATS_CFG + beat][k*ADDR_WIDTH +: ADDR_WIDTH] =
                    (idx < DATA_WIDTH) ? ADDR_WIDTH'(idx) : ADDR_WIDTH'(DATA_WIDTH-1);
            end
            rx_tlast[BEATS_CFG + beat] = 1'b0;
        end

        // DATA: 16 x 64-bit slices of the bitstring
        for (int beat = 0; beat < BEATS_DATA; beat++) begin
            rx_packet[2*BEATS_CFG + beat] = bitstring[beat*CONFIG_WIDTH +: CONFIG_WIDTH];
            // tlast ONLY on the very last beat of the entire packet
            rx_tlast[2*BEATS_CFG + beat]  = (beat == BEATS_DATA - 1) ? 1'b1 : 1'b0;
        end

        // ---- Stream all beats back-to-back, tvalid held high -----------------
        // Rule: drive tdata/tlast on NEGEDGE, sample tready on POSEDGE.
        // tvalid is asserted before the first negedge and never deasserted.
        // Beat index advances only when tready was high on the last posedge.
        // During RX_WAIT tready is low - the same beat is re-presented each
        // cycle until tready goes high again (correct AXI-S stall behaviour).
        begin : rx_stream
            int beat      = 0;
            bit tready_ok = 0;

            // Assert tvalid and pre-drive beat 0 before the first clock edge
            s_axis_rx_tvalid = 1'b1;
            s_axis_rx_tdata  = rx_packet[0];
            s_axis_rx_tlast  = rx_tlast[0];

            while (beat < BEATS_TOTAL) begin
                // Sample tready on posedge
                @(posedge clk);
                tready_ok = s_axis_rx_tready;
                if (beat == 0 && tready_ok) start_cycle = cycle_count;

                // Drive next beat on negedge (well before next posedge)
                @(negedge clk);
                if (tready_ok) begin
                    beat++;
                    if (beat < BEATS_TOTAL) begin
                        s_axis_rx_tdata = rx_packet[beat];
                        s_axis_rx_tlast = rx_tlast[beat];
                    end else begin
                        // Last beat accepted - deassert tvalid on this negedge
                        s_axis_rx_tvalid = 1'b0;
                        s_axis_rx_tlast  = 1'b0;
                    end
                end
            end
        end

        $display("[DBG] RX stream done at cycle %0d  rx_framing_err=%0b  rx_tready=%0b",
                 cycle_count, rx_framing_err, s_axis_rx_tready);

        // ---- Collect TX output -----------------------------------------------
        // TX beat 0 is presented on the posedge tvalid first goes high.
        // We must sample it on that same posedge, not the next one.
        // Strategy: wait on negedge until tvalid seen, then sample each
        // posedge for tvalid && tready without an extra clock advance.
        begin : collect_tx
            int cnt = 0;
            beat_idx = 0;
            // Wait for tvalid - check on each posedge
            while (!m_axis_tx_tvalid) begin
                @(posedge clk);
                if (++cnt > TIMEOUT_CYC)
                    $fatal(1, "TIMEOUT waiting for TX tvalid");
            end
            // tvalid is now high on the current posedge - sample beat 0 now,
            // then advance one posedge per beat.
            forever begin
                if (m_axis_tx_tvalid && m_axis_tx_tready) begin
                    rx_result[beat_idx*CONFIG_WIDTH +: CONFIG_WIDTH] = m_axis_tx_tdata;
                    if (m_axis_tx_tlast) end_cycle = cycle_count;
                    beat_idx++;
                    if (beat_idx == BEATS_DATA) break;
                end
                @(posedge clk);
            end
        end

        // ---- Report ----------------------------------------------------------
        elapsed_cyc = end_cycle - start_cycle + 1;
        elapsed_ns  = elapsed_cyc * CLK_PERIOD_NS;

        $display("\n=================================================");
        $display(" RESULTS @ 400 MHz  (period = %.3f ns)", CLK_PERIOD_NS);
        $display(" Start cycle : %0d  (first RX beat accepted)", start_cycle);
        $display(" End cycle   : %0d  (TX tlast accepted)",      end_cycle);
        $display(" Elapsed     : %0d cycles  =  %.1f ns",  elapsed_cyc, elapsed_ns);
        $display(" Budget      : %0d cycles  =  %.0f ns",  BUDGET_CYC,  BUDGET_NS);

        if (rx_result === bitstring)
            $display(" Data        : PASS");
        else begin
            $display(" Data        : FAIL");
            $display("   XOR diff  : %0h", rx_result ^ bitstring);
            begin
                logic [DATA_WIDTH-1:0] xor_val;
                xor_val = rx_result ^ bitstring;
                for (int b = DATA_WIDTH-1; b >= DATA_WIDTH-32; b--) begin
                    if (xor_val[b])
                        $display("   bit %4d : got=%0b exp=%0b",
                                 b, rx_result[b], bitstring[b]);
                end
            end
        end

        if (elapsed_ns < BUDGET_NS)
            $display(" Timing      : PASS  (%.1f ns < 1000 ns, margin = %.1f ns)",
                     elapsed_ns, BUDGET_NS - elapsed_ns);
        else
            $display(" Timing      : FAIL  (%.1f ns >= 1000 ns, over by %0d cycles / %.1f ns)",
                     elapsed_ns, elapsed_cyc - BUDGET_CYC,
                     (elapsed_cyc - BUDGET_CYC) * CLK_PERIOD_NS);

        $display("=================================================\n");
        $finish;
    end

    // =========================================================================
    // Watchdog
    // =========================================================================
    initial begin
        #(CLK_PERIOD_NS * TIMEOUT_CYC);
        $fatal(1, "GLOBAL WATCHDOG expired after %0d cycles", TIMEOUT_CYC);
    end

endmodule
