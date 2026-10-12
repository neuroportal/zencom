#!/usr/bin/env python3
"""Manage ZenCom's BBS list (bbslist.seq) from the Mac.

The C64 reads BBSLIST (SEQ) from the Ultimate's SoftIEC drive, which is
/SD/ZenCom/bbslist.seq on the SD card: plain text, one board a line,
NAME|HOST:PORT|A or P[|*][|note]  (A = ANSI-80, P = PETSCII-40, * = bookmark,
listed first), # for comments.  ZenCom rewrites the file when you bookmark,
add, delete or edit a note on the C64.

  python3 tools/bbslist.py upload [file]       # default data/bbslist.seq
  python3 tools/bbslist.py download [file]     # what the C64 has now
  python3 tools/bbslist.py from-syncterm syncterm.lst > data/bbslist.seq

C64_IP (or C64_IP = ... in local.mk) and ZENCOM_DIR (default SD/ZenCom) select
the machine and folder.  ZenCom cuts names to 19 characters, hosts to 42
and notes to 60, and holds at most 64 boards.
"""
import configparser, ftplib, io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def _c64_ip():
    """C64_IP, else C64_IP = ... in local.mk (git-ignored); '' if neither."""
    ip = os.environ.get('C64_IP', '')
    if not ip:
        try:
            for line in open(os.path.join(ROOT, 'local.mk')):
                k, _, v = line.partition('=')
                if k.strip() == 'C64_IP': ip = v.strip()
        except OSError:
            pass
    return ip

IP = _c64_ip()
DIR = os.environ.get('ZENCOM_DIR', 'SD/ZenCom')
URL = f'ftp://{IP}/{DIR}/bbslist.seq'
REMOTE = f'/{DIR}/bbslist.seq'


def ftp():
    """Python's FTP client, not curl: no child process to crash on macOS."""
    if not IP: sys.exit('Set C64_IP (or put C64_IP = <address> in local.mk)')
    f = ftplib.FTP(IP, timeout=15)
    f.login()
    return f
DEFAULT = os.path.join(ROOT, 'data', 'bbslist.seq')


def check(text):
    """Warn about lines ZenCom would cut or skip."""
    n = 0
    for i, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.startswith('#'): continue
        f = line.split('|')
        if len(f) < 2 or not f[1].strip():
            print(f'line {i}: no host, ZenCom skips it', file=sys.stderr); continue
        n += 1
        if len(f[0]) > 19: print(f'line {i}: name cut to 19: {f[0][:19]}', file=sys.stderr)
        if len(f[1]) > 42: print(f'line {i}: host cut to 42', file=sys.stderr)
        if ':' not in f[1]: print(f'line {i}: no port (the Ultimate defaults to 80)', file=sys.stderr)
        if len(f) > 4 and len(f[4]) > 60: print(f'line {i}: note cut to 60', file=sys.stderr)
    if n > 64: print(f'{n} boards: ZenCom loads the first 64', file=sys.stderr)
    return n


def from_syncterm(path):
    """syncterm.lst: one [section] per BBS with Address, Port, ScreenMode..."""
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.read(path, encoding='latin-1')
    out = []
    for name in cp.sections():
        sec = cp[name]
        host = sec.get('Address', '').strip()
        if not host: continue
        if sec.get('ConnectionType', 'Telnet').strip().lower() not in ('telnet', 'rlogin', ''):
            continue                                   # SSH etc: not via the modem
        port = sec.get('Port', '23').strip() or '23'
        mode = 'P' if any(k in sec.get('ScreenMode', '').upper() for k in ('C64', 'C128')) else 'A'
        out.append(f'{name.strip()[:19]}|{host}:{port}|{mode}')
    return '\n'.join(out) + '\n'


def main():
    if len(sys.argv) < 2: sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == 'upload':
        path = sys.argv[2] if len(sys.argv) > 2 else DEFAULT
        n = check(open(path, encoding='latin-1').read())
        with ftp() as f: f.storbinary(f'STOR {REMOTE}', open(path, 'rb'))
        print(f'uploaded {n} boards to {URL}')
    elif cmd == 'download':
        buf = io.BytesIO()
        with ftp() as f: f.retrbinary(f'RETR {REMOTE}', buf.write)
        data = buf.getvalue()
        if len(sys.argv) > 2: open(sys.argv[2], 'wb').write(data)
        else: sys.stdout.write(data.decode('latin-1'))
    elif cmd == 'from-syncterm':
        text = from_syncterm(sys.argv[2])
        check(text)
        sys.stdout.write(text)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
