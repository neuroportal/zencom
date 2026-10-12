"""6502 test harness for ZenCom (py65). Loads build/zencom.prg (unpacked) plus build/zencom.lbl
and calls routines directly. KERNAL is NOT present: only code that avoids ROM calls
can run (screen/ANSI/telnet/ACIA logic). ser_put is stubbed at $C000 and recorded."""
import os, sys
from py65.devices.mpu6502 import MPU

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import gen_font

lbl = {}
for line in open(os.path.join(ROOT, 'build', 'zencom.lbl')):
    _, addr, name = line.split()
    lbl[name.lstrip('.')] = int(addr, 16)

SEG = {}                                    # symbol -> segment (tools/ovlcheck.py)
for line in open(os.path.join(ROOT, 'build', 'zencom.seg')):
    k, v = line.split(); SEG[k] = v

STUB_PUT, STUB_CHROUT, RET = 0xC000, 0xFFD2, 0xBFFF

class C64:
    def __init__(self):
        self.mpu = MPU()
        m = self.mpu.memory = [0] * 65536
        data = open(os.path.join(ROOT, 'build', 'zencom.prg'), 'rb').read()
        base = data[0] | data[1] << 8
        m[base:base + len(data) - 2] = list(data[2:])
        xfr = os.path.join(ROOT, 'dist', 'zencom.xfr')     # the transfer overlay
        if os.path.exists(xfr):
            x = open(xfr, 'rb').read()
            xb = x[0] | x[1] << 8
            m[xb:xb + len(x) - 2] = list(x[2:])
            self.park = m[0x9000:0xA000]                   # the menu overlay, parked
        m[STUB_PUT] = 0x60; m[STUB_CHROUT] = 0x60
        m[0x30], m[0x31] = 0x00, 0xC0      # getvec (unused)
        m[0x32], m[0x33] = 0x00, 0xC0      # putvec -> stub
        self.sent, self.chrout = [], []

    def xchg(self, page):
        """ovl_xchg in Python: the park is the RAM under the I/O chips, which
        a flat 64 KB memory can't keep apart from the chips' registers."""
        m, a = self.mpu.memory, page << 8
        m[a:a + 0x1000], self.park = self.park, m[a:a + 0x1000]

    def overlay(self, which):
        """Put the menu ('MENU') or transfer ('XFR') overlay at $A000."""
        m, want = self.mpu.memory, 1 if which == 'MENU' else 0
        if m[lbl['ovl_in']] != want:
            self.xchg(0xA0); m[lbl['ovl_in']] = want

    def step(self):
        """One instruction; ovl_xchg is done in Python (see xchg)."""
        mpu, m = self.mpu, self.mpu.memory
        if mpu.pc == lbl['ovl_xchg']:
            self.xchg(mpu.a)
            mpu.sp = (mpu.sp + 2) & 0xFF                   # RTS
            mpu.pc = (m[0x100 + mpu.sp] << 8 | m[0xFF + mpu.sp]) + 1
            return
        mpu.step()

    def call(self, name, a=0, limit=5_000_000, x=None):
        mpu, m = self.mpu, self.mpu.memory
        if SEG.get(name) in ('MENU', 'XFR'): self.overlay(SEG[name])
        mpu.sp = 0xFD
        for v in ((RET - 1) >> 8, (RET - 1) & 0xFF):
            m[0x100 + mpu.sp] = v; mpu.sp -= 1
        mpu.pc, mpu.a = lbl[name], a
        if x is not None: mpu.x = x
        start = mpu.processorCycles
        for _ in range(limit):
            if mpu.pc == STUB_PUT: self.sent.append(mpu.a)
            if mpu.pc == STUB_CHROUT: self.chrout.append(mpu.a)
            if mpu.pc == RET: return mpu.processorCycles - start
            self.step()
        raise RuntimeError('timeout in ' + name)

    def nmi(self, byte):
        """Simulate one ACIA receive interrupt delivering `byte`."""
        mpu, m = self.mpu, self.mpu.memory
        m[0xDE01], m[0xDE00] = 0x18, byte
        mpu.sp = 0xF0
        for v in (RET >> 8, RET & 0xFF, 0x20):
            m[0x100 + mpu.sp] = v; mpu.sp -= 1
        mpu.pc = lbl['acia_nmi']
        while mpu.pc != RET: mpu.step()

    def feed(self, data):
        if isinstance(data, str): data = data.encode('latin-1')
        return sum(self.call('term_putc', b) for b in data)

    def var(self, n): return self.mpu.memory[lbl[n]]

    def text(self, rows=24, cols=80):
        """Read the ANSI-80 bitmap back as text (reverse video reads as normal)."""
        m = self.mpu.memory
        rev = {}
        for i, g in enumerate(gen_font.glyphs):
            rev.setdefault(tuple(gen_font.bits(r) >> 4 for r in g), i)
        out = []
        for r in range(rows):
            s = ''
            for c in range(cols):
                cell = []
                for py in range(8):
                    b = m[0x6000 + r * 320 + (c // 2) * 8 + py]
                    cell.append((b >> 4) if c % 2 == 0 else b & 15)
                cell = tuple(cell)
                g = rev.get(cell)
                if g is None: g = rev.get(tuple(x ^ 15 for x in cell))
                s += chr(g + 32) if g is not None and g < 95 else ('*' if g is not None else '?')
            out.append(s.rstrip())
        return out
