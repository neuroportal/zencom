#!/usr/bin/env python3
"""Generate screens.inc for zencom.s: the startup menu and the help page.

Both are full 40x25 text screens (screen codes + colour RAM) in the
C64's upper-case/graphics character set, copied straight into $0400 and
$D800.  The menu's lower half is a picture of a leaf on water, drawn at
80x22 "pixels" with the quadrant-block characters (2x2 pixels per cell,
one colour per cell plus the black background).

  python3 tools/gen_screens.py > src/screens.inc
  python3 tools/gen_screens.py --preview out.png    # needs VICE + Pillow
"""
import math, os, sys

W, H = 40, 25
VICE = '/opt/homebrew/Cellar/vice/3.10/share/vice/C64'

BLACK, WHITE, RED, CYAN, PURPLE, GREEN, BLUE, YELLOW = range(8)
ORANGE, BROWN, LRED, DGREY, GREY, LGREEN, LBLUE, LGREY = range(8, 16)

# quadrant bits: top-left 8, top-right 4, bottom-left 2, bottom-right 1
QUAD = {0: 0x20, 15: 0xA0, 8: 0x7E, 4: 0x7C, 2: 0x7B, 1: 0x6C,
        10: 0x61, 5: 0xE1, 3: 0x62, 12: 0xE2, 9: 0x7F, 6: 0xFF,
        7: 0xFE, 11: 0xFC, 13: 0xFB, 14: 0xEC}
HLINE = 0x40                                  # centred horizontal line


def sc(ch):
    """ASCII (upper case) -> screen code."""
    o = ord(ch)
    if 0x41 <= o <= 0x5A: return o - 0x40
    if o == 0x40: return 0
    if 0x20 <= o <= 0x3F or o in (0x5B, 0x5D): return o
    raise ValueError(ch)


class Screen:
    def __init__(self):
        self.ch = [0x20] * (W * H)
        self.col = [LGREY] * (W * H)

    def text(self, row, col, s, colour, rev=False):
        assert col + len(s) <= W, f"row {row}: {s!r} runs off the screen"
        for i, c in enumerate(s):
            self.ch[row * W + col + i] = sc(c) | (0x80 if rev else 0)
            self.col[row * W + col + i] = colour

    def centre(self, row, s, colour, rev=False):
        self.text(row, (W - len(s)) // 2, s, colour, rev)

    def put(self, row, col, code, colour):
        self.ch[row * W + col] = code
        self.col[row * W + col] = colour

    def pixels(self, top, img, left=0):
        """img[y][x] = colour or None, 2x2 pixels per cell, from (top, left)."""
        for cy in range(len(img) // 2):
            for cx in range(len(img[0]) // 2):
                px = [img[cy*2][cx*2], img[cy*2][cx*2+1],
                      img[cy*2+1][cx*2], img[cy*2+1][cx*2+1]]
                lit = [p for p in px if p is not None]
                if not lit:
                    self.put(top + cy, left + cx, 0x20, LGREY); continue
                c = max(set(lit), key=lit.count)          # one colour per cell
                bits = sum(b for p, b in zip(px, (8, 4, 2, 1)) if p == c)
                self.put(top + cy, left + cx, QUAD[bits], c)


# ---- big title: 5x7 letters drawn with quadrant blocks -----------------
BIG = {
 'Z': ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
 'E': ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
 'N': ["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"],
 'C': [".####", "#....", "#....", "#....", "#....", "#....", ".####"],
 'O': [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
 'M': ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
}


def title(scr, top, word, colours):
    w = len(word) * 6 - 1
    img = [[None] * (W * 2) for _ in range(8)]
    x0 = (W * 2 - w) // 2
    for i, ch in enumerate(word):
        for y, line in enumerate(BIG[ch]):
            for x, b in enumerate(line):
                if b == '#':
                    img[y][x0 + i * 6 + x] = colours[min(y // 2, len(colours) - 1)]
    scr.pixels(top, img)


# ---- the leaf on water -------------------------------------------------
def leaf_on_water(rows):
    """A single small leaf on still, dark water: a few thin rings, lots of space."""
    pw, ph = W * 2, rows * 2
    img = [[None] * pw for _ in range(ph)]
    cx, cy = 40.0, ph * 0.5
    L, Wd, ang = 8.0, 2.8, math.radians(-12)
    ca, sa = math.cos(ang), math.sin(ang)

    def local(x, y):
        dx, dy = x + 0.5 - cx, y + 0.5 - cy
        return dx * ca + dy * sa, -dx * sa + dy * ca

    # two open rings, like an enso: each left unfinished
    for r, colour, gap in ((14, LBLUE, (300, 345)), (25, BLUE, (110, 175))):
        for t in range(0, 2880):
            if gap[0] * 8 <= t <= gap[1] * 8: continue
            a = math.radians(t / 8)
            x = cx + r * math.cos(a)
            y = cy + r * math.sin(a) * 0.3
            if 0 <= x < pw and 0 <= y < ph:
                img[int(y)][int(x)] = colour
    for y in range(ph):
        for x in range(pw):
            u, v = local(x, y)
            if abs(u) <= L:
                t = (u + L) / (2 * L)
                if abs(v) <= Wd * math.sin(math.pi * t) ** 0.8:
                    img[y][x] = LGREEN
    return img


def enso(rows, cols=W):
    """A single open brush circle: heavy where the brush lands (top), thinning
    anticlockwise to a dry, broken tail; gap at the upper right; red seal."""
    pw, ph = cols * 2, rows * 2
    img = [[None] * pw for _ in range(ph)]
    cx, cy = pw / 2, ph / 2
    r = min(pw, ph) / 2 - 2.4
    start, sweep = math.radians(75), math.radians(328)   # anticlockwise from the top
    for i in range(6000):
        f = i / 5999
        a = start + sweep * f
        w = (4.2 * (1 - f) ** 1.3 + 0.9) * r / 13.0          # heavy -> thin
        if f < 0.04: w *= f / 0.04 * 0.6 + 0.4               # brush landing
        rr = r - 0.25 * w + 0.5 * math.sin(f * 5.0)
        if f > 0.82 and (i // 40) % 3 == 0: continue         # dry brush tail
        for k in range(-8, 9):
            d = k * 0.3
            if abs(d) > w / 2: continue
            x = cx + (rr + d) * math.cos(a)
            y = cy - (rr + d) * math.sin(a)
            if 0 <= x < pw and 0 <= y < ph:
                img[int(y)][int(x)] = WHITE
    sx, sy = int(cx + r * 0.95), int(cy + r * 0.80)         # seal (hanko)
    for y in range(sy, sy + 3):
        for x in range(sx, sx + 2):
            if 0 <= x < pw and 0 <= y < ph: img[y][x] = RED
    return img


ART = os.environ.get('ZENCOM_ART', 'enso')
VERSION = 'V' + open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'VERSION')).read().strip()   # (VERSION file)


def menu():
    s = Screen()
    title(s, 1, "ZENCOM", [YELLOW, YELLOW, ORANGE, ORANGE])
    s.centre(5, "ANSI-80  PETSCII-40  TELNET", LGREY)
    s.text(7, 2, "CONNECTION", ORANGE)
    for i, (k, label) in enumerate((("1", "ACIA / ULTIMATE"),
                                    ("2", "USER PORT 1200"),
                                    ("3", "USER PORT 2400"),
                                    ("4", "UP9600 (BETA)"))):
        s.text(MENU_OPT_ROW + i, 2, k, YELLOW, rev=True)
        s.text(MENU_OPT_ROW + i, HILITE_COL, label, LGREY)
    s.text(13, 2, "MODE", ORANGE)             # which suits which boards
    for row, k, label, hint in ((14, "A", "ANSI", "PC BBS"), (15, "P", "PETSCII", "C64 BBS")):
        s.text(row, 2, k, YELLOW, rev=True)
        s.text(row, 4, label, LGREY)
        s.text(row, 12, hint, DGREY)
    s.text(17, 2, "QUICK START", ORANGE)
    s.text(18, 2, "F1", YELLOW, rev=True)
    s.text(18, 5, "ACIA + PETSCII", LGREY)
    s.text(19, 2, "F2", YELLOW, rev=True)
    s.text(19, 5, "ACIA + ANSI", LGREY)
    s.text(20, 2, "D", YELLOW, rev=True)
    s.text(20, 4, "DIRECTORY", LGREY)
    s.text(21, 2, "S", YELLOW, rev=True)
    s.text(21, 4, "SETTINGS", LGREY)
    s.text(21, 13, "M", YELLOW, rev=True)
    s.text(21, 15, "MACROS", LGREY)
    s.text(22, 2, "H", YELLOW, rev=True)
    s.text(22, 4, "HELP + KEYS", LGREY)
    s.text(22, 21, "Q", YELLOW, rev=True)
    s.text(22, 23, "QUIT TO BASIC", LGREY)
    s.text(MENU_PROMPT_ROW, 2, PROMPT_CONN, CYAN)
    s.text(24, W - 1 - len(VERSION), VERSION, DGREY)       # the version, quietly
    if ART == 'enso':
        s.pixels(7, enso(15, 18), left=21)
    else:
        s.pixels(7, [row[:36] for row in leaf_on_water(15)], left=21)
    return s


MENU_PROMPT_ROW = 23
MENU_OPT_ROW = 8
HILITE_COL = 4
HILITE_LEN = 15
PROMPT_CONN = "1-4, F1/F2 OR D TO START"
PROMPT_MODE = "CHOOSE A MODE: A OR P".ljust(len(PROMPT_CONN))


def help_page():
    """Two columns under headings (2026-10-12, picked from three):
    ANSI-only keys light blue, PETSCII-only green, the credits dimmed."""
    ANSI, PET = LBLUE, LGREEN
    s = Screen()
    s.centre(0, " " * 40, ORANGE, rev=True)
    s.centre(0, f"ZENCOM {VERSION}  KEYS + HELP", ORANGE, rev=True)
    def key(r, c, k, what, col=LGREY):
        s.text(r, c, k.ljust(3), col, rev=True)
        s.text(r, c + 4, what, col)
    def block(top, heading, rows):
        s.text(top, 1, heading, ORANGE)
        for i, pair in enumerate(rows):
            for c, item in zip((1, 21), pair):
                if item: key(top + 1 + i, c, *item)
    block(2, "IN A CALL", ((("F1", "ESC", ANSI), ("F3", "COLOUR ON/OFF", ANSI)),
                           (("F4", "REDIAL"), ("F5", "HANG UP, MENU")),
                           (("F6", "AUTO REDIAL"), ("F7", "ANSI/PETSCII")),
                           (("F8", "SWAP CASE"), ("DEL", "BACKSPACE"))))
    block(8, "C= KEYS", ((("C=D", "DOWNLOAD"), ("C=U", "UPLOAD")),
                         (("C=N", "SEND USERNAME"), ("C=P", "SEND PASSWORD")),
                         (("C=M", "MACRO, THEN 1-8"), ("C=S", "PAUSE")),
                         (("C=B", "SCROLL BACK", PET), ("C=L", "LOWER CASE LOCK", PET)),
                         (("C=H", "THIS PAGE"), None)))
    s.text(15, 1, "TYPING", ORANGE)
    key(16, 1, "CRS", "CURSOR KEYS, HOME", ANSI)
    key(17, 1, "CTL", "CTRL A-Z: CONTROL CODES", ANSI)
    s.text(18, 1, "SHIFT + - @ POUND UP: BRACES ETC.", ANSI)
    s.text(19, 1, "DIALLING: ATD HOST:PORT (EITHER CASE)", LGREY)
    s.text(20, 1, "BLUE", ANSI)
    s.text(20, 6, "ANSI ONLY", LGREY)
    s.text(20, 17, "GREEN", PET)
    s.text(20, 23, "PETSCII ONLY", LGREY)
    s.text(22, 1, "(C) 2026 NEUROPORTAL  MIT LICENCE", DGREY)
    s.text(23, 1, "ZENCOM@NEUROPORTAL.NET", DGREY)
    s.centre(24, "PRESS ANY KEY", CYAN)
    return s


def rle(data):
    """Escape-byte run-length: TOK count value for runs of 4+, TOK 0 ends.
    TOK is a byte that never occurs in this stream."""
    used = set(data)
    tok = next(v for v in range(256) if v not in used)
    out, i = [], 0
    while i < len(data):
        j = i
        while j < len(data) and data[j] == data[i] and j - i < 255: j += 1
        out += [tok, j - i, data[i]] if j - i >= 4 else list(data[i:j])
        i = j
    return out + [tok, 0], tok


def unrle(packed, tok):
    out, i = [], 0
    while True:
        b = packed[i]; i += 1
        if b != tok: out.append(b); continue
        n = packed[i]; i += 1
        if n == 0: return out
        out += [packed[i]] * n; i += 1


def emit(out, name, data):
    packed, tok = rle(list(data))
    assert unrle(packed, tok) == list(data)
    out.write(f"{name.upper()}_TOK = ${tok:02X}\n{name}:            ; RLE, {len(packed)} bytes\n")
    for i in range(0, len(packed), 16):
        out.write("    .byte " + ",".join(f"${b:02X}" for b in packed[i:i+16]) + "\n")


def main():
    m, h = menu(), help_page()
    if len(sys.argv) > 2 and sys.argv[1] == '--preview':
        return preview(sys.argv[2], [m, h])
    o = sys.stdout
    o.write("; generated by tools/gen_screens.py - do not edit\n")
    o.write(f"MENU_PROMPT_ROW = {MENU_PROMPT_ROW}\nMENU_OPT_ROW = {MENU_OPT_ROW}\n")
    o.write(f"HILITE_COL = {HILITE_COL}\nHILITE_LEN = {HILITE_LEN}\n")
    o.write("prompt_mode:\n    .byte " + ",".join(f"${sc(c):02X}" for c in PROMPT_MODE) + "\n")
    o.write(f"PROMPT_LEN = {len(PROMPT_MODE)}\n")
    emit(o, "menu_scr", m.ch); emit(o, "menu_col", m.col)
    emit(o, "help_scr", h.ch); emit(o, "help_col", h.col)


def preview(path, screens):
    from PIL import Image
    rom = open(os.path.join(VICE, 'chargen-901225-01.bin'), 'rb').read()
    # check the quadrant table against the real character ROM
    for bits, code in QUAD.items():
        g = rom[code * 8:code * 8 + 8]
        q = lambda rows, mask: all((g[r] & mask) == mask for r in rows)
        e = lambda rows, mask: all((g[r] & mask) == 0 for r in rows)
        for b, rows, mask in ((8, range(4), 0xF0), (4, range(4), 0x0F),
                              (2, range(4, 8), 0xF0), (1, range(4, 8), 0x0F)):
            assert (q(rows, mask) if bits & b else e(rows, mask)), (bits, hex(code))
    pal = []
    for line in open(os.path.join(VICE, 'colodore.vpl')):
        p = line.split()
        if len(p) >= 3 and not line.startswith('#'):
            pal.append(tuple(int(v, 16) for v in p[:3]))
    border = 32
    im = Image.new('RGB', (len(screens) * (320 + border * 2), 200 + border * 2), pal[BLACK])
    for n, s in enumerate(screens):
        ox, oy = n * (320 + border * 2) + border, border
        for i in range(W * H):
            code, c = s.ch[i], pal[s.col[i]]
            for y in range(8):
                b = rom[code * 8 + y]
                for x in range(8):
                    if b & (0x80 >> x):
                        im.putpixel((ox + (i % W) * 8 + x, oy + (i // W) * 8 + y), c)
    im = im.resize((im.width * 2, im.height * 2), Image.NEAREST)
    im.save(path)


if __name__ == '__main__':
    main()
