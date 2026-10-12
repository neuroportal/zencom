#!/usr/bin/env python3
"""Render docs/zencom_ansi_preview.png: a made-up board screen drawn by
ZenCom's own ANSI code (run in the emulator, as the tests do), then the
hires bitmap and colour matrix turned into a picture.

  make && python3 tools/ansi_preview.py docs/zencom_ansi_preview.png

Everything on the screen is invented: no real board, caller or place.
Needs Pillow and py65.
"""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tests'))
from harness import C64
from PIL import Image

PALETTE = [(0, 0, 0), (255, 255, 255), (136, 57, 50), (103, 182, 189), (139, 63, 150),
           (85, 160, 73), (64, 49, 141), (191, 206, 114), (139, 84, 41), (87, 66, 0),
           (184, 105, 98), (80, 80, 80), (120, 120, 120), (148, 224, 137),
           (120, 105, 196), (159, 159, 159)]

E = '\x1b['
TITLE = 'ZENCOM DEMO BBS  -  node 2  -  Synchronet 3.20  -  80x24 ANSI detected'
SCREEN = (
    E + '2J' + E + '1;1H'
    + E + '1;36m\xc9' + '\xcd' * 78 + '\xbb\r\n'
    + '\xba ' + E + '1;37m' + TITLE.ljust(77) + E + '1;36m\xba'
    + '\xc8' + '\xcd' * 78 + '\xbc\r\n\r\n'
    + E + '0;1;33m [M]' + E + '0;37m Message areas     '
    + E + '1;33m[F]' + E + '0;37m File areas        '
    + E + '1;33m[D]' + E + '0;37m Door games\r\n'
    + E + '1;33m [E]' + E + '0;37m E-mail            '
    + E + '1;33m[W]' + E + '0;37m Who\'s online      '
    + E + '1;33m[G]' + E + '0;37m Goodbye\r\n\r\n'
    + E + '0;32m Last callers:\r\n'
    + E + '0;37m   pixelfox        Lowtown, Nowhere     2400 baud  10/07/26\r\n'
    + '   modemgrrl       somewhere retro      2400 baud  10/07/26\r\n'
    + '   sysop           the basement         2400 baud  10/07/26\r\n\r\n'
    + E + '0;30;47m Quick brown foxes jump over the lazy dog 0123456789 !@#$%^&*() {}[]|\\~ '
    + E + '0m\r\n\r\n '
    + E + '37m\xb0\xb0\xb0\xb1\xb1\xb1\xb2\xb2\xb2\xdb\xdb\xdb '
    + ''.join(E + f'4{c}m  ' for c in (1, 2, 4, 5, 6, 3)) + E + '0m\r\n\r\n'
    + ' The quick brown fox jumps over the lazy dog. THE QUICK BROWN FOX JUMPS. 12:45pm\r\n'
    + E + '22;1H' + E + '1;37mCommand: ' + E + '0m'
)

def main(out):
    t = C64()
    t.call('screen_init'); t.call('term_reset')
    t.feed(SCREEN)
    m = t.mpu.memory
    img = Image.new('RGB', (320, 192))
    px = img.load()
    for row in range(24):
        for cell in range(40):
            colour = m[0x4400 + row * 40 + cell]
            fg, bg = PALETTE[colour >> 4], PALETTE[colour & 15]
            for y in range(8):
                b = m[0x6000 + row * 320 + cell * 8 + y]
                for x in range(8):
                    px[cell * 8 + x, row * 8 + y] = fg if b & (0x80 >> x) else bg
    img.resize((960, 576), Image.NEAREST).save(out)
    print('wrote', out)

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'docs', 'zencom_ansi_preview.png'))
