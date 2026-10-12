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
    assert res.get('r') is not None and res['r'][0] == data and res['r'][1] == 1
