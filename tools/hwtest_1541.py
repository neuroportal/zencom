#!/usr/bin/env python3
"""ZenCom on the C64 Ultimate from a 1541 disk image in drive 8 (the
Ultimate's cycle-exact 1541): load, then an XMODEM download to the disk and
an upload from it, against tools/xfr_server.py on this Mac.

  make && python3 tools/hwtest_1541.py

The SD card's own files are not touched: ZenCom runs from the image, so its
list and settings come from there.  No memory reads while the drive works:
REST reads pause the CPU and would break the 1541's serial timing.
"""
import os, socket, subprocess, sys, threading, time, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import hwtest as h
import vicetest, xfr_server

IMAGE = 'zctest.d64'                                     # in ZenCom's folder on the SD
PORT = 6466


def main():
    vicetest.make_disk()
    img = open(vicetest.D64, 'rb').read()
    h.ftp_put(IMAGE, img)
    path = '/' + h.FTP_DIR + '/' + IMAGE
    h.http('PUT', '/drives/a:mount?' + urllib.parse.urlencode({'image': path, 'mode': 'readwrite'}))
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as u:
        u.connect((h.IP, 80)); mac = os.environ.get('MAC_IP') or u.getsockname()[0]
    data = xfr_server.test_data(5000)
    saved = os.path.join(vicetest.BUILD, 'upload_u64.bin')
    if os.path.exists(saved): os.remove(saved)
    log = []
    threading.Thread(target=xfr_server.serve, args=(PORT, saved, data, False, log.append), daemon=True).start()
    check = h.check
    h.http('PUT', '/machine:reset'); time.sleep(4)
    h.keys(h.typed('load"zencom",8'))
    h.keys(h.typed('\nrun\n'))                           # RUN waits in the buffer
    time.sleep(int(os.environ.get('LOAD_1541_SECS', '100')))   # a 1541: no polling
    rows = h.screen40()
    check('menu shown (loaded from the 1541)', any('TO START' in r for r in rows), repr(rows[20:25]))
    check('home drive is 8', h.var('home_dev') == 8, f'home_dev={h.var("home_dev")}')
    check('ZENCOM.XFR found', not any('NOT FOUND' in r for r in rows))
    time.sleep(2.5)
    h.keys([0x89]); time.sleep(2)                        # F2: ACIA + ANSI
    h.keys(h.typed(f'atd {mac}:{PORT}\n'))
    check('dialled the test board', h.wait_for(h.screen80, 'ZENCOM TEST BOARD', 25) is not None, repr(log[-3:]))
    secs = int(os.environ.get('XFR_1541_SECS', '75'))
    h.keys(h.typed('d')); time.sleep(1)
    h.keys([0xAC]); time.sleep(2)                        # C=+D
    h.keys(h.typed('x')); time.sleep(secs)               # no polling: the 1541 writes
    rows = h.screen40()
    check('XMODEM received, name asked', any('NAME THE FILE' in r for r in rows), repr(rows[:4]) + repr(log[-3:]))
    h.keys([0x93] + h.typed('xtest\n')); time.sleep(30)  # rename on a 1541
    rows = h.screen80()
    check('"Saved" said', any('Saved XTEST' in r for r in rows), repr([r for r in rows if r.strip()][-3:]))
    h.keys(h.typed('u')); time.sleep(1)
    h.keys([0xB8]); time.sleep(25)                       # C=+U: the 1541's directory
    names = [r[1:17].strip() for r in h.screen40()[2:22]]
    check('C=+U lists the 1541', 'XTEST' in names, repr(names))
    if 'XTEST' in names:
        h.keys([0x11] * names.index('XTEST')); time.sleep(0.5)
        h.keys([13]); time.sleep(1)
        h.keys(h.typed('x')); time.sleep(secs)
        rows = h.screen40()
        check('upload reported', any('SENT' in r for r in rows), repr(rows[20:24]) + repr(log[-3:]))
        up = open(saved, 'rb').read() if os.path.exists(saved) else b''
        check('uploaded file matches byte for byte', up[:len(data)] == data, f'{len(up)} bytes')
        h.keys(h.typed(' ')); time.sleep(2)
    h.keys([0x87]); time.sleep(3)                        # F5: hang up
    h.http('PUT', '/drives/a:remove'); time.sleep(2)
    back = h.ftp_get(IMAGE)
    open(vicetest.D64, 'wb').write(back)
    tmp = os.path.join(vicetest.BUILD, 'xtest_u64.out')
    if os.path.exists(tmp): os.remove(tmp)
    vicetest.c1541('-attach', vicetest.D64, '-read', 'xtest', tmp)
    got = open(tmp, 'rb').read() if os.path.exists(tmp) else b''
    check('the file on the 1541 image matches byte for byte',
          got[:len(data)] == data and set(got[len(data):]) <= {0x1A}, f'{len(got)} bytes')
    h.ftp_delete(IMAGE)
    h.launch()                                           # ZenCom back as it normally runs
    return h.finish()


if __name__ == '__main__':
    main()
