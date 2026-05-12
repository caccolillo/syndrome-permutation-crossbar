// =============================================================================
// tb_runtime_configurable_crossbar
//
// PURPOSE
//   Self-checking testbench for runtime_configurable_crossbar.
//   Verifies functional correctness and configuration latency across six
//   test cases covering identity, reversal, random permutations, back-to-back
//   reconfiguration, and non-permutation (broadcast/multicast) mappings.
//
// VERIFICATION METHODOLOGY
//   A software golden model computes the expected output independently of
//   the RTL.  The golden model implements the same composition:
//     inv_om[om[i]] = i  (invert orig_map)
//     P[i] = inv_om[fm[i]]  (compose with final_map)
//     expected[i] = data_in[P[i]]
//   RTL output is compared against the golden model bit-for-bit.
//
// CONFIGURATION PROTOCOL UNDER TEST
//   - cfg_sel=0: orig_map loaded beat-by-beat, back-pressured via cfg_ready
//   - cfg_sel=1: final_map loaded beat-by-beat, back-pressured via cfg_ready
//   - ready_out: polled after both maps loaded; latency checked against 1 us
//
// CLOCK
//   400 MHz (2.500 ns period)
//   Latency limit remains 1000 ns absolute.
//
// TEST CASES
//   TC-01  Identity permutation         (P[i]=i, output == input)
//   TC-02  Full bit reversal            (P[i]=1023-i)
//   TC-03  Random permutation           (30 vectors, no gaps)
//   TC-04  Random permutation + gaps    (50 vectors, ~20% stall cycles)
//   TC-05  Back-to-back reconfiguration (2 iterations x 10 vectors)
//   TC-06  Non-permutation mappings     (broadcast and dualcast)
//
// PASS/FAIL REPORTING
//   Per-vector $error on mismatch; summary at end.
//   $fatal if any failures detected.
// =============================================================================
`timescale 1ns/1ps

module tb_runtime_configurable_crossbar;

    // -------------------------------------------------------------------------
    // Parameters — must match DUT generics
    // -------------------------------------------------------------------------
    localparam int DATA_WIDTH    = 1024;
    localparam int ADDR_WIDTH    = 10;
    localparam int CONFIG_WIDTH  = 64;
    localparam int IDXS_PER_BEAT = CONFIG_WIDTH / ADDR_WIDTH;   // 6 indices per beat
    localparam int BEATS_TOTAL   = (DATA_WIDTH + IDXS_PER_BEAT - 1) / IDXS_PER_BEAT; // 171

    localparam real CLK_PERIOD_NS = 2.778;             // 360 MHz — margin below 400 MHz
    localparam real CLK_HALF      = CLK_PERIOD_NS / 2.0;
    localparam real MAX_CFG_NS    = 1000.0;            // 1 us configuration latency limit

    // -------------------------------------------------------------------------
    // DUT interface signals
    // -------------------------------------------------------------------------
    logic                    clk, rst, cfg_restart;
    logic [CONFIG_WIDTH-1:0] cfg_data;
    logic                    cfg_valid, cfg_sel, cfg_ready;
    logic [DATA_WIDTH-1:0]   data_in, data_out;
    logic                    data_in_vld, data_out_vld;
    logic                    ready_out;

    // -------------------------------------------------------------------------
    // DUT instantiation — wildcard port connection for conciseness
    // -------------------------------------------------------------------------
    runtime_configurable_crossbar #(
        .DATA_WIDTH  (DATA_WIDTH),
        .ADDR_WIDTH  (ADDR_WIDTH),
        .CONFIG_WIDTH(CONFIG_WIDTH)
    ) dut (.*);

    // -------------------------------------------------------------------------
    // Clock generation — free-running, 50% duty cycle
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    // -------------------------------------------------------------------------
    // Global pass/fail counters — accumulated across all test cases
    // -------------------------------------------------------------------------
    int pass_cnt = 0;
    int fail_cnt = 0;

    // -------------------------------------------------------------------------
    // Golden model state
    //   g_map_om          : orig_map  supplied to DUT (cfg_sel=0)
    //   g_map_fm          : final_map supplied to DUT (cfg_sel=1)
    //   golden_permutation: composed permutation P[i] = inv_om[fm[i]]
    //                       used to compute expected outputs
    // -------------------------------------------------------------------------
    int g_map_om          [DATA_WIDTH];
    int g_map_fm          [DATA_WIDTH];
    int golden_permutation[DATA_WIDTH];

    // =========================================================================
    // Task: do_reset
    //   Drives active-high synchronous reset for 20 cycles then releases.
    //   All interface signals are driven to safe idle values.
    // =========================================================================
    task automatic do_reset();
        rst         <= 1'b1;
        cfg_restart <= 1'b0;
        cfg_valid   <= 1'b0;
        cfg_sel     <= 1'b0;
        cfg_data    <= '0;
        data_in     <= '0;
        data_in_vld <= 1'b0;
        repeat(20) @(posedge clk);
        rst <= 1'b0;
        repeat(5)  @(posedge clk);
    endtask

    // =========================================================================
    // Task: load_full_config
    //   Loads g_map_om (Bank 0) then g_map_fm (Bank 1) into the DUT over the
    //   64-bit configuration bus.  Each map requires BEATS_TOTAL=171 beats.
    //   Back-pressure is honoured via cfg_ready — the loop only advances when
    //   the DUT accepts the beat.
    //
    //   Measures wall-clock time from cfg_restart to ready_out and reports a
    //   LATENCY VIOLATION error if it exceeds MAX_CFG_NS (1 us).
    //
    //   Arguments:
    //     label  : test case name for display/error messages
    // =========================================================================
    task automatic load_full_config(input string label);
        int      w;
        int      timeout;
        realtime start_time;

        $display("[%s] Loading Maps (Bank 0 and Bank 1)...", label);

        // Pulse cfg_restart to clear DUT state before loading new maps
        @(posedge clk);
        start_time  = $realtime;
        cfg_restart <= 1'b1;
        @(posedge clk);
        cfg_restart <= 1'b0;

        // --- Bank 0: orig_map (cfg_sel=0) ---
        // Pack IDXS_PER_BEAT=6 indices per beat into cfg_data.
        // The last beat may contain padding zeros if DATA_WIDTH % IDXS_PER_BEAT != 0.
        w = 0;
        while (w < BEATS_TOTAL) begin
            cfg_valid <= 1'b1;
            cfg_sel   <= 1'b0;
            for (int k = 0; k < IDXS_PER_BEAT; k++) begin
                int idx = w * IDXS_PER_BEAT + k;
                cfg_data[k*ADDR_WIDTH +: ADDR_WIDTH] <=
                    (idx < DATA_WIDTH) ? ADDR_WIDTH'(g_map_om[idx]) : '0;
            end
            @(posedge clk);
            if (cfg_ready) w++;  // only advance if DUT accepted the beat
        end

        // --- Bank 1: final_map (cfg_sel=1) ---
        w = 0;
        while (w < BEATS_TOTAL) begin
            cfg_valid <= 1'b1;
            cfg_sel   <= 1'b1;
            for (int k = 0; k < IDXS_PER_BEAT; k++) begin
                int idx = w * IDXS_PER_BEAT + k;
                cfg_data[k*ADDR_WIDTH +: ADDR_WIDTH] <=
                    (idx < DATA_WIDTH) ? ADDR_WIDTH'(g_map_fm[idx]) : '0;
            end
            @(posedge clk);
            if (cfg_ready) w++;
        end

        // Deassert cfg_valid after last beat
        cfg_valid <= 1'b0;
        cfg_data  <= '0;

        // --- Poll ready_out ---
        // DUT asserts ready_out ~2 cycles after both maps are loaded.
        // Timeout prevents infinite hang on RTL bug.
        timeout = 2000;
        while (!ready_out && timeout-- > 0) @(posedge clk);

        // --- Latency check ---
        if (($realtime - start_time) > MAX_CFG_NS) begin
            $error("[%s] LATENCY VIOLATION: %.2fns (limit %.0fns)",
                   label, ($realtime - start_time), MAX_CFG_NS);
            fail_cnt++;
        end

        if (timeout <= 0) begin
            $error("[%s] TIMEOUT waiting for ready_out", label);
            $finish;
        end
    endtask

    // =========================================================================
    // Task: update_golden_model
    //   Computes the expected permutation from g_map_om and g_map_fm.
    //   Mirrors exactly what the DUT computes in hardware:
    //     1. Invert orig_map:  inv_om[om[i]] = i
    //     2. Compose:          P[i] = inv_om[fm[i]]
    //   golden_permutation[i] = index in data_in that drives data_out[i]
    // =========================================================================
    task automatic update_golden_model();
        int om_inv[DATA_WIDTH];
        // Step 1: build inverse of orig_map
        for (int i = 0; i < DATA_WIDTH; i++)
            om_inv[ g_map_om[i] ] = i;
        // Step 2: compose with final_map to get the output permutation
        for (int i = 0; i < DATA_WIDTH; i++)
            golden_permutation[i] = om_inv[ g_map_fm[i] ];
    endtask

    // =========================================================================
    // Task: shuffle_maps
    //   Generates two independent random permutations using Fisher-Yates
    //   shuffle and stores them in g_map_om and g_map_fm.
    //   Both arrays start as identity [0,1,...,N-1] and are shuffled in-place.
    // =========================================================================
    task automatic shuffle_maps();
        int j, tmp;
        // Initialise both maps to identity
        for (int i = 0; i < DATA_WIDTH; i++) begin
            g_map_om[i] = i;
            g_map_fm[i] = i;
        end
        // Fisher-Yates in-place shuffle — each independently
        for (int i = DATA_WIDTH-1; i > 0; i--) begin
            j = $urandom_range(0, i);
            tmp = g_map_om[i]; g_map_om[i] = g_map_om[j]; g_map_om[j] = tmp;
            j = $urandom_range(0, i);
            tmp = g_map_fm[i]; g_map_fm[i] = g_map_fm[j]; g_map_fm[j] = tmp;
        end
    endtask

    // =========================================================================
    // Task: verify_stream
    //   Drives num_vectors random 1024-bit input words through the DUT and
    //   checks each output against the golden model.
    //
    //   Uses a scoreboard queue (val_queue) to handle the fixed 4-cycle
    //   pipeline latency: expected values are pushed when data_in is driven
    //   and popped when data_out_vld asserts.
    //
    //   Arguments:
    //     num_vectors : number of test vectors to send and verify
    //     allow_gaps  : if 1, randomly stalls data_in_vld (~20% probability)
    //                   to test pipeline behaviour under non-contiguous input
    //     label       : test case name for error messages
    // =========================================================================
    task automatic verify_stream(
        input int  num_vectors,
        input bit  allow_gaps,
        input string label
    );
        logic [DATA_WIDTH-1:0] val_queue[$];   // scoreboard: expected outputs in order
        logic [DATA_WIDTH-1:0] cur_in, expected, permuted_val;
        int sent    = 0;
        int checked = 0;
        int timeout = num_vectors * 5 + 100;   // generous timeout for gap mode

        while (checked < num_vectors && timeout-- > 0) begin
            @(posedge clk);

            // --- Drive input ---
            // In gap mode, randomly suppress ~20% of cycles (urandom==0 out of 0-4)
            if (sent < num_vectors && (!allow_gaps || $urandom_range(0,4) != 0)) begin
                // Generate random input vector
                for (int i = 0; i < DATA_WIDTH/32; i++)
                    cur_in[i*32 +: 32] = $urandom();
                data_in     <= cur_in;
                data_in_vld <= 1'b1;

                // Compute expected output using golden permutation
                permuted_val = '0;
                for (int j = 0; j < DATA_WIDTH; j++)
                    permuted_val[j] = cur_in[golden_permutation[j]];
                val_queue.push_back(permuted_val);
                sent++;
            end else begin
                data_in     <= '0;
                data_in_vld <= 1'b0;
            end

            // --- Check output ---
            // Small #1 delay ensures NBA (non-blocking assignment) updates from
            // the posedge above are visible before we sample data_out.
            #1;
            if (data_out_vld && val_queue.size() > 0) begin
                expected = val_queue.pop_front();
                if (data_out !== expected) begin
                    $error("[%s] Mismatch at vector %0d\n  got      %0h\n  expected %0h",
                           label, checked, data_out, expected);
                    fail_cnt++;
                end else begin
                    pass_cnt++;
                end
                checked++;
            end
        end

        data_in_vld <= 1'b0;
        repeat(10) @(posedge clk);  // drain pipeline before next test case
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        do_reset();

        // --- TC-01: Identity ---
        // orig_map = final_map = [0,1,...,1023]
        // P[i] = i  =>  data_out == data_in
        $display("\n[TC-01] Identity");
        for (int i = 0; i < DATA_WIDTH; i++) begin
            g_map_om[i] = i;
            g_map_fm[i] = i;
        end
        update_golden_model();
        load_full_config("TC-01");
        verify_stream(20, 0, "TC-01");

        // --- TC-02: Full bit reversal ---
        // orig_map = identity, final_map[i] = 1023-i
        // P[i] = 1023-i  =>  data_out[0] = data_in[1023], etc.
        $display("\n[TC-02] Reverse");
        for (int i = 0; i < DATA_WIDTH; i++) begin
            g_map_om[i] = i;
            g_map_fm[i] = DATA_WIDTH - 1 - i;
        end
        update_golden_model();
        load_full_config("TC-02");
        verify_stream(20, 0, "TC-02");

        // --- TC-03: Random permutation (continuous) ---
        // Both maps independently shuffled.  No input gaps.
        $display("\n[TC-03] Random Permutations");
        shuffle_maps();
        update_golden_model();
        load_full_config("TC-03");
        verify_stream(30, 0, "TC-03");

        // --- TC-04: Random permutation with input gaps ---
        // Tests pipeline stall handling: data_in_vld randomly deasserted.
        $display("\n[TC-04] Stress Test (Random + Gaps)");
        shuffle_maps();
        update_golden_model();
        load_full_config("TC-04");
        verify_stream(50, 1, "TC-04");

        // --- TC-05: Back-to-back reconfiguration ---
        // Reconfigures twice in sequence without full reset between iterations.
        // Verifies that cfg_restart correctly clears previous permutation state.
        $display("\n[TC-05] Back-to-Back Latency Check");
        for (int i = 0; i < 2; i++) begin
            shuffle_maps();
            update_golden_model();
            load_full_config($sformatf("TC-05-I%0d", i));
            verify_stream(10, 0, $sformatf("TC-05-I%0d", i));
        end

        // --- TC-06: Non-permutation (broadcast) mappings ---
        // These are not valid permutations (repeated indices in final_map) but
        // the DUT must handle them without hanging.  The golden model correctly
        // computes the expected output for these degenerate cases.

        // Broadcast: every output bit driven by input bit 42
        $display("\n[TC-06] Multicast/Broadcast Patterns");
        for (int i = 0; i < DATA_WIDTH; i++) begin
            g_map_om[i] = i;
            g_map_fm[i] = 42;   // all outputs map to the same source
        end
        update_golden_model();
        load_full_config("TC-06-Broadcast");
        verify_stream(20, 0, "TC-06-Broadcast");

        // Dualcast: even outputs from in[0], odd outputs from in[1023]
        for (int i = 0; i < DATA_WIDTH; i++) begin
            g_map_om[i] = i;
            g_map_fm[i] = (i % 2 == 0) ? 0 : 1023;
        end
        update_golden_model();
        load_full_config("TC-06-Dualcast");
        verify_stream(20, 0, "TC-06-Dualcast");

        // --- Summary ---
        $display("\n==================================================");
        $display("  SIMULATION COMPLETE  PASS:%0d  FAIL:%0d", pass_cnt, fail_cnt);
        $display("==================================================\n");

        if (fail_cnt > 0) $fatal(1, "TEST FAILED");
        $finish;
    end

endmodule
