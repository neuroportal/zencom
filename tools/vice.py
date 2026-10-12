"""A small client for VICE's binary monitor (-binarymonitor, port 6502):
read and write C64 memory and set resources, then let it run again."""
import socket, struct, time


class Vice:
    def __init__(self, port=6502, tries=60):
        for _ in range(tries):
            try:
                self.s = socket.create_connection(('127.0.0.1', port), timeout=10); break
            except OSError:
                time.sleep(0.5)
        else:
            raise RuntimeError('VICE binary monitor not answering')
        self.rid = 0
        banks = self.cmd(0x82)                       # banks available
        n = struct.unpack_from('<H', banks)[0]; i = 2; self.banks = {}
        for _ in range(n):
            size = banks[i]; bid, ln = struct.unpack_from('<HB', banks, i + 1)
            self.banks[banks[i + 4:i + 4 + ln].decode()] = bid
            i += 1 + size
        self.go()

    def _recv(self, n):
        b = b''
        while len(b) < n:
            c = self.s.recv(n - len(b))
            if not c: raise ConnectionError('VICE closed the monitor')
            b += c
        return b

    def cmd(self, kind, body=b''):
        self.rid += 1
        self.s.sendall(struct.pack('<BBIIB', 2, 2, len(body), self.rid, kind) + body)
        while True:                                  # skip events (stopped etc.)
            hdr = self._recv(12)
            _, _, ln, rtype, err, rid = struct.unpack('<BBIBBI', hdr)
            data = self._recv(ln)
            if rid == self.rid:
                if err: raise RuntimeError(f'monitor command {kind:#x}: error {err:#x}')
                return data

    def go(self):
        self.cmd(0xAA)                               # exit the monitor: run

    def read(self, addr, n, bank='cpu'):
        out = b''
        while n:
            k = min(n, 0x1000)
            d = self.cmd(0x01, struct.pack('<BHHBH', 0, addr, addr + k - 1, 0, self.banks[bank]))
            out += d[2:2 + k]; addr += k; n -= k
        self.go()
        return out

    def write(self, addr, data, bank='cpu'):
        data = bytes(data)
        self.cmd(0x02, struct.pack('<BHHBH', 0, addr, addr + len(data) - 1, 0, self.banks[bank]) + data)
        self.go()

    def resource(self, name, value):
        n = name.encode()
        if isinstance(value, int):
            v = struct.pack('<I', value); body = struct.pack('<BB', 1, len(n)) + n + bytes([len(v)]) + v
        else:
            v = value.encode(); body = struct.pack('<BB', 0, len(n)) + n + bytes([len(v)]) + v
        self.cmd(0x52, body); self.go()

    def reset(self):
        self.cmd(0xCC, b'\x00'); self.go()           # soft reset

    def quit(self):
        try: self.cmd(0xBB)
        except (OSError, ConnectionError): pass
