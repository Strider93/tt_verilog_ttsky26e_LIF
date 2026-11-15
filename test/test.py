# SPDX-FileCopyrightText: © 2025 Kosmas Wernhard
# SPDX-License-Identifier: Apache-2.0
#
# cocotb tests for the LIF neuron PE (tt_um_strider93_lif).
# A Python golden model of the thesis PE (bit-exact, wrap-around arithmetic)
# is compared against the RTL / gate-level netlist.

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

# register addresses
LEAK_L, LEAK_H, THR_L, THR_H, VIN_L, VIN_H, ACC, CTRL = range(8)
STATUS = 0x7
MEM0, SVEC0 = 0x8, 0xC

CTRL_UPDATE = 1 << 0
CTRL_LBN = 1 << 1
CTRL_ZERO = 1 << 2
CTRL_FB = 1 << 3


def wrap(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


class PEModel:
    """Golden model of the thesis PE + Tiny Tapeout wrapper."""

    def __init__(self):
        self.leak = self.thr = self.vin = 0
        self.acc = 0
        self.upper = self.lower = 0
        self.svec = 0
        self.counter = 0
        self.full = 0
        self.moc = 0
        self.cd = 0
        self.lbn = 0
        self.fb = 0
        self.last_spike = 0

    def spike_now(self):
        s = wrap(wrap(self.acc + self.leak, 16) + self.vin, 16)
        st = wrap(s + self.thr, 16)
        return st >= 0, st, s

    def write(self, addr, data):
        if addr == LEAK_L:
            self.leak = wrap((self.leak & 0xFF00) | data, 16)
        elif addr == LEAK_H:
            self.leak = wrap((self.leak & 0x00FF) | (data << 8), 16)
        elif addr == THR_L:
            self.thr = wrap((self.thr & 0xFF00) | data, 16)
        elif addr == THR_H:
            self.thr = wrap((self.thr & 0x00FF) | (data << 8), 16)
        elif addr == VIN_L:
            self.vin = wrap((self.vin & 0xFF00) | data, 16)
        elif addr == VIN_H:
            self.vin = wrap((self.vin & 0x00FF) | (data << 8), 16)
        elif addr == ACC:
            weight = wrap(data & 0xF, 4)
            if data & 0x10:
                self.acc = wrap(self.acc + weight, 8)
            self.moc = 0
            self.cd = 0
        elif addr == CTRL:
            self.lbn = (data >> 1) & 1
            self.fb = (data >> 3) & 1
            zero = (data >> 2) & 1
            if data & CTRL_UPDATE:
                spike, st, s = self.spike_now()
                mo = st if spike else s
                if self.lbn and not self.moc:
                    self.upper = mo
                    self.moc = 1
                elif not self.lbn:
                    self.lower = mo
                old_counter = self.counter
                if not self.cd:
                    if spike:
                        self.svec |= 1 << self.counter
                    else:
                        self.svec &= ~(1 << self.counter)
                    self.counter = (self.counter + 1) % 32
                    self.cd = 1
                self.full = int(old_counter >= 31)
                self.acc = 0
                self.last_spike = int(spike)
                if self.fb:
                    self.vin = self.upper if self.lbn else self.lower
            if zero:
                self.svec = 0
                self.counter = 0

    def read(self, addr):
        mem = ((self.upper & 0xFFFF) << 16) | (self.lower & 0xFFFF)
        regs = [
            self.leak & 0xFF, (self.leak >> 8) & 0xFF,
            self.thr & 0xFF, (self.thr >> 8) & 0xFF,
            self.vin & 0xFF, (self.vin >> 8) & 0xFF,
            self.acc & 0xFF,
            (self.full << 7) | (self.last_spike << 6)
            | (int(self.spike_now()[0]) << 5) | self.counter,
            mem & 0xFF, (mem >> 8) & 0xFF, (mem >> 16) & 0xFF, (mem >> 24) & 0xFF,
            self.svec & 0xFF, (self.svec >> 8) & 0xFF,
            (self.svec >> 16) & 0xFF, (self.svec >> 24) & 0xFF,
        ]
        return regs[addr]


class Driver:
    def __init__(self, dut):
        self.dut = dut
        self.model = PEModel()

    async def write(self, addr, data):
        data &= 0xFF
        self.dut.ui_in.value = data
        self.dut.uio_in.value = addr
        await ClockCycles(self.dut.clk, 1)
        self.dut.uio_in.value = addr | 0x10  # WR high
        await ClockCycles(self.dut.clk, 4)
        self.dut.uio_in.value = addr  # WR low
        await ClockCycles(self.dut.clk, 3)
        self.model.write(addr, data)

    async def read(self, addr):
        self.dut.uio_in.value = addr
        await ClockCycles(self.dut.clk, 2)  # uo_out is registered
        return int(self.dut.uo_out.value)

    async def write16(self, addr_lo, value):
        value &= 0xFFFF
        await self.write(addr_lo, value & 0xFF)
        await self.write(addr_lo + 1, value >> 8)

    async def configure(self, leak, vth, vmem=0):
        """leak / vth given as positive numbers; stored negated (thesis convention)."""
        await self.write16(LEAK_L, -leak)
        await self.write16(THR_L, -vth)
        await self.write16(VIN_L, vmem)

    async def accumulate(self, weight, spike=1):
        await self.write(ACC, (weight & 0xF) | ((spike & 1) << 4))

    async def update(self, lbn=0, fb=0, zero=0):
        await self.write(CTRL, CTRL_UPDATE | (lbn << 1) | (zero << 2) | (fb << 3))

    async def check_all(self, tag=""):
        for addr in range(16):
            got = await self.read(addr)
            exp = self.model.read(addr)
            assert got == exp, f"{tag} addr 0x{addr:X}: got 0x{got:02X} expected 0x{exp:02X}"
        uio = int(self.dut.uio_out.value)
        assert (uio >> 6) & 1 == self.model.last_spike, f"{tag} uio[6] spike pin"
        assert (uio >> 7) & 1 == self.model.full, f"{tag} uio[7] full pin"

    async def vmem_lower(self):
        lo = await self.read(MEM0)
        hi = await self.read(MEM0 + 1)
        return wrap((hi << 8) | lo, 16)


async def setup(dut):
    clock = Clock(dut.clk, 100, unit="ns")  # 10 MHz
    cocotb.start_soon(clock.start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    drv = Driver(dut)
    assert int(dut.uio_oe.value) == 0xC0
    return drv


@cocotb.test()
async def test_register_readback(dut):
    drv = await setup(dut)
    await drv.check_all("reset")
    for addr, val in [(LEAK_L, 0x12), (LEAK_H, 0x34), (THR_L, 0x56),
                      (THR_H, 0x78), (VIN_L, 0x9A), (VIN_H, 0xBC)]:
        await drv.write(addr, val)
        assert await drv.read(addr) == val
    await drv.check_all("readback")


@cocotb.test()
async def test_integrate_and_fire(dut):
    drv = await setup(dut)
    await drv.configure(leak=1, vth=10)
    # each time step: 3 input spikes with weight +2 -> +6 - 1 leak = +5 per step
    vmem = 0
    spikes = []
    for step in range(8):
        for _ in range(3):
            await drv.accumulate(2)
        await drv.update(fb=1)
        await drv.check_all(f"step {step}")
        vmem += 5
        if vmem >= 10:
            vmem -= 10
            spikes.append(1)
        else:
            spikes.append(0)
        assert await drv.vmem_lower() == vmem
    dut._log.info(f"spike train: {spikes}")
    assert spikes == [0, 1, 0, 1, 0, 1, 0, 1]


@cocotb.test()
async def test_leak_and_negative_weights(dut):
    drv = await setup(dut)
    await drv.configure(leak=3, vth=100, vmem=50)
    await drv.accumulate(0, spike=0)  # open the time step without input
    await drv.update(fb=1)
    assert await drv.vmem_lower() == 47
    await drv.accumulate(-8)
    await drv.accumulate(-1)
    await drv.accumulate(7, spike=0)  # no spike -> weight ignored
    await drv.check_all("neg acc")
    assert wrap(await drv.read(ACC), 8) == -9
    await drv.update(fb=1)
    assert await drv.vmem_lower() == 47 - 9 - 3
    await drv.check_all("neg")


@cocotb.test()
async def test_accumulator_wrap(dut):
    drv = await setup(dut)
    await drv.configure(leak=0, vth=1000)
    for _ in range(20):  # 20 * 7 = 140 -> wraps in the 8-bit accumulator (thesis behaviour)
        await drv.accumulate(7)
    assert wrap(await drv.read(ACC), 8) == wrap(140, 8)
    await drv.update()
    await drv.check_all("acc wrap")


@cocotb.test()
async def test_spike_vector(dut):
    drv = await setup(dut)
    await drv.configure(leak=0, vth=1)
    for step in range(33):
        await drv.accumulate(1, spike=step % 3 == 0)
        await drv.update()
    await drv.check_all("svec 33")
    await drv.write(CTRL, CTRL_ZERO)
    await drv.check_all("svec zero")
    assert await drv.read(SVEC0) == 0


@cocotb.test()
async def test_upper_half(dut):
    drv = await setup(dut)
    await drv.configure(leak=2, vth=50, vmem=20)
    await drv.accumulate(5)
    await drv.update(lbn=1)
    await drv.update(lbn=1)  # second update without accumulate: upper must not change
    await drv.check_all("upper")


@cocotb.test()
async def test_random_vs_model(dut):
    drv = await setup(dut)
    rng = random.Random(1234)
    await drv.configure(leak=rng.randint(0, 20), vth=rng.randint(10, 200))
    for i in range(300):
        op = rng.random()
        if op < 0.6:
            await drv.accumulate(rng.randint(-8, 7), spike=rng.random() < 0.7)
        elif op < 0.9:
            await drv.update(lbn=int(rng.random() < 0.2), fb=int(rng.random() < 0.8),
                             zero=int(rng.random() < 0.05))
        elif op < 0.95:
            await drv.write(rng.choice([LEAK_L, LEAK_H, THR_L, THR_H, VIN_L, VIN_H]),
                            rng.randint(0, 255))
        else:
            await drv.write(CTRL, rng.randint(0, 15) & ~CTRL_UPDATE)
        if i % 10 == 0:
            await drv.check_all(f"rand {i}")
    await drv.check_all("rand end")
