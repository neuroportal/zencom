#!/usr/bin/env python3
"""README.md -> a SEQ file a C64 can read (PETSCII, lower/upper case set,
lines of at most 39 characters, CR line ends).

  python3 tools/mkreadme.py README.md build/readme.seq

Markdown is flattened: headings in capitals, tables as two columns, code
fences and images dropped.  The ANSI shifted-key table is replaced by one
line: its characters ({ } | ~ `) don't exist in PETSCII.
"""
import re, sys, textwrap

W = 39
SUBST = {'£': '\\', '↑': '^', '←': '_', '{': '(', '}': ')', '~': '-',
         '`': "'", '_': '-', '\\': '/', '—': '-', '–': '-', '’': "'", '“': '"', '”': '"'}

def petscii(text):
    out = bytearray()
    for ch in text:
        if ch == '\n': out.append(13); continue
        ch = SUBST.get(ch, ch)
        o = ord(ch)
        if ch == '|': out.append(0x7D); continue   # (a vertical bar graphic)
        if ch == '\\': out.append(0x5C)        # (the pound sign)
        elif ch == '^': out.append(0x5E)       # up arrow
        elif ch == '_': out.append(0x5F)       # left arrow
        elif 'a' <= ch <= 'z': out.append(o - 0x20)    # lower case: $41-$5A
        elif 'A' <= ch <= 'Z': out.append(o + 0x80)    # capitals: $C1-$DA
        elif 0x20 <= o < 0x5B or ch in '[]': out.append(o)
        else: out.append(0x3F)
    return bytes(out)

def inline(s):
    s = re.sub(r'!\[[^\]]*\]\([^)]*\)', '', s)          # images
    s = re.sub(r'\[([^\]]*)\]\(([^)]*)\)', r'\1 (\2)', s)  # links
    s = re.sub(r'`([^`]*)`', lambda m: m.group(1).replace('*', '\0'), s)   # code: as is
    s = s.replace('**', '')
    s = re.sub(r'\*([^*\s][^*]*)\*', r'\1', s)                      # *italics*
    return s.replace('\0', '*')

def convert(md):
    lines, out, i = md.split('\n'), [], 0
    skip_table = False
    while i < len(lines):
        ln = lines[i]; i += 1
        if ln.startswith('```'):
            while i < len(lines) and not lines[i].startswith('```'):
                out.append('  ' + lines[i]); i += 1
            i += 1; continue
        if ln.startswith('In ANSI mode, shifted symbol keys'):
            out += textwrap.wrap('In ANSI mode, shifted + - @ (pound) and up-arrow send the PC symbols the C64 '
                                 'lacks: braces, bar, tilde, backtick (see README.md).', W)
            while i < len(lines) and lines[i].strip() != '' and not lines[i].startswith('|'): i += 1
            while i < len(lines) and (lines[i].startswith('|') or lines[i].strip() == ''):
                if lines[i].strip() == '' and i + 1 < len(lines) and not lines[i + 1].startswith('|'): break
                i += 1
            continue
        if ln.startswith('## Building from source'):          # (for PCs: not on the disk)
            while i < len(lines) and not lines[i].startswith('## '): i += 1
            continue
        if ln.startswith('#'):
            title = inline(ln.lstrip('#').strip()).upper()
            out += ['', title, '-' * min(len(title), W)]; continue
        if ln.startswith('|'):
            cells = [inline(c.strip()) for c in ln.strip('|').split('|')]
            if all(re.fullmatch(r'-+', c) for c in cells if c): continue
            if not any(cells[1:]) and len(cells) > 1 and cells[0] == 'Key': continue
            key, rest = cells[0], ' '.join(c for c in cells[1:] if c)
            if key.lower() in ('key', 'keys') and not rest: continue
            out += textwrap.wrap(f'{key:<10} {rest}', W, subsequent_indent=' ' * 11) or ['']
            continue
        if not ln.strip():
            out.append(''); continue
        if '![' in ln: continue
        para = [ln]                                     # a paragraph or a list item
        while i < len(lines) and lines[i].strip() and not lines[i].startswith(('#', '|', '```', '- ')) \
                and not re.match(r'\s+- |\d+\. ', lines[i]):
            para.append(lines[i].strip()); i += 1
        text = inline(' '.join(p.strip() for p in para))
        m = re.match(r'(\s*)- (.*)', ' '.join(para))
        n = re.match(r'(\d+\.) (.*)', ' '.join(p.strip() for p in para))
        if n:
            out += textwrap.wrap(inline(n.group(2)), W, initial_indent=n.group(1) + ' ',
                                 subsequent_indent=' ' * (len(n.group(1)) + 1))
        elif m:
            depth = len(m.group(1)) // 2
            text = inline(m.group(2))
            out += textwrap.wrap(text, W, initial_indent='  ' * depth + '- ',
                                 subsequent_indent='  ' * depth + '  ')
        else:
            out += textwrap.wrap(text, W)
    text = re.sub(r'\n{3,}', '\n\n', '\n'.join(out).strip('\n')) + '\n'
    return text.replace('See LICENSE (LICENCE on the disk).', 'The licence is in LICENCE on this disk.')

if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    text = convert(open(src, encoding='utf-8').read())
    if '--text' in sys.argv: print(text)
    open(dst, 'wb').write(petscii(text))
