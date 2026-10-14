"""XMODEM engine tests: the overlay's xm_recv / xm_send against simulated
boards (Python), with telnet escaping.  Run via tests/test_zencom.py."""
from harness import C64, lbl

RET, PUT, OUT_STUB, IN_STUB = 0xBFFF, 0xC000, 0xC300, 0xC310
RXBUF = 0xC800
XB_RX, XB_PEND = 0xB800, 0xBC00
SOH, STX, EOT, ACK, NAK, CAN = 1, 2, 4, 6, 0x15, 0x18

def crc16(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else crc << 1
            crc &= 0xFFFF
    return crc

def telnet(data, binary):
    out = []
    for b in data:
        out.append(b)
        if b == 0xFF: out.append(0xFF)
        elif b == 0x0D and not binary: out.append(0)
    return out

def packet(n, payload, crc=True, size=128):
    data = list(payload) + [0x1A] * (size - len(payload))
    head = [SOH if size == 128 else STX, n & 255, 255 - (n & 255)]
    tail = [crc16(data) >> 8, crc16(data) & 255] if crc else [sum(data) & 255]
    return head + data + tail

class Rig:
    def __init__(self, binary=True):
        self.t = t = C64(); m = self.m = t.mpu.memory
        t.call('screen_init'); t.call('term_reset')
        m[0x30], m[0x31] = lbl['acia_get'] & 255, lbl['acia_get'] >> 8
        m[0x32], m[0x33] = PUT & 255, PUT >> 8
        m[0xFFE4:0xFFE7] = [0xA9, 0x00, 0x60]                 # GETIN: no key
        m[OUT_STUB:OUT_STUB + 2] = [0x18, 0x60]                # CLC RTS
        m[IN_STUB:IN_STUB + 2] = [0x18, 0x60]
        m[0x40], m[0x41] = OUT_STUB & 255, OUT_STUB >> 8       # xm_out
        m[0x42], m[0x43] = IN_STUB & 255, IN_STUB >> 8         # xm_in
        m[lbl['tn_bin_in']] = m[lbl['tn_bin_out']] = m[lbl['tn_seen']] = 1 if binary else 0
        m[lbl['x_strip']] = 0
        self.binary = binary
        self.queue, self.sent, self.out = [], [], bytearray()
        self.on_put = lambda b: None
        self.on_fill = lambda: b''
        self.on_tick = None                     # called once a jiffy
        self.inq = None

    def send(self, data):
        self.queue += telnet(data, True) if self.binary else list(data)   # no BINARY: raw TCP

    def run(self, entry, steps=20_000_000):
        t, m, mpu = self.t, self.m, self.t.mpu
        mpu.sp = 0xFD
        m[0x1FE], m[0x1FF] = (RET - 1) & 255, (RET - 1) >> 8
        mpu.pc = lbl[entry]
        head, tail = lbl['rx_head'], lbl['rx_tail']
        for i in range(steps):
            pc = mpu.pc
            if pc == RET: return not (mpu.p & 1)
            if pc == PUT:
                self.sent.append(mpu.a); self.on_put(mpu.a)
            elif pc == OUT_STUB:
                n = m[lbl['xo_len']] | m[lbl['xo_len'] + 1] << 8
                self.out += bytes(m[XB_PEND:XB_PEND + n])
            elif pc == IN_STUB:
                chunk = self.on_fill()
                m[XB_RX:XB_RX + len(chunk)] = list(chunk); mpu.a = len(chunk)
            if not self.queue and self.inq is not None and not self.inq.empty():
                self.queue.append(self.inq.get())
            if self.queue and (m[head] + 1) & 255 != m[tail]:   # feed the ring
                m[RXBUF + m[head]] = self.queue.pop(0); m[head] = (m[head] + 1) & 255
            if i % 400 == 0:                                       # jiffy clock
                m[0xA2] = (m[0xA2] + 1) & 255
                if m[0xA2] == 0: m[0xA1] = (m[0xA1] + 1) & 255
                if self.on_tick: self.on_tick()
            mpu.step()
        raise RuntimeError('timeout')

def sender(rig, payload, crc=True, size=128, corrupt=None, dup=False, ignore_c=False):
    """A board sending payload: answers C (or NAK if ignore_c) then ACK/NAK."""
    blocks = [payload[i:i + size] for i in range(0, len(payload), size)] or [b'']
    st = {'n': 0, 'started': False, 'bad': set(corrupt or [])}
    def emit():
        n = st['n']
        if n >= len(blocks): rig.send([EOT]); return
        p = packet(n + 1, blocks[n], crc, size)
        if n in st['bad']: st['bad'].discard(n); p[10] ^= 0x55   # damage one byte
        rig.send(p)
    def on_put(b):
        if not st['started']:
            if (b == ord('C') and not ignore_c) or (b == NAK and (ignore_c or not crc)):
                st['started'] = True; emit()
            return
        if b == ACK:
            if st.get('skip_ack'): st['skip_ack'] = False; return   # the duplicate's ACK
            st['n'] += 1
            if dup and st['n'] == 1:                                 # resend block 1
                rig.send(packet(1, blocks[0], crc, size)); st['skip_ack'] = True
            emit()
        elif b == NAK: emit()
    rig.on_put = on_put

def test_xmodem_receive_raw_tcp_without_binary():
    # No telnet BINARY negotiated: a raw TCP board's $FF and CR arrive as they are
    data = bytes(range(256)) + b'\r\n\xff\xff hello'
    rig = Rig(binary=False); sender(rig, data)
    assert rig.run('xm_recv')
    assert bytes(rig.out) == data + b'\x1a' * (384 - len(data))
    assert rig.m[lbl['xm_nblk']] == 3

def test_xmodem_receive_seq_strips_padding_and_1k():
    data = b'some text\r' * 150
    rig = Rig(); rig.m[lbl['x_strip']] = 1; sender(rig, data, size=1024)
    assert rig.run('xm_recv') and bytes(rig.out) == data

def test_xmodem_receive_retries_bad_block_and_ignores_duplicate():
    data = bytes(i * 7 & 255 for i in range(500))
    rig = Rig(); sender(rig, data, corrupt=[1], dup=True)
    assert rig.run('xm_recv')
    assert bytes(rig.out)[:500] == data and rig.m[lbl['xm_retries']] == 1
    assert NAK in rig.sent

def test_xmodem_receive_checksum_fallback():
    data = b'checksum mode ' * 20
    rig = Rig(); sender(rig, data, crc=False, ignore_c=True)
    assert rig.run('xm_recv') and bytes(rig.out)[:len(data)] == data
    assert rig.sent[:4] == [ord('C')] * 4 and rig.m[lbl['xm_crc']] == 0

def test_xmodem_receive_cancels():
    rig = Rig(); rig.on_put = lambda b: rig.send([CAN, CAN]) if b == ord('C') else None
    assert not rig.run('xm_recv') and rig.m[lbl['xm_err']] == 4
    rig = Rig(); rig.m[0xFFE4:0xFFE7] = [0xA9, 0x5F, 0x60]   # <- pressed
    assert not rig.run('xm_recv') and rig.m[lbl['xm_err']] == 5
    assert rig.sent[-3:] == [CAN] * 3

def test_xmodem_send_crc_with_a_nak():
    data = bytes((i * 13) & 255 for i in range(300)) + b'\xff'
    rig = Rig()
    chunks = [data[i:i + 128] for i in range(0, len(data), 128)]
    state = {'got': [], 'buf': [], 'naked': False}
    rig.on_fill = lambda: chunks.pop(0) if chunks else b''
    def on_put(b):                      # a receiver: collect 133-byte packets
        buf = state['buf']; buf.append(b)
        if buf[0] == EOT: rig.send([ACK]); buf.clear(); return
        if buf[0] == SOH and len(buf) > 3 and buf[-1] == 0xFF and buf[-2] == 0xFF and len(buf) % 1 == 0:
            pass
        raw = []; i = 0                 # undo telnet doubling
        while i < len(buf):
            raw.append(buf[i]); i += 2 if buf[i] == 0xFF and i + 1 < len(buf) and buf[i+1] == 0xFF else 1
        if len(raw) == 133:
            body = raw[3:131]
            ok = crc16(body) == (raw[131] << 8 | raw[132]) and raw[1] == 255 - raw[2]
            if ok and len(state['got']) == 1 and not state['naked']:
                state['naked'] = True; rig.send([NAK])
            elif ok: state['got'].append(bytes(body)); rig.send([ACK])
            else: rig.send([NAK])
            buf.clear()
    rig.on_put = on_put
    rig.send([ord('C')])
    assert rig.run('xm_send')
    got = b''.join(state['got'])
    assert got[:len(data)] == data and set(got[len(data):]) == {0x1A}
    assert rig.m[lbl['xm_retries']] == 1


def test_xmodem_send_1k():
    # K on the upload screen: 1024-byte STX blocks with CRC; the last one
    # padded with ^Z; a NAK resends the whole 1K block
    data = bytes((i * 7 + 1) & 255 for i in range(2500))
    rig = Rig(); rig.m[lbl['x_proto']] = 3; rig.m[lbl['x_eof']] = 0
    chunks = [data[i:i + 128] for i in range(0, len(data), 128)]
    state = {'got': [], 'buf': [], 'naked': False, 'stx': 0}
    rig.on_fill = lambda: chunks.pop(0) if chunks else b''
    def on_put(b):
        buf = state['buf']; buf.append(b)
        if buf[0] == EOT: rig.send([ACK]); buf.clear(); return
        raw = []; i = 0                 # undo telnet doubling
        while i < len(buf):
            raw.append(buf[i]); i += 2 if buf[i] == 0xFF and i + 1 < len(buf) and buf[i+1] == 0xFF else 1
        if len(raw) == 1029:
            assert raw[0] == 2                         # STX
            body = raw[3:1027]
            ok = crc16(body) == (raw[1027] << 8 | raw[1028]) and raw[1] == 255 - raw[2]
            if ok and len(state['got']) == 1 and not state['naked']:
                state['naked'] = True; rig.send([NAK])
            elif ok: state['got'].append(bytes(body)); rig.send([ACK])
            else: rig.send([NAK])
            buf.clear()
    rig.on_put = on_put
    rig.send([ord('C')])
    assert rig.run('xm_send', steps=40_000_000)
    got = b''.join(state['got'])
    assert len(state['got']) == 3 and got[:len(data)] == data and set(got[len(data):]) == {0x1A}
    assert rig.m[lbl['xm_retries']] == 1

def test_xmodem_send_falls_back_to_checksum_on_a_slow_start():
    # A 1541 takes seconds to open the file: the receiver gave up on CRC and
    # sent NAKs (checksum), but the sender had already seen its old "C"
    data = bytes((i * 7 + 1) & 255 for i in range(200))
    rig = Rig()
    chunks = [data[i:i + 128] for i in range(0, len(data), 128)]
    state = {'got': [], 'buf': [], 'sizes': []}
    rig.on_fill = lambda: chunks.pop(0) if chunks else b''
    def on_put(b):                      # a checksum-only receiver
        buf = state['buf']; buf.append(b)
        if buf[0] == EOT: rig.send([ACK]); buf.clear(); return
        raw = []; i = 0
        while i < len(buf):
            raw.append(buf[i]); i += 2 if buf[i] == 0xFF and i + 1 < len(buf) and buf[i+1] == 0xFF else 1
        if len(raw) == 132 and sum(raw[3:131]) & 255 == raw[131] and raw[1] == 255 - raw[2]:
            state['got'].append(bytes(raw[3:131])); state['sizes'].append(132); rig.send([ACK]); buf.clear()
        elif len(raw) == 133:           # a CRC block: not what it wants
            state['sizes'].append(133); rig.send([NAK]); buf.clear()
    rig.on_put = on_put
    rig.send([ord('C')])                # the stale request
    assert rig.run('xm_send')
    got = b''.join(state['got'])
    assert got[:len(data)] == data and state['sizes'][0] == 133 and state['sizes'][1] == 132


def test_xmodem_send_follows_the_latest_request():
    # The receiver's requests piled up while a 1541 opened the file: C, C,
    # then NAKs (it gave up on CRC).  Answer the last one, once.
    data = bytes((i * 5 + 2) & 255 for i in range(300))
    rig = Rig()
    chunks = [data[i:i + 128] for i in range(0, len(data), 128)]
    state = {'got': [], 'buf': [], 'sizes': []}
    rig.on_fill = lambda: chunks.pop(0) if chunks else b''
    def on_put(b):                      # a checksum-only receiver
        buf = state['buf']; buf.append(b)
        if buf[0] == EOT: rig.send([ACK]); buf.clear(); return
        raw = []; i = 0
        while i < len(buf):
            raw.append(buf[i]); i += 2 if buf[i] == 0xFF and i + 1 < len(buf) and buf[i+1] == 0xFF else 1
        if len(raw) == 132:
            ok = sum(raw[3:131]) & 255 == raw[131] and raw[1] == 255 - raw[2]
            state['sizes'].append(132)
            if ok: state['got'].append(bytes(raw[3:131]))
            rig.send([ACK if ok else NAK]); buf.clear()
    rig.on_put = on_put
    rig.send([ord('C'), ord('C'), NAK, NAK, NAK])
    assert rig.run('xm_send', steps=30_000_000)
    got = b''.join(state['got'])
    assert got[:len(data)] == data and set(state['sizes']) == {132} and len(state['sizes']) == 3


# ---- Punter: the 6502 code against the Python reference (tools/punter.py)
import os, sys, queue, threading
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'tools'))
import punter

def punter_link(rig):
    """Python endpoint wired to the emulated modem, telnet escaping both ways."""
    rig.inq, from_c64 = queue.Queue(), queue.Queue()
    pending = {'ff': False}
    def on_put(b):                                  # undo $FF doubling
        if pending['ff']:
            pending['ff'] = False
            if b == 0xFF: return
        elif b == 0xFF: pending['ff'] = True
        from_c64.put(b)
    rig.on_put = on_put
    def get(timeout):
        try: return from_c64.get(timeout=max(timeout, 3))
        except queue.Empty: return None
    def put(bs):
        for b in bs:
            rig.inq.put(b)
            if b == 0xFF: rig.inq.put(0xFF)
    return get, put

def test_punter_receive_from_reference_sender():
    data = bytes((i * 37 + 5) & 255 for i in range(700)) + b'\xff\r\x00\xff'
    rig = Rig(); get, put = punter_link(rig)
    th = threading.Thread(target=punter.send, args=(get, put, data, 0), daemon=True); th.start()
    assert rig.run('pt_recv', steps=60_000_000)
    assert bytes(rig.out) == data
    assert rig.m[lbl['xm_bytes']] | rig.m[lbl['xm_bytes'] + 1] << 8 == len(data)

def test_punter_send_to_reference_receiver():
    data = bytes((i * 11 + 3) & 255 for i in range(600)) + b'\xff\xff end'
    rig = Rig(); get, put = punter_link(rig)
    chunks = [data[i:i + 248] for i in range(0, len(data), 248)]
    rig.on_fill = lambda: chunks.pop(0) if chunks else b''
    rig.m[lbl['x_type']] = ord('S')
    res = {}
    th = threading.Thread(target=lambda: res.setdefault('r', punter.recv(get, put)), daemon=True); th.start()
    assert rig.run('pt_send', steps=60_000_000)
    th.join(30)
    assert res.get('r') is not None and res['r'][0] == data and res['r'][1] == 2   # SEQ


# ---- Punter upload to a C64 board (as Particles): CCGMS's receiver
# (rectype/receive/receive_block/accept/recmodem in its punter.s), timed in
# jiffies, with a delay each way (the internet) and 2400 baud into the board.
# Its habits: every code it sends first clears its input buffer; a token
# counts only with nothing after it; a block is read byte by byte, and if
# nothing comes within ~0.4 s it sends S/B again.  (So a round trip much
# over 1/3 s defeats it whatever the sender does.)  With iac, the board sits
# behind a bridge that reads telnet without ever negotiating it: an
# undoubled $FF $FF arrives as one $FF, phase A's block is a byte short, and
# the board answers BAD for ever (Particles, 0.9.0: GOO, S/B, BAD, hundreds
# of retries, 0 blocks).  0.9.1 switches $FF doubling on after BADs there.
# Without phase_a, the board skips the file-type phase and asks for the
# 7-byte header at once, as Particles turned out to (2026-10-14): every
# 8-byte type block failed its check, BAD for ever.
def c64_board(rig, delay=10, cps_per_jiffy=4, accept_t=31, rec_t=22, pause=20, iac=False,
              phase_a=True):
    st = {'iac': 0, 'now': 0, 'up_t': 0.0, 'up': [], 'down': [], 'inbox': [],
          'wait': None, 'kind': None, 'res': None, 'gen': None}
    GOO, BAD, ACK, SB, SYN = punter.TOKENS
    def send(code):
        st['inbox'].clear()                         # rs232_clear
        st['down'].append((st['now'] + delay, code))
    def get(t): return (yield ('get', t))
    def sleep(t): yield ('sleep', t)
    def accept(want):
        w = b''
        while True:
            b = yield from get(accept_t)
            if b is None:
                yield from sleep(pause); return None
            w = (w + bytes([b]))[-3:]
            if w in want and not st['inbox']: return w
    def recmodem(n):
        buf = b''
        while len(buf) < n:
            b = yield from get(rec_t)
            if b is None:
                yield from sleep(pause); return ('short' if buf else 'nodata'), buf
            buf += bytes([b])
            if buf == ACK and not st['inbox']: return 'ack', buf
        return 'good', buf
    def good(buf, n):
        if len(buf) != n: return False
        add, cyc = punter.checksums(buf[4:])
        return buf[0] | buf[1] << 8 == add and buf[2] | buf[3] << 8 == cyc
    def receive_block(code, size, end):
        yield from sleep(pause)
        while True:
            send(code)
            if (yield from accept((ACK,))) or (yield from accept((ACK,))): break
        while True:
            yield from sleep(pause)
            send(SB)
            if end and code == GOO:
                if not (yield from accept((SYN,))): continue
                for _ in range(10):
                    send(SYN)
                    if (yield from accept((SB,))): break
                return None
            stat, buf = yield from recmodem(size)
            if stat in ('nodata', 'ack'): continue
            return buf
    def board():
        size, code, ftype = 8, GOO, None                # rectype
        while phase_a:
            buf = yield from receive_block(code, size, ftype is not None)
            if ftype is not None: break
            if good(buf, size): ftype, code = buf[7], GOO
            else: code = BAD
        data, size, code, end = b'', 7, GOO, False      # receive
        while True:
            buf = yield from receive_block(code, size, end)
            if end: return data, ftype
            if good(buf, size):
                data += buf[7:]
                end = buf[6] == 0xFF
                size, code = buf[4], GOO
            else: code = BAD
    def step(v):
        try: kind, t = st['gen'].send(v)
        except StopIteration as e: st['kind'], st['res'] = None, ('done', e.value); return
        st['kind'], st['wait'] = kind, st['now'] + t
    def tick():
        st['now'] += 1
        while st['down'] and st['down'][0][0] <= st['now']:
            rig.queue += list(st['down'].pop(0)[1])
        while st['up'] and st['up'][0][0] <= st['now']:
            st['inbox'].append(st['up'].pop(0)[1])
        if st['gen'] is None:
            st['gen'] = board(); step(None)
        while st['kind']:
            if st['kind'] == 'get' and st['inbox']: step(st['inbox'].pop(0))
            elif st['now'] >= st['wait']: step(None)
            else: break
    def on_put(b):
        if iac:                             # a bridge that reads telnet: FF FF = FF,
            if st['iac'] == 1:              # FF + a command = gone
                st['iac'] = 2 if 0xFB <= b <= 0xFE else 0
                if b != 0xFF: return
            elif st['iac'] == 2: st['iac'] = 0; return
            elif b == 0xFF: st['iac'] = 1; return
        st['up_t'] = max(st['up_t'], st['now'] + delay) + 1 / cps_per_jiffy
        st['up'].append((st['up_t'], b))
    rig.on_put, rig.on_tick = on_put, tick
    return st

def punter_to_board(data, **kw):
    rig = Rig(binary=False)                 # raw TCP, as Particles
    chunks = [data[i:i + 248] for i in range(0, len(data), 248)]
    rig.on_fill = lambda: chunks.pop(0) if chunks else b''
    rig.m[lbl['x_type']] = ord('P')
    st = c64_board(rig, **kw)
    if kw.get('iac'): rig.m[lbl['tn_seen']] = 0     # it never negotiates
    ok = rig.run('pt_send', steps=40_000_000)
    for _ in range(600):                    # let the board finish its end
        if st['res']: break
        rig.on_tick()
    return ok, st['res'] and st['res'][1], rig.m[lbl['xm_retries']]

def test_punter_send_to_a_c64_board():
    data = bytes((i * 13 + 7) & 255 for i in range(900)) + b'\xff\r end'
    for delay in (2, 10):                   # near, and 1/6 s each way
        for iac in (False, True):           # a plain bridge, one that reads telnet
            ok, res, retries = punter_to_board(data, delay=delay, iac=iac)
            assert ok and res == (data, 1), (delay, iac, ok, res and len(res[0]), retries)
            assert retries <= (3 if iac else 0), (delay, iac, retries)

def test_punter_send_to_a_board_without_phase_a():
    data = bytes((i * 29 + 1) & 255 for i in range(700))
    for iac in (False, True):
        ok, res, retries = punter_to_board(data, delay=10, iac=iac, phase_a=False)
        assert ok and res and res[0] == data, (iac, ok, res and len(res[0]), retries)
        assert retries <= 8, (iac, retries)
