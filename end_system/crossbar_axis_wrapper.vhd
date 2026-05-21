-- =============================================================================
-- crossbar_axis_wrapper_vhdl.vhd
--
-- VHDL wrapper around the SystemVerilog crossbar_axis_wrapper module.
--
-- Mixed-language synthesis lets VHDL parents instantiate SystemVerilog modules
-- directly, but the parameter / port mapping syntax is awkward and tool
-- support for generic override on SV modules from VHDL is uneven across
-- Vivado versions. Wrapping the SV module in a VHDL entity with matching
-- generics and ports gives the cleanest interface for downstream VHDL code.
--
-- Generic defaults mirror the SV module:
--   DATA_WIDTH      = 256
--   ADDR_WIDTH      = 8
--   CONFIG_WIDTH    = 64
--   RX_PIPE_STAGES  = 2
--   TX_PIPE_STAGES  = 2
--
-- Override at instantiation as needed. Note that the inner SystemVerilog
-- module further instantiates runtime_configurable_crossbar_0 and passes
-- DATA_WIDTH / ADDR_WIDTH / CONFIG_WIDTH through, so overriding those on
-- this VHDL wrapper propagates all the way down (provided the packaged
-- runtime_configurable_crossbar IP exposes them as user-configurable).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity crossbar_axis_wrapper_vhdl is
    generic (
        DATA_WIDTH     : integer := 128;
        ADDR_WIDTH     : integer := 7;
        CONFIG_WIDTH   : integer := 64;
        RX_PIPE_STAGES : integer := 2;
        TX_PIPE_STAGES : integer := 2
    );
    port (
        clk : in  std_logic;
        rst : in  std_logic;

        -- RX AXI4-Stream (slave)
        s_axis_rx_tdata  : in  std_logic_vector(63 downto 0);
        s_axis_rx_tkeep  : in  std_logic_vector(7 downto 0);
        s_axis_rx_tvalid : in  std_logic;
        s_axis_rx_tlast  : in  std_logic;
        s_axis_rx_tready : out std_logic;

        -- Error flag
        rx_framing_err   : out std_logic;

        -- TX AXI4-Stream (master)
        m_axis_tx_tdata  : out std_logic_vector(63 downto 0);
        m_axis_tx_tkeep  : out std_logic_vector(7 downto 0);
        m_axis_tx_tvalid : out std_logic;
        m_axis_tx_tlast  : out std_logic;
        m_axis_tx_tready : in  std_logic
    );
end entity crossbar_axis_wrapper_vhdl;

architecture wrapper of crossbar_axis_wrapper_vhdl is

    -- -------------------------------------------------------------------------
    -- Component declaration matching the SystemVerilog module exactly.
    --
    -- Important: in VHDL, component generic / port types and order must
    -- match the SV module declaration. Vivado's mixed-language elaborator
    -- maps SV `parameter int` to VHDL `integer`, SV `logic` to VHDL
    -- `std_logic`, and SV packed vectors to `std_logic_vector` with the
    -- same range direction. SV always declares packed vectors as
    -- [MSB:LSB], which corresponds to VHDL `(MSB downto LSB)`.
    -- -------------------------------------------------------------------------
    component crossbar_axis_wrapper
        generic (
            DATA_WIDTH     : integer;
            ADDR_WIDTH     : integer;
            CONFIG_WIDTH   : integer;
            RX_PIPE_STAGES : integer;
            TX_PIPE_STAGES : integer
        );
        port (
            clk : in  std_logic;
            rst : in  std_logic;

            s_axis_rx_tdata  : in  std_logic_vector(63 downto 0);
            s_axis_rx_tkeep  : in  std_logic_vector(7 downto 0);
            s_axis_rx_tvalid : in  std_logic;
            s_axis_rx_tlast  : in  std_logic;
            s_axis_rx_tready : out std_logic;

            rx_framing_err   : out std_logic;

            m_axis_tx_tdata  : out std_logic_vector(63 downto 0);
            m_axis_tx_tkeep  : out std_logic_vector(7 downto 0);
            m_axis_tx_tvalid : out std_logic;
            m_axis_tx_tlast  : out std_logic;
            m_axis_tx_tready : in  std_logic
        );
    end component;

begin

    -- -------------------------------------------------------------------------
    -- Direct one-to-one bind. All generics and ports pass through unchanged.
    -- -------------------------------------------------------------------------
    u_sv : crossbar_axis_wrapper
        generic map (
            DATA_WIDTH     => DATA_WIDTH,
            ADDR_WIDTH     => ADDR_WIDTH,
            CONFIG_WIDTH   => CONFIG_WIDTH,
            RX_PIPE_STAGES => RX_PIPE_STAGES,
            TX_PIPE_STAGES => TX_PIPE_STAGES
        )
        port map (
            clk              => clk,
            rst              => rst,

            s_axis_rx_tdata  => s_axis_rx_tdata,
            s_axis_rx_tkeep  => s_axis_rx_tkeep,
            s_axis_rx_tvalid => s_axis_rx_tvalid,
            s_axis_rx_tlast  => s_axis_rx_tlast,
            s_axis_rx_tready => s_axis_rx_tready,

            rx_framing_err   => rx_framing_err,

            m_axis_tx_tdata  => m_axis_tx_tdata,
            m_axis_tx_tkeep  => m_axis_tx_tkeep,
            m_axis_tx_tvalid => m_axis_tx_tvalid,
            m_axis_tx_tlast  => m_axis_tx_tlast,
            m_axis_tx_tready => m_axis_tx_tready
        );

end architecture wrapper;
