"""Run with:  make && python3 tests/test_zencom.py   (needs: pip install py65)"""
from harness import C64, lbl

def fresh():
    t = C64(); t.call('screen_init'); t.call('term_reset'); return t

def test_text_and_cursor_addressing():
    t = fresh()
    t.feed("Hello\r\n\x1b[5;10HAt5,10\x1b[1;80HZ")
    txt = t.text()
    assert txt[0].startswith("Hello") and txt[0][79] == 'Z'
    assert txt[4] == ' ' * 9 + "At5,10"
    assert t.var('wrap') == 1          # deferred wrap after column 80

def test_bare_cr_and_crlf():
    t = fresh()
    t.feed("ATI\rLINE ONE\rOK\r")
    t.feed("a\r\nb\r\n\r\nc")
    assert t.text(7) == ["ATI", "LINE ONE", "OK", "a", "b", "", "c"]

def test_cr_online_returns_to_column_0_only():
    t = fresh(); t.mpu.memory[lbl['online']] = 1
    t.feed("PRESS ANY KEY\rpress\r\nnext\r\n")
    assert t.text(3) == ["press ANY KEY", "next", ""]

def test_del_echo_erases():
    t = fresh()
    t.feed("ATIX"); t.call('key_send', 0x14); t.feed("\x08")
    assert t.text(1) == ["ATI"] and t.var('col') == 3
    t.feed("\x08")                                  # remote BS alone: move only
    assert t.text(1) == ["ATI"] and t.var('col') == 2
    t.feed("\r\nabc"); t.call('key_send', 0x14); t.feed("\x08 \x08")
    assert t.text(2)[1] == "ab" and t.var('col') == 2

def test_f5_hangs_up_and_returns_to_menu():
    for driver, check in ((0, lambda m: m[0xDE02] == 0x02),            # ACIA DTR off
                          (1, lambda m: m[0xDD01] & 0x04 == 0)):        # user port PB2 low
        t = fresh(); m = t.mpu.memory
        m[lbl['driver']] = driver; m[0xDE02] = 0x09; m[0xDD01] = 0xFF
        mpu = t.mpu; mpu.sp = 0xFD; mpu.pc, mpu.a = lbl['key_send'], 0x87
        for i in range(200000):                  # jiffy clock ticks while it waits
            if mpu.pc == lbl['menu_start']: break
            if i % 50 == 0: m[0xA2] = (m[0xA2] + 1) & 0xFF
            mpu.step()
        assert mpu.pc == lbl['menu_start'] and check(m)
        assert t.sent == []                      # F5 itself is not sent

def run_ticking(t, name, a=0, steps=400000):
    """Run a routine that waits on the jiffy clock; tick it as we go."""
    mpu, m = t.mpu, t.mpu.memory
    mpu.sp = 0xFD; m[0x1FE], m[0x1FF] = 0xFE, 0xBF; mpu.pc, mpu.a = lbl[name], a
    log = []
    for i in range(steps):
        if mpu.pc == 0xBFFF: return log
        if i % 50 == 0: m[0xA2] = (m[0xA2] + 1) & 0xFF
        if mpu.pc == 0xC000: t.sent.append(mpu.a)        # ser_put stub (as t.call)
        pc = mpu.pc; mpu.step()
        log.append((pc, dict((r, m[r]) for r in (0xD401, 0xD404, 0xD408, 0xD418))))
    raise RuntimeError('timeout')

def test_menu_screen_drawn_and_highlight():
    import gen_screens
    t = fresh(); m = t.mpu.memory
    t.call('draw_menu')
    menu = gen_screens.menu()
    assert m[0x0400:0x07E8] == menu.ch
    assert [c & 15 for c in m[0xD800:0xDBE8]] == menu.col
    t.call('hilite_row', gen_screens.MENU_OPT_ROW + 1)
    row = 0xD800 + (gen_screens.MENU_OPT_ROW + 1) * 40
    c0, n = gen_screens.HILITE_COL, gen_screens.HILITE_LEN
    assert m[row + c0:row + c0 + n] == [1] * n and m[row + c0 + n] != 1

def test_jingle_plays_four_two_tone_notes():
    t = fresh()
    log = run_ticking(t, 'play_jingle')
    gates = [st for _, st in log if st[0xD404] == 0x11]
    pitches = sorted({(st[0xD401], st[0xD408]) for st in gates})
    assert pitches == [(0x22, 0x50), (0x2B, 0x58), (0x34, 0x62), (0x45, 0x6C)]
    assert t.mpu.memory[0xD418] == 0x0F            # volume stays up (see below)

def test_carrier_loss_returns_to_menu():
    t = fresh(); m = t.mpu.memory
    run_ticking(t, 'acia_init')
    m[lbl['driver']] = 0
    m[0xDE01] = 0x50; t.call('carrier_check')          # idle at the AT prompt
    assert t.var('online') == 0 and t.var('lost') == 0
    m[0xDE01] = 0x10; t.call('carrier_check')          # connected
    assert t.var('online') == 1
    m[0xDE01] = 0x50; t.call('carrier_check')          # call dropped
    assert t.var('lost') == 1
    t.call('carrier_check')                             # not yet: waits 1 s
    assert t.var('lost') == 1
    m[0xA2] = t.var('lost_at'); t.call('carrier_check')
    assert t.var('lost') == 2
    assert any('Call ended' in row for row in t.text())
    t.call('carrier_check'); assert t.var('lost') == 2  # stays put
    m[0xDE00] = 0; t.call('key_send', 0x41)             # typing carries on
    assert t.var('lost') == 0 and m[0xDE00] == ord('a') # (ACIA driver active)
    t2 = fresh(); m2 = t2.mpu.memory                    # user port: ignored
    m2[lbl['driver']] = 1; m2[lbl['online']] = 1; m2[0xDE01] = 0x50
    t2.call('carrier_check'); assert t2.var('lost') == 0

def test_no_carrier_text_ends_the_call():
    for driver in (0, 1):
        t = fresh(); m = t.mpu.memory; m[lbl['driver']] = driver
        for b in b"\r\nCONNECT\r\nbusy, NO CARRY NO CARRIER\r\n":
            t.call('nc_match', b)
        assert t.var('lost') == 1
    t = fresh()
    for b in b"NO CARRIE": t.call('nc_match', b)
    assert t.var('lost') == 0

def test_redial_remembers_last_atd():
    t = fresh(); m = t.mpu.memory; m[lbl['mode']] = 1     # PETSCII: keys as-is
    for k in b"ATI\rATD 1.2.3.X" + bytes([0x14]) + b"4:23\r": t.call('key_send', k)
    t.call('key_send', ord('h')); t.call('key_send', 0x0D)  # not a dial: ignored
    t.sent.clear(); t.call('key_send', 0x8A)               # F4
    assert bytes(t.sent) == b"ATD 1.2.3.4:23\r"
    m[lbl['online']] = 1; t.sent.clear(); t.call('key_send', 0x8A)
    assert t.sent == [0x8A]                                 # connected: to the board
    m[lbl['online']] = 0; m[lbl['lost']] = 2; t.sent.clear()
    t.call('key_send', 0x8A)                                # F4 after a drop
    assert bytes(t.sent) == b"ATD 1.2.3.4:23\r" and t.var('lost') == 0

def test_auto_redial_cycle_and_fanfare():
    t = fresh(); m = t.mpu.memory
    m[lbl['driver']] = 0
    for k in b"ATD 1.2.3.4:23\r": t.call('key_send', k)   # ANSI: remembered as typed
    dial = bytes(t.sent)
    m[lbl['lost']] = 2; t.sent.clear()
    log = run_ticking(t, 'key_send', 0x8B)               # F6 at the closed prompt: a blip, dial
    assert bytes(t.sent) == dial and t.var('auto_state') == 2
    assert any(st[0xD404] == 0x11 for _, st in log)
    m[0xA1] = t.var('auto_at'); t.call('auto_tick')      # no connection in time
    assert t.var('auto_state') == 1
    assert any('Redial in 1 min (any key stops)' in row for row in t.text())
    t.sent.clear(); m[0xA1] = t.var('auto_at'); run_ticking(t, 'auto_tick')
    assert bytes(t.sent) == dial and t.var('auto_state') == 2
    m[lbl['online']] = 1; t.call('auto_tick')            # connected...
    assert t.var('auto_ok') == 1 and t.var('auto_state') == 2
    m[0xA1] = t.var('ok_at')                             # ...and still up 10 s later
    log = run_ticking(t, 'auto_tick')
    assert t.var('auto_state') == 0
    assert any('Connected' in row for row in t.text())
    notes = [st[0xD401] for _, st in log if st[0xD404] == 0x11]
    assert sorted(set(notes)) == [0x22, 0x2B, 0x34, 0x45]  # same four tones
    m[lbl['online']] = 0; m[lbl['auto_state']] = 1; t.sent.clear()
    t.call('key_send', ord('x'))                          # any key stops the wait
    assert t.var('auto_state') == 0 and t.sent == []

def test_no_answer_offers_redial():
    t = fresh(); m = t.mpu.memory
    for b in b"ATD 1.2.3.4:23\r\nNO ANSWER\r\n": t.call('nc_match', b)
    assert t.var('lost') == 1                        # -> R/A prompt after 1 s
    t = fresh(); m = t.mpu.memory; m[lbl['online']] = 1
    for b in b"NO ANSWER": t.call('nc_match', b)
    assert t.var('lost') == 0                        # board text while online

def test_f8_case_swap_both_modes():
    t = fresh(); m = t.mpu.memory
    t.call('key_send', 0x8C)                             # F8 on (ANSI mode)
    assert t.var('flipcase') == 1 and m[0xD020] == 11
    t.feed("tHE oASIS\x1b[1m!")
    assert t.text(1) == ["The Oasis!"] and t.var('bold') == 1   # escapes intact
    t.call('key_send', 0x8C); assert t.var('flipcase') == 0 and m[0xD020] == 0
    t = C64(); m = t.mpu.memory
    t.call('pet_mode_init'); m[lbl['online']] = 1; m[lbl['driver']] = 0
    t.call('key_send', 0x8C); t.chrout.clear()
    for b in b"Hi": t.call('term_putc', b)               # ASCII board, PETSCII screen
    assert t.chrout == [0xC8, 0x49]

def entries(t):
    m = t.mpu.memory; out = []
    field = lambda e, o, n: bytes(m[e+o:e+o+n]).split(b'\0')[0].decode('latin-1')
    for i in range(t.var('n_ent')):
        e = 0x8000 + i * 128
        out.append((field(e, 2, 20), field(e, 22, 43), chr(m[e])))
    return out

def entry_extra(t, i):
    m = t.mpu.memory; e = 0x8000 + i * 128
    return m[e + 1], bytes(m[e+65:e+126]).split(b'\0')[0].decode('latin-1')

ORDER = 0xC800 + 0x1C0
MEM_GET = 0xC280                                        # bytes from (bptr), C=1 at the 0

def mem_get_stub(m):
    m[MEM_GET:MEM_GET + 16] = [0xA0, 0x00, 0xB1, 0x34, 0xF0, 0x08, 0xE6, 0x34,
                               0xD0, 0x02, 0xE6, 0x35, 0x18, 0x60, 0x38, 0x60]
    m[0x38], m[0x39] = MEM_GET & 255, MEM_GET >> 8      # bget

def parse_text(t, text):
    m = t.mpu.memory
    data = text.encode('latin-1') + b'\0'
    m[0xC300:0xC300 + len(data)] = list(data)
    m[0x34], m[0x35] = 0x00, 0xC3                       # bptr
    mem_get_stub(m)
    t.call('list_parse')

def test_bbs_list_empty_and_parsing():
    t = fresh(); t.call('empty_list')                   # no built-in list any more
    assert t.var('n_ent') == 0 and t.var('list_src') == 0
    parse_text(t, "# comment|x:1|P\r\nOne|one.example:23|p\r\n\nNoHost||A\n"
                  "Two|two.example:6400\n" + "L" * 30 + "|" + "h" * 50 + "|A")
    e = entries(t)
    assert e[0] == ('One', 'one.example:23', 'P')
    assert e[1] == ('Two', 'two.example:6400', 'A')          # mode defaults to A
    assert e[2] == ('L' * 19, 'h' * 42, 'A') and len(e) == 3  # clipped; no-host skipped

def test_bbs_list_bookmarks_notes_order_delete():
    t = fresh(); m = t.mpu.memory
    parse_text(t, "One|one:23|A\nTwo|two:23|P|*|best board\nThree|three:23|A||just a note\n"
                  "Four|four:23|A|*\n")
    assert entry_extra(t, 1) == (1, 'best board') and entry_extra(t, 2) == (0, 'just a note')
    assert entry_extra(t, 3) == (1, '')
    t.call('build_order')
    assert m[ORDER:ORDER + 4] == [1, 3, 0, 2]            # bookmarks first, else file order
    t.call('ent_delete', 1)                               # remove "Two"
    assert [e[0] for e in entries(t)] == ['One', 'Three', 'Four']
    assert entry_extra(t, 1) == (0, 'just a note')
    assert m[ORDER:ORDER + 3] == [2, 0, 1]

def test_directory_rows_and_bar():
    t = fresh(); m = t.mpu.memory
    parse_text(t, "Alpha|alpha.example:23|A|*\nBeta|beta.example:6400|P\n")
    t.call('build_order')
    m[lbl['dir_sel']] = 1                                 # bar on the second row
    for r in range(3): t.call('dir_row', x=r)
    def row(r):
        return ''.join(chr(c & 0x7F) if 32 <= (c & 0x7F) < 64 else chr((c & 0x7F) + 64) if 1 <= (c & 0x7F) <= 26 else ' '
                       for c in m[0x0400 + r * 40:0x0428 + r * 40])
    assert row(2).startswith('*ALPHA') and 'ALPHA.EXAMPLE' in row(2) and row(2)[39] == 'A'
    assert row(3).startswith(' BETA') and row(3)[39] == 'P'
    assert all(c & 0x80 for c in m[0x0400 + 3*40:0x0428 + 3*40])   # the bar: whole row reversed
    assert not any(c & 0x80 for c in m[0x0400 + 2*40:0x0428 + 2*40])
    assert m[0xD800 + 3*40] & 15 == 3 and m[0xD800 + 2*40] & 15 == 7  # cyan bar, yellow star
    assert row(4).strip() == ''                            # past the end: blank

def test_directory_dial_builds_atd_and_mode():
    t = fresh(); m = t.mpu.memory
    parse_text(t, "Vertrauen|vert.synchro.net:23|A\nParticles!|particlesbbs.dyndns.org:6400|P\n")
    m[0xDE01] = 0x10                                     # ACIA: transmit empty
    t.overlay('MENU')                                    # (the directory is in it)
    m[lbl['login_load']] = 0x60                           # (reads ZENCOM.PWD: no disk here)
    mpu = t.mpu; mpu.sp = 0xFD; mpu.pc, mpu.a = lbl['dir_dial'], 1   # Particles!, P
    for i in range(2_000_000):
        if mpu.pc == lbl['main']: break
        m[0xDE01] = 0x10                                 # (acia_init resets it)
        if i % 50 == 0: m[0xA2] = (m[0xA2] + 1) & 0xFF   # jiffy clock (acia_init waits)
        t.step()
    assert mpu.pc == lbl['main']
    assert t.var('ovl_in') == 0 and m[0xA000:0xA003] == list(b'ZX\x03')   # transfers back in
    n = t.var('dial_len')
    DIAL_BUF = 0xC800 + 0x140                            # dial_buf (see zencom.s)
    assert bytes(m[DIAL_BUF:DIAL_BUF + n]) == b"ATD particlesbbs.dyndns.org:6400"
    assert t.var('mode') == 1 and t.var('driver') == 0

def test_carrier_line_detection_real_modems():
    for offline, online, name in ((0x50, 0x10, 'Ultimate: DSR'), (0x30, 0x10, 'DCD, DSR held active'),
                                  (0x70, 0x10, 'both lines')):
        t = fresh(); m = t.mpu.memory; run_ticking(t, 'acia_init'); m[lbl['driver']] = 0
        m[0xDE01] = offline; t.call('carrier_check'); assert t.var('online') == 0, name
        m[0xDE01] = online;  t.call('carrier_check'); assert t.var('online') == 1, name
        m[0xDE01] = offline; t.call('carrier_check'); assert t.var('lost') == 1, name
    t = fresh(); m = t.mpu.memory; run_ticking(t, 'acia_init')    # lines tied active
    m[0xDE01] = 0x10
    for _ in range(3): t.call('carrier_check')
    assert t.var('online') == 0 and t.var('lost') == 0     # text decides instead

def with_keys(t, keys):
    """GETIN stub: returns the next key from a list ($C200..), index at $C1FF."""
    m = t.mpu.memory
    m[0xC100:0xC10A] = [0xAE, 0xFF, 0xC1, 0xBD, 0x00, 0xC2, 0xEE, 0xFF, 0xC1, 0x60]
    m[0xFFE4:0xFFE7] = [0x4C, 0x00, 0xC1]              # JMP $C100
    m[0xC1FF] = 0; m[0xC200:0xC200 + len(keys)] = list(keys)

def edit_field(t, start, keys, off=22, mx=42, row=6):
    m = t.mpu.memory
    buf = 0xCA00                                          # EDIT_BUF
    m[buf:buf + 128] = [0] * 128
    m[buf + off:buf + off + len(start)] = list(start.encode())
    m[0x36], m[0x37] = 0x00, 0xCA                         # eptr
    m[lbl['ed_row']], m[lbl['ed_off']], m[lbl['ed_max']] = row, off, mx
    with_keys(t, keys)
    t.call('field_edit')
    return bytes(m[buf + off:buf + off + mx + 1]).split(b'\0')[0].decode(), t.mpu.a, t.mpu.p & 1

def test_field_editor():
    t = fresh(); m = t.mpu.memory
    m[0x0400 + 5 * 40:0x0400 + 5 * 40 + 40] = [0x41] * 40   # a label row above the field
    LEFT, RIGHT, HOME, CLR, DEL, INST, UP, BACKARROW = 0x9D, 0x1D, 0x13, 0x93, 0x14, 0x94, 0x91, 0x5F
    assert edit_field(t, '', b'ABC.COM\r') == ('ABC.COM', 0, 0)
    assert edit_field(t, 'EXAMPLE.COM', bytes([LEFT] * 4) + b'X\r')[0] == 'EXAMPLEX.COM'
    assert edit_field(t, 'EXAMPLE.COM', bytes([HOME, DEL, RIGHT, DEL]) + b'\r')[0] == 'XAMPLE.COM'
    assert edit_field(t, 'AB', bytes([HOME, INST]) + b'\r')[0] == ' AB'
    assert edit_field(t, 'OLD', bytes([CLR]) + b'NEW\r')[0] == 'NEW'
    assert edit_field(t, 'KEEP', b'XYZ' + bytes([BACKARROW]))[2] == 1     # <- mid-edit: cancel
    assert edit_field(t, 'A', bytes([UP]))[1:] == (1, 0)                   # up: back a field
    long = 'H' * 40
    assert edit_field(t, '', long.encode() + b'\r')[0] == long             # wraps to row 7
    assert m[0x0400 + 7 * 40 + 1] & 0x7F == 8 and m[0x0400 + 7 * 40 + 2] & 0x7F == 8
    assert edit_field(t, '', b'Z' * 50 + b'\r', mx=19)[0] == 'Z' * 19      # max length
    assert m[0x0400 + 5 * 40:0x0400 + 5 * 40 + 40] == [0x41] * 40          # nothing else touched

CFG = 0xC800 + 0x300
def cfg_text(t, off, n=39):
    return bytes(t.mpu.memory[CFG + off:CFG + off + n]).split(b'\0')[0].decode()

def test_settings_defaults_parse_write():
    t = fresh(); m = t.mpu.memory; CFG = 0xC800 + 0x300                # RXBUF_AT+$300
    m[lbl['home_dev']] = 11
    t.call('cfg_defaults')
    assert [cfg_text(t, o, 3) for o in (0, 42, 84)] == ['11', '11', '11']
    assert cfg_text(t, 3) == '' and cfg_text(t, 126) == ''
    text = b"LIST=11,/USB1/BBS/ZENCOM\r\nDOWN=9,\nUP=9,/UPLOADS\nHOME=11,/USB1/BBS/ZENCOM\nJUNK=1,2\n"
    m[0xC300:0xC300 + len(text) + 1] = list(text) + [0]
    m[0x34], m[0x35] = 0x00, 0xC3
    mem_get_stub(m)
    t.call('cfg_parse')
    assert (cfg_text(t, 0, 3), cfg_text(t, 3)) == ('11', '/USB1/BBS/ZENCOM')
    assert (cfg_text(t, 42, 3), cfg_text(t, 45)) == ('9', '')
    assert (cfg_text(t, 84, 3), cfg_text(t, 87)) == ('9', '/UPLOADS')
    assert cfg_text(t, 126) == '/USB1/BBS/ZENCOM'
    t.call('cfg_dev', 42); assert t.mpu.a == 9
    m[CFG + 42:CFG + 45] = list(b'99\0'); t.call('cfg_dev', 42); assert t.mpu.a == 11   # bad -> home
    t.chrout.clear(); t.call('cfg_write')
    assert bytes(t.chrout) == (b"#ZENCOM SETTINGS (S ON THE MENU)\n"
                               b"LIST=11,/USB1/BBS/ZENCOM\nDOWN=99,\nUP=9,/UPLOADS\n"
                               b"HOME=11,/USB1/BBS/ZENCOM\n")
    # read back with its header: the # line is skipped, nothing else changes
    out = bytes(t.chrout)
    m[0xC300:0xC300 + len(out) + 1] = list(out) + [0]
    m[0x34], m[0x35] = 0x00, 0xC3
    mem_get_stub(m); t.call('cfg_parse')
    assert (cfg_text(t, 0, 3), cfg_text(t, 42, 3), cfg_text(t, 87)) == ('11', '99', '/UPLOADS')

def test_swiftlink_speed_setting():
    # SPEED=<rate> in ZENCOM.CFG: parsed, written back only when set, and
    # turned into the ACIA control byte (a SwiftLink doubles every rate)
    t = fresh(); m = t.mpu.memory; CFG = 0xC800 + 0x300
    m[lbl['home_dev']] = 8; t.call('cfg_defaults')
    t.chrout.clear(); t.call('cfg_write')
    assert b'SPEED' not in bytes(t.chrout)                            # blank: no line
    text = b"LIST=8,\nspeed=38400\n"
    m[0xC300:0xC300 + len(text) + 1] = list(text) + [0]
    m[0x34], m[0x35] = 0x00, 0xC3
    mem_get_stub(m); t.call('cfg_parse')
    assert cfg_text(t, 165) == '38400' and cfg_text(t, 0, 3) == '8'
    t.chrout.clear(); t.call('cfg_write')
    assert bytes(t.chrout).endswith(b"SPEED=38400\n")
    for txt, want, bad in ((b'', 0x1C, 0), (b'1200', 0x17, 0), (b'2400', 0x18, 0), (b'9600', 0x1C, 0),
                           (b'19200', 0x1E, 0), (b'38400', 0x1F, 0), (b'960', 0x1C, 1), (b'96000', 0x1C, 1),
                           (b'FAST', 0x1C, 1)):
        m[0xC300:0xC300 + len(txt) + 1] = list(txt) + [0]
        t.mpu.y = 0xC3; t.call('speed_ctrl', 0x00)
        assert (t.mpu.a, t.mpu.p & 1) == (want, bad), (txt, hex(t.mpu.a))

def test_macros_parse_write_send():
    # M1=..M8= in ZENCOM.MAC (read by cfg_parse); C=+M then a digit sends one through key_send
    # (^ = Return), yellow border meanwhile; any other key cancels
    t = fresh(); m = t.mpu.memory; MAC = 0xC800 + 0x600
    m[lbl['home_dev']] = 8; t.call('cfg_defaults')
    assert m[MAC:MAC + 256] == [0] * 256
    text = b"LIST=8,\nM3=bEN^Pw^\nM9=nope\nM1=" + b"x" * 40 + b"\n"
    m[0xC300:0xC300 + len(text) + 1] = list(text) + [0]
    m[0x34], m[0x35] = 0x00, 0xC3
    mem_get_stub(m); t.call('cfg_parse')
    assert bytes(m[MAC + 64:MAC + 72]) == b"bEN^Pw^\0"
    assert bytes(m[MAC:MAC + 32]) == b"x" * 31 + b"\0"                 # 31 at most
    assert m[MAC + 32] == 0 and cfg_text(t, 0, 3) == '8'               # M9 ignored
    t.chrout.clear(); t.call('cfg_write')
    assert b'M1=' not in bytes(t.chrout)                               # settings only
    t.chrout.clear(); t.call('mac_write')                              # ZENCOM.MAC
    assert bytes(t.chrout) == (b"#ZENCOM MACROS (M ON THE MENU), PLAIN TEXT\n"
                               b"M1=" + b"x" * 31 + b"\nM3=bEN^Pw^\n")
    m[lbl['mode']] = 1; m[lbl['lost']] = 0                             # PETSCII: as typed
    m[0xD020] = 0; t.sent.clear()
    t.call('key_send', 0xA7)
    assert t.var('mac_wait') == 1 and m[0xD020] == 7 and t.sent == []
    t.call('key_send', ord('3'))
    assert bytes(t.sent) == b"BEN\rPW\r" and m[0xD020] == 0 and t.var('mac_wait') == 0  # (a-z: as typed)
    t.sent.clear(); t.call('key_send', 0xA7); t.call('key_send', ord('X'))
    assert t.sent == [] and t.var('mac_wait') == 0                      # cancelled
    t.call('key_send', ord('2')); assert t.sent == [ord('2')]          # empty slot? no: plain key

def test_multi_punter_header():
    # Multi-Punter: CTRL-Is, NAME,T + CR before each file; CTRL-D x16 ends
    XB_NAME = 0xC520                                       # (MP_NAME = GUESS)
    for feed, want in ((b'\t' * 16 + b'\x00MULTI,TWO,S\r', (0, 0, 'MULTI-TWO')),
                       (b'\t' * 3 + b'\x04' * 16 + b'\r', (1, 0, None)),
                       (b'\tjunk\r', (None, 1, None)),
                       (b'\tA VERY LONG NAME IS CUT,P\r', (None, 1, None))):  # 18 kept: no ,T
        t = fresh(); m = t.mpu.memory
        buf = 0xC400
        m[buf:buf + len(feed)] = list(feed); m[0xC1F0] = 0; m[0xC1F1] = len(feed)
        # ser_get stub: next byte of the feed (C=0), C=1 when it runs out
        m[0xC100:0xC113] = [0xAE, 0xF0, 0xC1, 0xEC, 0xF1, 0xC1, 0xB0, 0x09, 0xBD, 0x00, 0xC4,
                            0xEE, 0xF0, 0xC1, 0x18, 0x60, 0x38, 0x60, 0x60]
        m[0x30], m[0x31] = 0x00, 0xC1
        m[0xFFE4:0xFFE7] = [0xA9, 0x00, 0x60]              # GETIN: no key
        m[lbl['acia_on']] = 0; m[lbl['tn_seen']] = 0
        ticks = [0]
        def tick():
            ticks[0] += 1
            if ticks[0] % 20 == 0: m[0xA1] = (m[0xA1] + 1) & 0xFF   # time runs on
        mpu = t.mpu; mpu.sp = 0xFD
        for v in (0xBF, 0xFE): m[0x100 + mpu.sp] = v; mpu.sp -= 1
        mpu.pc = lbl['mp_header']
        while mpu.pc != 0xBFFF:
            t.step(); tick()
        a, c, name = want
        assert mpu.p & 1 == c, feed
        if c == 0:
            assert mpu.a == a, feed
        if name:
            n = bytes(m[XB_NAME:XB_NAME + 17]).split(b'\0')[0]
            assert n == name.encode(), n

def test_up9600_receive():
    # the SDR holds the byte bit-reversed; the second NMI after a start bit
    # puts it in the ring; RTS (PB1) drops when nearly full, rises drained
    t = fresh(); m = t.mpu.memory
    t.call('up9_init')
    rev = lambda b: int(f'{b:08b}'[::-1], 2)
    assert all(m[0xC540 + i] == rev(i) for i in range(128))
    def nmi(byte):
        mpu = t.mpu
        m[0xDD0C] = rev(byte)
        for state in (0, 1):
            m[0xDD0D] = 0x90 if state == 0 else 0x88               # FLAG, then SDR
            mpu.sp = 0xF0
            for v in (0xBF, 0xFF, 0x20): m[0x100 + mpu.sp] = v; mpu.sp -= 1
            mpu.pc = lbl['up9_nmi']
            while mpu.pc != 0xBFFF: mpu.step()
    for b in b'Hi\xff\x00\x81':
        nmi(b)
    got = []
    for _ in range(5):
        t.call('up9_get'); got.append(t.mpu.a)
    assert bytes(got) == b'Hi\xff\x00\x81'
    t.call('up9_get'); assert t.mpu.p & 1                         # empty
    m[0xDD01] = 0xFF
    for i in range(192): nmi(i)
    assert t.var('rts_off') == 1 and m[0xDD01] & 2 == 0               # held
    for i in range(140): t.call('up9_get')
    assert t.var('rts_off') == 0 and m[0xDD01] & 2 == 2               # going again

def test_io_quiet_live_acia_only():
    # io_live on the ACIA must not start the UP9600 driver: a BNE after
    # STA tested LDX's flags and fell into up9_enable (XMODEM broke in VICE)
    for rts in (0, 1):
        t = fresh(); m = t.mpu.memory
        m[lbl['acia_on']] = 1; m[lbl['up9_on']] = 0; m[lbl['rts_off']] = rts
        m[0x0314], m[0x0315] = 0x31, 0xEA
        t.call('io_quiet'); assert m[0xDE02] == 0x03 and t.var('io_depth') == 1
        t.call('io_live')
        assert m[0xDE02] == (0x01 if rts else 0x09) and t.var('io_depth') == 0
        assert (m[0x0314], m[0x0315]) == (0x31, 0xEA)                  # IRQ untouched

def test_multi_punter_header_before_c_d():
    # boards send the first header at once: it is often in RECENT already
    t = fresh(); m = t.mpu.memory; RECENT = 0xC4A0
    text = b'START YOUR BATCH\r' + b'\t' * 16 + b'MULTI ONE,P\r'
    ring = (bytes(128) + text)[-128:]
    pos = 37                                               # (the ring wraps)
    for i, b in enumerate(ring): m[RECENT + (pos + i) % 128] = b
    m[lbl['rc_pos']] = pos; m[lbl['mp_first']] = 1
    t.call('mp_header')
    assert t.mpu.p & 1 == 0 and t.mpu.a == 0 and t.var('mp_first') == 0
    assert bytes(m[0xC520:0xC520 + 10]) == b'MULTI ONE\0'

def test_multi_punter_header_split():
    # the CTRL-Is (and part of the name) came before C=+D, the rest after
    for before, after in ((b'\t' * 16 + b'MULT', b'I ONE,P\r'), (b'\t' * 16, b'\t\tMULTI ONE,P\r')):
        t = fresh(); m = t.mpu.memory; RECENT = 0xC4A0
        ring = (bytes(128) + b'START\r' + before)[-128:]
        m[RECENT:RECENT + 128] = list(ring); m[lbl['rc_pos']] = 0; m[lbl['mp_first']] = 1
        m[0xC400:0xC400 + len(after)] = list(after); m[0xC1F0] = 0; m[0xC1F1] = len(after)
        m[0xC100:0xC113] = [0xAE, 0xF0, 0xC1, 0xEC, 0xF1, 0xC1, 0xB0, 0x09, 0xBD, 0x00, 0xC4,
                            0xEE, 0xF0, 0xC1, 0x18, 0x60, 0x38, 0x60, 0x60]
        m[0x30], m[0x31] = 0x00, 0xC1
        m[0xFFE4:0xFFE7] = [0xA9, 0x00, 0x60]
        m[lbl['acia_on']] = 0; m[lbl['tn_seen']] = 0
        t.call('mp_header')
        assert t.mpu.p & 1 == 0 and t.mpu.a == 0, before
        assert bytes(m[0xC520:0xC520 + 10]) == b'MULTI ONE\0', bytes(m[0xC520:0xC530])

def test_macro_skips_what_the_editor_would_not_allow():
    # a ZENCOM.MAC edited elsewhere: C=+M, F5, controls are skipped (a macro
    # that called itself would recurse until the stack overran)
    t = fresh(); m = t.mpu.memory; MAC = 0xC800 + 0x600
    m[lbl['mode']] = 1; m[lbl['lost']] = 0
    m[MAC:MAC + 10] = [0x41, 0xA7, 0x31, 0x87, 0x05, 0x5E, 0xC1, 0x5F, 0x42, 0]
    t.sent.clear(); t.call('key_send', 0xA7); t.call('key_send', ord('1'))
    assert bytes(t.sent) == b'A1\r\xc1B' and t.var('mac_wait') == 0

def test_download_type_chosen_with_t():
    # T cycles guess -> PRG -> SEQ; a chosen type is set before the data
    # comes (no guessing), SEQ strips ^Z, and the finishing line says so
    t = fresh(); m = t.mpu.memory
    m[lbl['x_force']] = 0
    seen = []
    for _ in range(3):
        t.call('dl_tnext'); seen.append(t.var('x_force'))
    assert seen == [1, 2, 0]
    for force, typ, strip in ((1, ord('P'), 0), (2, ord('S'), 1)):
        m[lbl['x_force']] = force; m[lbl['x_type']] = 0; m[lbl['x_strip']] = 0
        t.call('dl_force')
        assert (t.var('x_type'), t.var('x_strip')) == (typ, strip)
        t.call('dl_guess')                                   # (skipped: chosen)
        assert t.var('x_type') == typ
        t.call('dl_tchosen'); assert t.mpu.p & 1
    m[lbl['x_force']] = 0; m[lbl['x_type']] = 0
    t.call('dl_force'); assert t.var('x_type') == 0
    t.call('dl_tchosen'); assert not t.mpu.p & 1

def test_scroll_back_wiped_at_the_menu():
    # echoed passwords mustn't carry into the next call's C=+B: the ring
    # is emptied and zeroed, and nothing past it ($FF40-, the vectors)
    t = fresh(); m = t.mpu.memory
    m[0xE000:0xFF40] = [0x55] * 0x1F40; m[0xFF40:0x10000] = [0xAA] * 0xC0
    m[lbl['sb_count']] = 100; m[lbl['sb_head']] = 37
    t.call('sb_wipe')
    assert m[0xE000:0xFF40] == [0] * 0x1F40 and m[0xFF40:0x10000] == [0xAA] * 0xC0
    assert t.var('sb_count') == 0 and t.var('sb_head') == 0

def _login_rig():
    t = fresh(); m = t.mpu.memory
    return t, m, 0x6000, 0xC800 + 0x700, 0xC800 + 0x740       # PWD_BUF, LOGIN, LOG_ED

def test_login_key_is_crc32_of_the_address():
    import zlib
    t, m, *_ = _login_rig()
    for host, raw in (('bbs.example.com:23', b'bbs.example.com:23'),
                      ('vert.synchro.net:23', b'VERT.SYNCHRO.NET:23'),        # unshifted (ASCII caps)
                      ('ssbbs.ddns.net:6510', bytes(c | 0x80 if 0x41 <= c <= 0x5A else c
                                                    for c in b'SSBBS.DDNS.NET:6510'))):  # PETSCII caps
        m[0xC400:0xC400 + len(raw) + 1] = list(raw) + [0]
        t.mpu.y = 0xC4; t.call('pwd_crc', 0x00)
        want = f'{zlib.crc32(host.encode()):08X}'.encode()
        assert bytes(m[lbl['pwd_key']:lbl['pwd_key'] + 8]) == want, (host, want)

def test_login_find_and_rewrite():
    # ZENCOM.PWD in PWD_BUF: KEY|USER|PASSWORD lines (made-up logins only)
    t, m, BUF, LOGIN, LOG_ED = _login_rig()
    text = (b'# my boards\n0000AAAA|alice|pw1\r\nDEADBEEF|bob|s3cr^t\nbroken line\n'
            b'12345678|carol|x')
    m[BUF:BUF + len(text)] = list(text)
    m[lbl['pwd_len']], m[lbl['pwd_len'] + 1] = len(text) & 255, len(text) >> 8
    def key(k): m[lbl['pwd_key']:lbl['pwd_key'] + 8] = list(k)
    def found(at):
        return (bytes(m[at:at + 32]).split(b'\0')[0], bytes(m[at + 32:at + 64]).split(b'\0')[0])
    key(b'DEADBEEF'); t.mpu.y = LOGIN >> 8; t.call('pwd_find', LOGIN & 255)
    assert not t.mpu.p & 1 and found(LOGIN) == (b'bob', b's3cr^t')
    key(b'12345678'); t.mpu.y = LOGIN >> 8; t.call('pwd_find', LOGIN & 255)
    assert not t.mpu.p & 1 and found(LOGIN) == (b'carol', b'x')               # (no line end)
    key(b'FFFFFFFF'); t.mpu.y = LOGIN >> 8; t.call('pwd_find', LOGIN & 255)
    assert t.mpu.p & 1 and found(LOGIN) == (b'', b'')                          # no match: none
    # an edit: bob's address changed (old key DEADBEEF -> new 11112222)
    m[lbl['pwd_old']:lbl['pwd_old'] + 8] = list(b'DEADBEEF'); key(b'11112222')
    m[LOG_ED:LOG_ED + 64] = [0] * 64
    m[LOG_ED:LOG_ED + 4] = list(b'bob2'); m[LOG_ED + 32:LOG_ED + 36] = list(b'new!')
    t.chrout.clear(); t.call('pwd_write')
    HEAD = b'#ZENCOM LOGINS (E IN THE DIRECTORY): KEY|USER|PASSWORD\n'
    assert bytes(t.chrout) == HEAD + (b'# my boards\n0000AAAA|alice|pw1\nbroken line\n12345678|carol|x\n'
                                      b'11112222|bob2|new!\n')
    # saved again: the header isn't doubled
    out = bytes(t.chrout); m[BUF:BUF + len(out)] = list(out)
    m[lbl['pwd_len']], m[lbl['pwd_len'] + 1] = len(out) & 255, len(out) >> 8
    m[LOG_ED] = 0; m[LOG_ED + 32] = 0
    t.chrout.clear(); t.call('pwd_write')
    assert bytes(t.chrout).count(b'#ZENCOM') == 1 and bytes(t.chrout).startswith(HEAD)
    m[BUF:BUF + len(text)] = list(text)
    m[lbl['pwd_len']], m[lbl['pwd_len'] + 1] = len(text) & 255, len(text) >> 8
    # a delete: no login to add, the line just goes
    m[LOG_ED] = 0; m[LOG_ED + 32] = 0; key(b'0000AAAA'); m[lbl['pwd_old']:lbl['pwd_old'] + 8] = list(b'0000AAAA')
    t.chrout.clear(); t.call('pwd_write')
    assert b'alice' not in bytes(t.chrout) and b'bob|' in bytes(t.chrout)

def test_login_keys_send_user_and_password():
    t, m, BUF, LOGIN, LOG_ED = _login_rig()
    m[lbl['mode']] = 1; m[lbl['lost']] = 0
    m[LOGIN:LOGIN + 64] = [0] * 64
    t.sent.clear(); t.call('key_send', 0xAA)                                    # none yet
    assert t.sent == []
    bob = bytes([0xC2, 0x4F, 0x42])                                            # "Bob" as typed (PETSCII)
    m[LOGIN:LOGIN + 3] = list(bob); m[LOGIN + 32:LOGIN + 38] = [0x50, 0x5E, 0x53, 0x53, 0x21, 0x87]
    t.sent.clear(); t.call('key_send', 0xAA)
    assert bytes(t.sent) == bob + b'\r'
    t.sent.clear(); t.call('key_send', 0xAF)                                    # ^ as itself; F5 no
    assert t.sent == [0x50, 0x5E, 0x53, 0x53, 0x21, 13] and t.var('st_raw') == 0
    t.call('login_clear'); assert m[LOGIN:LOGIN + 64] == [0] * 64

def test_bbs_list_header_round_trip():
    # the seed list starts with a # header: skipped when read, written back
    t = fresh(); m = t.mpu.memory
    import os
    seed = open(os.path.join(os.path.dirname(__file__), '..', 'data', 'bbslist.seq'), 'rb').read()
    assert seed.startswith(b'#ZENCOM BBS LIST')
    parse_text(t, seed.decode('latin-1'))
    assert t.var('n_ent') == seed.count(b'\n') - 1
    t.chrout.clear(); t.call('list_write')
    assert bytes(t.chrout) == seed

def test_call_end_wipes_typed_text():
    # passwords: the typed line and the name kept from it are zeroed, not
    # just forgotten, when a call ends (recent_clear: call_lost, the menu)
    t = fresh(); m = t.mpu.memory
    LINE, NAME = 0xC800 + 0x100, 0xC800 + 0x500
    m[LINE:LINE + 64] = [0x41] * 64; m[NAME:NAME + 17] = [0x42] * 17
    m[lbl['line_len']] = 9; m[lbl['last_len']] = 9
    t.call('recent_clear')
    assert m[LINE:LINE + 64] == [0] * 64 and m[NAME:NAME + 17] == [0] * 17
    assert t.var('line_len') == 0 and t.var('last_len') == 0

def test_settings_drive_check():
    t = fresh(); m = t.mpu.memory; SET = 0xC800 + 0x400
    for txt, bad in ((b'', 0), (b'8', 0), (b'30', 0), (b'7', 1), (b'31', 1), (b'X', 1), (b'1A', 1)):
        m[SET:SET + 3] = list(txt.ljust(3, b'\0'))
        t.call('dev_check', 0)
        assert (t.mpu.p & 1) == bad, txt

def test_scroll():
    t = fresh()
    for i in range(30): t.feed("line %02d\r\n" % i)
    txt = t.text()
    assert txt[0] == "line 07" and txt[22] == "line 29" and txt[23] == ""

def test_erase():
    t = fresh()
    t.feed("\x1b[HABCDEFGHIJ\x1b[1;5H\x1b[K\x1b[2;1H0123456789\x1b[2;5H\x1b[1K")
    t.feed("\x1b[3;1Hkeep\x1b[4;1Hgone\x1b[4;1H\x1b[J")
    assert t.text(4) == ["ABCD", "     56789", "keep", ""]

def test_dsr_reports_24x80():
    t = fresh(); t.sent.clear()
    t.feed("\x1b[255;255H\x1b[6n")
    assert bytes(t.sent) == b"\x1b[24;80R"

def test_telnet_negotiation():
    t = fresh(); t.sent.clear()
    t.feed(bytes([255,251,1, 255,251,3, 255,253,24, 255,251,5, 255,250,24,1,255,240]))
    assert t.sent == [255,253,1, 255,253,3, 255,252,24, 255,254,5]
    t.feed(b"\x1b[2Jok")
    assert t.text(1) == ["ok"]

def test_sgr_colour_cells():
    t = fresh()
    t.feed("\x1b[H   \x1b[1;31;44mX\x1b[0;32mY\x1b[0m")
    m = t.mpu.memory
    assert m[0x4401] == 0xA6 and m[0x4402] == 0x50

def test_keyboard_ansi_mode():
    t = fresh(); t.sent.clear()
    for k in [0x48, 0xC1, 0x0D, 0x91, 0x85, 0x14, 0xDB]: t.call('key_send', k)
    assert bytes(t.sent) == b"hA\r\x1b[A\x1b\x08{"

def test_acia_buffer_and_flow_control():
    t = C64(); m = t.mpu.memory
    run_ticking(t, 'acia_init')
    assert m[0xDE02] == 0x09 and m[0x318] | m[0x319] << 8 == lbl['acia_nmi']
    for i in range(200): t.nmi(i)
    assert t.var('rts_off') and m[0xDE02] == 0x01     # RTS dropped
    m[0x30], m[0x31] = lbl['acia_get'] & 0xFF, lbl['acia_get'] >> 8
    got = []
    while True:
        t.call('ser_get')
        if t.mpu.p & 1: break
        got.append(t.mpu.a)
    assert got == list(range(200)) and m[0xDE02] == 0x09   # RTS restored

def test_petscii_mode():
    t = C64(); m = t.mpu.memory
    t.call('pet_mode_init'); t.chrout.clear()
    m[0xD4] = 1
    for b in [0x93, 0x22, 0x0D, 255, 255]: t.call('term_putc', b)
    assert t.chrout == [0x93, 0x22, 0x0D, 0xFF] and m[0xD4] == 0
    t.sent.clear(); t.call('key_send', 0x85)
    assert t.sent == [0x85]

def test_petscii_case_for_modem_text():
    t = C64(); m = t.mpu.memory
    t.call('pet_mode_init'); t.chrout.clear()
    for b in b"OK ab": t.call('term_putc', b)            # offline: the modem
    assert t.chrout == [0xCF, 0xCB, 0x20, 0x41, 0x42]
    m[lbl['online']] = 1; t.chrout.clear()               # online: the board
    for b in b"OK ab": t.call('term_putc', b)
    assert t.chrout == list(b"OK ab")
    m[lbl['online']] = 0; m[0xD018] = 0x15; t.chrout.clear()   # graphics set
    for b in b"OK ab": t.call('term_putc', b)
    assert t.chrout == [0x4F, 0x4B, 0x20, 0x41, 0x42]
    m[0xD018] = 0x17
    m[lbl['online']] = 0; m[lbl['driver']] = 1; t.chrout.clear()   # user port
    for b in b"OK": t.call('term_putc', b)
    assert t.chrout == list(b"OK")

from test_xmodem import *   # the transfer engine (overlay)

def test_cs_pause_holds_incoming_text():
    t = fresh(); m = t.mpu.memory
    m[0xD020] = 0x0E
    t.call('key_send', 0xAE)                       # C=+S: pause
    assert t.var('paused') == 1 and m[0xD020] == 2 and t.sent == []
    m[0xFFE4:0xFFE7] = [0xA9, 0x00, 0x60]          # GETIN: no key
    m[0x30], m[0x31] = lbl['acia_get'] & 255, lbl['acia_get'] >> 8   # ACIA driver
    t.nmi(ord('Z'))                                 # a byte arrives
    tail = t.var('rx_tail')
    mpu = t.mpu; mpu.sp = 0xFD; mpu.pc = lbl['main']
    for _ in range(20000): mpu.step()
    assert t.var('rx_tail') == tail                # not read while paused
    t.call('key_send', 0xAE)                       # and again: carry on
    assert t.var('paused') == 0 and m[0xD020] == 0x0E
    mpu.sp = 0xFD; mpu.pc = lbl['main']
    for _ in range(20000): mpu.step()
    assert t.var('rx_tail') != tail                # read now

def _drive_rig(paths, refuse=()):
    """dos_loc with the drive simulated: returns a function running one
    location and giving back the commands sent to the drive."""
    t = fresh(); m = t.mpu.memory; CFG = 0xC800 + 0x300                # RXBUF_AT+$300
    m[lbl['home_dev']] = 11
    t.call('cfg_defaults')
    for off, text in paths.items():
        b = text.encode() + b'\0'; m[CFG + off:CFG + off + len(b)] = list(b)
    STUB = 0xC100
    RES = 0xC1F0
    m[STUB:STUB + 4] = [0xAD, RES & 255, RES >> 8, 0x60]          # LDA RES RTS: the drive's code
    for name in ('dos_cmd', 'dos_status'): m[lbl[name]:lbl[name] + 3] = [0x4C, STUB & 255, STUB >> 8]
    m[lbl['dev_present']:lbl['dev_present'] + 2] = [0x18, 0x60]    # CLC RTS: drive there
    def run(loc):
        cmds, mpu = [], t.mpu
        mpu.sp = 0xFD; m[0x1FE], m[0x1FF] = 0xFE, 0xBF; mpu.pc, mpu.x = lbl['dos_loc'], loc
        while mpu.pc != 0xBFFF:
            if mpu.pc == STUB:
                m[RES] = 0
                if mpu.a:                                        # dos_cmd: A = length
                    a = mpu.x | mpu.y << 8; c = bytes(m[a:a + mpu.a]).decode(); cmds.append(c)
                    if c in refuse: m[RES] = 71                  # 71, DIRECTORY ERROR
            mpu.step()
        assert not mpu.p & 1
        return cmds
    return run, t

def test_short_folders_are_inside_zencoms_folder():
    C = dict(C_LPATH=3, C_DPATH=45, C_UPATH=87, C_HPATH=126)          # (src/zencom.s)
    run, t = _drive_rig({C['C_DPATH']: 'DOWNLOADS', C['C_UPATH']: 'UPLOADS/C64'})
    L_LIST, L_DOWN, L_UP = 0, 1, 2
    assert run(L_DOWN) == ['CD:DOWNLOADS']
    assert run(L_UP) == ['CD:..', 'CD:UPLOADS/C64']                 # up, then the sibling
    assert run(L_LIST) == ['CD:..', 'CD:..']                        # blank: ZenCom's folder
    assert run(L_LIST) == []                                        # already there

def test_full_paths_return_via_zencoms_folder_setting():
    C = dict(C_LPATH=3, C_DPATH=45, C_HPATH=126)
    run, t = _drive_rig({C['C_DPATH']: '/USB1/DL', C['C_HPATH']: '/USB1/ZC'})
    assert run(1) == ['CD:/USB1/DL']
    assert run(0) == ['CD:/USB1/ZC']                                # back via the setting
    assert run(1) == ['CD:/USB1/DL']

def test_browser_paths():
    t = fresh(); m = t.mpu.memory; PATH, NAME = 0xC3E0, 0xC100
    def setp(text): b = text.encode() + b'\0'; m[PATH:PATH + len(b)] = list(b)
    def getp(): return bytes(m[PATH:PATH + 40]).split(b'\0')[0].decode()
    def add(name):
        b = name.encode() + b'\0'; m[NAME:NAME + len(b)] = list(b)
        m[0x3C], m[0x3D] = NAME & 255, NAME >> 8                       # xptr
        t.call('path_add'); return t.mpu.p & 1
    def up(): t.call('path_up'); return t.mpu.p & 1
    setp(''); assert add('GAMES') == 0 and getp() == 'GAMES'
    assert add('C64') == 0 and getp() == 'GAMES/C64'
    assert add('..') == 0 and getp() == 'GAMES'                       # ".." is up
    assert up() == 0 and getp() == ''
    assert up() == 1 and getp() == ''                                 # the top
    setp('/USB1/BBS'); assert up() == 0 and getp() == '/USB1'
    assert up() == 0 and getp() == '/'
    assert up() == 1 and getp() == '/'
    assert add('USB1') == 0 and getp() == '/USB1'                     # no double slash
    setp('A' * 30); assert add('B' * 16) == 1 and getp() == 'A' * 30  # too long: unchanged

def _type_lines(t, *lines):
    m = t.mpu.memory; m[0x32], m[0x33] = 0x00, 0xC0      # ser_put -> the stub
    for line in lines:
        for c in line + b'\r': t.call('key_out', c)

def test_download_name_prefill():
    RECENT, NAME = 0xC4A0, 0xC3C0
    def run(board=b'', *typed):
        t = fresh(); m = t.mpu.memory
        ring = (bytes(128) + board)[-128:]
        m[RECENT:RECENT + 128] = list(ring); m[lbl['rc_pos']] = 0
        _type_lines(t, *typed)
        m[NAME:NAME + 17] = [0] * 17
        t.call('dl_prefill')
        return bytes(m[NAME:NAME + 17]).split(b'\0')[0]
    assert run(b'\rSENDING...\rFILE NAME = DARKOLUTION/ROLE\r') == b'DARKOLUTION-ROLE'
    assert run(b'\r#  FILENAME   TYPE BLOCKS\r 123 4!SPY VS SPY  P 7\r', b'4!SPY VS SPY') == b'4!SPY VS SPY'
    assert run(b'\r\xc6ILENAME: \xd3PY.PRG  \r') == b'SPY.PRG'          # PETSCII capitals
    assert run(b'filename: tetris\r\n') == b'TETRIS'                       # ASCII small letters
    assert run(b'nothing useful\r', b'ATDT HOST:6400') == b''               # an AT command: no
    assert run(b'Filename: a,b*c?d=e"f@g$h\r') == b'A-B-C-D-E-F-G-H'

def test_download_name_survives_the_boards_questions():
    # Boards ask "protocol?" and "sure?" after the name: those answers
    # replaced the typed name, so the guess was "Y" or "P"
    RECENT, NAME = 0xC4A0, 0xC3C0
    def run(*typed):
        t = fresh(); m = t.mpu.memory
        m[RECENT:RECENT + 128] = [0] * 128
        _type_lines(t, *typed)
        m[NAME:NAME + 17] = [0] * 17
        t.call('dl_prefill')
        return bytes(m[NAME:NAME + 17]).split(b'\0')[0]
    assert run(b'skate or die', b'p', b'y') == b'SKATE OR DIE'
    assert run(b'skate or die', b'12', b'yes') == b'SKATE OR DIE'
    assert run(b'd skate.prg', b'x') == b'SKATE.PRG'                     # a command word goes
    assert run(b'dl tetris.zip') == b'TETRIS.ZIP'
    assert run(b'atdt bbs.example:23', b'y') == b''                    # never an AT line
    assert run(b'1234', b'n') == b''                                   # digits only: no
    assert run(b'grand theft pacman extra long name') == b'GRAND THEFT PACM'
    assert run(b'a mind is born', b'1') == b'A MIND IS BORN'            # a short word stays
    assert run(b'do androids dream') == b'DO ANDROIDS DREA'           # (only D / DL go)

def test_cl_lower_case_lock():
    t = fresh(); m = t.mpu.memory
    m[lbl['mode']] = 1; m[0xD018] = 0x15
    t.call('key_send', 0xB6)                            # C=+L on
    assert t.var('caselock') == 1 and m[0xD018] == 0x17 and m[0xD020] & 15 == 6
    t.chrout.clear(); t.call('pet_out', 0x8E); t.call('pet_out', 0x0E); t.call('pet_out', 0x41)
    assert t.chrout == [0x41]                           # the board's set switches ignored
    t.call('key_send', 0xB6)                            # off
    t.chrout.clear(); t.call('pet_out', 0x8E)
    assert t.var('caselock') == 0 and t.chrout == [0x8E] and t.sent == []
    t = fresh(); m = t.mpu.memory; m[lbl['mode']] = 0; m[0xD018] = 0x18
    t.call('key_send', 0xB6)                            # ANSI mode: nothing
    assert t.var('caselock') == 0 and m[0xD018] == 0x18

def test_protocol_default_follows_the_board():
    RECENT = 0xC4A0
    for text, want in ((b'START YOUR DOWNLOAD\rGOOGOOGOO', 1), (b'GOODBYE AND GOOD LUCK', 0), (b'', 0)):
        t = fresh(); m = t.mpu.memory
        m[RECENT:RECENT + 128] = list((bytes(128) + text)[-128:])
        m[0xFFE4:0xFFE7] = [0xA9, 0x0D, 0x60]           # GETIN: Return
        t.call('xfr_proto')
        assert t.var('x_proto') == want, (text, t.var('x_proto'))

def test_up_falls_back_to_left_arrow():
    run, t = _drive_rig({45: 'DOWNLOADS', 87: 'UPLOADS'}, refuse=('CD:..',))  # SD2IEC / CMD
    assert run(1) == ['CD:DOWNLOADS']
    assert run(2) == ['CD:..', 'CD:_', 'CD:UPLOADS']

def test_auto_redial_blips_then_dials():
    t = fresh(); m = t.mpu.memory
    DIAL_BUF = 0xC800 + 0x140
    line = b'ATD bbs.example:23'
    m[DIAL_BUF:DIAL_BUF + len(line)] = list(line); m[lbl['dial_len']] = len(line)
    m[lbl['driver']] = 0
    m[0x32], m[0x33] = 0x00, 0xC0                       # ser_put -> the stub
    log = run_ticking(t, 'auto_dial')
    gates = [r[0xD404] for _, r in log]
    assert 0x11 in gates                                # a note played (gate on)
    assert bytes(t.sent) == line + b'\r' and t.var('auto_state') == 2

def test_volume_stays_up_between_sounds():
    # Turning the SID volume 0 -> full on each blip blanked the HDMI picture
    t = fresh(); m = t.mpu.memory
    m[0xD418] = 0x0F                                    # as left by the jingle
    t.mpu.x = lbl['seq_blip'] - lbl['seqs']
    mpu = t.mpu
    mpu.sp = 0xFD; m[0x1FE], m[0x1FF] = 0xFE, 0xBF; mpu.pc = lbl['play_seq']
    vols = []
    for i in range(400000):
        if mpu.pc == 0xBFFF: break
        if i % 50 == 0: m[0xA2] = (m[0xA2] + 1) & 0xFF
        mpu.step(); vols.append(m[0xD418])
    else:
        raise RuntimeError('timeout')
    assert set(vols) == {0x0F}, set(vols)

def test_screen_texts_fit_39_columns():
    # put_line_* start at column 1: the settings hint lost its last letters
    import os, re
    for f in ('src/zencom.s', 'src/xfr.s'):
        for i, l in enumerate(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', f)), 1):
            m = re.match(r'^(\w+):\s*\.byte\s+"([^"]*)",\s*0', l)
            assert not (m and len(m.group(2)) > 39), (f, i, m.group(1))

LNBUF, NAME = 0xB900, 0xC3C0

def _name(t):
    return bytes(t.mpu.memory[NAME:NAME + 17]).split(b'\0')[0]

def test_name_from_a_list_line():
    t = fresh(); m = t.mpu.memory
    for line, want in ((b'  123 4!SPY VS SPY     P     7 AUG 3\'14', b'4!SPY VS SPY'),
                       (b'>  1 AD INFINITUM     P   157 AUG 3\'14', b'AD INFINITUM'),
                       (b' 1!T.COMMUNICATIO P     6 AUG 3\'14', b'1!T.COMMUNICATIO'),
                       (b' 12. HELLO/WORLD: X', b'HELLO-WORLD- X'),
                       (b'   ...........', b'')):
        m[LNBUF:LNBUF + 40] = list(line.ljust(39)[:39] + b'\0')
        t.call('lx_name', 0)
        assert _name(t) == want, (line, _name(t))
    m[lbl['last_num']:lbl['last_num'] + 4] = list(b'123\0')
    m[LNBUF:LNBUF + 40] = list(b'  123 4!SPY VS SPY'.ljust(39) + b'\0')
    t.call('lx_numeq', 0); assert t.mpu.p & 1
    m[LNBUF:LNBUF + 40] = list(b'  1234 OTHER'.ljust(39) + b'\0')
    t.call('lx_numeq', 0); assert not t.mpu.p & 1

def test_ansi_screen_read_back():
    t = fresh(); m = t.mpu.memory
    t.feed("Files:\r\n  12 Tetris.prg     P  33\r\n\x1b[7mRev\x1b[0m")
    m[lbl['mode']] = 1; m[lbl['x_mode']] = 0          # the session was ANSI (now the PETSCII transfer screen)
    t.call('fin_build')
    n = t.var('fin_n'); lines = [bytes(m[LNBUF + i * 40:LNBUF + i * 40 + 39]).rstrip() for i in range(n)]
    assert lines[:3] == [b'FILES:', b'  12 TETRIS.PRG     P  33', b'REV'], lines

def test_name_list_leaves_out_zencoms_own_lines():
    # the hint and nudges ("-- ...") are ZenCom's, not the board's: not names
    t = fresh(); m = t.mpu.memory
    t.feed("-- C=+H: keys and help  F5: menu --\r\nFILE: GAME.PRG\r\n-- Board may be sending --\r\n- one\r\n")
    m[lbl['mode']] = 1; m[lbl['x_mode']] = 0
    t.call('fin_build')
    n = t.var('fin_n'); lines = [bytes(m[LNBUF + i * 40:LNBUF + i * 40 + 39]).rstrip() for i in range(n)]
    assert lines == [b'FILE: GAME.PRG', b'- ONE'], lines

def test_petscii_screen_copy():
    t = fresh(); m = t.mpu.memory
    m[0x0400:0x07E8] = [0x20] * 1000
    row = [0x31, 0x32, 0x20, 0x01, 0x02, 0x43]            # "12 ab" + capital C (lower/upper set)
    m[0x0400 + 80:0x0400 + 86] = row
    m[lbl['mode']] = 1; m[lbl['x_mode']] = 1
    t.call('snap_save'); t.call('fin_build')
    assert t.var('fin_n') == 1 and bytes(m[LNBUF:LNBUF + 6]) == b'12 ABC'

def test_type_guess():
    t = fresh(); m = t.mpu.memory
    for proto, ptype, data, want in ((0, 0, b'\x01\x08', 'P'), (0, 0, b'Hi', 'S'), (1, 1, b'\x01\x08', 'S'), (1, 0, b'Hi', 'P')):
        m[lbl['x_type']] = 0; m[lbl['x_strip']] = 0; m[lbl['x_proto']] = proto; m[lbl['pt_ftype']] = ptype
        m[0xBC00:0xBC02] = list(data)
        t.call('dl_guess')
        assert chr(t.var('x_type')) == want and t.var('x_strip') == (want == 'S')

def test_goo_nudge_once():
    t = fresh()
    for b in b'GOOGOOGOOGOOGOO': t.call('goo_watch', b)
    assert sum('Punter: C=+D to download, C=+U to upload' in r for r in t.text()) == 1
    t2 = fresh()
    for b in b'GOOD GOOD': t2.call('goo_watch', b)
    assert not any('Punter' in r for r in t2.text())

def test_number_typed_is_kept():
    t = fresh()
    for k in b'123\r': t.call('key_send', k)
    assert bytes(t.mpu.memory[lbl['last_num']:lbl['last_num'] + 4]) == b'123\0'
    for k in b'Y\r': t.call('key_send', k)                 # not a number: kept as it was
    assert bytes(t.mpu.memory[lbl['last_num']:lbl['last_num'] + 4]) == b'123\0'

def test_field_edit_down_with_a_bar():
    t = fresh(); m = t.mpu.memory
    m[0xFFE4:0xFFE7] = [0xA9, 0x11, 0x60]                 # GETIN: cursor down
    m[NAME:NAME + 4] = list(b'AB\0\0')
    m[0x36], m[0x37] = NAME & 255, NAME >> 8                   # eptr
    m[lbl['ed_row']] = 5; m[lbl['ed_off']] = 0; m[lbl['ed_max']] = 16
    m[lbl['fe_bar']] = 1; t.call('field_edit'); assert t.mpu.a == 2
    m[lbl['fe_bar']] = 0; t.call('field_edit'); assert t.mpu.a == 0

def test_finishing_screen_names_from_the_typed_number():
    t = fresh(); m = t.mpu.memory
    m[0x0400:0x07E8] = [0x20] * 1000
    def put(row, text):                                  # PETSCII lower/upper screen codes
        for i, ch in enumerate(text):
            c = ord(ch); m[0x0400 + row * 40 + i] = c - 0x40 if 'A' <= ch <= 'Z' else c
    put(3, '  122 3!SPY VS SPY     P   140')
    put(4, '  123 4!SPY VS SPY     P     7')
    put(6, ' DOWNLOAD #: 123')
    m[lbl['mode']] = 1; m[lbl['x_mode']] = 1; m[lbl['home_dev']] = 11; m[lbl['x_bdev']] = 11
    m[lbl['last_num']:lbl['last_num'] + 4] = list(b'123\0')
    t.call('snap_save')
    m[0xFFE4:0xFFE7] = [0xA9, 0x0D, 0x60]                 # GETIN: Return
    STUB, cmds = 0xC100, []
    m[STUB:STUB + 3] = [0xA9, 0x00, 0x60]
    m[lbl['dos_cmd']:lbl['dos_cmd'] + 3] = [0x4C, STUB & 255, STUB >> 8]
    mpu = t.mpu; mpu.sp = 0xFD; m[0x1FE], m[0x1FF] = 0xFE, 0xBF; mpu.pc = lbl['dl_finish']
    while mpu.pc != 0xBFFF:
        if mpu.pc == STUB:
            a = mpu.x | mpu.y << 8; cmds.append(bytes(m[a:a + mpu.a]))
        mpu.step()
    assert not mpu.p & 1 and cmds == [b'R:4!SPY VS SPY=ZCTMP'], cmds
    assert t.var('fin_bar') == 1                          # the bar on the 123 line

def test_f3_mono_repaints_the_screen():
    t = fresh(); m = t.mpu.memory
    t.feed("\x1b[31mred\x1b[0m \x1b[44mblue bg\x1b[0m")
    assert len(set(m[0x4400:0x4400 + 1000])) > 1
    t.call('key_send', 0x86)                            # F3: mono
    assert len(set(m[0x4400:0x47E8])) == 1 and t.var('colour_on') == 0

def test_cs_h_help_in_a_call_and_back():
    t = fresh(); m = t.mpu.memory
    m[0xFFE4:0xFFE7] = [0xA9, 0x20, 0x60]               # GETIN: a key
    m[lbl['mode']] = 0; m[0xDD00] = 0x02; m[0xD018] = 0x18; m[0xD011] = 0x3B
    bitmap = bytes(m[0x6000:0x6100])
    t.call('key_send', 0xB4)                             # ANSI: help, then back
    assert m[0xD018] == 0x18 and m[0xD011] == 0x3B and m[0xDD00] & 3 == 2
    assert bytes(m[0x6000:0x6100]) == bitmap and t.sent == []
    t = fresh(); m = t.mpu.memory
    m[0xFFE4:0xFFE7] = [0xA9, 0x20, 0x60]
    m[lbl['mode']] = 1; m[0xD018] = 0x17
    m[0x0400:0x0405] = [8, 5, 12, 12, 15]; m[0xD800] = 7
    t.call('key_send', 0xB4)                             # PETSCII: screen kept and put back
    assert m[0x0400:0x0405] == [8, 5, 12, 12, 15] and m[0xD800] & 15 == 7 and m[0xD018] == 0x17

def test_telnet_seen_per_call():
    t = fresh(); m = t.mpu.memory
    t.feed(b"\xff\xfb\x01")                             # IAC WILL ECHO: a telnet board
    assert t.var('tn_seen') == 1
    t.call('call_lost'); assert t.var('tn_seen') == 0
    t.feed(b"\xff\xff text")                             # a raw board's $FF: no negotiation
    assert t.var('tn_seen') == 0

def _rows_labelled(t):
    t.feed(''.join(f"\x1b[{r + 1};1HR{r:02d}" for r in range(24)))

def _first(t): return [row[:3] for row in t.text()]

def test_scroll_region_linefeed():
    t = fresh(); _rows_labelled(t)
    t.feed("\x1b[6;11r")                                # rows 6-11 (1-based): 5..10
    assert t.var('sr_top') == 5 and t.var('sr_bot') == 10 and t.var('row') == 0
    t.feed("\x1b[11;1H\n")                             # a line feed at the region's bottom
    r = _first(t)
    assert r[4] == 'R04' and r[5] == 'R06' and r[9] == 'R10' and r[10] == '' and r[11] == 'R11' and r[23] == 'R23'

def test_reverse_index_at_region_top():
    t = fresh(); _rows_labelled(t)
    t.feed("\x1b[6;11r\x1b[6;1H\x1bM")                 # ESC M at the top of the region
    r = _first(t)
    assert r[5] == '' and r[6] == 'R05' and r[10] == 'R09' and r[11] == 'R11' and r[4] == 'R04'
    t = fresh(); _rows_labelled(t)
    t.feed("\x1b[1;1H\x1bM")                            # whole screen: ESC M at the top scrolls down
    r = _first(t); assert r[0] == '' and r[1] == 'R00' and r[23] == 'R22'

def test_insert_and_delete_lines():
    t = fresh(); _rows_labelled(t)
    t.feed("\x1b[8;1H\x1b[2L")                          # two blank lines at row 7
    r = _first(t); assert r[6] == 'R06' and r[7] == '' and r[8] == '' and r[9] == 'R07' and r[23] == 'R21'
    t.feed("\x1b[8;1H\x1b[2M")                          # and gone again
    r = _first(t); assert r[7] == 'R07' and r[21] == 'R21' and r[22] == '' and r[23] == ''

def test_region_reset():
    t = fresh(); t.feed("\x1b[6;11r\x1b[r")
    assert t.var('sr_top') == 0 and t.var('sr_bot') == 23
    t.feed("\x1b[5;5r"); assert t.var('sr_top') == 0 and t.var('sr_bot') == 23   # one row: ignored

def test_scrollback_keeps_rows_and_pages():
    t = fresh(); m = t.mpu.memory
    m[lbl['mode']] = 1; m[0xD6] = 24; m[0xD3] = 0; m[0xDA] = 0x80   # bottom row; row 1 starts a line
    for n in range(30):                                 # 30 lines scroll off the top
        m[0x0400:0x0428] = [0x30 + n % 10] * 40; m[0xD800] = n & 15
        t.call('sb_check', 0x0D)
    assert t.var('sb_count') == 30 and t.var('sb_head') == 30
    assert m[0xE000 + 29 * 80] == 0x30 + 9 and m[0xE000 + 29 * 80 + 40] == 29 & 15
    m[lbl['sb_pos']] = 0; t.call('sb_page')             # newest at the bottom
    assert m[0x0400 + 23 * 40] == 0x30 + 9 and m[0x0400 + 22 * 40] == 0x30 + 8
    assert m[0x0400 + 24 * 40] & 0x80                   # the footer, reversed
    m[lbl['sb_pos']] = 6; t.call('sb_page')             # 6 older: the oldest (n=0) at the top
    assert m[0x0400] == 0x30 and m[0x0400 + 23 * 40] == 0x30 + 3
    t.call('sb_check', 0x41)                            # a letter mid-row: no scroll, nothing kept
    assert t.var('sb_count') == 30
    m[0xD3] = 39; t.call('sb_check', 0x41)              # ...in the last column: it wraps, kept
    assert t.var('sb_count') == 31

def test_scrollback_keeps_a_page_the_board_clears():
    # Boards clear between pages, so nothing scrolled: C=+B showed only old text
    t = fresh(); m = t.mpu.memory
    m[lbl['mode']] = 1; m[0xD6] = 5; m[0xD3] = 0
    m[0x0400:0x07E8] = [0x20] * 1000
    for r in (0, 2, 9):                                 # rows 0, 2, 9; 10-24 blank
        m[0x0400 + r * 40] = 0x01 + r
    t.call('sb_check', 0x93)
    assert t.var('sb_count') == 10                      # rows 0-9, the blank tail dropped
    assert [m[0xE000 + i * 80] for i in (0, 1, 2, 9)] == [0x01, 0x20, 0x03, 0x0A]
    m[0x0400:0x07E8] = [0x20] * 1000
    t.call('sb_check', 0x93)                            # a blank screen: nothing kept
    assert t.var('sb_count') == 10

def test_session_start_forgets_old_board_text():
    t = fresh(); m = t.mpu.memory
    RECENT = 0xC4A0
    m[RECENT:RECENT + 12] = list(b'GOOGOOGOOGOO')            # left in RAM from before a reset
    m[lbl['last_num']:lbl['last_num'] + 4] = list(b'123\0')
    run_ticking(t, 'acia_init')
    assert bytes(m[RECENT:RECENT + 12]) == bytes(12) and m[lbl['last_num']] == 0
    t.call('recent_goo'); assert not t.mpu.p & 1
    m[RECENT:RECENT + 6] = list(b'GOOGOO'); t.call('call_lost')
    t.call('recent_goo'); assert not t.mpu.p & 1

def _text40(t):
    m = t.mpu.memory
    def ch(c):
        c &= 0x7F
        return chr(c + 64) if 1 <= c <= 26 else chr(c) if 32 <= c < 64 else ' '
    return [''.join(ch(c) for c in m[0x0400 + r * 40:0x0400 + r * 40 + 40]) for r in range(25)]

def _start_rig(key, x_mode, goo=False):
    t = fresh(); m = t.mpu.memory
    m[0xFFE4:0xFFE7] = [0xA9, key, 0x60]                   # GETIN: this key
    m[lbl['dev_present']:lbl['dev_present'] + 2] = [0x18, 0x60]
    m[lbl['x_mode']] = x_mode; m[lbl['x_bdev']] = 11; m[lbl['home_dev']] = 11
    m[0xC4A0:0xC4A0 + 128] = list((bytes(128) + (b'GOOGOO' if goo else b''))[-128:])
    m[0xC520] = 0                                         # no guessed name
    t.call('dl_start')
    return t

def test_download_start_screen_defaults_and_keys():
    t = _start_rig(13, 1)
    assert t.var('x_proto') == 1                          # PETSCII: Return = Punter
    rows = _text40(t); assert 'RETURN STARTS THE DOWNLOAD' in rows[23] and 'BACK TO THE BOARD' in rows[24]
    assert 'SAVES TO' in rows[1] and 'DRIVE 11' in rows[2] and 'L CHANGES' in rows[3]
    assert _start_rig(13, 0).var('x_proto') == 0          # ANSI: Return = XMODEM
    t = _start_rig(13, 0, goo=True)                       # the board sending Punter
    assert t.var('x_proto') == 1 and any('THE BOARD IS SENDING' in r for r in _text40(t))
    assert _start_rig(ord('L'), 1).var('x_proto') == 2
    t = _start_rig(0x5F, 1); assert t.mpu.p & 1           # <- : back to the board

def test_result_line_on_the_board_screen():
    t = fresh(); m = t.mpu.memory
    m[lbl['mode']] = 0
    m[0xC3C0:0xC3C5] = list(b'TEST\0'); m[lbl['dl_res']] = 1
    t.call('dl_say')
    assert any("-- Saved TEST. Back on the board: press Return if it's quiet --" in r for r in t.text())
    m[lbl['dl_res']] = 6; m[lbl['xm_err']] = 2
    t.call('dl_say')
    assert any('-- Download failed: TOO MANY ERRORS. Nothing saved --' in r for r in t.text())

def test_screen_editor_state_comes_back():
    t = fresh(); m = t.mpu.memory
    m[0xD6] = 17; m[0xD3] = 12; m[0xD9 + 5] = 0x00; m[0xD020] = 6
    t.call('snap_save')
    m[0xD6] = 0; m[0xD3] = 0; m[0xD9 + 5] = 0x84; m[0xD020] = 0
    t.call('snap_restore')
    assert (m[0xD6], m[0xD3], m[0xD9 + 5], m[0xD020]) == (17, 12, 0x00, 6)

def test_q_quits_to_basic_with_the_modem_quiet():
    t = fresh(); m = t.mpu.memory
    STUB = 0xC100; m[STUB] = 0xEA                          # (stands in for the KERNAL reset)
    m[0xFFFC], m[0xFFFD] = STUB & 255, STUB >> 8
    m[0xDE01] = 0x55
    mpu = t.mpu; mpu.sp = 0xFD; mpu.pc = lbl['quit_basic']
    for _ in range(50):
        if mpu.pc == STUB: break
        mpu.step()
    assert mpu.pc == STUB and m[0xDE01] == 0 and mpu.p & 0x04   # reset, IRQs off, ACIA reset

def test_menu_warns_when_its_files_are_missing():
    t = fresh(); m = t.mpu.memory
    m[0x0400 + 24 * 40:0x0400 + 25 * 40] = [0x20] * 40
    m[lbl['xfr_ok']] = 1; t.call('menu_warn')
    assert 'FILES' not in _text40(t)[24]
    m[lbl['xfr_ok']] = 0; t.call('menu_warn')
    assert "ZENCOM'S FILES NOT FOUND" in _text40(t)[24]

def test_a_program_is_saved_as_prg_whatever_the_board_says():
    t = fresh(); m = t.mpu.memory
    prog = bytes([0x01, 0x08, 0x0B, 0x08, 0xE9, 0x07, 0x9E, 0x32, 0x30, 0x36, 0x31, 0x00])
    for proto, ptype, data, want, fixed in ((1, 1, prog, 'P', 1),          # Punter says SEQ: a program
                                            (1, 1, b'Hello there', 'S', 0),
                                            (0, 0, prog, 'P', 0)):
        m[lbl['x_type']] = 0; m[lbl['x_strip']] = 0; m[lbl['dl_tfix']] = 0
        m[lbl['x_proto']] = proto; m[lbl['pt_ftype']] = ptype
        m[0xBC00:0xBC00 + len(data)] = list(data)
        t.call('dl_guess')
        assert chr(t.var('x_type')) == want and t.var('dl_tfix') == fixed and t.var('x_strip') == (want == 'S')

def test_cursor_stops_at_region_margins():
    t = fresh()
    t.feed("\x1b[6;11r\x1b[8;1H\x1b[9A")                 # inside the region: up stops at its top
    assert t.var('row') == 5
    t.feed("\x1b[8;1H\x1b[9B"); assert t.var('row') == 10  # down stops at its bottom
    t.feed("\x1b[2;1H\x1b[30B"); assert t.var('row') == 10 # from above it: stops at its bottom
    t.feed("\x1b[20;1H\x1b[30A"); assert t.var('row') == 5 # from below: stops at its top
    t.feed("\x1b[r\x1b[8;1H\x1b[30A"); assert t.var('row') == 0  # no region: the screen's edges
    t.feed("\x1b[30B"); assert t.var('row') == 23

def test_insert_delete_erase_character():
    t = fresh()
    t.feed("ABCDEFGHIJ\x1b[1;3H\x1b[2P")                    # delete 2 at column 2 (even)
    assert t.text()[0] == 'ABEFGHIJ'
    t.feed("\x1b[1;4H\x1b[3P")                              # delete 3 at column 3 (odd)
    assert t.text()[0] == 'ABEIJ'
    t.feed("\x1b[1;2H\x1b[2@")                              # insert 2 blanks at column 1
    assert t.text()[0] == 'A  BEIJ'
    t.feed("\x1b[1;1H\x1b[3X")                              # erase 3: nothing moves
    assert t.text()[0] == '   BEIJ'
    t = fresh(); t.feed("\x1b[1;79HYZ\x1b[1;79H\x1b[5@")    # at the row's end: falls off
    assert t.text()[0].strip() == ''

def test_nudge_when_the_board_says_start_your_transfer():
    t = fresh()
    for b in b'Please start your XMODEM receive now.\r\n start your\r\n': t.call('goo_watch', b)
    rows = t.text()
    assert sum('may be sending: press C=+D' in r for r in rows) == 1   # once
    t2 = fresh()
    for b in b'\xd3ELECT \xd2\xc5\xc3\xc5\xc9\xd6\xc5 \xcdODE\r': t2.call('goo_watch', b)   # PETSCII capitals
    assert any('may be sending' in r for r in t2.text())
    t3 = fresh()
    for b in b'You have 3 new messages received.': t3.call('goo_watch', b)
    assert not any('may be sending' in r for r in t3.text())
    t4 = fresh()                                            # then GOOs: no second nudge
    for b in b'SELECT RECEIVE MODE\r\nGOOGOOGOOGOO': t4.call('goo_watch', b)
    rows = t4.text()
    assert sum('press C=+D' in r for r in rows) == 1 and not any('(Punter)' in r for r in rows)

def test_nudge_waits_for_the_end_of_the_boards_line():
    # It used to print at once and split the line ("START YOU" .. "R XMODEM")
    t = fresh()
    for b in b'START YOUR XMODEM DOWNLOAD\r\n>':
        t.call('goo_watch', b); t.call('term_putc', b)
    rows = [r for r in t.text() if r.strip()]
    assert rows[0] == 'START YOUR XMODEM DOWNLOAD' and 'may be sending' in rows[1], rows[:3]

def test_no_download_nudge_for_an_upload():
    # "START YOUR XMODEM UPLOAD" means the board waits for us: no "C=+D"
    t = fresh()
    for b in b'START YOUR XMODEM UPLOAD\r\n':
        t.call('goo_watch', b); t.call('term_putc', b)
    assert not any('may be sending' in r for r in t.text())

def test_overlay_exchange():
    # ovl_xchg itself (the harness normally does it in Python): the menu
    # overlay and the transfer code trade places, all RAM ($01 = $34)
    # meanwhile, and $01 comes back
    t = fresh(); m = t.mpu.memory; mpu = t.mpu
    a = [(i * 7) & 0xFF for i in range(0x1000)]; d = [(i * 13 + 5) & 0xFF for i in range(0x1000)]
    m[0xA000:0xB000] = a; m[0xD000:0xE000] = d; m[0x01] = 0x36; m[lbl['acia_on']] = 0
    mpu.sp = 0xFD
    for v in ((0xBFFE) >> 8, 0xBFFE & 0xFF):
        m[0x100 + mpu.sp] = v; mpu.sp -= 1
    mpu.pc, mpu.a = lbl['ovl_xchg'], 0xA0
    seen = set()
    while mpu.pc != 0xBFFF:
        mpu.step(); seen.add(m[0x01])
    assert m[0xA000:0xB000] == d and m[0xD000:0xE000] == a
    assert m[0x01] == 0x36 and 0x34 in seen
    assert m[0xFFFA] | m[0xFFFB] << 8 == lbl['sb_rti']

def test_menu_overlay_round_trip():
    # the menu overlay's code is where the labels say once swapped in, and
    # the transfer code's entry points are back after swapping out
    t = fresh(); m = t.mpu.memory
    m[lbl['xfr_ok']] = 1
    t.call('ovl_menu')
    assert t.var('ovl_in') == 1 and m[lbl['ovm_dir']] == 0x4C          # JMP directory
    assert m[lbl['ovm_dir'] + 1] | m[lbl['ovm_dir'] + 2] << 8 == lbl['directory']
    t.call('ovl_menu'); assert t.var('ovl_in') == 1                     # (already in)
    t.call('ovl_xfr')
    assert t.var('ovl_in') == 0 and m[0xA000:0xA003] == list(b'ZX\x03')
    m[lbl['xfr_ok']] = 0                                                 # no overlay file:
    t.call('ovl_menu'); assert t.var('ovl_in') == 0 and t.mpu.p & 1     # C=1, nothing swapped

def test_empty_list_only_adds():
    # No built-in list any more: with no boards, Return/I/B/X/E must not
    # act on an entry that isn't there
    t = fresh(); m = t.mpu.memory
    m[lbl['n_ent']] = 0; m[lbl['dir_sel']] = 0
    keys = [13, ord('I'), ord('B'), ord('X'), ord('E')]
    m[0xC1F0] = 0; m[0xC1F1:0xC1F1 + len(keys)] = keys; m[0xC1F1 + len(keys)] = 0
    m[0xC100:0xC10C] = [0xAE, 0xF0, 0xC1, 0xBD, 0xF1, 0xC1, 0xF0, 0x03, 0xEE, 0xF0, 0xC1, 0x60]  # ldx/lda/beq/inc/rts
    m[0xC10C] = 0x60
    m[0xFFE4:0xFFE7] = [0x4C, 0x00, 0xC1]                 # GETIN -> the key list
    bad = {lbl[n] for n in ('dir_go', 'dir_info', 'dir_mark', 'dir_del', 'dir_edit')}
    t.overlay('MENU')
    mpu = t.mpu; mpu.sp = 0xFD; mpu.pc = lbl['dir_key']
    for _ in range(20000):
        assert mpu.pc not in bad, hex(mpu.pc)
        t.step()
    assert m[0xC1F0] == len(keys)                          # all the keys were read

def test_xmodem_default_when_the_board_says_so():
    # Retro Campus (PETSCII): "PLEASE START XMODEM TRANSFER", but Return
    # picked Punter, the PETSCII default.  dl_start now asks recent_xm.
    RECENT = 0xC4A0
    for text, want in ((b'PLEASE START XMODEM TRANSFER\r', 1), (b'DOWNLOAD #: 12\r', 0),
                       (b'start your xmodem download\r', 1), (b'\xd8\xcd\xcf\xc4\xc5\xcd', 1)):
        t = fresh(); m = t.mpu.memory
        m[RECENT:RECENT + 128] = list((bytes(128) + text)[-128:])
        t.call('recent_xm')
        assert (t.mpu.p & 1) == want, text

def test_nudge_for_please_start_xmodem():
    t = fresh()
    for b in b'PLEASE START XMODEM TRANSFER\r\n':
        t.call('goo_watch', b); t.call('term_putc', b)
    assert any('may be sending' in r for r in t.text())

if __name__ == '__main__':
    import sys
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith('test_'):
            try: fn(); print('ok  ', name)
            except Exception as e: fails += 1; print('FAIL', name, repr(e))
    sys.exit(1 if fails else 0)
