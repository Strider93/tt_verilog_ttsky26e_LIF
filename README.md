![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg)

# LIF Neuron PE: Tiny Tapeout (SkyWater SKY130)

One **leaky integrate-and-fire (LIF) processing element** from a convolutional spiking neural network (CSNN)
accelerator developed in my master thesis (TUM / Lund University), taped out on Tiny Tapeout
(SkyWater SKY130, 1x1 tile, about 167x108 µm).

In the full accelerator a 4x4 array of these PEs is fed by an FSM and SRAM-based input, weight and membrane
memories. This tile contains a single PE. The microcontroller on the Tiny Tapeout demo board takes over the job of the
FSM and the memories: it writes the neuron parameters, sends the preprocessed input spikes with their
weights, triggers the LIF update, and reads back Vmem and the output spikes.

The PE arithmetic is **bit-exact to the thesis RTL**.

## Neuron model

Per input event (`accumulate`): `acc += weight` if the input spike is 1 (4-bit signed weight, 8-bit accumulator).

Per time step (`updateLIF`), with 16-bit two's complement wrap-around arithmetic:

```
sum      = acc + leak + Vmem_in
sub_th   = sum + thr
spike    = (sub_th >= 0)
Vmem_out = spike ? sub_th : sum        // reset by subtraction
```

The spike is shifted into a 32-bit spike vector and the accumulator is cleared. As in the thesis, leakage and
threshold are only ever added, so they are written **negated** (`LEAK = -leak`, `THR = -Vth`).

## Interface

| Pin | Dir | Function |
|---|---|---|
| `ui[7:0]` | in | DATA byte to write |
| `uio[3:0]` | in | ADDR: register to write / byte to read back |
| `uio[4]` | in | WR strobe: a rising edge writes DATA to ADDR (synchronised to `clk`) |
| `uio[6]` | out | spike result of the last updateLIF |
| `uio[7]` | out | spike vector full |
| `uo[7:0]` | out | read-back byte for ADDR (registered, valid 1 clock after ADDR changes) |

| ADDR | Write | Read |
|---|---|---|
| 0x0 / 0x1 | LEAK low / high (store -leak) | LEAK |
| 0x2 / 0x3 | THR low / high (store -Vth) | THR |
| 0x4 / 0x5 | VMEM_IN low / high | VMEM_IN |
| 0x6 | ACC: `[3:0]` weight, `[4]` input spike, triggers one accumulate | accumulator |
| 0x7 | CTRL: `[0]` updateLIF, `[1]` upper/lower Vmem half, `[2]` clear spike vector, `[3]` feedback | status `{full, last_spike, spike_now, counter[4:0]}` |
| 0x8 - 0xB | - | membrane_out bytes 0..3 |
| 0xC - 0xF | - | spike vector bytes 0..3 |

The full description and a MicroPython example for the demo board are in [docs/info.md](docs/info.md).

## Repository layout

| Path | Content |
|---|---|
| [src/project.v](src/project.v) | top module `tt_um_strider93_lif`: register interface, command pulses, read-back mux |
| [src/lif_pe.v](src/lif_pe.v) | the LIF PE, ported from the thesis `PE.sv` |
| [src/clamped_adder.v](src/clamped_adder.v) | adder, ported from the thesis `clamped_adder.sv` (wraps, as in the thesis) |
| [src/config.json](src/config.json) | LibreLane configuration (`CLOCK_PERIOD` = 100 ns) |
| [test/test.py](test/test.py) | cocotb tests against a bit-exact Python model of the PE |
| [info.yaml](info.yaml) | Tiny Tapeout project metadata and pinout |

Changes from the thesis RTL are limited to what the Tiny Tapeout flow needs: two `always_ff` blocks that drove the
same registers are merged into one, `counter_deactivated` gets a reset value, an implicit net is declared, and debug
outputs are added. A lock-step simulation against the original `PE.sv` (200,000 random cycles) showed no mismatches.

## Simulation

```sh
cd test
make -B            # RTL simulation (Icarus Verilog + cocotb)
```

Requirements are listed in [test/requirements.txt](test/requirements.txt). The GitHub Actions also build the
SkyWater SKY130 layout (`gds`), run the precheck and repeat the tests on the gate-level netlist.

## Specifications

- Clock: 10 MHz (timing closed at a 100 ns period)
- Process: SkyWater SKY130, 1x1 Tiny Tapeout tile
- External hardware: none. Only the microcontroller on the Tiny Tapeout demo board is used.

## About Tiny Tapeout

Tiny Tapeout is an educational project that makes it easier and cheaper to get digital and analog designs
manufactured on a real chip. See https://tinytapeout.com and the [FAQ](https://tinytapeout.com/faq/).
