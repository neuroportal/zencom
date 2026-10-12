#!/usr/bin/env python3
"""Check the overlay rules after a build (run by make; reads build/zencom.lst).

The menu overlay (segment MENU) and the first 4 KB of the transfer overlay
(XFR) share $A000-$AFFF and are swapped by ovl_menu / ovl_xfr, so:

  1. resident code (CODE, CODE2) and XFR may name a MENU symbol only
     through its entry table (ovm_*), after ovl_menu;
  2. MENU may not name an XFR symbol, nor reach one through resident code;
  3. MENU may not call anything that swaps the overlays back (it would be
     replaced while running); it leaves only by JMP to an exit (EXITS).

Also writes build/zencom.seg (symbol -> segment) for the emulator tests.
"""
import os, re, sys, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'build', 'zencom.lst')
EXITS = {'menu_start', 'dial_go'}
SWAP = {'ovl_xfr', 'ovl_menu', 'ovl_xchg'}
OPC = set('adc and asl bcc bcs beq bit bmi bne bpl brk bvc bvs clc cld cli clv cmp '
          'cpx cpy dec dex dey eor inc inx iny jmp jsr lda ldx ldy lsr nop ora pha '
          'php pla plp rol ror rti rts sbc sec sed sei sta stx sty tax tay tsx txa '
          'txs tya'.split())
ENDS = {'rts', 'jmp', 'rti', 'brk'}

seg, rout = 'CODE', None
defs = {}                                  # label -> segment
order = []                                 # (segment, offset, label)
refs = collections.defaultdict(set)        # routine -> names
uses = []                                  # (segment, routine, opcode, name, line)
last = {}
for line in open(LST, encoding='latin-1'):
    m = re.match(r'^([0-9A-F]{6})r [0-9]  (.{12})  ?(.*)$', line.rstrip('\n'))
    if not m: continue
    off, s = int(m.group(1), 16), m.group(3).split(';')[0].strip()
    ms = re.match(r'\.segment\s+"(\w+)"', s)
    if ms:
        seg, rout = ms.group(1), None
        continue
    ml = re.match(r'^([A-Za-z_]\w*):(.*)$', s)
    if ml:
        rout = ml.group(1); defs[rout] = seg; order.append((seg, off, rout))
        s = ml.group(2).strip()
    if rout is None or re.match(r'^[A-Za-z_]\w*\s*=', s): continue
    s = re.sub(r'"[^"]*"', '', s); s = re.sub(r"'.'", '', s)
    t = s.split(None, 1)
    if not t: continue
    op = t[0].lower(); last[rout] = op
    body = (t[1] if len(t) > 1 else '') if (op in OPC or op.startswith('.')) else s
    for n in re.findall(r'(?<![@\w$%])([A-Za-z_]\w*)', body):
        refs[rout].add(n); uses.append((seg, rout, op, n, line.strip()))

# fall-through: a routine that doesn't end in RTS/JMP runs into the next label
order.sort()
for a, b in zip(order, order[1:]):
    if a[0] == b[0] and last.get(a[2], 'rts') not in ENDS and not last.get(a[2], '').startswith('.'):
        refs[a[2]].add(b[2])

def reach(r, stop=EXITS):
    seen, st = set(), [r]
    while st:
        x = st.pop()
        if x in seen or x not in defs: continue
        seen.add(x)
        st.extend(n for n in refs.get(x, ()) if n not in stop)
    return seen

bad = []
for sg, r, op, n, line in uses:
    ns = defs.get(n)
    if ns is None: continue
    if sg != 'MENU' and ns == 'MENU' and not n.startswith('ovm_'):
        bad.append(f'{sg} {r} names MENU symbol {n}: {line}')
    if sg == 'MENU' and ns == 'XFR':
        bad.append(f'MENU {r} names XFR symbol {n}: {line}')
    if sg == 'MENU' and ns in ('CODE', 'CODE2'):
        if n in EXITS:
            if op != 'jmp': bad.append(f'MENU {r} must JMP to {n}, not {op}: {line}')
            continue
        got = reach(n)
        if got & SWAP:
            bad.append(f'MENU {r} calls {n}, which can swap the overlays: {line}')
        x = sorted(k for k in got if defs[k] == 'XFR')
        if x:
            bad.append(f'MENU {r} calls {n}, which reaches XFR code ({x[0]}): {line}')
    if sg != 'MENU' and n.startswith('ovm_') and ns == 'MENU':
        if not any(k in SWAP for k in refs.get(r, ())):
            bad.append(f'{sg} {r} enters the menu overlay without ovl_menu: {line}')

if len(sys.argv) == 1:
    with open(os.path.join(ROOT, 'build', 'zencom.seg'), 'w') as f:
        for k, v in sorted(defs.items()): f.write(f'{k} {v}\n')
for b in sorted(set(bad)): print('ovlcheck:', b)
sys.exit(1 if bad else 0)
