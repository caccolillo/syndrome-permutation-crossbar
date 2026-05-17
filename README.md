# QEC Syndrome Router

> A runtime-configurable 1024-bit bit-permutation crossbar for low-latency syndrome routing in quantum error correction. Targets Xilinx UltraScale+ RFSoC (ZCU111).

[![SystemVerilog](https://img.shields.io/badge/SystemVerilog-IEEE_1800-005A9E.svg)](https://en.wikipedia.org/wiki/SystemVerilog)
[![Vivado](https://img.shields.io/badge/Vivado-2024.x-FF6F00.svg)](https://www.xilinx.com/products/design-tools/vivado.html)
[![Target](https://img.shields.io/badge/Target-ZCU111_XCZU28DR--2e-1F3A68.svg)](https://www.xilinx.com/products/boards-and-kits/zcu111.html)
[![Clock](https://img.shields.io/badge/fmax-400_MHz-2E75B6.svg)]()
[![Status](https://img.shields.io/badge/status-timing_met-2E8B57.svg)]()

---

## Headline numbers

| Metric                  | Value                                  |
|-------------------------|----------------------------------------|
| Data path width         | 1024 bits                              |
| Throughput              | 1 word / clock cycle (sustained)       |
| Data-path latency       | 4 cycles (10 ns @ 400 MHz)             |
| Reconfiguration latency | **~863 ns** (< 1 µs budget)            |
| Timing closure          | WNS **+1.311 ns** @ 400 MHz, standalone |
| LUT utilisation         | ~9% of XCZU28DR                        |
| Verification            | 188 vectors, 7 test classes, 0 fails   |

## What it does

A programmable component that maps an input bitstring to a re-ordered output bitstring at line rate. The user supplies two index vectors — an "original" labelling and a "final" labelling — and the hardware composes them into a permutation `P` such that:

```
data_out[i] = data_in[P[i]]
```

The permutation can be reconfigured at runtime over a 64-bit bus in under 1 microsecond, so the same FPGA bitstream can serve many different qubit layouts, QEC codes, and logical-qubit encodings without recompilation.

## Why this exists

Real-time quantum error correction needs to route syndrome bits from the qubit measurement layout into whatever order the decoder expects, every QEC round, within microseconds. Hard-wired permutations force a bitstream rebuild for every layout change. This component does it in software — and fast.

## Architecture at a glance

```
                                       400 MHz clock domain
                            ┌────────────────────────────────────────────┐
   Aurora 64B/66B   ┌─────┐ │  ┌──────────────────────┐  ┌───────────┐   │  ┌─────┐    Aurora
   ───────────────► │FIFO ├─┼─►│ crossbar_axis_wrapper├─►│ crossbar  ├──►│─►│FIFO ├──────────────►
       25.78 Gbps   └─────┘ │  │ (RX/TX FSMs, AXI-S)  │  │ 1024-bit  │   │  └─────┘     25.78 Gbps
                            │  └──────────────────────┘  └───────────┘   │
                            └────────────────────────────────────────────┘
                                   pl_clk0 from Zynq UltraScale+ PS
```

The crossbar core uses pipelined `MUXF7/F8/F9` primitives for the 1024:1 selection — the dedicated wide-mux silicon in UltraScale+ CLBs. Two LUTRAM arrays hold the original-inverse and final maps; a single composition pulse computes the per-output source index `P[i]` in one cycle, after which the data path runs at one word per clock.

See [crossbar_design_document.pdf](docs/crossbar_design_document.pdf) for the full technical write-up (27 pages: platform rationale, permutation algebra, memory architecture, timing analysis, verification plan including formal proposals, alternative architectures evaluated, build instructions, glossary).

## Repository layout

```
.
├── crossbar/                    # Crossbar core IP
│   ├── runtime_configurable_crossbar.sv
│   ├── mux_f789_tree.sv         # Pipelined 1024:1 mux (MUXF7/F8/F9)
│   ├── tb_runtime_configurable_crossbar.sv
│   ├── constraints.xdc
│   ├── constraints_standalone.xdc
│   └── prj.tcl
├── axis_wrapper/                # AXI4-Stream wrapper IP
│   ├── crossbar_axis_wrapper.sv
│   ├── tb_crossbar_axis_wrapper.sv
│   └── prj.tcl
├── end_system/                  # Aurora + crossbar + Zynq PS block design
│   ├── bd.tcl
│   ├── aurora_zcu111.xdc
│   └── constraints.xdc
├── docs/
│   ├── crossbar_design_document.pdf
│   └── crossbar_design_document.docx
├── Makefile
├── vivado_build_all.sh
├── clean.sh
└── README.md
```

## Build

Requires Vivado 2024.x and a ZCU111 board (or any UltraScale+ device for the standalone crossbar).

```bash
make             # build crossbar IP, then wrapper IP, then end-system block design
make clean       # remove all Vivado project directories and outputs
```

Each stage can also be built independently:

```bash
cd crossbar && vivado -mode batch -source prj.tcl
```

## Simulate

From the Vivado GUI: open any of the three projects, **Run Simulation → Run Behavioral Simulation**. Expected output from the crossbar testbench:

```
==================================================
  SIMULATION COMPLETE   PASS:188   FAIL:0
==================================================
```

## Test coverage

| Test case                     | What it checks                                                 | Vectors  |
|-------------------------------|----------------------------------------------------------------|----------|
| TC-01: Identity               | `data_out == data_in` when `orig_map = final_map`              | 20       |
| TC-02: Bit reversal           | `final_map[i] = 1023 - i`; maximum-displacement permutation    | 20       |
| TC-03: Random permutation     | Fisher–Yates shuffle, both maps independent                    | 30       |
| TC-04: Random + input gaps    | ~20% stall cycles on `data_in_vld`; pipeline-stall handling    | 50       |
| TC-05: Back-to-back reconfig  | Two reconfigs without full reset; verifies `cfg_restart`       | 2 × 10   |
| TC-06a: Broadcast             | All outputs map to one input bit                               | 20       |
| TC-06b: Dualcast              | Multi-source fan-out (even from `input[0]`, odd from `input[1023]`) | 20  |

Plus a separate AXI4-Stream end-to-end testbench that exercises the full 358-beat RX packet (171 + 171 + 16) through the wrapper and measures total receive-permute-transmit latency.

## Alternative architectures considered

Three other approaches were evaluated and rejected before settling on the `MUXF7/F8/F9` tree. The design document has the full comparison; the short version:

| Approach                  | Latency    | FF count    | Verdict                                             |
|---------------------------|------------|-------------|-----------------------------------------------------|
| **MUXF7/F8/F9 tree** ✅   | **4 cyc**  | **~6K**     | Selected — wins on latency, control, and timing      |
| CARRY8 one-hot mux        | ~3 cyc     | low         | Doesn't scale to 1024:1 at 400 MHz                  |
| Batcher bitonic sorter    | 56 cyc     | ~580K       | 14× latency, ~97× flip-flops                        |
| Benes network             | 19+ cyc    | low         | Complex Waksman control generation at runtime       |

## License

MIT — see [LICENSE](LICENSE).
