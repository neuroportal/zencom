"""A Hayes-style modem for VICE, so ZenCom can be tested in the emulator
the way users run it (SwiftLink cartridge or user-port Wi-Fi modem).

VICE connects to it as its RS232 device (-rsdev1 127.0.0.1:25232, with
-rsdev1ip232 so DTR and DCD travel as the ip232 protocol does: $FF $00 /
$FF $01 for the line state, $FF $FF for a literal $FF).

Command mode: echo, AT / ATZ / ATE / ATH -> OK, ATI -> a banner,
ATD[T|P]host:port -> CONNECT then data mode (DCD on).  Data mode ends
when the far end closes (NO CARRIER, DCD off) or DTR drops (hang up).
"""
import select, socket, sys, threading, time

BANNER = b'ZENCOM TEST MODEM (VICE)'


class Modem:
    def __init__(self, conn, log):
        self.c, self.log, self.ip232 = conn, log, True
        self.remote, self.line, self.dtr, self.pend = None, b'', True, b''

    # ---- the C64 side (ip232)
    def to_c64(self, data):
        if self.ip232: data = data.replace(b'\xff', b'\xff\xff')
        self.c.sendall(data)

    def dcd(self, on):
        if self.ip232: self.c.sendall(b'\xff' + (b'\x01' if on else b'\x00'))

    def from_c64(self, data):
        """Strip ip232 escapes; returns the data bytes, notes DTR."""
        data = self.pend + data; self.pend = b''
        out, i = bytearray(), 0
        while i < len(data):
            b = data[i]; i += 1
            if b == 0xFF and self.ip232:
                if i >= len(data): self.pend = b'\xff'; break   # the escape's 2nd byte
                n = data[i]; i += 1                             # comes next time
                if n == 0xFF: out.append(0xFF)
                else:
                    self.dtr = bool(n & 1)
                    self.log(f'DTR {"on" if self.dtr else "off"}')
                continue
            out.append(b)
        return bytes(out)

    def reply(self, text):
        self.to_c64(b'\r\n' + text + b'\r\n')

    # ---- commands
    def command(self, line):
        u = line.strip().upper()
        self.log(f'cmd {u!r}')
        if not u.startswith(b'AT'):
            return
        u = u[2:]
        if u.startswith(b'D'):
            target = u[1:].lstrip(b'TP ').decode('latin-1').strip()
            host, _, port = target.rpartition(':')
            if not host: host, port = target, '23'
            try:
                self.remote = socket.create_connection((host, int(port)), timeout=10)
                self.remote.settimeout(None)
            except (OSError, ValueError) as e:
                self.log(f'dial {target}: {e}')
                self.reply(b'NO ANSWER'); return
            self.reply(b'CONNECT 9600'); self.dcd(True)
            return
        if u.startswith(b'I'): self.reply(BANNER); self.reply(b'OK'); return
        self.reply(b'OK')

    def hang_up(self, why):
        self.log(f'hang up: {why}')
        try: self.remote.close()
        except OSError: pass
        self.remote = None
        self.dcd(False)
        self.reply(b'NO CARRIER')

    def run(self):
        self.dcd(False)
        while True:
            socks = [self.c] + ([self.remote] if self.remote else [])
            r, _, _ = select.select(socks, [], [], 0.5)
            if self.c in r:
                raw = self.c.recv(4096)
                if not raw: break
                data = self.from_c64(raw)
                if self.remote:
                    if not self.dtr: self.hang_up('DTR'); continue
                    if data: self.remote.sendall(data)
                else:
                    for b in data:
                        if b in (8, 20):                    # BS / DEL: echo a BS
                            self.line = self.line[:-1]; self.to_c64(b'\x08')
                        elif b == 13:
                            self.to_c64(b'\r'); line, self.line = self.line, b''
                            self.command(line)
                        elif b >= 32:
                            self.line += bytes([b & 0x7F]); self.to_c64(bytes([b]))
            if self.remote and self.remote in r:
                try: data = self.remote.recv(4096)
                except OSError: data = b''
                if not data: self.hang_up('far end'); continue
                self.to_c64(data)
        if self.remote: self.remote.close()


def serve(port=25232, log=print, once=False):
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', port)); srv.listen(1)
    log(f'modem on {port}')
    while True:
        conn, _ = srv.accept()
        log('VICE connected')
        try: Modem(conn, log).run()
        except OSError as e: log(f'modem: {e}')
        conn.close()
        if once: break


if __name__ == '__main__':
    serve(int(sys.argv[1]) if len(sys.argv) > 1 else 25232)
