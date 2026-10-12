#!/usr/bin/env python3
"""ZenCom in VICE, set up as other people's C64s are: a stock 1541 (true
drive emulation), and a SwiftLink cartridge or a user-port modem, talking
to tools/vice_modem.py (a Hayes modem) which dials tools/xfr_server.py.

  make && python3 tools/vicetest.py                 # SwiftLink ($DE00, NMI), ANSI
  python3 tools/vicetest.py --userport              # user port, KERNAL 1200, PETSCII
  python3 tools/vicetest.py --ntsc                  # either, on an NTSC machine

The same checks as tools/hwtest.py where they make sense; memory goes
through VICE's binary monitor instead of the Ultimate's REST API.
"""
import os, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import hwtest as h
import vice_modem, xfr_server
from vice import Vice

UP9600 = '--up9600' in sys.argv               # the user port, UP9600 wiring, 9600
USERPORT = '--userport' in sys.argv or UP9600
NTSC = '--ntsc' in sys.argv
BUILD = os.path.join(ROOT, 'build', 'vice')
D64 = os.path.join(BUILD, 'zencom.d64')
MODEM_PORT, BOARD_PORT = 25232, 6465
SAVED = os.path.join(BUILD, 'upload.bin')


def c1541(*args):
    return subprocess.run(['c1541', *args], capture_output=True, text=True).stdout


def make_disk():
    os.makedirs(BUILD, exist_ok=True)
    if os.path.exists(D64): os.remove(D64)
    c1541('-format', 'zencom,zc', 'd64', D64,
          '-write', os.path.join(ROOT, 'dist', 'zencom.prg'), 'zencom',
          '-write', os.path.join(ROOT, 'dist', 'zencom.xfr'), 'zencom.xfr',
          '-write', os.path.join(ROOT, 'data', 'bbslist.seq'), 'bbslist,s')


def start_vice():
    args = ['x64sc', '-default', '-minimized', '+sound',
            '-binarymonitor', '-binarymonitoraddress', 'ip4://127.0.0.1:6502',
            '-drive8type', '1541', '-drive8truedrive', '-8', D64,
            '-rsdev1', f'127.0.0.1:{MODEM_PORT}', '-rsdev1ip232', '-rsdev1baud',
            '1200' if USERPORT and not UP9600 else '9600']
    if NTSC: args.append('-ntsc')
    if USERPORT:
        args += ['-userportdevice', '2', '-rsuserdev', '0',
                 '-rsuserbaud', '9600' if UP9600 else '1200']
        if UP9600: args.append('-rsuserup9600')
    else:
        args += ['-acia1', '-acia1base', '0xDE00', '-acia1mode', '1', '-acia1irq', '1',
                 '-myaciadev', '0']
    log = open(os.path.join(BUILD, 'x64sc.log'), 'w')
    return subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)


def main():
    make_disk()
    if os.path.exists(SAVED): os.remove(SAVED)
    mlog, blog = [], []
    threading.Thread(target=vice_modem.serve, args=(MODEM_PORT, mlog.append), daemon=True).start()
    data = xfr_server.test_data(5000)
    threading.Thread(target=xfr_server.serve, args=(BOARD_PORT, SAVED, data, False, blog.append),
                     daemon=True).start()
    proc = start_vice()
    v = Vice()
    h.read, h.write = v.read, v.write                    # hwtest's helpers, on VICE
    check = h.check
    try:
        time.sleep(3)
        h.keys(h.typed('load"zencom",8\n'))
        h.keys(h.typed('run\n'))
        rows = h.wait_for(h.screen40, 'TO START', 180)
        check('menu shown (loaded from a 1541)', rows is not None)
        if rows is None: return h.finish()
        check('home drive is 8', h.var('home_dev') == 8, f'home_dev={h.var("home_dev")}')
        check('ZENCOM.XFR found (no warning)', not any('NOT FOUND' in r for r in rows), rows[24])
        time.sleep(2)
        # the menu overlay: D and S swap it in (from the RAM under the I/O
        # chips), the menu swaps the transfer code back (C=+D below uses it)
        h.keys(h.typed('d'))
        rows = h.wait_for(h.screen40, 'DIALLING DIRECTORY', 10)
        check('D: the directory (menu overlay in)', rows is not None and h.var('ovl_in') == 1
              and any('PARTICLES' in r for r in rows), repr((rows or h.screen40())[:4]))
        h.keys([0x5F])                                   # <-: back to the menu
        rows = h.wait_for(h.screen40, 'TO START', 10)
        check('<-: the menu, transfer code back', rows is not None and h.var('ovl_in') == 0
              and h.read(0xA000, 3) == b'ZX\x03')               # (XFR_VER)
        h.keys(h.typed('s'))
        rows = h.wait_for(h.screen40, 'ZENCOM  SETTINGS', 10)
        check('S: the settings screen', rows is not None and h.var('ovl_in') == 1)
        h.keys([0x5F]); time.sleep(1)                    # <-: cancel
        check('<-: the menu again', h.wait_for(h.screen40, 'TO START', 10) is not None
              and h.var('ovl_in') == 0)
        time.sleep(1)
        if USERPORT:
            h.keys(h.typed('4' if UP9600 else '2')); time.sleep(1)          # user port 1200,
            h.keys(h.typed('p')); time.sleep(3)          # then the mode: PETSCII
        else:
            h.keys([0x89]); time.sleep(3)                # F2: ACIA + ANSI
        scr = h.screen40 if USERPORT else h.screen80
        check('session started', h.var('mode') == (1 if USERPORT else 0) and h.var('driver') == ((2 if UP9600 else 1) if USERPORT else 0),
              f'mode={h.var("mode")} driver={h.var("driver")}')
        h.keys(h.typed('ati\n'))
        check('the modem answers ATI', h.wait_for(scr, 'TEST MODEM', 15) is not None,
              repr([r for r in scr() if r.strip()][-4:]) + repr(mlog[-3:]))
        h.keys(h.typed(f'atd 127.0.0.1:{BOARD_PORT}\n'))
        check('dialled the test board', h.wait_for(scr, 'ZENCOM TEST BOARD', 30) is not None,
              repr(mlog[-3:]) + repr(blog[-3:]))
        check('carrier seen (DCD)', h.var('online') == 1, f'online={h.var("online")}')
        if USERPORT:                                     # scroll-back is PETSCII
            h.keys(h.typed('c'))
            check('the board cleared to page two', h.wait_for(scr, 'PAGE TWO', 15) is not None)
            h.keys([0xBF]); time.sleep(2)
            rows = h.screen40()
            check('C=+B keeps the cleared page', 'SCROLL-BACK' in rows[24]
                  and any('PAGE ONE END' in r for r in rows[:24]), repr(rows[20:25]))
            h.keys(h.typed(' ')); time.sleep(1.5)
        # ---- XMODEM download to the 1541
        h.keys(h.typed('d')); time.sleep(1.5)
        h.keys([0xAC]); time.sleep(3)                    # C=+D
        rows = h.screen40()
        check('C=+D: the start screen', any('SAVES TO' in r for r in rows), repr(rows[:4]))
        h.keys(h.typed('x'))                             # XMODEM: it starts
        secs = int(os.environ.get('VICE_XFR_SECS', '150' if USERPORT else '90'))
        rows = h.wait_for(h.screen40, 'NAME THE FILE', secs)
        check('XMODEM received, name asked', rows is not None, repr(blog[-4:]))
        h.keys([0x93] + h.typed('xtest\n')); time.sleep(20)   # a 1541 renames slowly
        rows = scr()
        check('back on the board, "Saved" said', any('SAVED XTEST' in r.upper() for r in rows),
              repr([r for r in rows if r.strip()][-4:]))
        # ---- XMODEM upload from the 1541 (the file just saved)
        h.keys(h.typed('u')); time.sleep(1.5)
        h.keys([0xB8]); time.sleep(15)                   # C=+U: a 1541 directory
        rows = h.screen40()
        names = [r[1:17].strip() for r in rows[2:22]]
        check('C=+U lists the 1541', 'XTEST' in names, repr(names))
        if 'XTEST' in names:
            h.keys([0x11] * names.index('XTEST')); time.sleep(0.5)
            h.keys([13]); time.sleep(1)
            h.keys(h.typed('x'))
            rows = h.wait_for(h.screen40, 'SENT', secs)
            check('upload reported', rows is not None, repr(h.screen40()[20:24]) + repr(blog[-3:]) + repr(mlog[-6:]))
            for _ in range(90):                          # the board saves it at the end
                if os.path.exists(SAVED): break
                time.sleep(1)
            time.sleep(1)
            up = open(SAVED, 'rb').read() if os.path.exists(SAVED) else b''
            check('uploaded file matches byte for byte', up[:len(data)] == data, f'{len(up)} bytes')
            h.keys(h.typed(' ')); time.sleep(2)
        # ---- hang up: DTR drops, the modem hangs up
        h.keys([0x87]); time.sleep(4)                    # F5
        check('F5: back to the menu', h.wait_for(h.screen40, 'TO START', 10) is not None)
        check('the modem saw DTR drop', any('DTR off' in m for m in mlog), repr(mlog[-4:]))
    finally:
        v.quit()
        try: proc.wait(10)
        except subprocess.TimeoutExpired: proc.kill()
    listing = c1541('-attach', D64, '-list')
    tmp = os.path.join(BUILD, 'xtest.out')
    if os.path.exists(tmp): os.remove(tmp)
    c1541('-attach', D64, '-read', 'xtest', tmp)
    got = open(tmp, 'rb').read() if os.path.exists(tmp) else b''
    if got[:2] == data[:2] or not got: pass
    check('the file on the 1541 matches byte for byte',
          got[:len(data)] == data and set(got[len(data):]) <= {0x1A},
          f'{len(got)} bytes; ' + ' | '.join(l for l in listing.splitlines() if '"' in l))
    return h.finish()


if __name__ == '__main__':
    main()
