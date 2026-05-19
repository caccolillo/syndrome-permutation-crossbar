// =============================================================================
// crossbar_axis_wrapper.sv
//
// AXI4-Stream wrapper for runtime_configurable_crossbar
//
// RX stream (slave - receives from Aurora / upstream):
//   Single continuous packet, 358 beats total, tvalid held throughout:
//     Beats [0   .. 170]  : original mapping  (cfg_sel=0)
//     Beats [171 .. 341]  : final   mapping   (cfg_sel=1)
//     Beats [342 .. 357]  : 1024-bit input bitstring
//
//   Phase transitions are driven by beat count alone.
//   tlast is only checked on the very last beat (357): if it is absent
//   rx_framing_err is set.  tlast on any earlier beat is ignored -
//   it does NOT trigger an error or a state change.
//
// TX stream (master - sends to Aurora / downstream):
//   16 beats of 64-bit data, tlast on beat 15.
//
// -----------------------------------------------------------------------------
// I/O register pipelines
// -----------------------------------------------------------------------------
// Parameters RX_PIPE_STAGES and TX_PIPE_STAGES insert N stages of fully
// handshake-correct AXIS skid buffers between the module ports and the core
// state machines. Each stage is a 2-deep skid buffer (primary + skid register)
// so no data is lost when downstream stalls. All registers in the pipeline
// carry KEEP / DONT_TOUCH / SHREG_EXTRACT=NO attributes to prevent the
// synthesizer from absorbing them into the surrounding logic or collapsing
// them into SRLs - this preserves the timing closure margin they buy.
//
// Set RX_PIPE_STAGES / TX_PIPE_STAGES to 0 to bypass (original behaviour).
// Typical value: 1-2 stages per side. Increase if STA still struggles.
// =============================================================================

module crossbar_axis_wrapper #(
    parameter int DATA_WIDTH      = 1024,
    parameter int ADDR_WIDTH      = 10,
    parameter int CONFIG_WIDTH    = 64,
    parameter int RX_PIPE_STAGES  = 2,   // # of AXIS skid stages on RX input
    parameter int TX_PIPE_STAGES  = 2    // # of AXIS skid stages on TX output
)(
    input  logic clk,
    input  logic rst,

    // ---- RX AXI4-Stream (slave) --------------------------------------------
    input  logic [63:0] s_axis_rx_tdata,
    input  logic [7:0]  s_axis_rx_tkeep,
    input  logic        s_axis_rx_tvalid,
    input  logic        s_axis_rx_tlast,
    output logic        s_axis_rx_tready,

    // ---- Error flag --------------------------------------------------------
    output logic        rx_framing_err,   // tlast absent on final DATA beat

    // ---- TX AXI4-Stream (master) -------------------------------------------
    output logic [63:0] m_axis_tx_tdata,
    output logic [7:0]  m_axis_tx_tkeep,
    output logic        m_axis_tx_tvalid,
    output logic        m_axis_tx_tlast,
    input  logic        m_axis_tx_tready
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam int IDXS_PER_BEAT  = CONFIG_WIDTH / ADDR_WIDTH;   // 6
    localparam int BEATS_CFG      = (DATA_WIDTH + IDXS_PER_BEAT - 1)
                                     / IDXS_PER_BEAT;            // 171
    localparam int BEATS_DATA     = DATA_WIDTH / CONFIG_WIDTH;   // 16
    localparam int BEATS_RX_TOTAL = 2 * BEATS_CFG + BEATS_DATA; // 358

    localparam int RX_CTR_W = $clog2(BEATS_RX_TOTAL + 1);
    localparam int TX_CTR_W = $clog2(BEATS_DATA);

    // =========================================================================
    // ===== RX INPUT PIPELINE (skid buffers) ==================================
    //
    // s_axis_rx_*  ->  [stage 0] -> [stage 1] -> ... -> rx_pipe_*_int
    //
    // Each stage is a 2-deep skid buffer. The downstream-facing tready/tvalid
    // pair is the *next* stage's upstream-facing pair, so handshakes chain
    // cleanly without dead cycles when both sides are continuously ready.
    // =========================================================================

    // Per-stage wires. Index 0 is the upstream (module port) side;
    // index RX_PIPE_STAGES is the downstream (internal) side.
    logic [63:0] rx_pipe_tdata  [0:RX_PIPE_STAGES];
    logic [7:0]  rx_pipe_tkeep  [0:RX_PIPE_STAGES];
    logic        rx_pipe_tvalid [0:RX_PIPE_STAGES];
    logic        rx_pipe_tlast  [0:RX_PIPE_STAGES];
    logic        rx_pipe_tready [0:RX_PIPE_STAGES];

    // Connect upstream module ports to the head of the pipeline.
    assign rx_pipe_tdata [0] = s_axis_rx_tdata;
    assign rx_pipe_tkeep [0] = s_axis_rx_tkeep;
    assign rx_pipe_tvalid[0] = s_axis_rx_tvalid;
    assign rx_pipe_tlast [0] = s_axis_rx_tlast;
    assign s_axis_rx_tready  = rx_pipe_tready[0];

    // Internal-side wires consumed by the RX state machine.
    logic [63:0] rx_int_tdata;
    logic [7:0]  rx_int_tkeep;
    logic        rx_int_tvalid;
    logic        rx_int_tlast;
    logic        rx_int_tready;

    assign rx_int_tdata           = rx_pipe_tdata [RX_PIPE_STAGES];
    assign rx_int_tkeep           = rx_pipe_tkeep [RX_PIPE_STAGES];
    assign rx_int_tvalid          = rx_pipe_tvalid[RX_PIPE_STAGES];
    assign rx_int_tlast           = rx_pipe_tlast [RX_PIPE_STAGES];
    assign rx_pipe_tready[RX_PIPE_STAGES] = rx_int_tready;

    // Instantiate the chain of skid buffers.
    genvar gi;
    generate
        for (gi = 0; gi < RX_PIPE_STAGES; gi++) begin : g_rx_pipe
            axis_skid_buffer #(.DATA_W(64), .KEEP_W(8)) u_skid (
                .clk      (clk),
                .rst      (rst),
                .s_tdata  (rx_pipe_tdata [gi]),
                .s_tkeep  (rx_pipe_tkeep [gi]),
                .s_tvalid (rx_pipe_tvalid[gi]),
                .s_tlast  (rx_pipe_tlast [gi]),
                .s_tready (rx_pipe_tready[gi]),
                .m_tdata  (rx_pipe_tdata [gi+1]),
                .m_tkeep  (rx_pipe_tkeep [gi+1]),
                .m_tvalid (rx_pipe_tvalid[gi+1]),
                .m_tlast  (rx_pipe_tlast [gi+1]),
                .m_tready (rx_pipe_tready[gi+1])
            );
        end
    endgenerate

    // =========================================================================
    // Crossbar wires
    // =========================================================================
    logic                    cfg_restart;
    logic [CONFIG_WIDTH-1:0] cfg_data;
    logic [CONFIG_WIDTH-1:0] cfg_data_reg;
    logic                    cfg_valid;
    logic                    cfg_sel;
    logic                    cfg_ready;
    logic                    ready_out;
    logic [DATA_WIDTH-1:0]   data_in;
    logic                    data_in_vld;
    logic [DATA_WIDTH-1:0]   data_out;
    logic                    data_out_vld;

    runtime_configurable_crossbar_0 #(
    .DATA_WIDTH   (DATA_WIDTH),
    .ADDR_WIDTH   (ADDR_WIDTH),
    .CONFIG_WIDTH (CONFIG_WIDTH)
    )   u_xbar (
        .clk         (clk),
        .rst         (rst),
        .cfg_restart (cfg_restart),
        .cfg_data    (cfg_data),
        .cfg_valid   (cfg_valid),
        .cfg_sel     (cfg_sel),
        .cfg_ready   (cfg_ready),
        .ready_out   (ready_out),
        .data_in     (data_in),
        .data_in_vld (data_in_vld),
        .data_out    (data_out),
        .data_out_vld(data_out_vld)
    );

    assign cfg_restart = rst;
    // cfg_data must be registered to stay aligned with the registered cfg_valid.
    // Both update on the same posedge: cfg_data_reg captures tdata at the same
    // time cfg_valid is set, so the crossbar sees a consistent pair.
    always_ff @(posedge clk)
        if (rx_int_tvalid && cfg_ready)
            cfg_data_reg <= rx_int_tdata;
    assign cfg_data = cfg_data_reg;

    // =========================================================================
    // RX state machine  (consumes the *internal* side of the RX pipeline)
    //
    //   RX_CFG_A : accept BEATS_CFG beats → cfg_sel=0
    //   RX_CFG_B : accept BEATS_CFG beats → cfg_sel=1
    //   RX_WAIT  : deassert tready; wait for crossbar ready_out
    //   RX_DATA  : accept BEATS_DATA beats → assemble data_in
    //   RX_IDLE  : done (one-shot)
    //   RX_ERROR : tlast absent on final beat; sticky until reset
    // =========================================================================
    typedef enum logic [2:0] {
        RX_CFG_A = 3'd0,
        RX_CFG_B = 3'd1,
        RX_WAIT  = 3'd2,
        RX_DATA  = 3'd3,
        RX_IDLE  = 3'd4,
        RX_ERROR = 3'd5
    } rx_state_t;

    rx_state_t             rx_state;
    logic [RX_CTR_W-1:0]   rx_beat;
    logic [DATA_WIDTH-1:0] data_in_shreg;

    // tready high only while actively consuming beats
    assign rx_int_tready = (rx_state == RX_CFG_A) ||
                           (rx_state == RX_CFG_B) ||
                           (rx_state == RX_DATA);

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_state       <= RX_CFG_A;
            rx_beat        <= '0;
            cfg_valid      <= 1'b0;
            cfg_sel        <= 1'b0;
            data_in        <= '0;
            data_in_vld    <= 1'b0;
            data_in_shreg  <= '0;
            rx_framing_err <= 1'b0;
        end else begin
            cfg_valid   <= 1'b0;
            data_in_vld <= 1'b0;

            case (rx_state)

                RX_CFG_A: begin
                    cfg_sel <= 1'b0;
                    if (rx_int_tvalid && cfg_ready) begin
                        cfg_valid <= 1'b1;
                        if (rx_beat == RX_CTR_W'(BEATS_CFG - 1)) begin
                            rx_beat  <= '0;
                            rx_state <= RX_CFG_B;
                        end else begin
                            rx_beat <= rx_beat + 1'b1;
                        end
                    end
                end

                RX_CFG_B: begin
                    cfg_sel <= 1'b1;
                    if (rx_int_tvalid && cfg_ready) begin
                        cfg_valid <= 1'b1;
                        if (rx_beat == RX_CTR_W'(BEATS_CFG - 1)) begin
                            rx_beat  <= '0;
                            rx_state <= RX_WAIT;
                        end else begin
                            rx_beat <= rx_beat + 1'b1;
                        end
                    end
                end

                RX_WAIT: begin
                    if (ready_out) begin
                        rx_beat  <= '0;
                        rx_state <= RX_DATA;
                    end
                end

                RX_DATA: begin
                    if (rx_int_tvalid && rx_int_tready) begin
                        data_in_shreg <= {rx_int_tdata,
                                          data_in_shreg[DATA_WIDTH-1:CONFIG_WIDTH]};

                        if (rx_beat == RX_CTR_W'(BEATS_DATA - 1)) begin
                            if (!rx_int_tlast) begin
                                rx_framing_err <= 1'b1;
                                rx_state       <= RX_ERROR;
                            end else begin
                                data_in     <= {rx_int_tdata,
                                                data_in_shreg[DATA_WIDTH-1:CONFIG_WIDTH]};
                                data_in_vld <= 1'b1;
                                rx_beat     <= '0;
                                rx_state    <= RX_IDLE;
                            end
                        end else begin
                            rx_beat <= rx_beat + 1'b1;
                        end
                    end
                end

                RX_IDLE: begin
                    // One-shot. For continuous streaming: rx_state <= RX_CFG_A;
                end

                RX_ERROR: begin
                    rx_framing_err <= 1'b1;  // sticky until reset
                end

                default: rx_state <= RX_ERROR;
            endcase
        end
    end

    // =========================================================================
    // TX state machine - produces an *internal* AXIS stream which is then
    // pushed through a chain of TX_PIPE_STAGES skid buffers before reaching
    // the module's m_axis_tx_* ports.
    // =========================================================================
    logic [63:0] tx_int_tdata;
    logic [7:0]  tx_int_tkeep;
    logic        tx_int_tvalid;
    logic        tx_int_tlast;
    logic        tx_int_tready;

    typedef enum logic {
        TX_IDLE = 1'b0,
        TX_SEND = 1'b1
    } tx_state_t;

    tx_state_t             tx_state;
    logic [TX_CTR_W-1:0]   tx_beat;
    logic [DATA_WIDTH-1:0] tx_shreg;

    always_ff @(posedge clk) begin
        if (rst) begin
            tx_state      <= TX_IDLE;
            tx_beat       <= '0;
            tx_shreg      <= '0;
            tx_int_tdata  <= '0;
            tx_int_tkeep  <= 8'hFF;
            tx_int_tvalid <= 1'b0;
            tx_int_tlast  <= 1'b0;
        end else begin
            case (tx_state)

                TX_IDLE: begin
                    tx_int_tvalid <= 1'b0;
                    tx_int_tlast  <= 1'b0;
                    if (data_out_vld) begin
                        tx_shreg      <= data_out;
                        tx_beat       <= '0;
                        tx_state      <= TX_SEND;
                        tx_int_tdata  <= data_out[CONFIG_WIDTH-1:0];
                        tx_int_tkeep  <= 8'hFF;
                        tx_int_tvalid <= 1'b1;
                        tx_int_tlast  <= (BEATS_DATA == 1) ? 1'b1 : 1'b0;
                    end
                end

                TX_SEND: begin
                    if (tx_int_tready) begin
                        if (tx_beat == TX_CTR_W'(BEATS_DATA - 1)) begin
                            tx_int_tvalid <= 1'b0;
                            tx_int_tlast  <= 1'b0;
                            tx_state      <= TX_IDLE;
                        end else begin
                            tx_beat      <= tx_beat + 1'b1;
                            tx_int_tdata <= tx_shreg[(tx_beat+1)*CONFIG_WIDTH
                                                     +: CONFIG_WIDTH];
                            tx_int_tkeep <= 8'hFF;
                            tx_int_tlast <= (tx_beat == TX_CTR_W'(BEATS_DATA - 2))
                                            ? 1'b1 : 1'b0;
                        end
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    // =========================================================================
    // ===== TX OUTPUT PIPELINE (skid buffers) =================================
    //
    // tx_int_*  ->  [stage 0] -> [stage 1] -> ... -> m_axis_tx_*
    // =========================================================================
    logic [63:0] tx_pipe_tdata  [0:TX_PIPE_STAGES];
    logic [7:0]  tx_pipe_tkeep  [0:TX_PIPE_STAGES];
    logic        tx_pipe_tvalid [0:TX_PIPE_STAGES];
    logic        tx_pipe_tlast  [0:TX_PIPE_STAGES];
    logic        tx_pipe_tready [0:TX_PIPE_STAGES];

    // Head of TX pipeline = output of the TX state machine
    assign tx_pipe_tdata [0] = tx_int_tdata;
    assign tx_pipe_tkeep [0] = tx_int_tkeep;
    assign tx_pipe_tvalid[0] = tx_int_tvalid;
    assign tx_pipe_tlast [0] = tx_int_tlast;
    assign tx_int_tready     = tx_pipe_tready[0];

    // Tail of TX pipeline = module's master AXIS port
    assign m_axis_tx_tdata  = tx_pipe_tdata [TX_PIPE_STAGES];
    assign m_axis_tx_tkeep  = tx_pipe_tkeep [TX_PIPE_STAGES];
    assign m_axis_tx_tvalid = tx_pipe_tvalid[TX_PIPE_STAGES];
    assign m_axis_tx_tlast  = tx_pipe_tlast [TX_PIPE_STAGES];
    assign tx_pipe_tready[TX_PIPE_STAGES] = m_axis_tx_tready;

    generate
        for (gi = 0; gi < TX_PIPE_STAGES; gi++) begin : g_tx_pipe
            axis_skid_buffer #(.DATA_W(64), .KEEP_W(8)) u_skid (
                .clk      (clk),
                .rst      (rst),
                .s_tdata  (tx_pipe_tdata [gi]),
                .s_tkeep  (tx_pipe_tkeep [gi]),
                .s_tvalid (tx_pipe_tvalid[gi]),
                .s_tlast  (tx_pipe_tlast [gi]),
                .s_tready (tx_pipe_tready[gi]),
                .m_tdata  (tx_pipe_tdata [gi+1]),
                .m_tkeep  (tx_pipe_tkeep [gi+1]),
                .m_tvalid (tx_pipe_tvalid[gi+1]),
                .m_tlast  (tx_pipe_tlast [gi+1]),
                .m_tready (tx_pipe_tready[gi+1])
            );
        end
    endgenerate

endmodule


// =============================================================================
// axis_skid_buffer
//
// Standard 2-deep AXI4-Stream skid buffer (a.k.a. "registered slice").
//   - Fully registers tdata/tkeep/tlast/tvalid in both directions.
//   - Adds 1 cycle of latency.
//   - Does NOT drop data when downstream stalls: a secondary 'skid' register
//     captures the bubble beat so the upstream interface can still accept
//     one more beat before deasserting tready.
//   - All storage flops carry KEEP / DONT_TOUCH / SHREG_EXTRACT=NO so the
//     synthesizer cannot absorb them into surrounding logic or collapse
//     the pair into an SRL.
// =============================================================================
module axis_skid_buffer #(
    parameter int DATA_W = 64,
    parameter int KEEP_W = DATA_W / 8
)(
    input  logic              clk,
    input  logic              rst,

    // Slave (upstream) port
    input  logic [DATA_W-1:0] s_tdata,
    input  logic [KEEP_W-1:0] s_tkeep,
    input  logic              s_tvalid,
    input  logic              s_tlast,
    output logic              s_tready,

    // Master (downstream) port
    output logic [DATA_W-1:0] m_tdata,
    output logic [KEEP_W-1:0] m_tkeep,
    output logic              m_tvalid,
    output logic              m_tlast,
    input  logic              m_tready
);

    // -------------------------------------------------------------------------
    // Primary storage: drives the master interface directly.
    // -------------------------------------------------------------------------
    (* keep = "true", dont_touch = "true", shreg_extract = "no" *)
    logic [DATA_W-1:0] m_tdata_r;
    (* keep = "true", dont_touch = "true", shreg_extract = "no" *)
    logic [KEEP_W-1:0] m_tkeep_r;
    (* keep = "true", dont_touch = "true", shreg_extract = "no" *)
    logic              m_tvalid_r;
    (* keep = "true", dont_touch = "true", shreg_extract = "no" *)
    logic              m_tlast_r;

    // -------------------------------------------------------------------------
    // Skid (secondary) storage: holds a bubble beat when the downstream
    // stalls after we've already told upstream we're ready.
    // -------------------------------------------------------------------------
    (* keep = "true", dont_touch = "true", shreg_extract = "no" *)
    logic [DATA_W-1:0] skid_tdata_r;
    (* keep = "true", dont_touch = "true", shreg_extract = "no" *)
    logic [KEEP_W-1:0] skid_tkeep_r;
    (* keep = "true", dont_touch = "true", shreg_extract = "no" *)
    logic              skid_tvalid_r;
    (* keep = "true", dont_touch = "true", shreg_extract = "no" *)
    logic              skid_tlast_r;

    // -------------------------------------------------------------------------
    // Ready toward upstream: we can accept when the skid is empty.
    // Pre-register the tready as well so the upstream sees a registered output.
    // -------------------------------------------------------------------------
    (* keep = "true", dont_touch = "true", shreg_extract = "no" *)
    logic s_tready_r;

    assign s_tready = s_tready_r;
    assign m_tdata  = m_tdata_r;
    assign m_tkeep  = m_tkeep_r;
    assign m_tvalid = m_tvalid_r;
    assign m_tlast  = m_tlast_r;

    // -------------------------------------------------------------------------
    // Skid-buffer control. Standard pattern - see e.g. Xilinx PG059 axis_register_slice.
    //
    //   - When downstream accepts (m_tvalid_r & m_tready), the primary slot
    //     empties: refill it either from the skid (if non-empty) or from the
    //     upstream beat (if valid).
    //   - When downstream stalls but we've already accepted an upstream beat
    //     into the primary, the next upstream beat goes into the skid and we
    //     deassert s_tready_r.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            m_tdata_r     <= '0;
            m_tkeep_r     <= '0;
            m_tvalid_r    <= 1'b0;
            m_tlast_r     <= 1'b0;
            skid_tdata_r  <= '0;
            skid_tkeep_r  <= '0;
            skid_tvalid_r <= 1'b0;
            skid_tlast_r  <= 1'b0;
            s_tready_r    <= 1'b1;
        end else begin
            if (m_tready || !m_tvalid_r) begin
                // Primary slot is being drained (or is empty) - reload it.
                if (skid_tvalid_r) begin
                    // Drain skid into primary.
                    m_tdata_r     <= skid_tdata_r;
                    m_tkeep_r     <= skid_tkeep_r;
                    m_tvalid_r    <= 1'b1;
                    m_tlast_r     <= skid_tlast_r;
                    skid_tvalid_r <= 1'b0;
                    s_tready_r    <= 1'b1;
                end else begin
                    // No skid pending - take directly from upstream.
                    m_tdata_r  <= s_tdata;
                    m_tkeep_r  <= s_tkeep;
                    m_tvalid_r <= s_tvalid;
                    m_tlast_r  <= s_tlast;
                    s_tready_r <= 1'b1;
                end
            end else if (s_tvalid && s_tready_r) begin
                // Primary is held (downstream stalled) but we'd already
                // promised upstream we'd take one more beat - capture it
                // into the skid and tell upstream to back off.
                skid_tdata_r  <= s_tdata;
                skid_tkeep_r  <= s_tkeep;
                skid_tvalid_r <= 1'b1;
                skid_tlast_r  <= s_tlast;
                s_tready_r    <= 1'b0;
            end
        end
    end

endmodule
