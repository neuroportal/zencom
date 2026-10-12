#!/usr/bin/env python3
"""Generate font.inc for zencom.s.

Text glyphs are 3 pixels wide in a 4x8 cell: row 0 blank, rows 1-5 cap
height, row 6 descender, row 7 blank (the cursor underline lives there).
Block/line glyphs use the full 4x8 cell so they tile seamlessly.
Edit the shapes below and re-run:  python3 tools/gen_font.py > src/font.inc
"""
import sys

# ---- printable ASCII $20-$7E: rows A-E (+ optional descender row F) ----
T = {
 ' ': "...,...,...,...,...",  '!': ".#.,.#.,.#.,...,.#.",
 '"': "#.#,#.#,...,...,...",  '#': "#.#,###,#.#,###,#.#",
 '$': ".##,##.,.#.,.##,##.",  '%': "#.#,..#,.#.,#..,#.#",
 '&': ".#.,#.#,.##,#.#,.##",  "'": ".#.,.#.,...,...,...",
 '(': "..#,.#.,.#.,.#.,..#",  ')': "#..,.#.,.#.,.#.,#..",
 '*': "...,#.#,.#.,#.#,...",  '+': "...,.#.,###,.#.,...",
 ',': "...,...,...,...,.#.,#..", '-': "...,...,###,...,...",
 '.': "...,...,...,...,.#.",  '/': "..#,..#,.#.,#..,#..",
 '0': ".##,#.#,#.#,#.#,##.",  '1': ".#.,##.,.#.,.#.,###",
 '2': "##.,..#,.#.,#..,###",  '3': "##.,..#,.#.,..#,##.",
 '4': "#.#,#.#,###,..#,..#",  '5': "###,#..,##.,..#,##.",
 '6': ".##,#..,###,#.#,###",  '7': "###,..#,.#.,.#.,.#.",
 '8': "###,#.#,###,#.#,###",  '9': "###,#.#,###,..#,##.",
 ':': "...,.#.,...,.#.,...",  ';': "...,.#.,...,.#.,#..",
 '<': "..#,.#.,#..,.#.,..#",  '=': "...,###,...,###,...",
 '>': "#..,.#.,..#,.#.,#..",  '?': "##.,..#,.#.,...,.#.",
 '@': ".#.,#.#,###,#..,.##",
 'A': ".#.,#.#,###,#.#,#.#",  'B': "##.,#.#,##.,#.#,##.",
 'C': ".##,#..,#..,#..,.##",  'D': "##.,#.#,#.#,#.#,##.",
 'E': "###,#..,###,#..,###",  'F': "###,#..,###,#..,#..",
 'G': ".##,#..,#.#,#.#,.##",  'H': "#.#,#.#,###,#.#,#.#",
 'I': "###,.#.,.#.,.#.,###",  'J': "..#,..#,..#,#.#,.#.",
 'K': "#.#,#.#,##.,#.#,#.#",  'L': "#..,#..,#..,#..,###",
 'M': "#.#,###,###,#.#,#.#",  'N': "##.,#.#,#.#,#.#,#.#",
 'O': ".#.,#.#,#.#,#.#,.#.",  'P': "##.,#.#,##.,#..,#..",
 'Q': ".#.,#.#,#.#,##.,.##",  'R': "##.,#.#,##.,#.#,#.#",
 'S': ".##,#..,.#.,..#,##.",  'T': "###,.#.,.#.,.#.,.#.",
 'U': "#.#,#.#,#.#,#.#,###",  'V': "#.#,#.#,#.#,.#.,.#.",
 'W': "#.#,#.#,###,###,#.#",  'X': "#.#,#.#,.#.,#.#,#.#",
 'Y': "#.#,#.#,.#.,.#.,.#.",  'Z': "###,..#,.#.,#..,###",
 '[': "##.,#..,#..,#..,##.",  '\\': "#..,#..,.#.,..#,..#",
 ']': ".##,..#,..#,..#,.##",  '^': ".#.,#.#,...,...,...",
 '_': "...,...,...,...,###",  '`': "#..,.#.,...,...,...",
 'a': "...,##.,.##,#.#,###",  'b': "#..,##.,#.#,#.#,##.",
 'c': "...,.##,#..,#..,.##",  'd': "..#,.##,#.#,#.#,.##",
 'e': "...,.##,###,#..,.##",  'f': "..#,.#.,###,.#.,.#.",
 'g': "...,.##,#.#,.##,..#,##.", 'h': "#..,##.,#.#,#.#,#.#",
 'i': ".#.,...,.#.,.#.,.#.",  'j': "..#,...,..#,..#,#.#,.#.",
 'k': "#..,#.#,##.,##.,#.#",  'l': "##.,.#.,.#.,.#.,###",
 'm': "...,###,###,#.#,#.#",  'n': "...,##.,#.#,#.#,#.#",
 'o': "...,.#.,#.#,#.#,.#.",  'p': "...,##.,#.#,#.#,##.,#..",
 'q': "...,.##,#.#,#.#,.##,..#", 'r': "...,.##,#..,#..,#..",
 's': "...,.##,#..,..#,##.",  't': ".#.,###,.#.,.#.,.##",
 'u': "...,#.#,#.#,#.#,.##",  'v': "...,#.#,#.#,#.#,.#.",
 'w': "...,#.#,#.#,###,###",  'x': "...,#.#,.#.,.#.,#.#",
 'y': "...,#.#,#.#,.##,..#,##.", 'z': "...,###,.#.,#..,###",
 '{': ".##,.#.,##.,.#.,.##",  '|': ".#.,.#.,.#.,.#.,.#.",
 '}': "##.,.#.,.##,.#.,##.",  '~': "...,.##,##.,...,...",
}

def text_glyph(s):
    rows = s.split(',')
    rows += ['...'] * (6 - len(rows))
    return ['....'] + [r + '.' for r in rows] + ['....']

def full(rows8):
    assert len(rows8) == 8 and all(len(r) == 4 for r in rows8)
    return rows8

V, H = '.#..', '####'
def box(top, mid, bot):           # vertical stub top/bottom, row 3 = mid
    return [top]*3 + [mid] + [bot]*4

SPECIAL = [  # (name, 8 rows)
 ('shade1', full(['#...', '..#.'] * 4)),
 ('shade2', full(['#.#.', '.#.#'] * 4)),
 ('shade3', full(['.###', '##.#'] * 4)),
 ('block',  full(['####'] * 8)),
 ('lower',  full(['....'] * 4 + ['####'] * 4)),
 ('upper',  full(['####'] * 4 + ['....'] * 4)),
 ('left',   full(['##..'] * 8)),
 ('right',  full(['..##'] * 8)),
 ('hline',  box('....', H, '....')),
 ('vline',  box(V, V, V)),
 ('tl',     box('....', '.###', V)),
 ('tr',     box('....', '##..', V)),
 ('bl',     box(V, '.###', '....')),
 ('br',     box(V, '##..', '....')),
 ('lt',     box(V, '.###', V)),
 ('rt',     box(V, '##..', V)),
 ('tt',     box('....', H, V)),
 ('bt',     box(V, H, '....')),
 ('cross',  box(V, H, V)),
 ('bullet', full(['....', '....', '.##.', '.##.', '.##.', '....', '....', '....'])),
 ('middot', full(['....', '....', '....', '.#..', '....', '....', '....', '....'])),
]

glyphs = [text_glyph(T[chr(c)]) for c in range(0x20, 0x7F)]
names = [repr(chr(c)) for c in range(0x20, 0x7F)]
sp_index = {}
for n, g in SPECIAL:
    sp_index[n] = len(glyphs)
    glyphs.append(g); names.append(n)

def gi(ch):
    return ord(ch) - 0x20

# ---- CP437 $80-$FF -> glyph index ----
cp = {}
acc = "CueaaaaceeeiiiAAEaAooouuyOUcLYPfaiounNao?--//!<>"   # $80-$AF
for i, ch in enumerate(acc):
    cp[0x80 + i] = gi(ch)
for c in (0xB3, 0xBA): cp[c] = sp_index['vline']
for c in (0xC4, 0xCD): cp[c] = sp_index['hline']
groups = {
 'tl': (0xDA, 0xC9, 0xD5, 0xD6), 'tr': (0xBF, 0xBB, 0xB8, 0xB7),
 'bl': (0xC0, 0xC8, 0xD4, 0xD3), 'br': (0xD9, 0xBC, 0xBE, 0xBD),
 'lt': (0xC3, 0xCC, 0xC6, 0xC7), 'rt': (0xB4, 0xB9, 0xB5, 0xB6),
 'tt': (0xC2, 0xCB, 0xD1, 0xD2), 'bt': (0xC1, 0xCA, 0xCF, 0xD0),
 'cross': (0xC5, 0xCE, 0xD7, 0xD8),
}
for n, cs in groups.items():
    for c in cs: cp[c] = sp_index[n]
cp.update({0xB0: sp_index['shade1'], 0xB1: sp_index['shade2'],
           0xB2: sp_index['shade3'], 0xDB: sp_index['block'],
           0xDC: sp_index['lower'], 0xDD: sp_index['left'],
           0xDE: sp_index['right'], 0xDF: sp_index['upper'],
           0xFE: sp_index['bullet'], 0xF9: sp_index['middot'],
           0xFA: sp_index['middot'], 0xFF: gi(' '),
           0xE1: gi('B'), 0xE6: gi('u'), 0xF0: gi('='), 0xF1: gi('+'),
           0xF2: gi('>'), 0xF3: gi('<'), 0xF6: gi('/'), 0xF7: gi('~'),
           0xF8: gi('o'), 0xFB: gi('v'), 0xFC: gi('n'), 0xFD: gi('2')})

def bits(row):
    v = 0
    for i, ch in enumerate(row):
        if ch == '#': v |= 0x80 >> i
    return v

def emit():
    # row-major: font_l + row*NUM_GLYPHS + glyph, so draw_glyph can index
    # each pixel row with X = glyph (no x8 multiply, no pointer)
    out = [f"; generated by gen_font.py - {len(glyphs)} glyphs", "NUM_GLYPHS = %d" % len(glyphs), "",
           "font_l:  ; glyph in high nibble (even columns), row-major"]
    for r in range(8):
        row = [bits(g[r]) for g in glyphs]
        out.append(f"    ; row {r}")
        for i in range(0, len(row), 16):
            out.append("    .byte " + ",".join("$%02X" % v for v in row[i:i+16]))
    out.append("font_r:  ; glyph in low nibble (odd columns), row-major")
    for r in range(8):
        row = [bits(g[r]) >> 4 for g in glyphs]
        out.append(f"    ; row {r}")
        for i in range(0, len(row), 16):
            out.append("    .byte " + ",".join("$%02X" % v for v in row[i:i+16]))
    out.append("cp437_map:  ; CP437 $80-$FF -> glyph index")
    q = gi('?')
    vals = [cp.get(c, q) for c in range(0x80, 0x100)]
    for i in range(0, 128, 16):
        out.append("    .byte " + ",".join("%d" % v for v in vals[i:i+16]))
    return "\n".join(out) + "\n"

if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--preview':
        text = ' '.join(sys.argv[2:]) or "The quick brown fox jumps over 0123456789"
        for r in range(8):
            print(''.join(glyphs[gi(c)][r] for c in text).replace('.', ' '))
    else:
        sys.stdout.write(emit())
