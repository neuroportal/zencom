"""Punter (C1) in Python: a reference for ZenCom's 6502 version.

Receive follows the long-standing receivers (as in CGTerm): 3-letter
tokens resent until the expected answer, blocks requested with S/B and
answered GOO/BAD.  Send answers the receiver's tokens.  Used by the
emulator tests and by tools/xfr_server.py.

An endpoint is (get(timeout) -> byte or None, put(bytes)).
"""
import time

TOKENS = (b'GOO', b'BAD', b'ACK', b'S/B', b'SYN')
MAXDATA = 248


def checksums(body):
    """Additive and cyclic 16-bit checksums of a block from byte 4 on."""
    add = cyc = 0
    for b in body:
        add = (add + b) & 0xFFFF
        cyc ^= b
        cyc = ((cyc << 1) | (cyc >> 15)) & 0xFFFF
    return add, cyc


def block(nextsize, number, data=b''):
    body = bytes([nextsize & 255, number & 255, (number >> 8) & 255]) + bytes(data)
    add, cyc = checksums(body)
    return bytes([add & 255, add >> 8, cyc & 255, cyc >> 8]) + body


def _get3(get, timeout):
    out = b''
    while len(out) < 3:
        b = get(timeout)
        if b is None: return None
        out += bytes([b])
    return out


def handshake(get, put, send, want, timeout=1.0):
    for _ in range(10):
        put(send)
        for _ in range(10):
            tok = _get3(get, timeout)
            if tok is not None: break
            put(send)
        else:
            return False
        if tok == want: return True
        if tok == send: return False
    return False


def recv_block(get, put, n, timeout=1.0):
    for _ in range(10):
        put(b'S/B')
        buf = b''
        while len(buf) < n:
            b = get(timeout)
            if b is None: break
            buf += bytes([b])
            if len(buf) == 4 and buf[:3] == b'ACK':       # stray ACKs: resync
                if buf[3:] == b'A':
                    buf = b''; put(b'S/B')                # (as CGTerm: ask again)
                else:
                    buf = buf[3:]
        if len(buf) == n:
            add, cyc = checksums(buf[4:])
            if buf[0] | buf[1] << 8 == add and buf[2] | buf[3] << 8 == cyc:
                if not handshake(get, put, b'GOO', b'ACK'): return None
                return buf
        if not handshake(get, put, b'BAD', b'ACK'): return None
    return None


def recv(get, put, patience=60):
    """Receive a file: (data, type byte) or None.  The first handshake waits
    up to `patience` seconds: the sender's user has a file to pick."""
    end = time.time() + patience
    while not handshake(get, put, b'GOO', b'ACK'):
        if time.time() > end: return None
    a = recv_block(get, put, 8)
    if a is None: return None
    for s, w in ((b'GOO', b'ACK'), (b'S/B', b'SYN'), (b'SYN', b'S/B'), (b'GOO', b'ACK')):
        if not handshake(get, put, s, w): return None
    blk = recv_block(get, put, 7)
    if blk is None: return None
    data = b''
    while blk[6] != 0xFF and blk[4] >= 7:
        blk = recv_block(get, put, blk[4])
        if blk is None: return None
        data += blk[7:]
    if handshake(get, put, b'S/B', b'SYN'):
        handshake(get, put, b'SYN', b'S/B')
    return data, a[7]


def send(get, put, data, ftype=0, timeout=10.0):
    """Send a file by answering the receiver's tokens.  True when done."""
    chunks = [data[i:i + MAXDATA] for i in range(0, len(data), MAXDATA)]
    def phase_b():
        blocks, nxt = [], (len(chunks[0]) + 7 if chunks else 0)
        blocks.append(block(nxt, 0 if chunks else 0xFFFF))
        for i, c in enumerate(chunks):
            last = i == len(chunks) - 1
            blocks.append(block(0 if last else len(chunks[i + 1]) + 7, 0xFFFF if last else i + 1, c))
        return blocks
    phases = [[block(0, 0xFFFF, bytes([ftype]))], phase_b()]
    phase, idx, unacked, window = 0, 0, False, b''
    end = time.time() + 120
    while time.time() < end:
        b = get(timeout)
        if b is None: return False
        window = (window + bytes([b]))[-3:]
        if window not in TOKENS: continue
        tok, window = window, b''
        blocks = phases[phase]
        done = idx >= len(blocks)
        if tok == b'GOO':
            if unacked: idx += 1; unacked = False
            put(b'ACK')
        elif tok == b'BAD':
            unacked = False; put(b'ACK')
        elif tok == b'S/B':
            if done: put(b'SYN')
            else: put(blocks[idx]); unacked = True
        elif tok == b'SYN':
            put(b'S/B')
            if done:
                if phase == 1: return True
                phase, idx = 1, 0
    return False
