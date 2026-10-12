#!/usr/bin/env python3
"""Hardware smoke test for ZenCom on a C64 Ultimate, driven over its REST API.

It loads dist/zencom.prg, types keys into the KERNAL keyboard buffer, and
reads the screen back (text mode from $0400, the ANSI-80 bitmap from $6000
decoded with the same font as the emulator tests).  It cannot hear the SID
or judge colours, so those still need a person.

  make && python3 tools/hwtest.py            # offline checks (modem only)
  python3 tools/hwtest.py --online           # also dials a real board

C64_IP (or C64_IP = ... in local.mk) selects the machine.
"""
import os, sys, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import gen_font

def _c64_ip():
    """The Ultimate's address: C64_IP, else C64_IP = ... in local.mk (git-ignored)."""
    ip = os.environ.get('C64_IP')
    if not ip:
        try:
            for line in open(os.path.join(ROOT, 'local.mk')):
                k, _, v = line.partition('=')
                if k.strip() == 'C64_IP': ip = v.strip()
        except OSError:
            pass
    if not ip:
        raise SystemExit('Set C64_IP (or put C64_IP = <address> in local.mk)')
    return ip

IP = _c64_ip()
BASE = f'http://{IP}/v1'
LBL = {}
for line in open(os.path.join(ROOT, 'build', 'zencom.lbl')):
    _, addr, name = line.split()
    LBL[name.lstrip('.')] = int(addr, 16)


def http(method, path, data=None, tries=3):
    for i in range(tries):
        try:
            req = urllib.request.Request(BASE + path, data=data, method=method)
            with urllib.request.urlopen(req, timeout=8) as r:
                return r.read()
        except OSError:
            if i == tries - 1: raise
            time.sleep(1)        # the first request after it wakes can fail


def read(addr, n):
    out = b''
    while n:                     # keep requests modest
        k = min(n, 4096)
        out += http('GET', f'/machine:readmem?address={addr:04X}&length={k}')
        addr += k; n -= k
    return out


def write(addr, data):
    http('PUT', f'/machine:writemem?address={addr:04X}&data={bytes(data).hex()}')


def var(name): return read(LBL[name], 1)[0]


FTP_DIR = os.environ.get('ZENCOM_DIR', 'SD/ZenCom')

def _ftp():
    """Python's own FTP client: no curl child process (macOS crashes a
    forked Python once it has used the network: "Python quit unexpectedly")."""
    import ftplib
    f = ftplib.FTP(IP, timeout=15)
    f.login()
    return f

def ftp_get(name):
    import io
    buf = io.BytesIO()
    try:
        with _ftp() as f: f.retrbinary(f'RETR /{FTP_DIR}/{name}', buf.write)
    except Exception:
        return b''
    return buf.getvalue()

def ftp_list():
    try:
        with _ftp() as f: return '\n'.join(f.nlst(f'/{FTP_DIR}/')).encode()
    except Exception:
        return b''

def ftp_delete(name):
    try:
        with _ftp() as f: f.delete(f'/{FTP_DIR}/{name}')
    except Exception:
        pass

def ftp_get_any(prefix):
    for name in ftp_list().split(b'\n'):
        name = name.rsplit(b'/', 1)[-1]
        if name.lower().startswith(prefix.encode()):
            return ftp_get(name.decode())
    return b''

def ftp_put(name, data):
    """Upload and read back: a silent FTP hiccup once left 0-byte files."""
    import io
    for _ in range(3):
        try:
            with _ftp() as f: f.storbinary(f'STOR /{FTP_DIR}/{name}', io.BytesIO(data))
        except Exception:
            pass
        if ftp_get(name) == data: return
        time.sleep(2)
    raise RuntimeError(f'FTP upload of {name} did not verify')


def keys(codes, gap=0.05):
    """Type PETSCII codes via the keyboard buffer ($0277, count in $C6)."""
    codes = list(codes)
    while codes:
        chunk, codes = codes[:8], codes[8:]
        for _ in range(100):                     # wait for room
            if read(0xC6, 1)[0] == 0: break
            time.sleep(0.05)
        write(0x0277, chunk)
        write(0xC6, [len(chunk)])
        time.sleep(gap)


def typed(text):
    """Unshifted letters as the keyboard sends them ($41-$5A), CR = Return."""
    return [ord(c.upper()) if c.isalpha() else (13 if c == '\n' else ord(c)) for c in text]


def screen40():
    """PETSCII text screen as text (screen codes, either character set)."""
    raw = read(0x0400, 1000)
    rows = []
    for r in range(25):
        s = ''
        for b in raw[r * 40:(r + 1) * 40]:
            c = b & 0x7F
            if 1 <= c <= 26: s += chr(c + 64)
            elif 0x41 <= c <= 0x5A: s += chr(c)          # capitals, lower/upper set
            elif 0x20 <= c <= 0x3F: s += chr(c)
            elif c == 0: s += '@'
            else: s += '.'
        rows.append(s.rstrip())
    return rows


def screen80(nrows=24):
    """The ANSI-80 bitmap read back as text (the top nrows rows: less to
    read over the network)."""
    bm = read(0x6000, nrows * 320)
    rev = {}
    for i, g in enumerate(gen_font.glyphs):
        rev.setdefault(tuple(gen_font.bits(r) >> 4 for r in g), i)
    rows = []
    for r in range(nrows):
        s = ''
        for c in range(80):
            cell = []
            for py in range(8):
                b = bm[r * 320 + (c // 2) * 8 + py]
                cell.append((b >> 4) if c % 2 == 0 else b & 15)
            cell[7] = 0                                  # ignore the cursor row
            g = rev.get(tuple(cell)) or rev.get(tuple(x ^ 15 for x in cell))
            s += chr(g + 32) if g is not None and g < 95 else ' '
        rows.append(s.rstrip())
    return rows


def wait_for(fn, needle, secs, every=0.7):
    end = time.time() + secs
    while time.time() < end:
        rows = fn()
        if any(needle.lower() in r.lower() for r in rows): return rows
        time.sleep(every)
    return None


# saves (temp file, status, scratch, rename) must finish before we look over
# FTP: FTP access to the folder mid-rename can make the C64's save fail
SAVE_SECS = float(os.environ.get('ZENCOM_SAVE_SECS', '7'))

RESULTS = []
def check(name, ok, detail=''):
    RESULTS.append((name, ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  ({detail})' if detail and not ok else ''))


def transfer_tests():
    """Download and upload over XMODEM against tools/xfr_server.py on this Mac.
    No memory polling while ZenCom writes to the drive (DMA vs IEC timing)."""
    import socket, threading, tempfile
    import xfr_server
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as u:   # our address on the
        u.connect((socket.gethostbyname(IP), 80))                 # C64's network (no
        mac = os.environ.get('MAC_IP') or u.getsockname()[0]      # child process)
    data = xfr_server.test_data(5000)
    up_data = bytes((i * 11 + 3) & 255 for i in range(700)) + b'\xff\r\x00end'
    saved = os.path.join(tempfile.mkdtemp(), 'up.bin')
    log = []
    threading.Thread(target=xfr_server.serve, args=(6464, saved, data, True, log.append),
                     daemon=True).start()
    global FTP_DIR
    base = FTP_DIR
    up_dir = base + '/UPLOADS' if '--folders' in sys.argv else base
    dl_dir = base + '/DOWNLOADS' if '--folders' in sys.argv else base
    FTP_DIR = up_dir
    ftp_put('utest.seq', up_data)                         # a SEQ file to upload
    FTP_DIR = dl_dir
    for name in ftp_list().split(b'\n'):
        name = name.rsplit(b'/', 1)[-1]
        if name.lower().startswith((b'xtest', b'ptest')): ftp_delete(name.decode())
    time.sleep(1)
    keys([0x89]); time.sleep(1.5)                         # F2: ACIA + ANSI
    keys(typed(f'atd {mac}:6464\n'))
    rows = wait_for(screen80, 'ZENCOM TEST BOARD', 25)
    check('transfer: dialled the test board', rows is not None, f'mac={mac} log={log[-3:]}')
    if rows is None: return finish()
    # ---- download
    keys(typed('d')); time.sleep(1)
    keys([0xAC]); time.sleep(1.5)                         # C=+D
    check('transfer: C=+D opens the download screen', any('DOWNLOAD' in r for r in screen40()))
    keys(typed('x'))                                      # protocol; the transfer starts
    time.sleep(int(os.environ.get('ZENCOM_XFR_SECS', '60')))   # no polling: disk busy
    rows = screen40()
    check('transfer: name asked at the end', any('NAME THE FILE' in r for r in rows), repr(rows[:3]))
    keys([0x93] + typed('xtest\n')); time.sleep(SAVE_SECS)    # name it: CLR, type, Return
    rows = screen80()                                     # back on the board's screen
    check('transfer: back on the board, "Saved" said', any('Saved XTEST' in r for r in rows)
          and any('ZENCOM TEST BOARD' in r for r in rows), repr([r for r in rows if r.strip()][-4:]) + repr(log[-3:]))
    got = ftp_get_any('xtest')
    check('transfer: downloaded file matches byte for byte',
          got[:len(data)] == data and set(got[len(data):]) <= {0x1A} and len(got) % 128 == 0,
          f'{len(got)} bytes; first diff at ' +
          str(next((i for i in range(min(len(got), len(data))) if got[i] != data[i]), None)))
    # ---- upload
    keys(typed('u')); time.sleep(1.5)
    keys([0xB8]); time.sleep(6)                           # C=+U: reads the directory
    rows = screen40()
    names = [r[1:17].strip() for r in rows[2:22]]
    check('transfer: C=+U lists the uploads folder', 'UTEST' in names, repr(names))
    if 'UTEST' in names:
        keys([0x11] * names.index('UTEST')); time.sleep(0.5)
        keys([13]); time.sleep(0.8)
        keys(typed('x'))
        time.sleep(int(os.environ.get('ZENCOM_XFR_SECS', '60')) // 2)
        rows = screen40()
        check('transfer: upload reported', any('SENT' in r for r in rows), repr(rows[22:24]) + repr(log[-3:]))
        up = open(saved, 'rb').read() if os.path.exists(saved) else b''
        check('transfer: uploaded file matches byte for byte',
              up[:len(up_data)] == up_data and set(up[len(up_data):]) <= {0x1A}, f'{len(up)} bytes')
        keys(typed(' ')); time.sleep(1.5)
        # ---- the same upload as XMODEM-1K (K)
        if os.path.exists(saved): os.remove(saved)
        keys(typed('u')); time.sleep(1.5)
        keys([0xB8]); time.sleep(6)
        names = [r[1:17].strip() for r in screen40()[2:22]]
        if 'UTEST' in names:
            keys([0x11] * names.index('UTEST')); time.sleep(0.5)
            keys([13]); time.sleep(0.8)
            keys(typed('k'))
            time.sleep(int(os.environ.get('ZENCOM_XFR_SECS', '60')) // 2)
            rows = screen40()
            check('1K: upload reported', any('SENT' in r for r in rows), repr(rows[22:24]) + repr(log[-3:]))
            up = open(saved, 'rb').read() if os.path.exists(saved) else b''
            check('1K: uploaded file matches, one 1K block', up[:len(up_data)] == up_data
                  and set(up[len(up_data):]) <= {0x1A} and len(up) == 1024, f'{len(up)} bytes')
            keys(typed(' ')); time.sleep(1.5)
    # ---- Punter: the same, both ways
    secs = int(os.environ.get('ZENCOM_XFR_SECS', '60'))
    keys(typed('p')); time.sleep(1)
    keys([0xAC]); time.sleep(1.5)
    keys(typed('p'))                                      # protocol: Punter; it starts
    time.sleep(secs)
    rows = screen40()
    check('punter: type from the board', any('FROM THE BOARD' in r for r in rows), repr(rows[5:7]))
    keys([0x93] + typed('ptest\n')); time.sleep(SAVE_SECS)
    rows = screen80()
    check('punter: download reported', any('Saved PTEST' in r for r in rows), repr([r for r in rows if r.strip()][-3:]) + repr(log[-3:]))
    got = ftp_get_any('ptest')
    check('punter: downloaded file matches exactly', got == data, f'{len(got)} bytes')
    keys(typed('o')); time.sleep(1.5)
    keys([0xB8]); time.sleep(6)
    names = [r[1:17].strip() for r in screen40()[2:22]]
    check('punter: C=+U lists the uploads folder', 'UTEST' in names, repr(names))
    if 'UTEST' in names:
        keys([0x11] * names.index('UTEST')); time.sleep(0.5)
        keys([13]); time.sleep(0.8)
        keys(typed('p'))
        time.sleep(secs // 2)
        rows = screen40()
        check('punter: upload reported', any('SENT' in r for r in rows), repr(rows[22:24]) + repr(log[-3:]))
        up = open(saved + '.punter', 'rb').read() if os.path.exists(saved + '.punter') else b''
        check('punter: uploaded file matches exactly', up == up_data, f'{len(up)} bytes')
        keys(typed(' ')); time.sleep(1.5)
    # ---- a C64-style board: GOO nudge, C=+D starts Punter, name from its list
    keys(typed('g')); time.sleep(2)
    keys(typed('123\n')); time.sleep(5)
    check('nudge: "press C=+D" shown', any('press C=+D' in r for r in screen80()))
    keys([0xAC]); time.sleep(3)                           # C=+D: the start screen waits
    rows = screen40()
    check('start: the file guessed and Punter offered', '4!SPY VS SPY' in rows[6]
          and 'THE BOARD IS SENDING' in rows[10] and 'L CHANGES' in rows[3] and 'SAVES TO' in rows[1], repr(rows[1:12]))
    keys([13])                                            # Return: receive
    time.sleep(secs)
    rows = screen40()
    check('name: from the list line with the number typed', '4!SPY VS SPY' in rows[5], repr(rows[5:16]))
    keys([13]); time.sleep(SAVE_SECS)                     # Return: saved
    rows = screen80()
    check('name: saved as 4!SPY VS SPY, back on the board', any('Saved 4!SPY VS SPY' in r for r in rows)
          and any('GOO' in r for r in rows), repr([r for r in rows if r.strip()][-5:]))
    got = ftp_get_any('4!spy')
    check('name: file matches', got == data, f'{len(got)} bytes')
    # ---- Multi-Punter: a batch of two, each named from its header
    for name in ftp_list().split(b'\n'):
        name = name.rsplit(b'/', 1)[-1]
        if name.lower().startswith(b'multi'): ftp_delete(name.decode())
    keys(typed('m')); time.sleep(2)
    keys([0xAC]); time.sleep(3)                           # C=+D, then M: the batch
    keys(typed('m'))
    time.sleep(secs)
    rows = screen80()
    check('multi: "Saved 2 FILE(S)", back on the board', any('Saved 2 FILE(S)' in r for r in rows),
          repr([r for r in rows if r.strip()][-4:]) + repr(log[-6:]))
    got = ftp_get_any('multi one')
    check('multi: first file, named from its header', got == data, f'{len(got)} bytes')
    got = ftp_get_any('multi-two')
    check('multi: second file, its comma made safe', got == xfr_server.MULTI2, f'{len(got)} bytes')
    keys([0x87]); time.sleep(2)                           # F5: hang up
    for name in ftp_list().split(b'\n'):                       # (FTP_DIR: the downloads)
        name = name.rsplit(b'/', 1)[-1]
        if name.lower().startswith((b'ptest', b'xtest', b'4!spy')): ftp_delete(name.decode())
    FTP_DIR = up_dir
    ftp_delete('utest.seq')
    FTP_DIR = base
    return finish()


def busy_test():
    """Call, F5, call again: no stray "call ended" on the second call; and a
    board that hangs up straight after its text gets the notice after it."""
    import socket, threading, xfr_server
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as u:
        u.connect((socket.gethostbyname(IP), 80)); mac = os.environ.get('MAC_IP') or u.getsockname()[0]
    log = []
    threading.Thread(target=xfr_server.serve, args=(6464, None, b'', False, log.append), daemon=True).start()
    time.sleep(1)
    def call():
        for _ in range(3):                                # F1: PETSCII
            keys([0x85]); time.sleep(2)
            if var('mode') == 1 and not any('TO START' in r for r in screen40()): break
        keys(typed(f'atd {mac}:6464\n'))
        return wait_for(screen40, 'TEST BOARD', 25) is not None
    check('busy: first call', call(), repr(log[-3:]))
    keys([0x87]); time.sleep(3)                           # F5: hang up, menu
    check('busy: second call', call(), repr(log[-3:]))
    time.sleep(5)
    check('busy: no stray "call ended" on the second call',
          not any('CALL ENDED' in r for r in screen40()) and var('online') == 1)
    keys(typed('c'))                                      # a page, then the board clears
    check('busy: the board cleared to page two', wait_for(screen40, 'PAGE TWO', 10) is not None
          and not any('PAGE ONE' in r for r in screen40()))
    keys([0xBF]); time.sleep(1.5)                         # C=+B: the cleared page is there
    rows = screen40()
    check('C=+B keeps the page the board cleared', 'SCROLL-BACK' in rows[24]
          and any('PAGE ONE END' in r for r in rows[:24]), repr(rows[18:25]))
    keys(typed(' ')); time.sleep(1)
    check('scroll-back: back to page two', any('PAGE TWO' in r for r in screen40()))
    keys(typed('b'))                                      # the board: text, then gone
    rows = wait_for(screen40, 'CALL ENDED', 20) or screen40()
    text = '\n'.join(rows)
    check("busy: notice after the board's last words",
          'CALL ENDED' in text and 'LAST WORDS' in text and text.index('LAST WORDS') < text.index('CALL ENDED'))
    keys([0x87]); time.sleep(2)
    return finish()


def browse_tests():
    """C=+U / C=+D folder browsing, offline (needs --folders' settings)."""
    import ftplib, io
    global FTP_DIR
    base = FTP_DIR
    with _ftp() as f:
        try: f.mkd(f'/{base}/UPLOADS/SUB')
        except ftplib.error_perm: pass
        f.storbinary(f'STOR /{base}/UPLOADS/SUB/btest.seq', io.BytesIO(b'browse'))
    def rows(): return screen40()
    def row1(): return rows()[1].strip()
    keys([0x89]); time.sleep(1.5)                         # F2: a session (no call)
    keys([0xB8]); time.sleep(5)                           # C=+U
    r = rows()
    names = [x[1:17].strip() for x in r[2:22]]
    check('browse: C=+U shows the uploads folder', 'UPLOADS' in r[1] and 'SUB' in names, repr(r[1]) + repr(names))
    print('   listing:', [x.rstrip() for x in r[2:8]])
    if 'SUB' in names:
        keys([0x11] * names.index('SUB')); time.sleep(0.5)
        keys([13]); time.sleep(4)                         # Return on a folder: in
        r = rows()
        check('browse: Return opens a folder', 'UPLOADS/SUB' in r[1] and any('BTEST' in x for x in r[2:22]), repr(r[1:4]))
        keys([0x14]); time.sleep(4)                       # DEL: up
        r = rows()
        check('browse: DEL goes up', 'UPLOADS' in r[1] and 'SUB' not in r[1] and any('SUB' in x for x in r[2:22]), repr(r[1:4]))
    keys(typed('d')); time.sleep(5)                       # D: next drive that answers
    r = rows()
    print('   after D:', repr(r[1]), repr(r[22]))
    check('browse: D moves to another drive (or says why not)', 'DRIVE 11' not in r[1] or r[22].strip() != '', repr(r[1]) + repr(r[22]))
    keys([0x5F]); time.sleep(1.5)                         # <- : back to the session
    keys([0xAC]); time.sleep(2)                           # C=+D
    check('browse: C=+D shows where it goes', 'SAVES TO' in rows()[1] and 'DOWNLOADS' in rows()[2], repr(rows()[1:3]))
    keys(typed('l')); time.sleep(4)                       # L: browse
    check('browse: L opens the browser', 'S SAVE HERE' in rows()[23], repr(rows()[23]))
    keys([0x14]); time.sleep(4)                           # up to ZenCom's folder
    check("browse: DEL to ZenCom's folder", "ZENCOM'S FOLDER" in row1(), repr(row1()))
    keys(typed('s')); time.sleep(1.5)                     # save here
    check('browse: S keeps it for the download', "ZENCOM'S FOLDER" in rows()[2] and 'L CHANGES' in rows()[3], repr(rows()[1:4]))
    keys([0x5F]); time.sleep(1.5)
    keys([0xAC]); time.sleep(2)                           # again: the session remembers
    check('browse: the choice lasts the session', "ZENCOM'S FOLDER" in rows()[2], repr(rows()[1:3]))
    keys([0x5F]); time.sleep(1.5)
    with _ftp() as f:
        f.delete(f'/{base}/UPLOADS/SUB/btest.seq'); f.rmd(f'/{base}/UPLOADS/SUB')
    return finish()


def finish():
    bad = [n for n, ok in RESULTS if not ok]
    print(f'\n{len(RESULTS) - len(bad)}/{len(RESULTS)} passed')
    sys.exit(1 if bad else 0)


def main():
    online = '--online' in sys.argv
    # Start ZenCom as an Ultimate user would: from BASIC, off the SoftIEC
    # drive (so it knows its home drive).  No memory polling while the
    # drive is busy: REST reads pause the CPU (DMA) and can break the
    # KERNAL's timing on the IEC bus.
    ftp_put('zencom.prg', open(os.path.join(ROOT, 'dist', 'zencom.prg'), 'rb').read())
    ftp_put('zencom.xfr', open(os.path.join(ROOT, 'dist', 'zencom.xfr'), 'rb').read())
    global USER_LIST, USER_CFG, USER_MAC, USER_PWD
    for name in ftp_list().split(b'\n'):                       # the user's settings, if any
        name = name.rsplit(b'/', 1)[-1].decode()
        if name.lower().startswith('zencom.cfg'):
            USER_CFG = (name, ftp_get(name))
            open(os.path.join(ROOT, 'build', 'zencom.cfg.backup'), 'wb').write(USER_CFG[1])
        if name.lower().startswith('zencom.mac'):                  # (the user's macros)
            USER_MAC = (name, ftp_get(name))
            open(os.path.join(ROOT, 'build', 'zencom.mac.backup'), 'wb').write(USER_MAC[1])
        if name.lower().startswith('zencom.pwd'):                  # (the user's logins:
            USER_PWD = (name, ftp_get(name))                       #  build/ is never committed)
            open(os.path.join(ROOT, 'build', 'zencom.pwd.backup'), 'wb').write(USER_PWD[1])
    USER_LIST = ftp_get_any('bbslist')                    # the user's list: put back at the end
    if not USER_LIST: raise SystemExit('could not read bbslist.seq to back it up: not starting')
    open(os.path.join(ROOT, 'build', 'bbslist.backup.seq'), 'wb').write(USER_LIST)
    ftp_put('bbslist.seq', open(os.path.join(ROOT, 'data', 'bbslist.seq'), 'rb').read())
    for name in ftp_list().split(b'\n'):                       # (backed up above) tests start
        name = name.rsplit(b'/', 1)[-1]                   # with no settings file
        if name.lower().startswith((b'zencom.cfg', b'cfgtmp', b'zencom.mac', b'mactmp',
                                    b'zencom.pwd', b'pwdtmp')): ftp_delete(name.decode())
    if '--folders' in sys.argv:                           # downloads/uploads in short-named
        ftp_put('zencom.cfg.seq', b'DOWN=,DOWNLOADS\nUP=,UPLOADS\n')   # folders inside ZenCom's
    launch()
    check('menu shown', wait_for(screen40, 'TO START', 12) is not None)
    check('home drive is 11 (loaded from it)', var('home_dev') == 11, f'home_dev={var("home_dev")}')
    time.sleep(2.5)                                       # jingle

    if '--transfer' in sys.argv:
        return transfer_tests()
    if '--busy' in sys.argv:                              # call-ended notice after the text
        return busy_test()
    if '--browse' in sys.argv:                            # the transfer screens' folder browser
        return browse_tests()
    if '--directory' in sys.argv:                         # just the directory checks
        return directory_tests()
    keys([0x89])                                          # F2: ACIA + ANSI
    time.sleep(1.5)
    check('F2 -> ANSI mode', var('mode') == 0 and var('driver') == 0)
    keys(typed('ati\n'))
    rows = wait_for(screen80, 'MODEM EMULATION', 12)
    check('ANSI: ATI answers (lower case)', rows is not None)
    keys([0xB4]); time.sleep(1.5)                         # C=+H: help over the call
    check('ANSI: C=+H shows help', any('KEYS + HELP' in r for r in screen40()))
    keys(typed(' ')); time.sleep(1)
    check('ANSI: any key: the call screen is back', read(0xD018, 1)[0] & 0xFE == 0x18
          and wait_for(screen80, 'MODEM EMULATION', 3) is not None)
    keys(typed('\n') * 26); time.sleep(1.5)              # scroll the reply away
    keys([0xAE]); time.sleep(0.5)                         # C=+S: pause
    check('C=+S pauses (red border)', var('paused') == 1 and read(0xD020, 1)[0] & 15 == 2)
    keys(typed('ati\n')); time.sleep(3)
    check('paused: the reply waits', not any('MODEM EMULATION' in r for r in screen80()))
    keys([0xAE])                                          # carry on
    check('C=+S again: the reply arrives', wait_for(screen80, 'MODEM EMULATION', 6) is not None
          and var('paused') == 0)

    keys([0x87])                                          # F5: back to menu
    check('F5 -> menu', wait_for(screen40, 'TO START', 6) is not None)

    keys([0x85])                                          # F1: ACIA + PETSCII
    time.sleep(1.5)
    check('F1 -> PETSCII mode', var('mode') == 1)
    keys(typed('ati\n'))
    rows = wait_for(screen40, 'MODEM EMULATION', 6)
    check('PETSCII: ATI answers', rows is not None)
    write(0xD018, [0x15])                                 # as if a board sent $8E
    keys([0xB6]); time.sleep(0.6)                         # C=+L: lower case lock
    check('C=+L locks lower case (blue border)', var('caselock') == 1 and read(0xD018, 1)[0] == 0x17
          and read(0xD020, 1)[0] & 15 == 6)
    keys([0xB6]); time.sleep(0.6)
    check('C=+L again: off', var('caselock') == 0 and read(0xD020, 1)[0] & 15 == 0)
    keys([0xB4]); time.sleep(1.5)                         # C=+H in PETSCII
    check('PETSCII: C=+H shows help', any('KEYS + HELP' in r for r in screen40()))
    keys(typed(' ')); time.sleep(1)
    check('PETSCII: any key: the call screen is back', any('MODEM EMULATION' in r for r in screen40()))
    for _ in range(8):                                    # enough to scroll the screen
        keys(typed('ati\n')); time.sleep(0.8)
    time.sleep(1)
    keys([0xBF]); time.sleep(1.5)                         # C=+B: scroll-back
    rows = screen40()
    check('C=+B shows scroll-back', 'SCROLL-BACK' in rows[24] and any('MODEM' in r for r in rows[:24]),
          repr(rows[22:25]) + f' count={var("sb_count")}')
    keys([0x91] * 5); time.sleep(1)                       # older
    check('scroll-back: up moves', var('sb_pos') == 5, f'pos={var("sb_pos")}')
    keys(typed(' ')); time.sleep(1)
    rows = screen40()
    check('scroll-back: any key returns', 'SCROLL-BACK' not in rows[24] and any('MODEM EMULATION' in r for r in rows))

    directory_tests()


def directory_tests():
    # ---- dialling directory (BBS list on the SoftIEC drive)
    original = open(os.path.join(ROOT, 'data', 'bbslist.seq'), 'rb').read()
    keys([0x87])                                          # F5: menu
    wait_for(screen40, 'TO START', 6)
    keys(typed('d'))
    rows = wait_for(screen40, 'DIALLING DIRECTORY', 6)
    check('directory opens', rows is not None)
    n = var('n_ent')
    check('directory: list from USB', var('list_src') == 1 and n > 0, f'n_ent={n} src={var("list_src")}')
    check('directory: rows shown', rows is not None and len(rows[2]) > 10)
    keys([0x11]); time.sleep(0.6)                         # cursor down
    check('directory: bar moves', var('dir_sel') == 1)
    keys(typed('i'))
    check('directory: I shows info', wait_for(screen40, 'BOARD INFO', 4) is not None)
    keys(typed(' '))
    wait_for(screen40, 'DIALLING DIRECTORY', 4)
    keys(typed('b')); time.sleep(SAVE_SECS)                       # bookmark the second board
    saved = ftp_get('bbslist.seq')
    boards = [l for l in original.split(b'\n') if l and not l.startswith(b'#')]   # (the header: not a board)
    second = boards[1].split(b'|')[0]
    check('directory: B bookmarks (saved, listed first)',
          any(l.startswith(second + b'|') and b'|*' in l for l in saved.split(b'\n'))
          and var('dir_sel') == 0, repr(saved[:80]))
    keys(typed('b')); time.sleep(SAVE_SECS)                       # and off again
    check('directory: B again unmarks', not any(b'|*' in l for l in ftp_get('bbslist.seq').split(b'\n')
                                                if not l.startswith(b'#')))
    keys(typed('a')); time.sleep(0.8)                     # add: the same form, blank
    check('directory: A opens the form', any('ADD A BOARD' in r for r in screen40()))
    keys(typed('zzhwtest\n')); time.sleep(0.3)
    keys(typed('example.com\n')); time.sleep(0.3)
    keys(typed('a')); time.sleep(0.3)
    keys(typed('\n\n\n')); time.sleep(SAVE_SECS)                  # no note, no login
    check('directory: A adds a board', var('n_ent') == n + 1, f'n_ent={var("n_ent")}')
    check('directory: added board saved', b'ZZHWTEST|example.com:23|A' in ftp_get('bbslist.seq'))
    keys(typed('i')); time.sleep(0.8)                     # info, then E from there
    keys(typed('e')); time.sleep(0.8)
    check('directory: E from the info screen', any('EDIT BOARD' in r for r in screen40()))
    keys(typed('\n')); time.sleep(0.3)                     # name, address, mode: keep
    keys(typed('\n')); time.sleep(0.3)
    keys(typed('\n')); time.sleep(0.3)
    keys(typed('test note\n\n\n')); time.sleep(SAVE_SECS)           # (no login)
    check('directory: note added via E', b'ZZHWTEST|example.com:23|A||TEST NOTE' in ftp_get('bbslist.seq'),
          repr(ftp_get('bbslist.seq')[-60:]))
    keys(typed('e')); time.sleep(0.8)                     # E: edit in place
    check('directory: E opens the form', any('EDIT BOARD' in r for r in screen40()))
    keys(typed('\n')); time.sleep(0.3)                     # name: keep
    keys([0x1D] * 14 + [0x14] * 14); time.sleep(0.5)      # address: rub it out...
    keys(typed('other.org:64\n')); time.sleep(0.3)         # ...and retype
    keys(typed('p')); time.sleep(0.3)                     # mode: PETSCII
    keys(typed('\n\n\n')); time.sleep(SAVE_SECS)                  # note, login: keep
    check('directory: E edits address and mode, keeps the note',
          b'ZZHWTEST|other.org:64|P||TEST NOTE' in ftp_get('bbslist.seq'), repr(ftp_get('bbslist.seq')[-60:]))
    before = ftp_get('bbslist.seq')
    keys(typed('e')); time.sleep(0.8)
    keys(typed('\n\n\n')); time.sleep(0.5)                # to the note
    keys(typed('abc')); time.sleep(0.3)
    rows = screen40()
    check('directory: edit stays inside the field', rows[0].strip().startswith('ZENCOM') and 'NOTE' in rows[12],
          repr(rows[:2]))
    keys([0x5F]); time.sleep(1.5)                         # <- mid-note: cancel
    check('directory: <- cancels from inside the note', any('DIALLING DIRECTORY' in r for r in screen40())
          and ftp_get('bbslist.seq') == before)
    # ---- a login (made up) for this board: ZENCOM.PWD, keyed by the
    # CRC-32 of its address, so the file names no board
    import zlib
    key = f'{zlib.crc32(b"other.org:64"):08X}'.encode()
    keys(typed('e')); time.sleep(2)
    keys(typed('\n\n\n\n')); time.sleep(0.5)           # name, address, mode, note
    keys(typed('guest\n')); time.sleep(0.3)
    keys(typed('letmein\n')); time.sleep(SAVE_SECS + 3)
    pwd = ftp_get_any('zencom.pwd')
    check('login: saved under the address key', pwd == b'#ZENCOM LOGINS (E IN THE DIRECTORY): KEY|USER|PASSWORD\n' + key + b'|GUEST|LETMEIN\n', repr(pwd))
    check('login: the board list has no password', b'LETMEIN' not in ftp_get('bbslist.seq'))
    keys(typed('e')); time.sleep(2.5)
    rows = screen40()
    check('login: the form shows it, the password as *', 'GUEST' in rows[17] and '*******' in rows[20]
          and 'LETMEIN' not in ''.join(rows), repr(rows[16:22]))
    keys([0x5F]); time.sleep(1.5)
    keys(typed('x')); time.sleep(0.5)
    rows = screen40()
    check('directory: X asks first', any('DELETE ZZHWTEST? Y/N' in r for r in rows), repr(rows[22]))
    keys(typed('y')); time.sleep(SAVE_SECS + 4)
    check('directory: X deletes', var('n_ent') == n and b'ZZHWTEST' not in ftp_get('bbslist.seq'))
    check('login: deleting the board removes its login', key not in ftp_get_any('zencom.pwd'),
          repr(ftp_get_any('zencom.pwd')))
    check('directory: list intact after edits', ftp_get('bbslist.seq').strip() == original.strip())
    write(LBL['list_ro'], [1])                            # pretend the drive refused a save
    keys(typed('a')); time.sleep(0.6)
    check('directory: read-only refuses edits', any('READ-ONLY' in r for r in screen40()) and var('n_ent') == n)
    write(LBL['list_ro'], [0])
    ftp_put('bbslist.seq', original)                      # the seed again (restore_list: the user's)
    check('directory: program file untouched', b'zencom.prg' in ftp_list())
    keys([0x87])                                          # back to the menu

    # ---- settings (S): change the downloads drive, check ZENCOM.CFG
    wait_for(screen40, 'TO START', 6)
    keys(typed('s'))
    check('settings: S opens', wait_for(screen40, 'ZENCOM  SETTINGS', 4) is not None)
    keys(typed('\n\n')); time.sleep(0.3)                   # list drive, list folder
    keys([0x93] + typed('9\n')); time.sleep(0.3)          # downloads drive: 9
    keys(typed('\n\n\n\n\n')); time.sleep(SAVE_SECS)              # the rest (speed last), then save
    cfg = ftp_get_any('zencom.cfg')
    check('settings: saved to ZENCOM.CFG', b'DOWN=9,' in cfg and b'LIST=11,' in cfg and b'HOME=11,' in cfg, repr(cfg))
    check('settings: list still loads', var('n_ent') > 0 and var('list_src') == 1)
    keys(typed('s')); time.sleep(0.8)
    keys(typed('\n\n')); time.sleep(0.3)
    keys([0x93] + typed('7\n\n\n\n\n\n\n')); time.sleep(1.5)  # drive 7: refused
    check('settings: bad drive refused', any('DRIVES ARE 8-30' in r for r in screen40()))
    keys([0x5F]); time.sleep(2)                           # cancel
    after = ftp_get_any('zencom.cfg')
    if after != cfg:                                      # (the FTP read can race the
        time.sleep(3); after = ftp_get_any('zencom.cfg')  # drive: once more)
    check('settings: cancel keeps the saved file', after == cfg, repr(after))
    # ---- macros (M): saved to their own file, ZENCOM.MAC
    wait_for(screen40, 'TO START', 6)
    keys(typed('m'))
    check('macros: M opens', wait_for(screen40, 'ZENCOM  MACROS', 4) is not None)
    keys(typed('hello^\n') + [13] * 7); time.sleep(SAVE_SECS)    # macro 1, then save
    mac = ftp_get_any('zencom.mac')
    check('macros: saved to ZENCOM.MAC', mac == b'#ZENCOM MACROS (M ON THE MENU), PLAIN TEXT\nM1=HELLO^\n', repr(mac))
    check('macros: not in ZENCOM.CFG', b'M1=' not in ftp_get_any('zencom.cfg'))
    for name in ftp_list().split(b'\n'):                       # clean up
        if name.lower().startswith(b'zencom.cfg'):
            ftp_delete(name.decode())

    if "--online" in sys.argv:
        keys(typed('d'))
        wait_for(screen40, 'DIALLING DIRECTORY', 6)
        keys([0x91] * 70); time.sleep(2)                  # the bar to the top (Vertrauen)
        keys([13])                                        # Return: board under the bar
        time.sleep(8)                                     # (no memory reads while it reads
                                                          #  ZENCOM.PWD: DMA vs IEC)

        # during a call: the top of the screen, every 3 s (heavy reads over
        # the Ultimate's Wi-Fi while the modem is busy have dropped it)
        top = lambda: screen80(12)
        rows = wait_for(top, 'Synchronet', 30, 3) if var('mode') == 0 else wait_for(screen40, 'CONNECT', 30, 3)
        check('online: directory dial connects', rows is not None,
              f"mode={var('mode')} sel={var('dir_sel')} " + repr([r for r in (top() if var('mode') == 0 else screen40()) if r.strip()][:6]))
        # one call only: hanging up and redialling the same board straight
        # away has knocked the Ultimate's Wi-Fi out three times (2026-10-12)
        check('online: DSR seen (online flag)', var('online') == 1)
        keys([0x87])                                      # F5: hang up
        check('online: F5 hangs up -> menu', wait_for(screen40, 'TO START', 8) is not None)
        keys([0x85]); time.sleep(1.5)
        keys(typed('ati\n'))
        check('online: modem free after hang-up', wait_for(screen40, 'MODEM EMULATION', 6) is not None)

    bad = [n for n, ok in RESULTS if not ok]
    print(f'\n{len(RESULTS) - len(bad)}/{len(RESULTS)} passed')
    sys.exit(1 if bad else 0)


def launch():
    """Reset and start ZenCom from BASIC, off the SoftIEC drive."""
    http('PUT', '/machine:reset')
    time.sleep(4)
    keys(typed(f'open15,11,15,"cd:/{FTP_DIR.lower()}":close15\n'))   # (ZENCOM_DIR)
    time.sleep(2)
    keys(typed('load"zencom"'))
    keys(typed(',11\nrun\n'))                            # RUN waits in the buffer
    time.sleep(int(os.environ.get('ZENCOM_LOAD_SECS', '45')))   # load + BBS list


USER_LIST = None
USER_CFG = None
USER_MAC = None
USER_PWD = None

def restore_list():
    """Put the user's list and settings back, then restart ZenCom so the
    copy left running has them (not the test's settings in memory)."""
    global FTP_DIR
    if not USER_LIST: return
    FTP_DIR = os.environ.get('ZENCOM_DIR', 'SD/ZenCom')
    ftp_put('bbslist.seq', USER_LIST)
    for name in ftp_list().split(b'\n'):
        name = name.rsplit(b'/', 1)[-1].decode()
        if name.lower().startswith(('zencom.cfg', 'cfgtmp', 'zencom.mac', 'mactmp',
                                    'zencom.pwd', 'pwdtmp')): ftp_delete(name)
    if USER_CFG: ftp_put(USER_CFG[0], USER_CFG[1])
    if USER_MAC: ftp_put(USER_MAC[0], USER_MAC[1])
    if USER_PWD: ftp_put(USER_PWD[0], USER_PWD[1])
    print('(your BBS list and settings are back; restarting ZenCom with them)')
    launch()


if __name__ == '__main__':
    try:
        main()
    finally:
        restore_list()
