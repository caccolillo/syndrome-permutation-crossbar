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
// =============================================================================

module crossbar_axis_wrapper #(
    parameter int DATA_WIDTH   = 1024,
    parameter int ADDR_WIDTH   = 10,
    parameter int CONFIG_WIDTH = 64
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

    runtime_configurable_crossbar_0  u_xbar (
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
        if (s_axis_rx_tvalid && cfg_ready)
            cfg_data_reg <= s_axis_rx_tdata;
    assign cfg_data = cfg_data_reg;

    // =========================================================================
    // RX state machine
    //
    //   RX_CFG_A : accept BEATS_CFG beats → cfg_sel=0
    //   RX_CFG_B : accept BEATS_CFG beats → cfg_sel=1
    //   RX_WAIT  : deassert tready; wait for crossbar ready_out
    //   RX_DATA  : accept BEATS_DATA beats → assemble data_in
    //   RX_IDLE  : done (one-shot)
    //   RX_ERROR : tlast absent on final beat; sticky until reset
    //
    // Transitions are purely beat-count driven.
    // tlast is only inspected on the last DATA beat as a sanity check.
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
    assign s_axis_rx_tready = (rx_state == RX_CFG_A) ||
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

                // -------------------------------------------------------------
                // Phase 1: original mapping  cfg_sel=0
                // Transition on beat count - tlast ignored here.
                // -------------------------------------------------------------
                RX_CFG_A: begin
                    cfg_sel <= 1'b0;
                    if (s_axis_rx_tvalid && cfg_ready) begin
                        cfg_valid <= 1'b1;
                        if (rx_beat == RX_CTR_W'(BEATS_CFG - 1)) begin
                            rx_beat  <= '0;
                            rx_state <= RX_CFG_B;
                        end else begin
                            rx_beat <= rx_beat + 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Phase 2: final mapping  cfg_sel=1
                // Transition on beat count - tlast ignored here.
                // -------------------------------------------------------------
                RX_CFG_B: begin
                    cfg_sel <= 1'b1;
                    if (s_axis_rx_tvalid && cfg_ready) begin
                        cfg_valid <= 1'b1;
                        if (rx_beat == RX_CTR_W'(BEATS_CFG - 1)) begin
                            rx_beat  <= '0;
                            rx_state <= RX_WAIT;
                        end else begin
                            rx_beat <= rx_beat + 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Wait for crossbar to resolve src_for_out (~2 cycles)
                // tready deasserted here so upstream beats are held.
                // -------------------------------------------------------------
                RX_WAIT: begin
                    if (ready_out) begin
                        rx_beat  <= '0;
                        rx_state <= RX_DATA;
                    end
                end

                // -------------------------------------------------------------
                // Phase 3: input bitstring  (16 × 64-bit beats)
                // Assemble into shift register; fire data_in_vld on last beat.
                // Gate on tvalid AND tready - tvalid is held high through
                // RX_WAIT so we must not shift until tready re-asserts.
                // tlast checked ONLY on the last beat - absent = error.
                // -------------------------------------------------------------
                RX_DATA: begin
                    if (s_axis_rx_tvalid && s_axis_rx_tready) begin
                        data_in_shreg <= {s_axis_rx_tdata,
                                          data_in_shreg[DATA_WIDTH-1:CONFIG_WIDTH]};

                        if (rx_beat == RX_CTR_W'(BEATS_DATA - 1)) begin
                            if (!s_axis_rx_tlast) begin
                                rx_framing_err <= 1'b1;
                                rx_state       <= RX_ERROR;
                            end else begin
                                data_in     <= {s_axis_rx_tdata,
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
    // TX state machine
    // =========================================================================
    typedef enum logic {
        TX_IDLE = 1'b0,
        TX_SEND = 1'b1
    } tx_state_t;

    tx_state_t             tx_state;
    logic [TX_CTR_W-1:0]   tx_beat;
    logic [DATA_WIDTH-1:0] tx_shreg;

    always_ff @(posedge clk) begin
        if (rst) begin
            tx_state         <= TX_IDLE;
            tx_beat          <= '0;
            tx_shreg         <= '0;
            m_axis_tx_tdata  <= '0;
            m_axis_tx_tkeep  <= 8'hFF;
            m_axis_tx_tvalid <= 1'b0;
            m_axis_tx_tlast  <= 1'b0;
        end else begin
            case (tx_state)

                TX_IDLE: begin
                    m_axis_tx_tvalid <= 1'b0;
                    m_axis_tx_tlast  <= 1'b0;
                    if (data_out_vld) begin
                        tx_shreg         <= data_out;
                        tx_beat          <= '0;
                        tx_state         <= TX_SEND;
                        m_axis_tx_tdata  <= data_out[CONFIG_WIDTH-1:0];
                        m_axis_tx_tkeep  <= 8'hFF;
                        m_axis_tx_tvalid <= 1'b1;
                        m_axis_tx_tlast  <= (BEATS_DATA == 1) ? 1'b1 : 1'b0;
                    end
                end

                TX_SEND: begin
                    if (m_axis_tx_tready) begin
                        if (tx_beat == TX_CTR_W'(BEATS_DATA - 1)) begin
                            m_axis_tx_tvalid <= 1'b0;
                            m_axis_tx_tlast  <= 1'b0;
                            tx_state         <= TX_IDLE;
                        end else begin
                            tx_beat         <= tx_beat + 1'b1;
                            m_axis_tx_tdata <= tx_shreg[(tx_beat+1)*CONFIG_WIDTH
                                                        +: CONFIG_WIDTH];
                            m_axis_tx_tkeep <= 8'hFF;
                            m_axis_tx_tlast <= (tx_beat == TX_CTR_W'(BEATS_DATA - 2))
                                               ? 1'b1 : 1'b0;
                        end
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

endmodule
