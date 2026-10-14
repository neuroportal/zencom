#!/usr/bin/env python3
"""A tiny telnet 'board' for testing ZenCom's file transfers on real hardware.

The C64 dials it (ATD <mac-ip>:6464).  Keys on the board:
  D  send the test file by XMODEM (128-byte blocks, CRC or checksum)
  K  send it with 1K blocks (XMODEM-1K)
  U  receive a file by XMODEM (saved to --save)
  P  send the test file by Punter
  O  receive a file by Punter (saved to --save)
  Q  hang up
  B  busy: a burst of text, then hang up at once
  G  a C64-style board: a file list, DOWNLOAD #:, then Punter opening with GOO
It asks for telnet BINARY both ways (as many boards do) and escapes $FF.
Used by tools/hwtest.py --transfer; can also be run by hand.
"""
import argparse, os, socket, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import punter

SOH, STX, EOT, ACK, NAK, CAN = 1, 2, 4, 6, 0x15, 0x18
IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240


def crc16(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else crc << 1
            crc &= 0xFFFF
    return crc


def test_data(n=5000):
    """Every byte value, CRs, $FFs, then a pattern: catches escaping bugs."""
    d = bytes(range(256)) + b'\r\r\n\xff\xff\xff\r\x00' + bytes((i * 31 + 7) & 255 for i in range(n))
    return d[:n]


class Telnet:
    def __init__(self, conn, log):
        self.c, self.log, self.buf = conn, log, bytearray()
        conn.settimeout(0.2)

    def raw(self, data):
        self.c.sendall(bytes(data))

    def send(self, data):
        self.raw(bytes(data).replace(b'\xff', b'\xff\xff'))

    def getb(self, timeout):
        """One data byte (telnet commands consumed), or None."""
        end = time.time() + timeout
        while time.time() < end:
            if not self.buf:
                try:
                    chunk = self.c.recv(4096)
                    if not chunk: raise ConnectionError('closed')
                    self.buf += chunk
                except socket.timeout:
                    continue
            b = self.buf.pop(0)
            if b != IAC: return b
            while not self.buf: self.buf += self.c.recv(4096)
            cmd = self.buf.pop(0)
            if cmd == IAC: return IAC
            if cmd in (DO, DONT, WILL, WONT):
                while not self.buf: self.buf += self.c.recv(4096)
                self.log(f'telnet {cmd} {self.buf.pop(0)}')
            elif cmd == SB:
                while True:
                    while not self.buf: self.buf += self.c.recv(4096)
                    if self.buf.pop(0) == SE: break
        return None


def xmodem_send(t, data, size, log):
    t.log(f'waiting for C/NAK ({size}-byte blocks)')
    crc = None
    end = time.time() + 60
    while time.time() < end and crc is None:
        b = t.getb(1)
        if b == ord('C'): crc = True
        elif b == NAK: crc = False
        elif b == CAN: return False
    if crc is None: return False
    blocks = [data[i:i + size] for i in range(0, len(data), size)]
    n = 0
    while n < len(blocks):
        body = blocks[n] + b'\x1a' * (size - len(blocks[n]))
        pkt = bytes([SOH if size == 128 else STX, (n + 1) & 255, 255 - ((n + 1) & 255)]) + body
        pkt += bytes([crc16(body) >> 8, crc16(body) & 255]) if crc else bytes([sum(body) & 255])
        for attempt in range(10):
            t.send(pkt)
            r = t.getb(15)
            if r == ACK: break
            if r == CAN: log('cancelled by the C64'); return False
            log(f'block {n + 1}: {r!r}, resending')
        else:
            return False
        n += 1
    for attempt in range(10):
        t.send([EOT])
        if t.getb(10) == ACK: log(f'sent {len(data)} bytes in {len(blocks)} blocks'); return True
    return False


def xmodem_recv(t, log):
    out = bytearray()
    expect, crc = 1, True
    for start in range(30):                                # ~90 s: a 1541 is slow to
        t.send([ord('C') if crc else NAK])                 # list and open the file
        b = t.getb(3)
        if b is not None: break
        if start == 3: crc = False
    else:
        return None
    while True:
        if b is None: b = t.getb(10)
        if b == EOT:
            t.send([ACK]); log(f'received {len(out)} bytes'); return bytes(out)
        if b == CAN: return None
        if b not in (SOH, STX): b = None; continue
        size = 128 if b == SOH else 1024
        hdr = [t.getb(2), t.getb(2)]
        raw = [t.getb(2) for _ in range(size)]
        body = bytes(x or 0 for x in raw)
        tail = [t.getb(2) for _ in range(2 if crc else 1)]
        good = None not in hdr and None not in tail and hdr[0] == 255 - hdr[1] and (
            (crc and crc16(body) == (tail[0] << 8 | tail[1])) or (not crc and sum(body) & 255 == tail[0]))
        if good and hdr[0] == expect & 255:
            out += body; expect += 1; t.send([ACK])
        elif good and hdr[0] == (expect - 1) & 255:
            t.send([ACK])
        else:
            log(f'bad block, NAK: hdr={hdr} expect={expect} missing={raw.count(None)} tail={tail} crc={crc16(body):04x}'); t.send([NAK])
        b = None


MULTI2 = b'THE SECOND FILE OF A MULTI-PUNTER BATCH\r' * 20

def serve(port, save, data, once, log):
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('0.0.0.0', port)); srv.listen(1)
    log(f'listening on {port}')
    while True:
        conn, addr = srv.accept()
        log(f'call from {addr}')
        t = Telnet(conn, log)
        try:
            t.raw([IAC, WILL, 0, IAC, DO, 0])              # BINARY both ways
            t.send(b'\r\nZENCOM TEST BOARD\r\nD download  K 1K download  U upload  Q quit\r\n> ')
            while True:
                k = t.getb(600)
                if k is None: break
                k = chr(k).upper()
                if k == 'D' or k == 'K':
                    t.send(b'\r\nSTART YOUR XMODEM DOWNLOAD\r\n')
                    ok = xmodem_send(t, data, 128 if k == 'D' else 1024, log)
                    t.send(b'\r\nDOWNLOAD %s\r\n> ' % (b'OK' if ok else b'FAILED'))
                elif k == 'U':
                    t.send(b'\r\nSTART YOUR XMODEM UPLOAD\r\n')
                    got = xmodem_recv(t, log)
                    if got is not None and save:
                        open(save, 'wb').write(got)
                    t.send(b'\r\nUPLOAD %s\r\n> ' % (b'OK' if got is not None else b'FAILED'))
                elif k == 'P':
                    t.send(b'\r\nSTART YOUR PUNTER DOWNLOAD\r\n')
                    ok = punter.send(lambda to: t.getb(to), t.send, data, 1)
                    log(f'punter send {"ok" if ok else "failed"}')
                    t.send(b'\r\nDOWNLOAD %s\r\n> ' % (b'OK' if ok else b'FAILED'))
                elif k == 'O':
                    t.send(b'\r\nSTART YOUR PUNTER UPLOAD\r\n')
                    got = punter.recv(lambda to: t.getb(to), t.send)
                    if got is not None and save:
                        open(save + '.punter', 'wb').write(got[0])
                    log(f'punter received {len(got[0]) if got else None}')
                    t.send(b'\r\nUPLOAD %s\r\n> ' % (b'OK' if got else b'FAILED'))
                elif k == 'M':                             # Multi-Punter: two files, each after
                    t.send(b'\r\nMULTI-PUNTER: START YOUR BATCH\r\n')   # a CTRL-I header, then
                    time.sleep(2)                          # the CTRL-D end (as CCGMS sends)
                    ok = True
                    for name, d, ft in ((b'MULTI ONE,P', data, 1), (b'MULTI,TWO,S', MULTI2, 2)):
                        t.send(b'\x09' * 16 + name + b'\r')
                        seen = []                          # (the tokens, for the log)
                        def get(to, seen=seen):
                            b = t.getb(to); seen.append(b); return b
                        ok1 = punter.send(get, t.send, d, ft, 30.0)
                        txt = bytes(x for x in seen if x is not None)
                        log(f'multi tokens in: {txt[:60]!r} ... {txt[-40:]!r} ({len(seen)})')
                        ok = ok1 and ok
                        log(f'multi {name!r} {"ok" if ok else "failed"}')
                        time.sleep(2)
                    t.send(b'\x09' * 16 + b'\x04' * 16 + b'\r')
                    t.send(b'\r\nBATCH %s\r\n> ' % (b'OK' if ok else b'FAILED'))
                elif k == 'Q':
                    t.send(b'\r\nBYE\r\n'); break
                elif k == 'G':                             # a C64-style board: list, number,
                    t.send(b'\r\n  #   FILENAME          TYPE BLOCKS\r\n'      # then GOOs until asked
                           b'  122 3!SPY VS SPY     P   140\r\n'
                           b'  123 4!SPY VS SPY     P     7\r\n'
                           b'  124 1!T.COMMUNICATIO P     6\r\n'
                           b'DOWNLOAD #: ')
                    num = b''
                    while True:
                        c = t.getb(60)
                        if c is None or c in (13, 10): break
                        num += bytes([c]); t.send(bytes([c]))
                    log(f'G: file {num!r}')
                    t.send(b'\r\nSELECT RECEIVE MODE ON YOUR TERMINAL!\r\n')
                    first = None
                    for _ in range(90):                    # a C1 sender opens with GOO
                        t.send(b'GOO')
                        first = t.getb(1)
                        if first is not None: break
                    pending = [first] if first is not None else []
                    ok = punter.send(lambda to: pending.pop() if pending else t.getb(to), t.send, data, 1)
                    log(f'punter G send {"ok" if ok else "failed"}')
                    t.send(b'\r\nDOWNLOAD %s\r\n> ' % (b'OK' if ok else b'FAILED'))
                elif k == 'C':                             # a page, cleared (PETSCII CLR), the next
                    t.send(b'\r\nPAGE ONE TOP\r\nPAGE ONE MIDDLE\r\nPAGE ONE END\r\n')
                    time.sleep(0.5)
                    t.send(b'\x93PAGE TWO\r\n> ')
                elif k == 'B':                             # a busy board: a burst, then gone
                    for i in range(20):                    # (trickled, as a slow modem would)
                        t.send(b'\r\nBUSY LINE %02d ....................' % i); time.sleep(0.15)
                    t.send(b'\r\nLAST WORDS\r\n'); break
        except (ConnectionError, OSError) as e:
            log(f'connection: {e}')
        conn.close()
        if once: break


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=6464)
    ap.add_argument('--save', default='upload.bin')
    ap.add_argument('--size', type=int, default=5000)
    ap.add_argument('--once', action='store_true')
    a = ap.parse_args()
    serve(a.port, a.save, test_data(a.size), a.once, lambda s: print('[board]', s, flush=True))


if __name__ == '__main__':
    main()
