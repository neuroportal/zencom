; =====================================================================
; ZENCOM - ANSI-80 / PETSCII-40 telnet terminal for the Commodore 64
;
; Build (cc65 suite):
;   ca65 -t none zencom.s -o zencom.o
;   ld65 -C zencom.cfg -o zencom.prg zencom.o
; Load:  LOAD "ZENCOM",8  /  RUN
;
; Modes   : ANSI-80   hires bitmap, 4x8 cells -> 80 columns x 24 rows
;           PETSCII-40 native text screen, bytes go straight to the
;           KERNAL screen editor (colours, cursor codes, graphics)
;           F7 switches between them at any time (screen is cleared)
; Comms   : 1 = 6551 ACIA at $DE00 (SwiftLink, Ultimate modem emulation,
;               VICE "ACIA" cartridge), NMI-driven, RTS flow control
;           2/3 = user port RS-232 via KERNAL (WiFi modems), 1200/2400
; Telnet  : IAC filtering; accepts WILL ECHO/SGA, refuses everything else
; ANSI    : CUU/CUD/CUF/CUB/CNL/CPL/CHA/VPA/CUP/HVP, ED, EL, SGR
;           (bold, reverse, 8 colours), save/restore cursor, DSR 6n
; CP437   : box drawing, shade and block characters approximated
; Keys    : F7 = switch ANSI-80 / PETSCII-40 (both modes)
;           ANSI mode: cursor keys -> ANSI, F1 = ESC, F3 = colour on/off,
;           DEL = backspace, shift-+ { shift-- } shift-@ ` shift-£ |
;           shift-up-arrow ~, CTRL-letters send control codes
;           PETSCII mode: every other key is sent unchanged
;           F5 = hang up (drop DTR) and return to the startup menu
; Dial    : type AT commands directly, e.g. ATDT bbs.example.com:23
; =====================================================================

; ---- hardware / KERNAL ----------------------------------------------
BITMAP   = $6000            ; VIC bank 1 ($4000-$7FFF)
SCREEN   = $4400            ; colour matrix for the bitmap
ACIA     = $DE00
NMIVEC   = $0318
RSSTAT   = $0297
COLOR    = $0286            ; KERNAL current text colour
GDCOL    = $0287            ; colour under the cursor
SHFLAG   = $0291            ; $80 = shift/C= charset toggle disabled
PNTR     = $D3              ; cursor column
TBLX     = $D6              ; cursor row
LDTB1    = $D9              ; line links: bit 7 clear = continues the row above
QTSW     = $D4              ; quote mode flag
INSRT    = $D8              ; pending inserts
PNT      = $D1              ; current screen line pointer
USER     = $F3              ; current colour line pointer
BLNSW    = $CC              ; 0 = cursor blink enabled
GDBLN    = $CE              ; character under the cursor
BLNON    = $CF              ; 1 = cursor currently drawn

CHRIN    = $FFCF
PLOT     = $FFF0
STATUS   = $90              ; KERNAL I/O status (ST)
SETLFS   = $FFBA
SETNAM   = $FFBD
OPEN     = $FFC0
CHKIN    = $FFC6
CHKOUT   = $FFC9
CLRCHN   = $FFCC
LISTEN   = $FFB1
SECOND   = $FF93
UNLSN    = $FFAE
SETMSG   = $FF90
LOAD     = $FFD5
MEMTOP   = $FF99
CLOSE    = $FFC3
TIME_LO  = $A2              ; jiffy clock, low byte (60 Hz)
GETIN    = $FFE4
CHROUT   = $FFD2

; ACIA settings.  Control: bit 4 = internal baud generator, 8N1.
; Baud nibble on a SwiftLink (3.6864 MHz crystal, double a stock 6551):
;   $8=2400 $A=4800 $C=9600 $E=19200 $F=38400
; Keep it at 9600-19200: a full-screen scroll takes ~0.1 s.
ACIA_CTRL     = $1C        ; 9600 on SwiftLink (4800 on a stock 6551)
ACIA_CMD_ON   = $09        ; DTR on, RX IRQ on, RTS asserted
ACIA_CMD_HOLD = $01        ; DTR on, RX IRQ on, RTS released (pause)
RX_HIGH       = 192        ; buffer level that drops RTS
RX_LOW        = 64         ; level that raises it again

COLS = 80
XFR_VER  = 3               ; bump when the overlay's interface changes
UP_TOP   = $C800            ; user-port RS-232 buffers go just below this
RXBUF_AT = $C800            ; free RAM, not part of the .prg ($C000 page
rxbuf    = RXBUF_AT         ; is left alone: the test harness uses it)
line_buf = RXBUF_AT+$100
dial_buf = RXBUF_AT+$140
dos_msg  = RXBUF_AT+$180   ; the drive's last status text (40)
ORDER    = RXBUF_AT+$1C0   ; directory order: bookmarks first (64)
EDIT_BUF = RXBUF_AT+$200   ; the entry being edited (128)
CMD_BUF  = RXBUF_AT+$280   ; a DOS command being built (48)
CFG      = RXBUF_AT+$300   ; settings, as text (see C_* offsets)
SET_EDIT = RXBUF_AT+$400   ; settings being edited
NAME_LINE = RXBUF_AT+$500  ; the last typed line that could be a file name (16 + 0)
MACROS   = RXBUF_AT+$600   ; 8 macros x 32 (31 + 0): M1=..M8= in ZENCOM.MAC
MAC_LEN  = 31
MAC_EDIT = $7000           ; the macro screen's copy (the bitmap is idle then)
LOGIN    = RXBUF_AT+$700   ; this call's login: user (31+0), password at +32
LOG_ED   = RXBUF_AT+$740   ; the board edit form's copy (the same layout)
RIBUF    = $F7              ; KERNAL RS-232: receive buffer pointer,
RIDBE    = $029B            ; its end (the NMI writes here)
RIDBS    = $029C            ; and start (we read here)
RECENT   = $C4A0            ; the board's last 128 bytes (rc_pos: next)
C_LDEV   = 0               ; drive numbers: 2 digits + 0
C_LPATH  = 3               ; folders: up to 38 + 0 (blank = current)
C_DDEV   = 42
C_DPATH  = 45
C_UDEV   = 84
C_UPATH  = 87
C_HPATH  = 126             ; ZenCom's own folder on the load drive
C_SPEED  = 165             ; SwiftLink speed as text (blank = 9600)
CFG_SIZE = 204             ; (the parser may write a folder's 39 there)
L_LIST   = 0               ; locations for dos_loc
L_DOWN   = 1
L_UP     = 2
L_HOME   = 3
ROWS = 24

; ---- zero page (BASIC area; BASIC never regains control) -------------
ptr      = $20
gidx     = $22              ; draw_glyph: glyph index
src      = $24
dst      = $26
len      = $28
cptr     = $2A
tmp      = $2C
tmp2     = $2D
getvec   = $30              ; indirect vectors for the active driver
putvec   = $32
bptr     = $34              ; BBS list: built-in text being parsed
eptr     = $36              ; BBS list: current entry
bget     = $38              ; BBS list: byte source (JMP indirect)
wvec     = $3A              ; safe_save: the writer routine
sb_ptr   = $44              ; scroll-back: ring line, colour row
sb_col   = $46

LIST_AT  = $8000            ; BBS list in free RAM ($8000-$9FFF, 8 KB)
ENT_SIZE = 128              ; one board: +0 mode 'A'/'P', +1 flags (1 =
MAX_ENT  = 64               ; bookmark), +2 name, +22 host:port, +65 note
E_MODE   = 0
E_FLAGS  = 1
E_NAME   = 2
E_HOST   = 22
E_NOTE   = 65
NAME_MAX = 19
HOST_MAX = 42
NOTE_MAX = 60
VIS      = 20               ; directory rows on screen, from row LIST_ROW
LIST_ROW = 2
MSG_ROW  = 22
FOOT1    = 23
FOOT2    = 24
DOS_MSG_MAX = 38
ED_NAME_ROW = 3             ; edit form rows (label on the row above)
ED_HOST_ROW = 6
ED_MODE_ROW = 10
ED_NOTE_ROW = 13
ED_USER_ROW = 17            ; the login (ZENCOM.PWD)
ED_PASS_ROW = 20
LGREY_C  = 15
CYAN_C   = 3
DGREY_C  = 11
YELLOW_C = 7
ORANGE_C = 8
HOME_DEV = $BA              ; KERNAL: the device ZenCom was loaded from

; =====================================================================
.segment "LOADADDR"
    .word $0801
.segment "CODE"
; BASIC stub: 10 SYS 2061
    .word stub_end, 10
    .byte $9E, "2061", 0
stub_end:
    .word 0

start:                      ; entry from BASIC: play the jingle once
    lda HOME_DEV            ; the drive ZenCom was loaded from (8-30)
    cmp #8
    bcc @h8
    cmp #31
    bcc @hk
@h8: lda #8
@hk: sta home_dev
    lda #$36                ; BASIC ROM out: $A000-$BFFF is RAM (the
    sta $01                 ; transfer overlay); BASIC never runs again
    lda #1
    sta jingle
    jsr xfr_find            ; ZENCOM.XFR (file transfers): fixes home_dev
    jsr cfg_load            ; ZENCOM.CFG from that drive (or defaults)
    jsr list_load           ; the BBS list (or the built-in one)
menu_start:                 ; also the target of F5 (hang up) and help
    ldx #$FF                ; BASIC never regains control: reset stack
    txs
    lda #2                  ; user-port file, if a session left it open
    jsr CLOSE
    jsr up9_off             ; (UP9600: the KERNAL's timers and vectors back)
    jsr ovl_xfr             ; the transfer code in (after the directory)
    jsr recent_clear        ; a call is over: forget what was typed in it
    jsr sb_wipe             ; and what the board showed (echoed passwords)
    jsr login_clear         ; and the board's login
    jsr pet_cursor_off
    jsr pet_mode_init       ; text screen (after a session in either mode)
    lda #$15                ; the menu uses the upper case/graphics set
    sta $D018
    lda #$80                ; and C=/shift mustn't flip it
    sta SHFLAG
    jsr draw_menu
    jsr menu_warn           ; ZenCom's own files not found: say so
    lda #0
    sta quick
    sta auto_state
    sta paused
    sta caselock
    sta flipcase
    lda jingle
    beq @wait
    lda #0
    sta jingle
    jsr play_jingle
@wait:
    jsr GETIN
    cmp #$85                ; F1: ACIA + PETSCII in one key
    beq @qp
    cmp #$89                ; F2: ACIA + ANSI
    beq @qa
    and #$7F                ; accept shifted keys too (shift lock)
    cmp #'H'
    bne @nd
    jmp show_help
@nd:
    cmp #'D'
    bne @ns
    jsr ovl_menu            ; (no overlay: the menu says so; stay)
    bcs @wait
    jmp ovm_dir
@ns:
    cmp #'S'
    bne @nm
    jsr ovl_menu
    bcs @wait
    jmp ovm_set
@nm:
    cmp #'M'
    bne @nq
    jsr ovl_menu
    bcs @wait
    jmp ovm_mac
@nq:
    cmp #'Q'
    bne @nh
    jmp quit_basic
@nh:
    ldx #0
    beq @nc
@qp:
    lda #'P'
    .byte $2C               ; BIT abs: skip next 2 bytes
@qa:
    lda #'A'
    sta quick
    ldx #0
    beq @chose
@nc:
    cmp #'1'
    beq @chose
    cmp #'!'
    beq @chose
    inx
    cmp #'2'
    beq @chose
    cmp #'"'
    beq @chose
    inx
    cmp #'3'
    beq @chose
    cmp #'#'
    beq @chose
    inx
    cmp #'4'
    beq @chose
    cmp #'$'
    beq @chose
    jmp @wait
@chose:
    stx tmp
    txa
    clc
    adc #MENU_OPT_ROW
    jsr hilite_row
    ldy #PROMPT_LEN-1       ; "CHOOSE A MODE"
@pr: lda prompt_mode,y
    sta $0400+MENU_PROMPT_ROW*40+2,y
    dey
    bpl @pr
    lda tmp
    beq @acia
    cmp #3
    bne @kp
    lda #2                  ; UP9600
    sta driver
    lda #0
    sta acia_on
    jsr up9_init
    jmp @go
@kp: cmp #1
    beq @up12
    lda #$0A                ; 2400 8N1
    .byte $2C               ; BIT abs: skip next 2 bytes
@up12:
    lda #$08                ; 1200 8N1
    ldx #1
    stx driver
    dex
    stx acia_on
    jsr up_init
    jmp @go
@acia:
    lda #0
    sta driver
    jsr acia_init
    lda #1
    sta acia_on
@go:
@mw:
    lda quick               ; F1/F2 already chose the mode
    bne @mk
    jsr GETIN
@mk:
    and #$7F
    cmp #'P'
    beq @pet
    cmp #'A'
    bne @mw
    jsr ansi_mode_init
    jmp @hint
@pet:
    jsr pet_mode_init
@hint:
    jsr sess_hint           ; the keys that matter, once

; ---- main loop -------------------------------------------------------
main:
    jsr carrier_check
    jsr auto_tick
    lda paused              ; C=+S: leave the text where it is; the ring
    bne @idle               ; fills and flow control holds the board
    jsr ser_get
    bcs @idle
    ldx rc_pos              ; the board's last 128 bytes (a download's
    sta RECENT,x            ; name is often in them)
    inx
    bpl @rc
    ldx #0
@rc: stx rc_pos
    jsr goo_watch           ; (keeps A)
    cmp #$0D                ; a new line from the board: what was typed
    beq @nl0                ; before it (hotkeys) isn't a file's name
    cmp #$0A
    bne @nl1
@nl0: ldx #0
    stx line_len
@nl1:
    pha
    jsr nc_match
    jsr cursor_hide
    pla
    jsr term_putc
    jmp @key
@idle:
    jsr cursor_show
@key:
    jsr GETIN
    cmp #0
    beq main
    jsr key_send
    jmp main

; ---- F5: drop DTR for half a second so the modem hangs up, then
; go back to the startup menu (which resets the stack)
hang_up:
    lda driver
    bne @up
    lda #$02                ; ACIA: DTR off, receive IRQ off
    sta ACIA+2
    bne @wait
@up:
    lda $DD03               ; user port: DTR is PB2 (an output: UP9600
    ora #$04                ; leaves it an input, pulled up = on)
    sta $DD03
    lda $DD01
    and #$FB
    sta $DD01
@wait:
    lda #30
    jsr wait_jiffies
    jmp menu_start

show_help:
    lda #<help_scr
    ldy #>help_scr
    ldx #HELP_SCR_TOK
    jsr unpack_scr
    lda #<help_col
    ldy #>help_col
    ldx #HELP_COL_TOK
    jsr unpack_col
@k: jsr GETIN
    beq @k
    jmp menu_start

f3_colour:                  ; F3 (ANSI): colour on/off.  To mono: the whole
    lda colour_on           ; screen now, not just new text (colour can't
    eor #1                  ; come back: it isn't kept)
    sta colour_on
    jsr update_color
    lda colour_on
    bne @r
    lda cur_color
    ldx #0
@mf: sta SCREEN,x
    sta SCREEN+$100,x
    sta SCREEN+$200,x
    sta SCREEN+$2E8,x
    inx
    bne @mf
@r: rts

help_session:               ; C=+H in a call: show help, any key returns.
    lda mode                ; ANSI: the bitmap stays where it is (bank 1);
    beq @an                 ; help goes on the text screen (bank 0).
    jsr snap_save           ; PETSCII: the screen is kept at $6000 first
    jmp @show
@an: jsr cursor_hide
    lda $DD00               ; VIC bank 0, text mode
    ora #$03
    sta $DD00
    lda #$1B
    sta $D011
    lda #$C8
    sta $D016
@show:
    lda #$15                ; the help page's character set
    sta $D018
    lda #<help_scr
    ldy #>help_scr
    ldx #HELP_SCR_TOK
    jsr unpack_scr
    lda #<help_col
    ldy #>help_col
    ldx #HELP_COL_TOK
    jsr unpack_col
@k: jsr GETIN
    beq @k
    lda mode
    beq @ab
    jmp snap_restore        ; PETSCII: the screen back
@ab: jmp ansi_show

recent_clear:               ; forget the board's text: the RECENT ring, the
    ldx #127                ; typed line and number, the GOO watch (keeps A)
    pha
    lda #0
@c: sta RECENT,x
    dex
    bpl @c
    ldx #63                 ; and the typed text itself (passwords): the
@w: sta line_buf,x          ; line being typed, the name kept from it
    cpx #17
    bcs @w2
    sta NAME_LINE,x
@w2: dex
    bpl @w
    sta rc_pos
    sta last_len
    sta line_len
    sta last_num
    sta NAME_LINE
    sta gw_i
    sta gw_n
    sta gw_shown
    sta ph_shown
    sta ph_pend
    jsr ph_reset
    pla
    rts

snap_save:                  ; PETSCII: screen, colours, $D018 -> SNAP
    jsr pet_cursor_off
    ldx #0
@sv: lda $0400,x
    sta SNAP,x
    lda $0500,x
    sta SNAP+$100,x
    lda $0600,x
    sta SNAP+$200,x
    lda $06E8,x
    sta SNAP+$2E8,x
    lda $D800,x
    sta SNAP+$400,x
    lda $D900,x
    sta SNAP+$500,x
    lda $DA00,x
    sta SNAP+$600,x
    lda $DAE8,x
    sta SNAP+$6E8,x
    inx
    bne @sv
    lda $D018
    sta hs_d018
    lda $D020
    sta hs_d020
    ldx #$F4-$D1            ; the screen editor's state: cursor row and
@ed: lda $D1,x              ; column, line pointers, line links ($D1-$F4)
    sta hs_ed,x
    dex
    bpl @ed
    rts

snap_restore:               ; ... and back
    ldx #0
@rs: lda SNAP,x
    sta $0400,x
    lda SNAP+$100,x
    sta $0500,x
    lda SNAP+$200,x
    sta $0600,x
    lda SNAP+$2E8,x
    sta $06E8,x
    lda SNAP+$400,x
    sta $D800,x
    lda SNAP+$500,x
    sta $D900,x
    lda SNAP+$600,x
    sta $DA00,x
    lda SNAP+$6E8,x
    sta $DAE8,x
    inx
    bne @rs
    lda hs_d018
    sta $D018
    lda hs_d020
    sta $D020
    ldx #$F4-$D1
@ed: lda hs_ed,x
    sta $D1,x
    dex
    bpl @ed
    lda #0                  ; (never back into quote/insert mode)
    sta QTSW
    sta INSRT
    jmp pet_cursor_on

ansi_show:                  ; the ANSI bitmap back on screen (bank 1), as
    lda $DD00               ; screen_init sets it, without clearing it
    and #$FC
    ora #$02
    sta $DD00
    lda #$18
    sta $D018
    lda #$3B
    sta $D011
    lda #$08
    sta $D016
    rts

draw_menu:
    lda #<menu_scr
    ldy #>menu_scr
    ldx #MENU_SCR_TOK
    jsr unpack_scr
    lda #<menu_col
    ldy #>menu_col
    ldx #MENU_COL_TOK
    ; fall through
unpack_col:                 ; RLE stream A/Y (token X) -> colour RAM
    pha
    lda #$D8
    bne unpack
unpack_scr:                 ; RLE stream A/Y (token X) -> screen $0400
    pha
    lda #$04
unpack:                     ; (see rle() in tools/gen_screens.py)
    sta dst+1
    pla
    sta src
    sty src+1
    stx tmp2
    ldy #0
    sty dst
@l: jsr @get
    cmp tmp2
    beq @run
    sta (dst),y
    jsr @inc
    jmp @l
@run:
    jsr @get                ; count (0 = end)
    beq @r
    tax
    jsr @get                ; value
@rl: sta (dst),y
    jsr @inc
    dex
    bne @rl
    beq @l
@r: rts
@get:
    lda (src),y
    inc src
    bne @g
    inc src+1
@g: cmp #0                  ; (Z for the count)
    rts
@inc:
    inc dst
    bne @i
    inc dst+1
@i: rts

hilite_row:                 ; A = screen row: option text turns white
    tax
    lda #<($D800+HILITE_COL)
    sta dst
    lda #>($D800+HILITE_COL)
    sta dst+1
@r: dex
    bmi @f
    lda dst
    clc
    adc #40
    sta dst
    bcc @r
    inc dst+1
    bne @r
@f: ldy #HILITE_LEN-1
    lda #1
@w: sta (dst),y
    dey
    bpl @w
    rts

; ---- start-up jingle: 1-3-5-8, each note paired with a DTMF high tone
play_jingle:
    lda #60                 ; let the display (and HDMI audio) settle first
    jsr wait_jiffies
    ldx #seq_jingle-seqs
    ; fall through
play_seq:                   ; X = offset into seqs: (note, jiffies)..., $FF
    txa
    pha
    ldx #$17                ; not $D418: the volume stays up between sounds
    lda #0                  ; (0 -> full blanked an HDMI picture)
@clr: sta $D400,x
    dex
    bpl @clr
    pla
    tax
    lda #$0F
    sta $D418               ; volume
    lda #$00
    sta $D405               ; attack/decay
    sta $D40C
    lda #$F4
    sta $D406               ; sustain full, short release
    sta $D40D
@note:
    ldy seqs,x
    bmi @end
    lda jing_lo,y
    sta $D400
    lda jing_hi,y
    sta $D401
    lda dtmf_lo,y
    sta $D407
    lda dtmf_hi,y
    sta $D408
    lda #$11                ; triangle, gate on
    sta $D404
    sta $D40B
    lda seqs+1,x
    jsr wait_jiffies
    lda #$10                ; gate off
    sta $D404
    sta $D40B
    lda #2
    jsr wait_jiffies
    inx
    inx
    bne @note
@end:
    lda #20
    jmp wait_jiffies

seqs:
seq_jingle:  .byte 0, 5, 1, 5, 2, 5, 3, 5, $FF          ; 1-3-5-8
seq_fanfare: .byte 0, 4, 1, 4, 2, 4, 3, 10, 2, 4, 3, 24, $FF
seq_blip:    .byte 3, 4, $FF                             ; auto redial: one more try

wait_jiffies:               ; A = 1/60 s ticks (keeps X)
    clc
    adc TIME_LO
@w: cmp TIME_LO
    bne @w
    rts

jing_lo:  .byte $CE, $DA, $26, $9C          ; C5 E5 G5 C6 (PAL)
jing_hi:  .byte $22, $2B, $34, $45
dtmf_lo:  .byte $6B, $DE, $3F, $9F          ; 1209 1336 1477 1633 Hz
dtmf_hi:  .byte $50, $58, $62, $6C

; ---- back to the menu when the call drops (ACIA only).  Carrier is
; whichever of DCD/DSR has been seen inactive: on the Ultimate DSR (bit 6)
; is 0 while connected and DCD reads 0 always; real modems use DCD.
; Neither ever inactive (lines tied): rely on the NO CARRIER text.  Act on a connected -> not
; connected change only.  After a second (for any last text) say so and
; wait for a key (key_send then returns to the menu).
carrier_check:
    lda lost
    beq @live
    cmp #1
    beq @timing
    rts                     ; 2: message shown, waiting for a key
@live:
    lda driver              ; status lines only on the ACIA
    bne @r
    lda ACIA+1              ; DCD (bit 5) / DSR (bit 6), 0 = active
    and #$60
    tax
    ora car_seen            ; a line seen inactive is a carrier line
    sta car_seen            ; (Ultimate: DSR; real modems: DCD)
    txa
    eor #$60                ; 1 = active
    and car_seen
    beq @off                ; no carrier line active
    lda #1
    sta online
@r: rts
@off:
    lda online
    beq @r
    jmp call_lost
@timing:
    lda TIME_LO
    cmp lost_at
    bne @r
    lda auto_state          ; auto redial: wait a minute and go again
    beq @closed
    lda #0
    sta lost
    jmp auto_wait
@closed:
    lda #2
    sta lost
    ldx #msg_closed-msgs
    jmp print_msg

call_lost:
    jsr recent_clear        ; the next call starts with nothing remembered
    lda #0
    sta online
    sta tn_seen             ; the next call starts without telnet
    sta tn_bin_in
    sta tn_bin_out
    lda TIME_LO
    clc
    adc #60
    sta lost_at
    lda #1
    sta lost
    rts

; "NO CARRIER" from the modem also ends the call (any driver; covers
; calls too short for DSR to be seen).  A = received byte, kept.
nc_match:
    pha
    ldx nc_idx
    cmp nc_str,x
    beq @hit
    ldx #0
    cmp nc_str
    bne @set
    inx
    bne @set
@hit:
    inx
    cpx #10
    bne @set
    ldx lost
    bne @z
    jsr call_lost
@z: ldx #0
@set:
    stx nc_idx
    pla
    ; fall through: NO ANSWER (the dial failed) also ends the attempt,
    ; but only offline so board text can't trigger it
na_match:
    pha
    ldx online
    bne @set0
    ldx na_idx
    cmp na_str,x
    beq @hit
    ldx #0
    cmp na_str
    bne @set
    inx
    bne @set
@hit:
    inx
    cpx #9
    bne @set
    ldx lost
    bne @set0
    jsr call_lost
@set0:
    ldx #0
@set:
    stx na_idx
    pla
    rts

na_str: .byte "NO ANSWER"

nc_str: .byte "NO CARRIER"

; ---- typed keys go through here: remember the line so that an ATD
; command can be redialled (F4, or R after a dropped call)
key_out:
    pha
    cmp #$0D
    beq @cr
    cmp #$08                ; BS (ANSI) / DEL (PETSCII): forget one
    beq @bs
    cmp #$14
    beq @bs
    ldx line_len
    cpx #LINE_MAX
    bcs @out
    sta line_buf,x
    inc line_len
    bne @out
@bs:
    ldx line_len
    beq @out
    dec line_len
    bne @out
@cr:
    ldx line_len
    stx last_len            ; (a download's name may be what was typed)
    jsr num_keep            ; (or the list line with the number typed)
    jsr name_keep
    ldx line_len
    cpx #3
    bcc @clr
    ldy #2                  ; starts with ATD in any case?
@ck:
    lda line_buf,y
    and #$5F
    cmp atd_str,y
    bne @clr
    dey
    bpl @ck
    stx dial_len            ; yes: keep it for redial
@cp:
    dex
    bmi @clr
    lda line_buf,x
    sta dial_buf,x
    jmp @cp
@clr:
    lda #0
    sta line_len
@out:
    pla
    jmp ser_put

name_keep:                  ; Return: a line that could be a file name ->
    ldx line_len            ; NAME_LINE.  Not answers like Y, P, 1 (boards
    cpx #4                  ; ask "protocol?", "sure?" after the name), not
    bcc @r                  ; AT..., and a download command goes ("D NAME",
    lda line_buf            ; "DL NAME"; not any short word: "A MIND IS BORN")
    and #$5F
    cmp #'A'
    bne @w
    lda line_buf+1
    and #$5F
    cmp #'T'
    beq @r
@w: ldy #0
    lda line_buf
    and #$5F
    cmp #'D'
    bne @l
    ldy #2
    lda line_buf+1
    cmp #' '
    beq @l
    and #$5F
    cmp #'L'
    bne @l0
    iny
    lda line_buf+2
    cmp #' '
    beq @l
@l0: ldy #0
@l: sty fin_t               ; a letter in what is left?
@lc: lda line_buf,y
    and #$5F
    cmp #'A'
    bcc @ln
    cmp #'Z'+1
    bcc @cp
@ln: iny
    cpy line_len
    bcc @lc
@r: rts
@cp: ldy fin_t
    ldx #0
@c: lda line_buf,y
    sta NAME_LINE,x
    inx
    iny
    cpy line_len
    bcs @e
    cpx #16
    bcc @c
@e: lda #0
    sta NAME_LINE,x
    rts

redial:                     ; resend the remembered ATD line + CR
    ldx #0
@l: cpx dial_len
    beq @cr
    lda dial_buf,x
    stx tmp2
    jsr ser_put             ; KERNAL calls in the user-port driver
    ldx tmp2                ; clobber X
    inx
    bne @l
@cr:
    lda dial_len
    beq @r
    lda #$0D
    jmp ser_put
@r: rts

atd_str: .byte "ATD"
LINE_MAX = 60

print_msg:                  ; X = offset into msgs; shown in either mode
    stx msg_x
    jsr cursor_hide
    lda #1
    sta swapcase
@m: ldx msg_x
    lda msgs,x
    beq @d
    inc msg_x
    jsr char_in
    jmp @m
@d: lda #0
    sta swapcase
    rts

msgs:
msg_closed:
    .byte 13, 10, 13, 10, "-- Call ended --", 13, 10
    .byte "F4 redial  F6 auto redial  F5 menu", 13, 10, 0
msg_wait:
    .byte 13, 10, "-- Redial in 1 min (any key stops) --", 13, 10, 0
msg_off:
    .byte 13, 10, "-- Auto redial off --", 13, 10, 0
msg_on:
    .byte 13, 10, "-- Connected --", 13, 10, 0
msg_goo:
    .byte 13, 10, "-- The board is sending (Punter): press C=+D --", 13, 10, 0
msg_sbansi:
    .byte 13, 10, "-- Scroll-back (C=+B) is for PETSCII mode so far --", 13, 10, 0
msg_noxfr:
    .byte 13, 10, "-- Transfers need ZENCOM.XFR with ZENCOM --", 13, 10, 0

; ---- auto redial (ACIA only: needs DSR to know a call is up).
; 1 = waiting a minute, 2 = dialled: success is 10 s online, failure is
; the call dropping (carrier_check) or nothing after ~45 s.
TIME_MID = $A1              ; jiffy clock middle byte: +1 every 4.27 s

auto_start:
    lda dial_len
    beq @no
    lda driver
    beq auto_dial
@no:
    rts
auto_dial:
    ldx #seq_blip-seqs      ; a blip on every try: still at it
    jsr play_seq
    jsr redial
    lda #2
    sta auto_state
    lda #0
    sta auto_ok
    lda TIME_MID
    clc
    adc #11                 ; ~47 s to get connected
    sta auto_at
    rts

auto_wait:
    lda #1
    sta auto_state
    lda #0
    sta online
    lda TIME_MID
    clc
    adc #14                 ; ~60 s
    sta auto_at
    ldx #msg_wait-msgs
    jmp print_msg

auto_stop:
    lda #0
    sta auto_state
    ldx #msg_off-msgs
    jmp print_msg

auto_tick:
    lda auto_state
    beq @r
    cmp #1
    bne @dialled
    lda TIME_MID
    cmp auto_at
    bne @r
    jmp auto_dial
@dialled:
    lda online
    beq @notyet
    lda auto_ok
    bne @check
    lda #1
    sta auto_ok
    lda TIME_MID
    clc
    adc #3                  ; ~10 s connected = a real login, not busy
    sta ok_at
@r: rts
@check:
    lda TIME_MID
    cmp ok_at
    bne @r
    lda #0
    sta auto_state
    ldx #msg_on-msgs
    jsr print_msg
    ldx #seq_fanfare-seqs
    jmp play_seq
@notyet:
    lda #0
    sta auto_ok
    lda TIME_MID
    cmp auto_at
    bne @r
    jmp auto_wait           ; no connection: try again in a minute

; =====================================================================
; BBS list (dialling directory): BBSLIST (SEQ; bbslist.seq on the stick),
; one board a line: NAME|HOST:PORT|A or P|*|note   (* = bookmark; the
; last two fields are optional).  Lines starting # are ignored.
; Saving writes BBSTMP, checks the drive said OK, then scratches BBSLIST
; and renames BBSTMP, so a failed write never loses the list.  Any drive
; error makes the list read-only for the session.
; =====================================================================
list_load:
    lda #0
    sta list_src
    sta list_ro
    sta save_err
    sta n_ent
    ldx #L_LIST
    jsr dos_loc
    bcc @drive
    inc list_ro             ; no drive: an empty list, read-only
    jmp empty_list
@drive:
    lda #<fname
    ldy #>fname
    ldx #fname_len
    jsr list_read
    lda n_ent
    bne @usb
    lda #<tname             ; a save interrupted before the rename
    ldy #>tname
    ldx #tname_len
    jsr list_read
    lda n_ent
    beq empty_list          ; drive but no file: empty, created on save
@usb:
    lda #1
    sta list_src
    jmp build_order

list_read:                  ; A/Y = name, X = length -> entries
    jsr io_quiet
    jsr list_read2
    jmp io_live
list_read2:
    sta tmp
    txa                     ; SETNAM: A = length, X/Y = name
    ldx tmp
    jsr SETNAM
    lda #3
    ldx cur_dev
    ldy #2
    jsr SETLFS
    lda #0
    sta eof_next
    jsr OPEN
    bcs @close
    ldx #3
    jsr CHKIN
    bcs @close
    lda #<file_get
    sta bget
    lda #>file_get
    sta bget+1
    jsr list_parse
@close:
    jsr CLRCHN
    lda #3
    jmp CLOSE

empty_list:                 ; (the seed list ships beside ZenCom instead
    lda #0                  ; of a built-in one)
    sta list_src
    sta n_ent
    jmp build_order

list_parse:                 ; bytes from (bget) -> entries at LIST_AT
    lda #0
    sta n_ent
    lda #<LIST_AT
    sta eptr
    lda #>LIST_AT
    sta eptr+1
@line:
    lda #0
    sta fld
    sta nlen
    sta hlen
    sta tlen
    sta skip
    sta lpos
    ldy #ENT_SIZE-1         ; blank entry: every field 0-terminated
@z: sta (eptr),y
    dey
    bpl @z
    lda #'A'
    ldy #E_MODE
    sta (eptr),y
@next:
    jsr get_b
    bcc @got
    jmp @eof
@got:
    cmp #$0D
    beq @eolj
    cmp #$0A
    bne @noteol
@eolj:
    jmp @eol
@noteol:
    ldx skip
    bne @next
    ldx lpos
    inc lpos
    cpx #0
    bne @nc
    cmp #'#'                ; comment line
    bne @nc
    inc skip
    bne @next
@nc:
    cmp #'|'
    bne @ch
    inc fld
    jmp @next
@ch:
    ldx fld
    bne @f1
    ldx nlen                ; 0: name
    cpx #NAME_MAX
    bcs @next
    inc nlen
    ldy #E_NAME
    jmp @store
@f1:
    dex
    bne @f2
    cmp #' '                ; 1: host:port (no spaces)
    beq @next
    ldx hlen
    cpx #HOST_MAX
    bcs @next
    inc hlen
    ldy #E_HOST
    jmp @store
@f2:
    dex
    bne @f3
    and #$5F                ; 2: mode
    cmp #'P'
    beq @m
    lda #'A'
@m: ldy #E_MODE
    sta (eptr),y
    jmp @next
@f3:
    dex
    bne @f4
    cmp #'*'                ; 3: flags, * = bookmark
    bne @nx
    lda #1
    ldy #E_FLAGS
    sta (eptr),y
@nx:
    jmp @next
@f4:
    dex
    bne @nx                 ; (more fields: ignored)
    ldx tlen                ; 4: note
    cpx #NOTE_MAX
    bcs @nx
    inc tlen
    ldy #E_NOTE
@store:                     ; A at (eptr) + Y + X
    pha
    txa
    sty tmp
    clc
    adc tmp
    tay
    pla
    sta (eptr),y
    jmp @next
@eol:
    jsr @commit
    lda n_ent
    cmp #MAX_ENT
    bcs @done
    jmp @line
@eof:
    jsr @commit
@done:
    rts
@commit:                    ; a line with a host becomes an entry
    lda hlen
    beq @nope
    inc n_ent
    lda eptr
    clc
    adc #ENT_SIZE
    sta eptr
    bcc @nope
    inc eptr+1
@nope:
    rts

get_b:  jmp (bget)

file_get:                   ; next byte of the open file, C=1 at the end
    lda eof_next
    bne @e
    jsr CHRIN
    pha
    lda STATUS
    tax
    and #$82                ; device missing / read timeout: give up
    bne @x
    txa
    and #$40                ; end of file: this byte is the last
    beq @ok
    lda #1
    sta eof_next
@ok:
    pla
    clc
    rts
@x: pla
@e: sec
    rts

ent_addr:                   ; A = entry number -> eptr (x128)
    pha
    lsr
    clc
    adc #>LIST_AT
    sta eptr+1
    pla
    and #1
    beq @e
    lda #$80
@e: sta eptr                ; (LIST_AT is page-aligned)
    rts

build_order:                ; ORDER = bookmarked entries, then the rest
    ldx #0                  ; (each group in file order)
    lda #1
    jsr @pass
    lda #0
@pass:
    sta tmp2
    ldy #0
@l: cpy n_ent
    bcs @r
    tya
    pha
    jsr ent_addr
    ldy #E_FLAGS
    lda (eptr),y
    and #1
    cmp tmp2
    bne @skip
    pla
    sta ORDER,x
    inx
    pha
@skip:
    pla
    tay
    iny
    bne @l
@r: rts

ent_delete:                 ; A = entry number: remove it, close the gap
    sta tmp2
@l: lda tmp2
    clc
    adc #1
    cmp n_ent
    bcs @last
    jsr ent_addr            ; source: next entry
    lda eptr
    sta bptr
    lda eptr+1
    sta bptr+1
    lda tmp2
    jsr ent_addr            ; destination: this one
    ldy #ENT_SIZE-1
@c: lda (bptr),y
    sta (eptr),y
    dey
    bpl @c
    inc tmp2
    jmp @l
@last:
    dec n_ent
    jmp build_order

; ---- drive helpers.  A location (L_LIST, L_DOWN, L_UP, L_HOME) is a
; drive plus an optional folder; with a folder ZenCom sends CD:<folder>
; (SD2IEC, Ultimate, CMD drives).  A short folder is inside ZenCom's own
; folder: ZenCom counts how deep it has gone on each drive (cd_depth) and
; steps back up with CD:<- first.  A full path (/...) loses count; ZenCom's
; folder setting, if a full path, finds the way back.  Blank: ZenCom's folder.
dos_loc:                    ; X = location: cur_dev set, folder entered.
    stx tmp2                ; C=1: no drive, or the folder failed
    cpx #L_HOME
    bne @d
    lda home_dev
    bne @dv
@d: lda loc_dev,x
    jsr cfg_dev
@dv: sta cur_dev
    ldx tmp2
    lda loc_path,x          ; folder text at CFG + offset
    clc
    adc #<CFG
    tax
    lda #>CFG
    adc #0
    tay
dos_go:                     ; cur_dev, X/Y = folder (0-terminated; blank =
    txa                     ; ZenCom's): drive there?  back to ZenCom's
    pha                     ; folder, then in.  C=1: no drive, or no folder
    tya
    pha
    jsr dev_present         ; nothing there: fail now, don't hang on it
    bcs @f
    jsr cd_origin
@f: pla
    sta src+1
    pla
    sta src
    bcs @no
    ldy #0
    lda (src),y
    bne cd_go_src
    jsr dos_status          ; no folder: just check the drive is there
    cmp #$FF
    beq @no
    clc
    rts
@no:
    sec
    rts

cd_go:                      ; X/Y = folder (0-terminated): CD:<folder> on
    stx src                 ; cur_dev, counting the levels.  C=1: failed
    sty src+1
cd_go_src:
    ldx #0
@c1: lda cd_pre,x
    sta CMD_BUF,x
    inx
    cpx #3
    bne @c1
    ldy #0
@c2: lda (src),y
    sta CMD_BUF,x
    beq @c3
    inx
    iny
    bne @c2
@c3: txa
    ldx #<CMD_BUF
    ldy #>CMD_BUF
    jsr dos_cmd
    cmp #0
    bne @no                 ; no drive, or the folder isn't there
    ldx cur_dev
    lda CMD_BUF+3
    cmp #'/'
    beq @lost               ; a full path: count lost
    lda cd_depth-8,x
    cmp #$FF
    beq @ok
    inc cd_depth-8,x        ; one level, plus one per "/"
    ldy #3
@s: lda CMD_BUF,y
    beq @ok
    cmp #'/'
    bne @n
    inc cd_depth-8,x
@n: iny
    bne @s
@lost:
    lda #$FF
    sta cd_depth-8,x
@ok: clc
    rts
@no: sec
    rts

cd_origin:                  ; cur_dev back to ZenCom's folder.  C=1: failed
    ldx cur_dev
    lda cd_depth-8,x
    beq @ok
    cmp #$FF
    beq @lost
@up: lda #5                 ; CD:.. : up one level (the Ultimate, USB or
    ldx #<cd_up2            ; SD); refused: CD:<- (SD2IEC, CMD).  Not the
    ldy #>cd_up2            ; other way round: on the Ultimate's SD card a
    jsr dos_cmd             ; refused CD:<- leaves even CD:.. failing (71)
    cmp #0
    beq @upd
    lda #4
    ldx #<cd_up
    ldy #>cd_up
    jsr dos_cmd
    cmp #0
    bne @no
@upd:
    ldx cur_dev
    dec cd_depth-8,x
    bne @up
@ok: clc
    rts
@lost:                      ; after a full path: only ZenCom's folder
    lda cur_dev             ; setting (as a full path) knows the way
    cmp home_dev
    bne @ok
    lda CFG+C_HPATH
    cmp #'/'
    bne @ok
    ldx #<(CFG+C_HPATH)
    ldy #>(CFG+C_HPATH)
    jsr cd_go
    bcs @no
    ldx cur_dev
    lda #0
    sta cd_depth-8,x
    clc
    rts
@no: sec
    rts

cd_up:    .byte "CD:_"      ; "_" = $5F, the C64's left arrow: parent folder
cd_up2:   .byte "CD:.."
dev_present:                ; is drive cur_dev on the bus?  C=1: no
    jsr io_quiet
    lda #0
    sta STATUS
    lda cur_dev
    jsr LISTEN
    lda #$6F                ; secondary 15 (the command channel)
    jsr SECOND
    jsr UNLSN
    lda STATUS              ; bit 7: device not present
    asl                     ; -> C
    bcc @y
    ldx #m_nodrv_len        ; "NO DRIVE" as the reason
@nd: lda m_nodrv,x
    sta dos_msg,x
    dex
    bpl @nd
    sec
@y: jmp io_live

cd_pre:   .byte "CD:"
loc_dev:  .byte C_LDEV, C_DDEV, C_UDEV, 0
loc_path: .byte C_LPATH, C_DPATH, C_UPATH, C_HPATH

cfg_dev:                    ; A = offset of a 2-digit drive in CFG -> drive
    tax                     ; number (blank or out of range: home_dev)
    lda CFG,x
    beq @home
    and #$0F
    sta tmp
    lda CFG+1,x
    beq @one
    asl tmp                 ; tens x10
    lda tmp
    asl
    asl
    clc
    adc tmp
    sta tmp
    lda CFG+1,x
    and #$0F
    clc
    adc tmp
    sta tmp
@one:
    lda tmp
    cmp #8
    bcc @home
    cmp #31
    bcs @home
    rts
@home:
    lda home_dev
    rts

; ---- disk work while the ACIA is live: the KERNAL's serial-bus routines
; use timing loops that an NMI (each modem byte) can break, hanging the
; bus.  io_quiet holds the modem (RTS off, receive IRQ off; it buffers)
; and io_live lets it go again.  Nested calls are counted.
io_quiet:                   ; (keeps A and the flags: callers pass results
    php                     ; through it)
    pha
    lda acia_on
    ora up9_on
    beq @r
    inc io_depth
    lda io_depth
    cmp #1
    bne @r
    lda acia_on
    beq @u
    lda #$03                ; DTR on, receive IRQ off, RTS off
    sta ACIA+2
    bne @r
@u: txa                     ; UP9600: off (RTS off; the KERNAL's serial
    pha                     ; bus needs its CIA timers back)
    tya
    pha
    jsr up9_disable
    pla
    tay
    pla
    tax
@r: pla
    plp
    rts

io_live:
    pha
    php
    lda acia_on
    ora up9_on
    beq @r
    lda io_depth
    beq @r
    dec io_depth
    bne @r
    lda acia_on
    bne @a
    jsr up9_enable          ; UP9600
    jmp @r
@a: lda #ACIA_CMD_ON
    ldx rts_off
    beq @s
    lda #ACIA_CMD_HOLD
@s: sta ACIA+2
@r: plp
    pla
    rts

dos_cmd:                    ; send a command (A = len, X/Y = text); A =
    jsr io_quiet            ; drive status (00 OK), $FF = no drive
    jsr dos_cmd2
    jmp io_live
dos_cmd2:
    jsr SETNAM
    lda #15
    ldx cur_dev
    ldy #15
    jsr SETLFS
    lda #0
    sta STATUS
    jsr OPEN
    bcs @none
    lda STATUS
    bmi @none               ; device not present
    jsr dos_read
    pha
    lda #15
    jsr CLOSE
    pla
    rts
@none:
    lda #15
    jsr CLOSE
    ldx #m_nodrv_len        ; "NO DRIVE" as the status text
@nd: lda m_nodrv,x
    sta dos_msg,x
    dex
    bpl @nd
    lda #$FF
    rts

dos_status:                 ; read the drive's status: A = code, text in
    jsr io_quiet            ; dos_msg ($FF = no drive)
    jsr dos_status2
    jmp io_live
dos_status2:
    lda #0
    tax
    tay
    jsr SETNAM
    lda #15
    ldx cur_dev
    ldy #15
    jsr SETLFS
    jsr OPEN
    bcs @none
    jsr dos_read
    pha
    lda #15
    jsr CLOSE
    pla
    rts
@none:
    lda #15
    jsr CLOSE
    lda #$FF
    rts

dos_read:                   ; channel 15 is open: reply -> dos_msg, A = code
    ldx #15
    jsr CHKIN
    bcs @none
    ldy #0
@l: jsr CHRIN
    cmp #13
    beq @d
    sta dos_msg,y
    iny
    lda STATUS
    bne @d
    cpy #DOS_MSG_MAX
    bcc @l
@d: lda #0
    sta dos_msg,y
    jsr CLRCHN
    lda dos_msg             ; two digits -> number
    and #$0F
    sta tmp
    asl
    asl
    adc tmp
    asl                     ; x10
    sta tmp
    lda dos_msg+1
    and #$0F
    clc
    adc tmp
    rts
@none:
    jsr CLRCHN
    lda #$FF
    rts

.segment "MENU"             ; the menu overlay (see ovl_menu): runs at
ovm_dir: jmp directory      ; $A000; resident code enters it only here
ovm_set: jmp settings
ovm_mac: jmp macros
.segment "CODE"             ; (saving stays resident: the overlay is small)

list_save:                  ; C=0 saved; C=1 not saved (list now read-only)
    lda list_ro
    bne @ro
    ldx #L_LIST
    jsr dos_loc
    bcs @fail
    ldx #0                  ; safe_save set 0: the BBS list
    jsr safe_save
    bcs @fail
    lda #1
    sta list_src
    clc
    rts
@fail:
    lda #1
    sta list_ro
    sta save_err
    lda #<m_notsaved
    ldy #>m_notsaved
    jsr dir_msg
    lda #<dos_msg           ; the drive's own words, after the prefix
    ldy #>dos_msg
    ldx #11
    jsr dir_msg_at
    sec
    rts
@ro:
    lda #<m_ro
    ldy #>m_ro
    jsr dir_msg
    sec
    rts

; ---- safe save (drive and folder already chosen): write the temporary
; file, check the drive said OK, scratch the old file, rename the new one.
; X = set (0 BBS list, 1 settings).  C=1: failed, the reason in dos_msg.
safe_save:
    jsr io_quiet
    jsr safe_save2
    jmp io_live
safe_save2:
    stx ss_set
    lda ss_writer_lo,x
    sta wvec
    lda ss_writer_hi,x
    sta wvec+1
    lda ss_stmp_len,x       ; S:<temp> (any leftover)
    pha
    lda ss_stmp_hi,x
    tay
    lda ss_stmp_lo,x
    tax
    pla
    jsr dos_cmd
    ldx ss_set              ; open <temp>,S,W
    lda ss_wtmp_len,x
    pha
    lda ss_wtmp_hi,x
    tay
    lda ss_wtmp_lo,x
    tax
    pla
    jsr SETNAM
    lda #3
    ldx cur_dev
    ldy #3
    jsr SETLFS
    jsr OPEN
    bcs @f3
    ldx #3
    jsr CHKOUT
    bcs @f3
    jsr @write
    jsr CLRCHN
    lda #3
    jsr CLOSE
    jsr dos_status          ; did the write work?
    bne @fail
    ldx ss_set              ; S:<final>
    lda ss_sfin_len,x
    pha
    lda ss_sfin_hi,x
    tay
    lda ss_sfin_lo,x
    tax
    pla
    jsr dos_cmd
    ldx ss_set              ; R:<final>=<temp>
    lda ss_ren_len,x
    pha
    lda ss_ren_hi,x
    tay
    lda ss_ren_lo,x
    tax
    pla
    jsr dos_cmd
    bne @fail
    clc
    rts
@f3:
    jsr CLRCHN
    lda #3
    jsr CLOSE
    jsr dos_status
@fail:
    sec
    rts
@write:
    jmp (wvec)

ss_writer_lo: .byte <list_write, <cfg_write, <mac_write, <pwd_write
ss_writer_hi: .byte >list_write, >cfg_write, >mac_write, >pwd_write
ss_stmp_lo:   .byte <sct_cmd, <sct2_cmd, <sct3_cmd, <sct4_cmd
ss_stmp_hi:   .byte >sct_cmd, >sct2_cmd, >sct3_cmd, >sct4_cmd
ss_stmp_len:  .byte sct_len, sct2_len, sct3_len, sct4_len
ss_wtmp_lo:   .byte <wname, <wname2, <wname3, <wname4
ss_wtmp_hi:   .byte >wname, >wname2, >wname3, >wname4
ss_wtmp_len:  .byte wname_len, wname2_len, wname3_len, wname4_len
ss_sfin_lo:   .byte <scr_cmd, <scr2_cmd, <scr3_cmd, <scr4_cmd
ss_sfin_hi:   .byte >scr_cmd, >scr2_cmd, >scr3_cmd, >scr4_cmd
ss_sfin_len:  .byte scr_len, scr2_len, scr3_len, scr4_len
ss_ren_lo:    .byte <ren_cmd, <ren2_cmd, <ren3_cmd, <ren4_cmd
ss_ren_hi:    .byte >ren_cmd, >ren2_cmd, >ren3_cmd, >ren4_cmd
ss_ren_len:   .byte ren_len, ren2_len, ren3_len, ren4_len

list_write:                 ; every entry: name|host|mode[|*][|note] LF
    lda #<h_list            ; (a header first: what the file is)
    ldy #>h_list
    jsr print_pet
    lda #0
    sta dir_i
@e: lda dir_i
    cmp n_ent
    bcs @r
    jsr ent_addr
    ldy #E_NAME
    jsr out_field
    lda #'|'
    jsr CHROUT
    ldy #E_HOST
    jsr out_field
    lda #'|'
    jsr CHROUT
    ldy #E_MODE
    lda (eptr),y
    jsr CHROUT
    ldy #E_NOTE
    lda (eptr),y
    ldy #E_FLAGS
    ora (eptr),y
    beq @lf                 ; no bookmark, no note: three fields
    lda #'|'
    jsr CHROUT
    lda (eptr),y
    beq @nb
    lda #'*'
    jsr CHROUT
@nb:
    ldy #E_NOTE
    lda (eptr),y
    beq @lf
    lda #'|'
    jsr CHROUT
    jsr out_field
@lf:
    lda #$0A
    jsr CHROUT
    inc dir_i
    bne @e
@r: rts

out_field:                  ; raw bytes of a field (Y = offset) to output
    lda (eptr),y
    beq @r
    jsr CHROUT
    iny
    bne out_field
@r: rts

.segment "CODE"

; =====================================================================
; Settings: ZENCOM.CFG (SEQ) on the drive ZenCom was loaded from, in its
; current folder (or the ZenCom folder if set).  Lines of KEY=DRIVE,FOLDER:
;   LIST=8,      DOWN=9,/DOWNLOADS      UP=9,      HOME=8,
; Missing keys, or no file: everything on the load drive, current folder.
; =====================================================================
cfg_defaults:
    ldx #0
    txa
@m: sta MACROS,x            ; (RAM survives a reset)
    inx
    bne @m
    ldx #CFG_SIZE-1
@z: sta CFG,x
    dex
    bne @z
    sta CFG
    ldx #C_LDEV
    jsr @dev
    ldx #C_DDEV
    jsr @dev
    ldx #C_UDEV
@dev:                       ; home_dev as 1 or 2 digits at CFG+X
    lda home_dev
    cmp #10
    bcs @two
    ora #'0'
    sta CFG,x
    rts
@two:
    ldy #'0'
@t: cmp #10
    bcc @o
    sbc #10
    iny
    bne @t
@o: ora #'0'
    sta CFG+1,x
    tya
    sta CFG,x
    rts

cfg_load:                   ; ZENCOM.CFG, then ZENCOM.MAC (the macros), both
    jsr cfg_defaults        ; from the load drive's current folder
    lda #cname_len
    ldx #<cname
    ldy #>cname
    jsr cfg_file
    lda #mname_len
    ldx #<mname
    ldy #>mname
cfg_file:                   ; read KEY=... lines from the file A/X/Y
    pha
    lda home_dev
    sta cur_dev
    pla
    jsr SETNAM
    lda #3
    ldx cur_dev
    ldy #2
    jsr SETLFS
    lda #0
    sta eof_next
    sta STATUS
    jsr OPEN
    bcs @close
    lda STATUS
    bmi @close              ; no drive
    ldx #3
    jsr CHKIN
    bcs @close
    lda #<file_get
    sta bget
    lda #>file_get
    sta bget+1
    jsr cfg_parse
@close:
    jsr CLRCHN
    lda #3
    jmp CLOSE

cfg_parse:                  ; KEY=DRIVE,FOLDER lines from (bget) into CFG
@line:
    lda #0
    sta cp_state
    sta cp_mac
@next:
    jsr get_b
    bcc @got
    jmp @r
@got:
    cmp #$0D
    beq @line
    cmp #$0A
    beq @line
    ldx cp_state
    bne @s1
    and #$5F                ; state 0: the key letter
    cmp #'S'                ; SPEED=<text>
    beq @spd
    cmp #'M'                ; M1=..M8=<text>: the macros
    beq @mac
    ldx #3
@k: cmp cfg_keys,x
    beq @key
    dex
    bpl @k
    lda #4                  ; unknown key: skip the line
    sta cp_state
    bne @next
@spd:
    lda #$FF                ; no drive part: text from '=' to the end
    sta cp_dev
    lda #C_SPEED
    sta cp_path
    lda #6
    sta cp_state
    bne @next
@mac:
    lda #7                  ; the digit next
    sta cp_state
    bne @next
@key:
    lda loc_dev,x
    sta cp_dev
    cpx #L_HOME
    bne @kd
    lda #$FF                ; HOME: the drive is the load drive
    sta cp_dev
@kd: lda loc_path,x
    sta cp_path
    lda #5                  ; wait for '='
    sta cp_state
    bne @next
@s1: cpx #7
    bne @s1e
    sec                     ; state 7: which macro (1-8)
    sbc #'1'
    cmp #8
    bcs @skip
    asl
    asl
    asl
    asl
    asl
    sta cp_path
    tax                     ; empty the slot
    lda #0
    ldy #MAC_LEN+1
@me: sta MACROS,x
    inx
    dey
    bne @me
    lda #$FF
    sta cp_dev
    sta cp_mac
    lda #6
    sta cp_state
    jmp @next
@skip:
    lda #4
    sta cp_state
    jmp @next
@s1e:
    cpx #5
    bcc @s2
    cmp #'='
    beq @eq
    jmp @next
@eq: ldx cp_dev              ; clear this key's drive and folder
    bmi @cp
    lda #0
    sta CFG,x
    sta CFG+1,x
    sta CFG+2,x
@cp: lda cp_mac            ; (a macro's slot was emptied at its digit)
    bne @cm
    ldx cp_path
    ldy #39
@cz: sta CFG,x
    inx
    dey
    bne @cz
@cm: lda #0
    sta cp_n
    lda cp_state            ; (5 -> 1: drive; 6 -> 2: SPEED's text)
    sec
    sbc #4
    sta cp_state
    jmp @next
@s2: cpx #1
    beq @st1
    jmp @s3
@n2: jmp @next
@st1:
    cmp #','                ; state 1: drive digits
    bne @dg
    lda #0
    sta cp_n
    lda #2
    sta cp_state
    bne @n2
@dg: ldx cp_dev
    bmi @n2
    ldy cp_n
    cpy #2
    bcs @n2
    cmp #'0'
    bcc @n2
    cmp #'9'+1
    bcs @n2
    pha
    tya
    clc
    adc cp_dev
    tax
    pla
    sta CFG,x
    inc cp_n
    jmp @next
@s3: cpx #2
    bne @nx                 ; state 4 (skip): ignore
    ldy cp_n                ; state 2: the folder
    cpy #38
    bcs @nx
    pha
    tya
    clc
    adc cp_path
    tax
    pla
    ldy cp_mac
    bne @mw
    sta CFG,x
    inc cp_n
@nx: jmp @next
@mw: ldy cp_n               ; a macro: 31 at most
    cpy #MAC_LEN
    bcs @nx
    sta MACROS,x
    inc cp_n
    jmp @next
@r: rts

cfg_keys: .byte "LDUH"

speed_ctrl:                 ; A/Y = speed text -> A = ACIA control byte.
    sta bptr                ; C=1 (and 9600) if it isn't one of sp_text
    sty bptr+1
    ldy #0
    lda (bptr),y
    beq @def                ; blank: 9600
    ldx #0                  ; X: start of an entry in sp_text
    stx tmp2                ; (entry number)
@e: ldy #0
@c: lda sp_text,x
    cmp (bptr),y
    bne @no
    inx
    iny
    cmp #0
    bne @c
    ldx tmp2                ; matched, end and all
    lda sp_ctrl,x
    clc
    rts
@no: lda sp_text,x          ; skip to the next entry
    inx
    cmp #0
    bne @no
    inc tmp2
    lda tmp2
    cmp #SP_N
    bcc @e
    sec
    .byte $24               ; BIT zp: skip the CLC
@def: clc
    lda #ACIA_CTRL
    rts
; a SwiftLink's crystal is twice the 6551's usual one: every rate doubles
sp_text: .byte "1200", 0, "2400", 0, "4800", 0, "9600", 0, "19200", 0, "38400", 0
sp_ctrl: .byte $17, $18, $1A, $1C, $1E, $1F
SP_N = 6

cfg_write:                  ; the four lines
    lda #<h_cfg
    ldy #>h_cfg
    jsr print_pet
    ldx #0
@l: stx cw_i
    lda cw_key_lo,x
    ldy cw_key_hi,x
    jsr print_pet
    ldx cw_i
    cpx #L_HOME
    bne @d
    lda home_dev            ; HOME=<load drive>
    jsr out_dec
    jmp @c
@d: lda loc_dev,x
    tax
@dl: lda CFG,x
    beq @c
    jsr CHROUT
    inx
    bne @dl
@c: lda #','
    jsr CHROUT
    ldx cw_i
    lda loc_path,x
    tax
@pl: lda CFG,x
    beq @e
    jsr CHROUT
    inx
    bne @pl
@e: lda #$0A
    jsr CHROUT
    ldx cw_i
    inx
    cpx #4
    bne @l
    lda CFG+C_SPEED         ; SPEED=<text>, only when set
    beq @m
    lda #<k_speed
    ldy #>k_speed
    jsr print_pet
    lda #<(CFG+C_SPEED)
    ldy #>(CFG+C_SPEED)
    jsr print_pet
    lda #$0A
    jmp CHROUT
@m: rts

mac_write:                  ; ZENCOM.MAC: M1=..M8=, the ones that are set
    lda #<h_mac
    ldy #>h_mac
    jsr print_pet
    lda #0
@ml: sta cw_i
    asl
    asl
    asl
    asl
    asl
    tax
    lda MACROS,x
    beq @mn
    lda #'M'
    jsr CHROUT
    lda cw_i
    clc
    adc #'1'
    jsr CHROUT
    lda #'='
    jsr CHROUT
    lda cw_i
    asl
    asl
    asl
    asl
    asl
    clc
    adc #<MACROS
    ldy #>MACROS
    jsr print_pet
    lda #$0A
    jsr CHROUT
@mn: lda cw_i
    clc
    adc #1
    cmp #8
    bcc @ml
    rts

cw_key_lo: .byte <k_list, <k_down, <k_up, <k_home
cw_key_hi: .byte >k_list, >k_down, >k_up, >k_home
k_list: .byte "LIST=", 0
k_down: .byte "DOWN=", 0
k_up:   .byte "UP=", 0
k_home: .byte "HOME=", 0
k_speed: .byte "SPEED=", 0

out_dec:                    ; A (0-99) as digits to the current output
    ldx #0
@t: cmp #10
    bcc @u
    sbc #10
    inx
    bne @t
@u: pha
    txa
    beq @o
    ora #'0'
    jsr CHROUT
@o: pla
    ora #'0'
    jmp CHROUT

cfg_save:                   ; C=1: not saved (reason in dos_msg)
    ldx #1
    .byte $2C               ; BIT abs: skip the LDX
mac_save:                   ; the macros: ZENCOM.MAC beside ZENCOM.CFG
    ldx #2
    txa
    pha
    ldx #L_HOME
    jsr dos_loc
    pla
    bcs @r
    tax
    jmp safe_save
@r: rts

.segment "MENU"             ; (the menu overlay: see ovl_menu)
; ---- the macro screen (M on the menu): 8 lines of up to 31 characters,
; sent by C=+M then 1-8 in a call (mac_key); ^ sends Return.  Shown in the
; lower/upper set, so the case is what the board will get.
macros:
    ldx #0                  ; edit a copy
@c: lda MACROS,x
    sta MAC_EDIT,x
    inx
    bne @c
    lda #<MAC_EDIT
    sta eptr
    lda #>MAC_EDIT
    sta eptr+1
    lda #$93
    jsr CHROUT
    lda #$17
    sta $D018
    ldx #0
    lda #<t_mac
    ldy #>t_mac
    jsr title_bar
    lda #0
@l: sta ed_field            ; labels and values
    asl
    adc #2
    tax
    lda ed_field
    asl
    tay
    lda mac_lab,y
    pha
    lda mac_lab+1,y
    tay
    pla
    jsr put_label
    jsr mac_at
    lda #$FF                ; (no cursor)
    sta fe_cur
    jsr fe_show
    lda ed_field
    clc
    adc #1
    cmp #8
    bcc @l
    ldx #19
    lda #<h_mac1
    ldy #>h_mac1
    jsr put_line_v
    ldx #20
    lda #<h_mac2
    ldy #>h_mac2
    jsr put_line_v
    ldx #FOOT1
    lda #<f_set1
    ldy #>f_set1
    jsr put_line_c
    ldx #FOOT2
    lda #<f_set2
    ldy #>f_set2
    jsr put_line_c
    lda #1
    sta fe_case
    lda #0
    sta ed_field
@fld:
    jsr mac_at
    jsr field_edit
    bcs @out
    cmp #1
    beq @back
    inc ed_field
    lda ed_field
    cmp #8
    bcc @fld
    ldx #0                  ; accept: copy back and save
@a: lda MAC_EDIT,x
    sta MACROS,x
    inx
    bne @a
    jsr mac_save
    bcc @out
    lda #<m_notsaved
    ldy #>m_notsaved
    jsr dir_msg
    lda #<dos_msg
    ldy #>dos_msg
    ldx #11
    jsr dir_msg_at
@w: jsr GETIN
    beq @w
@out:
    lda #0
    sta fe_case
    jmp menu_start
@back:
    lda ed_field
    beq @f0
    dec ed_field
@f0: jmp @fld

mac_at:                     ; ed_row/ed_off/ed_max for macro ed_field
    lda ed_field
    asl
    adc #3
    sta ed_row
    lda ed_field
    asl
    asl
    asl
    asl
    asl
    sta ed_off
    lda #MAC_LEN
    sta ed_max
    rts

fe_show:                    ; draw field ed_off (from eptr) without editing
    ldy ed_off
    ldx #0
@ln: lda (eptr),y
    beq @d
    iny
    inx
    cpx ed_max
    bcc @ln
@d: stx fe_len
    jmp fe_draw

mac_lab: .word l_m1, l_m2, l_m3, l_m4, l_m5, l_m6, l_m7, l_m8
l_m1: .byte "C=+M 1", 0
l_m2: .byte "C=+M 2", 0
l_m3: .byte "C=+M 3", 0
l_m4: .byte "C=+M 4", 0
l_m5: .byte "C=+M 5", 0
l_m6: .byte "C=+M 6", 0
l_m7: .byte "C=+M 7", 0
l_m8: .byte "C=+M 8", 0
t_mac:  .byte "ZENCOM  MACROS", 0
h_mac1: .byte "^ SENDS RETURN.  IN A CALL: C=+M, 1-8", 0
h_mac2: .byte "KEPT AS PLAIN TEXT IN ZENCOM.MAC", 0

; ---- the settings screen (S on the menu)
ST_FIELDS = 8
st_row: .byte 3, 5, 8, 10, 13, 15, 18, 20
st_off: .byte C_LDEV, C_LPATH, C_DDEV, C_DPATH, C_UDEV, C_UPATH, C_HPATH, C_SPEED
st_max: .byte 2, 38, 2, 38, 2, 38, 38, 5

settings:
    ldx #0                  ; edit a copy (165 bytes: count up, as BPL
@c: lda CFG,x               ; would stop at 128)
    sta SET_EDIT,x
    inx
    cpx #CFG_SIZE
    bne @c
    lda #<SET_EDIT
    sta eptr
    lda #>SET_EDIT
    sta eptr+1
    jsr st_draw
    lda #0
    sta ed_field
@fld:
    ldx ed_field
    lda st_row,x
    sta ed_row
    lda st_off,x
    sta ed_off
    lda st_max,x
    sta ed_max
    jsr field_edit
    bcs @cancel
    cmp #1
    beq @back
    inc ed_field
    lda ed_field
    cmp #ST_FIELDS
    bcc @fld
    ldx #0                  ; check the three drive fields
@v: stx cw_i
    lda st_off,x
    jsr dev_check
    bcc @vok
    lda #<m_drives
    ldy #>m_drives
    jsr dir_msg
    lda cw_i
    sta ed_field
    jmp @fld
@vok:
    ldx cw_i
    inx
    inx
    cpx #6
    bcc @v
    lda #<(SET_EDIT+C_SPEED)
    ldy #>(SET_EDIT+C_SPEED)
    jsr speed_ctrl
    bcc @sok
    lda #<m_speeds
    ldy #>m_speeds
    jsr dir_msg
    lda #ST_FIELDS-1
    sta ed_field
    jmp @fld
@sok:
    ldx #0                  ; accept: copy back, save, reload the list
@a: lda SET_EDIT,x
    sta CFG,x
    inx
    cpx #CFG_SIZE
    bne @a
    jsr cfg_save
    bcc @ok
    lda #<m_notsaved
    ldy #>m_notsaved
    jsr dir_msg
    lda #<dos_msg
    ldy #>dos_msg
    ldx #11
    jsr dir_msg_at
@w: jsr GETIN
    beq @w
@ok:
    jsr list_load
@cancel:
    jmp menu_start
@back:
    lda ed_field
    beq @f0
    dec ed_field
@f0: jmp @fld

dev_check:                  ; A = offset in SET_EDIT: blank or 8-30? C=1 bad
    tax
    lda SET_EDIT,x
    beq @ok
    cmp #'0'
    bcc @bad
    cmp #'9'+1
    bcs @bad
    and #$0F
    sta tmp
    lda SET_EDIT+1,x
    beq @one
    cmp #'0'
    bcc @bad
    cmp #'9'+1
    bcs @bad
    lda tmp
    asl
    asl
    adc tmp
    asl
    sta tmp
    lda SET_EDIT+1,x
    and #$0F
    clc
    adc tmp
    sta tmp
@one:
    lda tmp
    cmp #8
    bcc @bad
    cmp #31
    bcs @bad
@ok:
    clc
    rts
@bad:
    sec
    rts

st_draw:
    lda #$93
    jsr CHROUT
    ldx #0
    lda #<t_set
    ldy #>t_set
    jsr title_bar
    ldx #0
@l: stx cw_i
    lda st_lab_row,x
    pha
    lda st_lab_lo,x
    ldy st_lab_hi,x
    tax
    pla
    stx tmp
    tax
    lda tmp
    jsr put_label
    ldx cw_i
    lda st_off,x            ; and the value under it
    pha
    lda st_row,x
    tax
    pla
    jsr info_field
    ldx cw_i
    inx
    cpx #ST_FIELDS
    bne @l
    ldx #21
    lda #<h_set1
    ldy #>h_set1
    jsr put_line_v
    ldx #FOOT1
    lda #<f_set1
    ldy #>f_set1
    jsr put_line_c
    ldx #FOOT2
    lda #<f_set2
    ldy #>f_set2
    jmp put_line_c

st_lab_row: .byte 2, 4, 7, 9, 12, 14, 17, 19
st_lab_lo:  .byte <s_ldev, <s_fold, <s_ddev, <s_fold, <s_udev, <s_fold, <s_home, <s_speed
st_lab_hi:  .byte >s_ldev, >s_fold, >s_ddev, >s_fold, >s_udev, >s_fold, >s_home, >s_speed
t_set:  .byte "ZENCOM  SETTINGS", 0
s_ldev: .byte "BBS LIST: DRIVE", 0
s_ddev: .byte "DOWNLOADS: DRIVE", 0
s_udev: .byte "UPLOADS: DRIVE", 0
s_fold: .byte "  FOLDER", 0
s_home: .byte "ZENCOM'S FOLDER (FOR ZENCOM.CFG)", 0
s_speed: .byte "SWIFTLINK SPEED (BLANK: 9600)", 0
h_set1: .byte "BLANK: LOAD DRIVE, CURRENT FOLDER", 0
f_set1: .byte "RETURN/DOWN NEXT  UP BACK  <- CANCEL", 0
f_set2: .byte "RETURN ON THE LAST FIELD SAVES", 0
m_drives: .byte "DRIVES ARE 8-30 (OR BLANK)", 0
m_speeds: .byte "1200 2400 4800 9600 19200 38400", 0

; ---- the directory screen: a bar over the list, written straight to
; screen memory (text mode, upper case/graphics set)
directory:
    lda #0
    sta dir_sel
dir_draw:
    lda #$93
    jsr CHROUT              ; clear (also resets the line links)
    ldx #0
    lda #<t_dir
    ldy #>t_dir
    jsr title_bar
    ldx #0                  ; 20 rows
@row:
    stx dir_i
    jsr dir_row
    ldx dir_i
    inx
    cpx #VIS
    bne @row
    jsr dir_status
    ldx #FOOT1
    lda list_ro
    bne @ro
    lda #<f_keys1
    ldy #>f_keys1
    jsr put_line_c
    ldx #FOOT2
    lda #<f_keys2
    ldy #>f_keys2
    jsr put_line_c
    jmp dir_key
@ro:
    lda #<f_keys1
    ldy #>f_keys1
    jsr put_line_c
    ldx #FOOT2
    lda #<f_ro
    ldy #>f_ro
    jsr put_line_c
dir_key:
    jsr GETIN
    beq dir_key
    cmp #$87                ; F5 / left arrow: back to the menu
    beq @menu
    cmp #$5F
    beq @menu
    cmp #$11                ; cursor down / up
    beq @down
    cmp #$91
    beq @up
    cmp #'+'
    beq @pgdn
    cmp #'-'
    beq @pgup
    ldx n_ent               ; an empty list: only A adds
    bne @has
    and #$7F
    cmp #'A'
    beq @add0
    jmp dir_key
@add0: jmp dir_add
@has:
    cmp #13
    bne @k1
    jmp dir_go
@k1:
    and #$7F
    cmp #'I'
    bne @k2
    jmp dir_info
@k2:
    cmp #'B'
    bne @k3
    jmp dir_mark
@k3:
    cmp #'X'
    bne @k6
    jmp dir_del
@k6:
    cmp #'E'
    bne @k5
    jmp dir_edit
@k5:
    cmp #'A'
    bne dir_key
    jmp dir_add
@menu:
    jmp menu_start
@dk: jmp dir_key
@down:
    ldx dir_sel
    inx
    cpx n_ent
    bcs @dk
    stx dir_sel
    jmp dir_redraw
@up:
    ldx dir_sel
    beq @dk
    dex
    stx dir_sel
    jmp dir_redraw
@pgdn:
    lda dir_sel
    clc
    adc #VIS
    cmp n_ent
    bcc @pd
    ldx n_ent
    beq @dk
    dex
    txa
@pd: sta dir_sel
    jmp dir_redraw
@pgup:
    lda dir_sel
    sec
    sbc #VIS
    bcs @pu
    lda #0
@pu: sta dir_sel
dir_redraw:                 ; the list rows only (no flicker of the rest)
    ldx #0
@r: stx dir_i
    jsr dir_row
    ldx dir_i
    inx
    cpx #VIS
    bne @r
    jsr dir_status
    jmp dir_key

dir_top:                    ; A = first position on dir_sel's page
    lda dir_sel
    ldx #0
@l: cmp #VIS
    bcc @d
    sbc #VIS
    inx
    bne @l
@d: lda #0
@m: dex
    bmi @r
    clc
    adc #VIS
    bne @m
@r: rts

dir_row:                    ; X = 0..19: draw that row of the page
    stx tmp2
    jsr dir_top
    clc
    adc tmp2
    sta dir_pos             ; position in ORDER
    lda tmp2
    clc
    adc #LIST_ROW
    tax
    lda #LGREY_C
    jsr row_blank           ; also sets dst/cptr to the row
    lda dir_pos
    cmp n_ent
    bcs @r
    ldx dir_pos
    lda ORDER,x
    jsr ent_addr
    lda #0
    sta w_rev
    lda #LGREY_C
    sta w_col
    lda dir_pos
    cmp dir_sel
    bne @n
    lda #$80                ; the bar: reversed cyan across the row
    sta w_rev
    lda #CYAN_C
    sta w_col
    ldy #39
@b: lda #$A0
    sta (dst),y
    lda #CYAN_C
    sta (cptr),y
    dey
    bpl @b
@n: ldy #E_FLAGS            ; bookmark mark (yellow unless under the bar)
    lda (eptr),y
    beq @nm
    lda w_col
    pha
    lda w_rev
    bne @sc
    lda #YELLOW_C
    sta w_col
@sc: lda #'*'
    ldy #0
    jsr put_ch
    pla
    sta w_col
@nm:
    lda #E_NAME
    ldx #1
    ldy #NAME_MAX
    jsr put_field
    lda w_rev
    bne @h
    lda #DGREY_C
    sta w_col
@h: lda #E_HOST
    ldx #21
    ldy #17
    jsr put_field
    ldy #E_MODE
    lda (eptr),y
    ldy #39
    jsr put_ch
@r: rts

dir_status:                 ; row 22: count and where the list came from
    lda save_err            ; a failed save: keep showing the drive's words
    beq @st
    lda #<m_notsaved
    ldy #>m_notsaved
    jsr dir_msg
    lda #<dos_msg
    ldy #>dos_msg
    ldx #11
    jmp dir_msg_at
@st:
    ldx #MSG_ROW
    lda #DGREY_C
    jsr row_blank
    lda n_ent               ; "nn BOARDS"
    jsr dec2
    lda #<m_boards
    ldy #>m_boards
    ldx #3
    jsr put_str_at
    lda list_ro
    beq @w
    lda #<m_rolist
    ldy #>m_rolist
    bne @s
@w: lda list_src
    beq @b
    lda #<m_usb
    ldy #>m_usb
    ldx #11
    jsr put_str_at
    lda cur_dev
    ldy #22
    jmp dec2_at
@b: lda #<m_builtin
    ldy #>m_builtin
@s: ldx #11
    jmp put_str_at

.segment "CODE"             ; (the transfer screens use these too)
dir_msg:                    ; A/Y = message on row 22 (yellow)
    pha
    tya
    pha
    ldx #MSG_ROW
    lda #YELLOW_C
    jsr row_blank
    lda #YELLOW_C
    sta w_col
    pla
    tay
    pla
    ldx #0
dir_msg_at:                 ; A/Y = text, X = column, on row 22
    sta bptr
    sty bptr+1
    lda #YELLOW_C
    sta w_col
    lda #0
    sta w_rev
    txa
    tay
    jmp put_bptr

.segment "MENU"
dir_need_rw:                ; C=1 (and a message) if the list can't change
    lda list_ro
    beq @ok
    lda #<m_ro
    ldy #>m_ro
    jsr dir_msg
    sec
    rts
@ok:
    lda n_ent
    clc
    rts

sel_entry:                  ; A = entry number under the bar (C=1: none)
    lda dir_sel
    cmp n_ent
    bcs @r
    tax
    lda ORDER,x
    clc
@r: rts

dir_go:                     ; Return: dial the board under the bar
    jsr sel_entry
    bcs @k
    jmp dir_dial
@k: jmp dir_key

dir_mark:                   ; B: bookmark on/off; bookmarks list first
    jsr dir_need_rw
    bcs @k
    jsr sel_entry
    bcs @k
    sta dir_e
    jsr ent_addr
    ldy #E_FLAGS
    lda (eptr),y
    eor #1
    sta (eptr),y
    jsr build_order
    ldx #0                  ; keep the bar on the same board
@f: lda ORDER,x
    cmp dir_e
    beq @s
    inx
    cpx n_ent
    bcc @f
    ldx #0
@s: stx dir_sel
    jsr list_save
    jmp dir_redraw
@k: jmp dir_key

dir_del:                    ; X: delete, after Y/N
    jsr dir_need_rw
    bcs @k1
    jsr sel_entry
    bcc @k2
@k1: jmp dir_key
@k2: sta dir_e
    jsr ent_addr
    lda #<m_del
    ldy #>m_del
    jsr dir_msg
    lda #E_NAME
    ldx #7
    ldy #NAME_MAX
    jsr put_field
    lda #<m_yn
    ldy #>m_yn
    ldx w_x
    jsr put_str_at
@y: jsr GETIN
    beq @y
    and #$7F
    cmp #'Y'
    bne @no
    lda dir_e               ; its login goes too (if it has one)
    jsr ent_addr
    jsr login_key
    jsr pwd_load
    ldx #7
@ko: lda pwd_key,x
    sta pwd_old,x
    dex
    bpl @ko
    lda #<LOG_ED
    ldy #>LOG_ED
    jsr pwd_find
    bcs @nl
    lda #0
    sta LOG_ED+L_USER
    sta LOG_ED+L_PASS
    jsr pwd_save
@nl:
    lda dir_e
    jsr ent_delete
    lda dir_sel             ; keep the bar inside the list
    cmp n_ent
    bcc @sv
    ldx n_ent
    beq @z0
    dex
    stx dir_sel
    jmp @sv
@z0:
    lda #0
    sta dir_sel
@sv:
    jsr list_save
    jmp dir_redraw
@no:
    jsr dir_status
@k: jmp dir_key

dir_info:                   ; I: everything about the board, Return dials
    jsr sel_entry
    bcc @ok
    jmp dir_key
@ok:
    sta dir_e
    jsr ent_addr
    lda #$93
    jsr CHROUT
    ldx #0
    lda #<t_info
    ldy #>t_info
    jsr title_bar
    ldx #2
    lda #<l_name
    ldy #>l_name
    jsr put_label
    lda #E_NAME
    ldx #3
    jsr info_field
    ldx #5
    lda #<l_addr
    ldy #>l_addr
    jsr put_label
    lda #E_HOST
    ldx #6
    jsr info_field
    ldx #9
    lda #<l_mode
    ldy #>l_mode
    jsr put_label
    ldy #E_MODE
    lda (eptr),y
    cmp #'P'
    beq @p
    lda #<v_ansi
    ldy #>v_ansi
    bne @m
@p: lda #<v_pet
    ldy #>v_pet
@m: ldx #10
    jsr put_line_v
    ldx #12
    lda #<l_mark
    ldy #>l_mark
    jsr put_label
    ldy #E_FLAGS
    lda (eptr),y
    beq @nb
    lda #<v_yes
    ldy #>v_yes
    bne @b
@nb: lda #<v_no
    ldy #>v_no
@b: ldx #13
    jsr put_line_v
    ldx #15
    lda #<l_note
    ldy #>l_note
    jsr put_label
    lda #E_NOTE
    ldx #16
    jsr info_field
    ldx #24
    lda #<f_info
    ldy #>f_info
    jsr put_line_c
@w: jsr GETIN
    beq @w
    cmp #13
    bne @e
    lda dir_e
    jmp dir_dial
@e: and #$7F
    cmp #'E'                ; E: edit it (unless the list is read-only)
    bne @back
    lda list_ro
    bne @w
    jmp dir_edit
@back:
    jmp dir_draw
@k: jmp dir_key

info_field:                 ; field A of eptr from row X, 38 a line
    sta w_off
    stx w_row
    lda #LGREY_C
    sta w_col
    lda #0
    sta w_rev
    lda w_off
    ldx w_row
    jsr row_ptrs
    lda w_off
    ldx #1
    ldy #38
    jsr put_field
    lda w_off               ; host and note: second line past 38
    cmp #E_NAME
    beq @r
    clc
    adc #37
    tay
    lda (eptr),y
    beq @r
    iny
    lda (eptr),y
    beq @r
    ldx w_row
    inx
    jsr row_ptrs
    lda w_off
    clc
    adc #38
    ldx #1
    ldy #38
    jmp put_field
@r: rts

dir_edit:                   ; E: edit the board under the bar
    lda #0
    sta ed_field
    jsr dir_need_rw
    bcs @k
    jsr sel_entry
    bcs @k
    sta dir_e
    lda #0
    sta ed_new
    jmp edit_board
@k: jmp dir_key

dir_add:                    ; A: a new board, in the same form
    jsr dir_need_rw
    bcs @k
    lda n_ent
    cmp #MAX_ENT
    bcs @full
    sta dir_e
    lda #1
    sta ed_new
    lda #0
    sta ed_field
    jmp edit_board
@full:
    lda #<m_full
    ldy #>m_full
    jsr dir_msg
@k: jmp dir_key

; ---- the edit form: fields edited in place with the screen editor on a
; copy of the entry (EDIT_BUF), so a cancel changes nothing
edit_board:
    lda #<EDIT_BUF
    sta eptr
    lda #>EDIT_BUF
    sta eptr+1
    ldy #ENT_SIZE-1
    lda #0
@z: sta (eptr),y
    dey
    bpl @z
    lda #'A'
    ldy #E_MODE
    sta (eptr),y
    lda ed_new
    bne @form
    lda dir_e               ; copy the board into the edit buffer
    jsr ent_addr
    lda eptr
    sta bptr
    lda eptr+1
    sta bptr+1
    lda #<EDIT_BUF
    sta eptr
    lda #>EDIT_BUF
    sta eptr+1
    ldy #ENT_SIZE-1
@c: lda (bptr),y
    sta (eptr),y
    dey
    bpl @c
@form:
    jsr ed_login            ; its login, from ZENCOM.PWD
    jsr ed_draw
@fld:                       ; field ed_field: 0 name, 1 address, 2 mode,
    ldx ed_field            ; 3 note, 4 user, 5 password.  Return/down =
    cpx #2                  ; next, up = back, <- = cancel
    bne @t4
    jsr ed_mode
    jmp @nav
@t4: cpx #4
    bcc @txt
    jsr ed_logfield
    jmp @nav
@txt:
    lda fld_row,x
    sta ed_row
    lda fld_off,x
    sta ed_off
    lda fld_max,x
    sta ed_max
    jsr field_edit
@nav:
    bcs @cancel
    cmp #1
    beq @back
    inc ed_field
    lda ed_field
    cmp #6
    bcc @fld
    jmp @done
@back:
    lda ed_field
    beq @fld
    dec ed_field
    jmp @fld
@done:
    ldy #E_HOST             ; an address is required
    lda (eptr),y
    bne @ok
    lda #<m_noaddr
    ldy #>m_noaddr
    jsr dir_msg
    lda #1
    sta ed_field
    jmp @fld
@ok:
    jsr host_tidy
    lda dir_e               ; copy back into the list
    jsr ent_addr
    ldy #ENT_SIZE-1
@b: lda EDIT_BUF,y
    sta (eptr),y
    dey
    bpl @b
    lda ed_new
    beq @o
    inc n_ent
@o: jsr build_order
    ldx #0                  ; bar on this board
@f: lda ORDER,x
    cmp dir_e
    beq @s
    inx
    cpx n_ent
    bcc @f
    ldx #0
@s: stx dir_sel
    jsr list_save
    jsr ed_logsave          ; the login, under the (new) address
@cancel:
    lda #LGREY_C
    sta COLOR
    jmp dir_draw

ed_draw:                    ; the form, values filled in from (eptr)
    lda #$93
    jsr CHROUT
    ldx #0
    lda ed_new
    beq @e
    lda #<t_add
    ldy #>t_add
    bne @t
@e: lda #<t_edit
    ldy #>t_edit
@t: jsr title_bar
    ldx #ED_NAME_ROW-1
    lda #<l_name
    ldy #>l_name
    jsr put_label
    ldx #ED_HOST_ROW-1
    lda #<l_addr
    ldy #>l_addr
    jsr put_label
    ldx #ED_MODE_ROW-1
    lda #<l_mode
    ldy #>l_mode
    jsr put_label
    ldx #ED_NOTE_ROW-1
    lda #<l_note
    ldy #>l_note
    jsr put_label
    lda #E_NAME
    ldx #ED_NAME_ROW
    jsr info_field
    lda #E_HOST
    ldx #ED_HOST_ROW
    jsr info_field
    jsr ed_mode_show
    lda #E_NOTE
    ldx #ED_NOTE_ROW
    jsr info_field
    ldx #ED_USER_ROW-1
    lda #<l_user
    ldy #>l_user
    jsr put_label
    ldx #ED_PASS_ROW-1
    lda #<l_pass
    ldy #>l_pass
    jsr put_label
    ldx #21
    lda #<h_pwd
    ldy #>h_pwd
    jsr put_line_v
    lda #4                  ; the login's values (the password as *)
    sta ed_field
    jsr ed_logat
    jsr ed_logshow
    inc ed_field
    jsr ed_logat
    jsr ed_logshow
    lda #0
    sta ed_field
    ldx #FOOT1
    lda #<f_edit1
    ldy #>f_edit1
    jsr put_line_c
    ldx #FOOT2
    lda #<f_edit2
    ldy #>f_edit2
    jmp put_line_c

ed_login:                   ; the form opens: ZENCOM.PWD read, this board's
    lda #<EDIT_BUF          ; login (if any) into LOG_ED, its key kept in
    sta eptr                ; pwd_old (a new board: none)
    lda #>EDIT_BUF
    sta eptr+1
    jsr pwd_load
    lda #0
    sta pwd_had
    ldx #7
@z: sta pwd_old,x
    dex
    bpl @z
    lda ed_new
    beq @e
    lda #<LOG_ED            ; (empties it)
    ldy #>LOG_ED
    ldx #8
@k: sta pwd_key-1,x         ; (a key no line has)
    dex
    bne @k
    jsr pwd_find
    jmp @r
@e: jsr login_key
    ldx #7
@c: lda pwd_key,x
    sta pwd_old,x
    dex
    bpl @c
    lda #<LOG_ED
    ldy #>LOG_ED
    jsr pwd_find
    bcs @r
    inc pwd_had
@r: lda #<EDIT_BUF
    sta eptr
    lda #>EDIT_BUF
    sta eptr+1
    rts

ed_logat:                   ; ed_field 4/5: the field in LOG_ED
    lda #<LOG_ED
    sta eptr
    lda #>LOG_ED
    sta eptr+1
    ldx ed_field
    lda #ED_USER_ROW
    ldy #L_USER
    cpx #5
    bne @u
    lda #ED_PASS_ROW
    ldy #L_PASS
@u: sta ed_row
    sty ed_off
    lda #31
    sta ed_max
    lda #1                  ; case kept; the password shown as *
    sta fe_case
    lda #0
    cpx #5
    bne @m
    lda #1
@m: sta fe_mask
    rts

ed_logshow:                 ; draw the field set up by ed_logat
    lda #$FF
    sta fe_cur
    jsr fe_show
    jmp ed_logdone

ed_logfield:                ; edit field 4/5
    jsr ed_logat
    jsr field_edit
    php
    pha
    jsr ed_logdone
    pla
    plp
    rts

ed_logdone:                 ; back to the board's own fields
    lda #0
    sta fe_case
    sta fe_mask
    lda #<EDIT_BUF
    sta eptr
    lda #>EDIT_BUF
    sta eptr+1
    rts

ed_logsave:                 ; accepted: ZENCOM.PWD loses the old key's line
    lda pwd_had             ; and gains the new one (if there is a login)
    ora LOG_ED+L_USER
    ora LOG_ED+L_PASS
    beq @r
    lda dir_e
    jsr ent_addr
    jsr login_key
    jsr pwd_save
    bcc @r
    lda #<m_pwdns
    ldy #>m_pwdns
    jsr dir_msg
@w: jsr GETIN
    beq @w
@r: rts

fld_row: .byte ED_NAME_ROW, ED_HOST_ROW, 0, ED_NOTE_ROW
fld_off: .byte E_NAME, E_HOST, 0, E_NOTE
fld_max: .byte NAME_MAX, HOST_MAX, 0, NOTE_MAX

.segment "CODE"

; ---- ZenCom's own field editor: confined to the field (no screen editor),
; so nothing else on screen can be typed over.  The field shows across up
; to two rows of 38 from ed_row, column 1, with a reversed cursor.
; Exit: C=1 cancel (<-); C=0 with A=0 next (Return, down), A=1 back (up).
FE_W = 38
field_edit:
    ldy ed_off              ; length = up to the 0 (or the max)
    ldx #0
@ln: lda (eptr),y
    beq @lnd
    iny
    inx
    cpx ed_max
    bcc @ln
@lnd:
    stx fe_len
    stx fe_cur
@loop:
    jsr fe_draw
@key:
    jsr GETIN
    beq @key
    cmp #13
    beq @next
    cmp #$11                ; down (A=2 with fe_bar: a list below the field)
    beq @down
    cmp #$91                ; up
    beq @prev
    cmp #$5F                ; <- : cancel
    beq @cancel
    cmp #$9D                ; left
    beq @left
    cmp #$1D                ; right
    beq @right
    cmp #$13                ; HOME
    beq @home
    cmp #$93                ; CLR: empty the field
    beq @clr
    cmp #$14
    beq @del
    cmp #$94
    beq @ins
    cmp #$C1                ; shifted letters -> capitals
    bcc @pl
    cmp #$DB
    bcs @key
    ldx fe_case             ; (macros keep them: passwords)
    bne @put
    and #$7F
@pl:
    cmp #$20                ; printable: space to ]
    bcc @key
    cmp #$5E
    bcc @put
    bne @key
    ldx fe_case             ; ^ only in a macro (it sends Return)
    beq @key
@put:
    jsr fe_insert
    jmp @loop
@down:
    lda fe_bar
    beq @next
    lda #2
    bne @out
@next:
    lda #0
    beq @out
@prev:
    lda #1
@out:
    pha
    jsr fe_end
    pla
    clc
    rts
@cancel:
    jsr fe_end
    sec
    rts
@kj: jmp @key
@left:
    lda fe_cur
    beq @kj
    dec fe_cur
    jmp @loop
@right:
    lda fe_cur
    cmp fe_len
    bcs @kj
    inc fe_cur
    jmp @loop
@home:
    lda #0
    sta fe_cur
    jmp @loop
@clr:
    lda #0
    sta fe_len
    sta fe_cur
    jmp @loop
@del:
    lda fe_cur
    beq @kj
    dec fe_cur
    jsr fe_remove
    jmp @loop
@ins:
    lda fe_len
    cmp ed_max
    bcs @kj
    lda #' '
    jsr fe_insert
    dec fe_cur              ; INST leaves the cursor on the new space
    jmp @loop

fe_insert:                  ; A at the cursor, the rest shifted right
    ldx fe_len
    cpx ed_max
    bcs @r
    sta fe_ch
@m: cpx fe_cur              ; for p = len down to cur+1: f[p] = f[p-1]
    beq @put
    txa
    clc
    adc ed_off
    tay
    dey
    lda (eptr),y
    iny
    sta (eptr),y
    dex
    jmp @m
@put:
    lda fe_cur
    clc
    adc ed_off
    tay
    lda fe_ch
    sta (eptr),y
    inc fe_len
    inc fe_cur
@r: rts

fe_remove:                  ; delete the character at the cursor
    ldx fe_cur
@m: inx                     ; for p = cur+1 .. len-1: f[p-1] = f[p]
    cpx fe_len
    bcs @d
    txa
    clc
    adc ed_off
    tay
    lda (eptr),y
    dey
    sta (eptr),y
    jmp @m
@d: dec fe_len
    rts

fe_end:                     ; 0-terminate at the length; clear the rest
    lda fe_len
    clc
    adc ed_off
    tay
    ldx fe_len
    lda #0
@z: sta (eptr),y
    iny
    inx
    cpx ed_max
    bcc @z
    beq @z                  ; (one more: the terminator slot at max)
    lda #$FF                ; redraw with no cursor
    sta fe_cur
    jmp fe_draw

fe_draw:                    ; the field, cursor reversed, white
    lda #0
    sta fe_p
@row:
    lda fe_p                ; which screen row: ed_row (+1 past 38)
    ldx ed_row
    cmp #FE_W
    bcc @r0
    inx
@r0: jsr row_ptrs
@col:
    lda fe_p
    cmp ed_max
    bcs @done
    cmp fe_len
    bcs @sp
    clc
    adc ed_off
    tay
    lda (eptr),y
    ldx fe_mask             ; (a password: * for each character)
    beq @ch
    lda #'*'
    jmp @ch
@sp: lda #' '
@ch: jsr asc_sc
    ldx fe_p
    cpx fe_cur
    bne @nr
    ora #$80
@nr: pha
    lda fe_p                ; column = 1 + p mod 38
    cmp #FE_W
    bcc @c0
    sbc #FE_W
@c0: tay
    iny
    pla
    sta (dst),y
    lda #1                  ; white
    sta (cptr),y
    inc fe_p
    lda fe_p
    cmp #FE_W               ; onto the second row
    bne @col
    jmp @row
@done:
    rts

.segment "MENU"             ; (the menu overlay: see ovl_menu)
ed_mode:                    ; A or P sets it (and moves on); Return/down
    jsr ed_mode_show        ; next, up back, <- cancel
    lda #$81                ; cursor on the mode letter
    ldx #ED_MODE_ROW
    jsr row_ptrs
    ldy #1
    lda (dst),y
    ora #$80
    sta (dst),y
@k: jsr GETIN
    beq @k
    cmp #$5F
    beq @c
    cmp #13
    beq @n
    cmp #$11
    beq @n
    cmp #$91
    beq @p
    and #$7F
    cmp #'P'
    beq @s
    cmp #'A'
    bne @k
@s: ldy #E_MODE
    sta (eptr),y
@n: jsr ed_mode_show
    lda #0
    clc
    rts
@p: jsr ed_mode_show
    lda #1
    clc
    rts
@c: jsr ed_mode_show
    sec
    rts

ed_mode_show:
    ldx #ED_MODE_ROW
    lda #LGREY_C
    jsr row_blank
    ldy #E_MODE
    lda (eptr),y
    cmp #'P'
    beq @p
    lda #<v_amode
    ldy #>v_amode
    bne @s
@p: lda #<v_pmode
    ldy #>v_pmode
@s: ldx #ED_MODE_ROW
    jmp put_line_v

host_tidy:                  ; host in lower case; add :23 if no port
    ldy #E_HOST             ; (and there is room)
    ldx #0
@lc: lda (eptr),y
    beq @e
    cmp #':'
    bne @l1
    inx
@l1: cmp #'A'
    bcc @l2
    cmp #'Z'+1
    bcs @l2
    ora #$20
    sta (eptr),y
@l2: iny
    bne @lc
@e: cpx #0
    bne @r
    cpy #E_HOST+HOST_MAX-3
    bcs @r
    ldx #0
@pt: lda port23,x
    sta (eptr),y
    iny
    inx
    cpx #4
    bne @pt
@r: rts

.segment "CODE"

; ---- screen-memory writers (text mode at $0400/$D800)
row_ptrs:                   ; X = row -> dst (screen), cptr (colour)
    lda row40_lo,x
    sta dst
    sta cptr
    lda row40_hi,x
    sta dst+1
    clc
    adc #$D4                ; $0400 -> $D800
    sta cptr+1
    rts

row_blank:                  ; X = row, A = colour: spaces; leaves ptrs set
    pha
    jsr row_ptrs
    pla
    ldy #39
@l: sta (cptr),y
    pha
    lda #$20
    sta (dst),y
    pla
    dey
    bpl @l
    rts

put_ch:                     ; ASCII A at column Y (w_col, w_rev)
    jsr asc_sc
    ora w_rev
    sta (dst),y
    lda w_col
    sta (cptr),y
    rts

.segment "MENU"             ; (the menu overlay: see ovl_menu)
put_field:                  ; field A of (eptr) at column X, max Y chars
    stx w_x
    sty w_max
    tay
@l: lda (eptr),y
    beq @r
    sty w_y
    ldy w_x
    jsr put_ch
    inc w_x
    ldy w_y
    iny
    dec w_max
    bne @l
@r: rts

.segment "CODE"

put_bptr:                   ; 0-terminated ASCII at (bptr), from column Y
    sty w_x
    ldy #0
@l: lda (bptr),y
    beq @r
    sty w_y
    ldy w_x
    cpy #40
    bcs @r
    jsr put_ch
    inc w_x
    ldy w_y
    iny
    bne @l
@r: rts

put_str_at:                 ; A/Y = text at column X of the current row
    sta bptr
    sty bptr+1
    txa
    tay
    jmp put_bptr

put_line_c:                 ; A/Y = text, row X, cyan
    pha
    tya
    pha
    lda #CYAN_C
    bne put_line_any
put_line_v:                 ; A/Y = text, row X, light grey (values)
    pha
    tya
    pha
    lda #LGREY_C
put_line_any:
    sta w_col
    lda #0
    sta w_rev
    jsr row_ptrs
    pla
    tay
    pla
    sta bptr
    sty bptr+1
    ldy #1
    jmp put_bptr

put_label:                  ; A/Y = label, row X, orange
    pha
    tya
    pha
    lda #ORANGE_C
    bne put_line_any

title_bar:                  ; A/Y = title, row X: reversed orange bar
    sta bptr
    sty bptr+1
    jsr row_ptrs
    ldy #39
@l: lda #$A0
    sta (dst),y
    lda #ORANGE_C
    sta (cptr),y
    dey
    bpl @l
    lda #ORANGE_C
    sta w_col
    lda #$80
    sta w_rev
    ldy #2
    jmp put_bptr

.segment "MENU"             ; (the menu overlay: see ovl_menu)
dec2:                       ; A (0-99) as two digits at columns 1-2
    ldy #1
dec2_at:                    ; ... at columns Y, Y+1
    sty w_y
    ldx #0
@t: cmp #10
    bcc @u
    sbc #10
    inx
    bne @t
@u: pha
    lda #DGREY_C
    sta w_col
    lda #0
    sta w_rev
    txa
    ora #'0'
    ldy w_y
    jsr put_ch
    pla
    ora #'0'
    ldy w_y
    iny
    jmp put_ch

.segment "CODE"

asc_sc:                     ; ASCII -> screen code (capitals)
    cmp #$60
    bcc @u
    cmp #$7B
    bcs @q
    sbc #$5F                ; a-z (C clear: -$60)
    rts
@u: cmp #$40
    bcc @r                  ; $20-$3F: the same
    sbc #$40                ; @ A-Z [ \ ] ^ _
@r: rts
@q: cmp #$C1                ; a shifted letter (only in macros: the macro
    bcc @x                  ; screen uses the lower/upper set, where this
    cmp #$DB                ; is the capital)
    bcs @x
    and #$7F
    rts
@x: lda #'?'
    rts

row40_lo:
    .repeat 25, R
    .byte <($0400+R*40)
    .endrep
row40_hi:
    .repeat 25, R
    .byte >($0400+R*40)
    .endrep

.segment "MENU"             ; (the menu overlay: see ovl_menu)
dir_dial:                   ; A = entry: ACIA, its mode, ATD host:port
    jsr ent_addr
    ldx #0
@a: lda atd_sp,x            ; "ATD "
    sta dial_buf,x
    inx
    cpx #4
    bne @a
    ldy #E_HOST
@h: lda (eptr),y
    beq @hd
    sta dial_buf,x
    inx
    iny
    bne @h
@hd:
    stx dial_len
    jsr login_load          ; its login (ZENCOM.PWD), for C=+N / C=+P
    jmp dial_go             ; (eptr kept: the board)             ; (resident: leaves the overlay for good)

atd_sp: .byte "ATD "
port23: .byte ":23", 0

.segment "CODE"
print_pet:                  ; print the 0-terminated PETSCII string at A/Y
    sta bptr
    sty bptr+1
    ldy #0
@l: lda (bptr),y
    beq @r
    jsr CHROUT
    iny
    bne @l
@r: rts

fname:  .byte "BBSLIST,S,R"
fname_len = * - fname
tname:  .byte "BBSTMP,S,R"
tname_len = * - tname
wname:  .byte "BBSTMP,S,W"
wname_len = * - wname
; scratch matches every file type: keep these names unique to the list
scr_cmd: .byte "S:BBSLIST"
scr_len = * - scr_cmd
sct_cmd: .byte "S:BBSTMP"
sct_len = * - sct_cmd
ren_cmd: .byte "R:BBSLIST=BBSTMP"
ren_len = * - ren_cmd
cname:   .byte "ZENCOM.CFG,S,R"
cname_len = * - cname
wname2:  .byte "CFGTMP,S,W"
wname2_len = * - wname2
sct2_cmd: .byte "S:CFGTMP"
sct2_len = * - sct2_cmd
scr2_cmd: .byte "S:ZENCOM.CFG"
scr2_len = * - scr2_cmd
ren2_cmd: .byte "R:ZENCOM.CFG=CFGTMP"
ren2_len = * - ren2_cmd
mname:   .byte "ZENCOM.MAC,S,R"
mname_len = * - mname
wname3:  .byte "MACTMP,S,W"
wname3_len = * - wname3
sct3_cmd: .byte "S:MACTMP"
sct3_len = * - sct3_cmd
scr3_cmd: .byte "S:ZENCOM.MAC"
scr3_len = * - scr3_cmd
ren3_cmd: .byte "R:ZENCOM.MAC=MACTMP"
ren3_len = * - ren3_cmd
pname:   .byte "ZENCOM.PWD,S,R"
pname_len = * - pname
wname4:  .byte "PWDTMP,S,W"
wname4_len = * - wname4
sct4_cmd: .byte "S:PWDTMP"
sct4_len = * - sct4_cmd
scr4_cmd: .byte "S:ZENCOM.PWD"
scr4_len = * - scr4_cmd
ren4_cmd: .byte "R:ZENCOM.PWD=PWDTMP"
ren4_len = * - ren4_cmd
.segment "MENU"             ; (the menu overlay: see ovl_menu)

t_dir:     .byte "ZENCOM  DIALLING DIRECTORY", 0
t_info:    .byte "ZENCOM  BOARD INFO", 0
t_edit:    .byte "ZENCOM  EDIT BOARD", 0
t_add:     .byte "ZENCOM  ADD A BOARD", 0
f_edit1:   .byte "RETURN/DOWN NEXT  UP BACK  MODE: A OR P", 0
f_edit2:   .byte "<- CANCEL  DEL INST HOME  CLR EMPTIES", 0
m_noaddr:  .byte "AN ADDRESS IS NEEDED", 0
v_amode:   .byte "A  ANSI-80", 0
v_pmode:   .byte "P  PETSCII-40", 0
f_keys1:   .byte "RETURN DIAL  I INFO  E EDIT  B MARK", 0
f_keys2:   .byte "A ADD  X DEL  +/- PAGE  F5 MENU", 0
f_ro:      .byte "READ-ONLY  +/- PAGE  F5 MENU", 0
f_info:    .byte "RETURN DIAL  E EDIT  OTHER KEYS BACK", 0
m_boards:  .byte "BOARDS", 0
m_usb:     .byte "FROM DRIVE", 0
m_builtin: .byte "NO LIST YET: A ADDS", 0
m_rolist:  .byte "READ-ONLY (NO DRIVE OR SAVE FAILED)", 0
.segment "CODE"
m_ro:      .byte "THE LIST IS READ-ONLY", 0
m_notsaved: .byte "NOT SAVED:", 0
.segment "MENU"
.segment "CODE"
m_nodrv:   .byte "NO DRIVE ANSWERS ON THAT NUMBER", 0
m_nodrv_len = * - m_nodrv - 1
.segment "MENU"
m_full:    .byte "THE LIST IS FULL (64 BOARDS)", 0
m_del:     .byte "DELETE ", 0
m_yn:      .byte "? Y/N", 0
l_name:    .byte "NAME", 0
l_addr:    .byte "ADDRESS", 0
l_mode:    .byte "MODE", 0
l_mark:    .byte "BOOKMARK", 0
l_note:    .byte "NOTE", 0
v_ansi:    .byte "ANSI-80", 0
v_pet:     .byte "PETSCII-40", 0
v_yes:     .byte "YES", 0
v_no:      .byte "NO", 0
l_user:    .byte "USERNAME (C=+N SENDS IT)", 0
l_pass:    .byte "PASSWORD (C=+P SENDS IT)", 0
h_pwd:     .byte "LOGINS: PLAIN TEXT IN ZENCOM.PWD", 0
m_pwdns:   .byte "LOGIN NOT SAVED", 0
.segment "CODE"

dial_go:                    ; the board at (eptr), dial_buf ready: call it
    jsr ovl_xfr             ; (the transfer code back in, before the call)
    lda #0
    sta driver
    jsr acia_init
    lda #1
    sta acia_on
    ldy #E_MODE
    lda (eptr),y
    cmp #'P'
    beq @p
    jsr ansi_mode_init
    jmp @go
@p: jsr pet_mode_init
@go:
    jsr sess_hint
    jsr redial
    jmp main

; ---- the download's type, chosen with T on the start screen (CBM drives
; can't change a file's type afterwards, so it is chosen before)
dl_tnext:                   ; T: guess -> PRG -> SEQ -> guess
    ldx x_force
    inx
    cpx #3
    bcc @s
    ldx #0
@s: stx x_force
dl_tshow:                   ; row 14
    ldx #14
    lda #LGREY_C
    jsr row_blank
    ldx x_force
    lda dt_lo,x
    ldy dt_hi,x
    ldx #14
    jmp put_line_v

dl_force:                   ; before the transfer: a chosen type is final
    ldx x_force
    beq @r
    lda #'P'
    dex
    beq @p
    lda #1                  ; SEQ: the ^Z padding goes, as for a guessed one
    sta x_strip
    lda #'S'
@p: sta x_type
@r: rts

dl_tchosen:                 ; C=1, A/Y = the finishing screen's type line
    ldx x_force
    beq @n
    lda #<fs_prgc
    ldy #>fs_prgc
    dex
    beq @y
    lda #<fs_seqc
    ldy #>fs_seqc
@y: sec
    rts
@n: clc
    rts

dt_lo: .byte <dt_g, <dt_p, <dt_s
dt_hi: .byte >dt_g, >dt_p, >dt_s
dt_g:  .byte "T       TYPE: GUESS IT", 0
dt_p:  .byte "T       TYPE: PRG", 0
dt_s:  .byte "T       TYPE: SEQ", 0

; ---- per-board logins.  ZENCOM.PWD (SEQ) in ZenCom's folder, one line a
; board: KEY|USER|PASSWORD.  KEY is the CRC-32 of the board's address
; (host:port, lower case) in 8 hex digits, so the file names no board and
; a login can only go to the address it was saved for (no match: none).
; The file is read whole into PWD_BUF (the bitmap's RAM, idle at the menu)
; when a board is dialled from the directory or edited, and written back
; with safe_save.  LOGIN holds this call's login until the menu.
PWD_BUF = $6000
PWD_MAX = $1F00
L_USER  = 0
L_PASS  = 32

pwd_crc:                    ; A/Y = an address (0-ended) -> pwd_key (hex)
    sta @g+1
    sty @g+2
    lda #$FF
    sta crc32
    sta crc32+1
    sta crc32+2
    sta crc32+3
    ldx #0
@g: lda $FFFF,x
    beq @hex
    cmp #$41                ; lower case: A-Z, and PETSCII capitals
    bcc @c
    cmp #$5B
    bcs @s
    adc #$20
    bne @c
@s: cmp #$C1
    bcc @c
    cmp #$DB
    bcs @c
    sbc #$5F                ; (C=0 here: -$60)
@c: eor crc32
    sta crc32
    ldy #8
@b: lsr crc32+3
    ror crc32+2
    ror crc32+1
    ror crc32
    bcc @nx
    lda crc32+3             ; the reflected polynomial $EDB88320
    eor #$ED
    sta crc32+3
    lda crc32+2
    eor #$B8
    sta crc32+2
    lda crc32+1
    eor #$83
    sta crc32+1
    lda crc32
    eor #$20
    sta crc32
@nx: dey
    bne @b
    inx
    bne @g
@hex: ldx #3                ; final XOR, high byte first
    ldy #0
@h: lda crc32,x
    eor #$FF
    pha
    lsr
    lsr
    lsr
    lsr
    jsr @d
    pla
    and #$0F
    jsr @d
    dex
    bpl @h
    rts
@d: cmp #10
    bcc @dg
    adc #6                  ; (C=1: +7)
@dg: adc #'0'
    sta pwd_key,y
    iny
    rts

login_key:                  ; pwd_key for the board at (eptr)
    lda eptr
    clc
    adc #E_HOST
    pha
    lda eptr+1
    adc #0
    tay
    pla
    jmp pwd_crc

pwd_load:                   ; ZENCOM.PWD -> PWD_BUF (pwd_len; 0: none)
    lda #0
    sta pwd_len
    sta pwd_len+1
    jsr io_quiet
    lda eptr
    pha
    lda eptr+1
    pha
    ldx #L_HOME
    jsr dos_loc
    bcs @r
    lda #pname_len
    ldx #<pname
    ldy #>pname
    jsr SETNAM
    lda #3
    ldx cur_dev
    ldy #2
    jsr SETLFS
    lda #0
    sta eof_next
    sta STATUS
    jsr OPEN
    bcs @c
    lda STATUS
    bmi @c
    ldx #3
    jsr CHKIN
    bcs @c
    lda #<PWD_BUF
    sta dst
    lda #>PWD_BUF
    sta dst+1
@l: jsr file_get
    bcs @c
    ldy #0
    sta (dst),y
    inc dst
    bne @x
    inc dst+1
@x: inc pwd_len
    bne @y
    inc pwd_len+1
@y: lda pwd_len+1
    cmp #>PWD_MAX
    bcc @l
@c: jsr CLRCHN
    lda #3
    jsr CLOSE
@r: pla
    sta eptr+1
    pla
    sta eptr
    jmp io_live

pw_start:                   ; src = PWD_BUF, pw_n = pwd_len
    lda #<PWD_BUF
    sta src
    lda #>PWD_BUF
    sta src+1
    lda pwd_len
    sta pw_n
    lda pwd_len+1
    sta pw_n+1
    rts

pw_get:                     ; next byte of PWD_BUF: C=1 at the end
    lda pw_n
    ora pw_n+1
    bne @g
    sec
    rts
@g: lda pw_n
    bne @d
    dec pw_n+1
@d: dec pw_n
    ldy #0
    lda (src),y
    inc src
    bne @r
    inc src+1
@r: clc
    rts

pw_is:                      ; does the line at src start with KEY| ?  X = 0
    ldy #0                  ; pwd_key, 8 pwd_old.  Z=1 yes (nothing taken)
@l: lda (src),y
    cmp pwd_key,x
    bne @r
    inx
    iny
    cpy #8
    bne @l
    lda (src),y
    cmp #'|'
@r: rts

pw_eol:                     ; skip to the next line (C=1: the end)
@l: jsr pw_get
    bcs @r
    cmp #$0D
    beq @n
    cmp #$0A
    bne @l
@n: clc
@r: rts

pwd_find:                   ; pwd_key's login in PWD_BUF -> (A/Y): user at
    sta dst                 ; +0, password at +32 (31 each); C=1 none
    sty dst+1
    ldy #63
    lda #0
@z: sta (dst),y
    dey
    bpl @z
    jsr pw_start
@line:
    lda pw_n+1              ; 9 bytes at least: KEY|
    bne @t
    lda pw_n
    cmp #9
    bcc @no
@t: ldx #0
    jsr pw_is
    beq @got
    jsr pw_eol
    bcc @line
@no: sec
    rts
@got:
    ldx #9                  ; past KEY|
@sk: jsr pw_get
    dex
    bne @sk
    ldx #0                  ; the user, to |
@u: jsr pw_get
    bcs @ok
    cmp #'|'
    beq @p
    cmp #$0D
    beq @ok
    cmp #$0A
    beq @ok
    cpx #31
    bcs @u
    stx tmp
    ldy tmp
    sta (dst),y
    inx
    jmp @u
@p: ldx #32                 ; the password, to the line's end
@pw: jsr pw_get
    bcs @ok
    cmp #$0D
    beq @ok
    cmp #$0A
    beq @ok
    cpx #63
    bcs @pw
    stx tmp
    ldy tmp
    sta (dst),y
    inx
    jmp @pw
@ok: clc
    rts

pwd_write:                  ; safe_save's writer: a header (the file is never
    lda #<pw_head           ; empty: the Ultimate's SoftIEC reads an empty
    ldy #>pw_head           ; file as junk), every line but pwd_key's, pwd_old's
    jsr print_pet           ; and an old header, then LOG_ED's login (if any)
    jsr pw_start
@line:
    lda pw_n
    ora pw_n+1
    beq @add
    ldy #0                  ; an empty line (or the LF of a CR LF): drop it
    lda (src),y
    cmp #$0D
    beq @skip
    cmp #$0A
    beq @skip
    ldy #6                  ; our header: replaced, not kept
@hd: lda (src),y
    cmp pw_head,y
    bne @nh
    dey
    bpl @hd
    bmi @skip
@nh: ldx #0
    jsr pw_is
    beq @skip
    ldx #8
    jsr pw_is
    beq @skip
@cp: jsr pw_get             ; a line kept: as it was, LF at the end
    bcs @lf0
    cmp #$0D
    beq @lf
    cmp #$0A
    beq @lf
    jsr CHROUT
    jmp @cp
@lf: lda #$0A
    jsr CHROUT
    jmp @line
@lf0: lda #$0A              ; (the file's last line had no end)
    jsr CHROUT
    jmp @add
@skip:
    jsr pw_eol
    jmp @line
@add:
    lda LOG_ED+L_USER
    ora LOG_ED+L_PASS
    beq @r
    ldx #0
@k: lda pwd_key,x
    jsr CHROUT
    inx
    cpx #8
    bne @k
    lda #'|'
    jsr CHROUT
    lda #<(LOG_ED+L_USER)
    ldy #>(LOG_ED+L_USER)
    jsr print_pet
    lda #'|'
    jsr CHROUT
    lda #<(LOG_ED+L_PASS)
    ldy #>(LOG_ED+L_PASS)
    jsr print_pet
    lda #$0A
    jmp CHROUT
@r: rts

pw_head: .byte "#ZENCOM LOGINS (E IN THE DIRECTORY): KEY|USER|PASSWORD", $0A, 0

pwd_save:                   ; ZENCOM.PWD rewritten (see pwd_write).  C=1 failed
    ldx #L_HOME
    jsr dos_loc
    bcs @r
    ldx #3
    jmp safe_save
@r: rts

login_load:                 ; dialling the board at (eptr): its login, if any
    jsr login_key
    jsr pwd_load
    lda #<LOGIN
    ldy #>LOGIN
    jmp pwd_find

login_clear:                ; back at the menu: no login kept
    ldx #63
    lda #0
@z: sta LOGIN,x
    dex
    bpl @z
    rts

send_text:                  ; A/Y = text (31 at most, 0-ended) through key_send,
    sta @g+1                ; only what the macro screen allows; ^ = Return
    sty @g+2                ; (st_raw: ^ as itself, for passwords)
    lda #0
    sta mac_p
@l: ldx mac_p
    cpx #31
    bcs @r
@g: lda $FFFF,x
    beq @r
    cmp #'^'
    bne @p
    ldx st_raw
    bne @s
    lda #13
    bne @s
@p: cmp #$C1                ; space to ], shifted letters; a-z as typed here.
    bcs @u                  ; A file edited elsewhere can't send C=+M (a
    cmp #$20                ; macro calling itself would overrun the
    bcc @n                  ; stack), F5 and the like
    cmp #$5E
    bcc @s
    cmp #$61
    bcc @n
    cmp #$7B
    bcs @n
    and #$DF
    bcc @s
@u: cmp #$DB
    bcs @n
@s: jsr key_send
@n: inc mac_p
    jmp @l
@r: rts

login_send:                 ; C=+N (X = L_USER) / C=+P (X = L_PASS): this
    lda LOGIN,x             ; board's login, then Return
    bne @go
    lda #<m_nolog
    ldy #>m_nolog
    jmp say
@go: txa
    clc
    adc #<LOGIN
    pha
    lda #>LOGIN
    adc #0
    tay
    pla
    ldx #1
    stx st_raw
    jsr send_text
    lda #0
    sta st_raw
    lda #13
    jmp key_send
m_nolog: .byte 13, 10, "-- No login saved for this board (E in the directory adds one) --", 13, 10, 0

sess_hint:                  ; a session starts: one line on where help is
    lda #<sh_text
    ldy #>sh_text
    jmp say
sh_text: .byte "-- C=+H: keys and help  F5: menu --", 13, 10, 0   ; (fits 40)

; ---- Multi-Punter receive (C=+D, then M): a batch of Punter files, as
; C64 boards send them.  Before each file the board sends CTRL-I (16 of
; them) and NAME,T + CR; the batch ends with CTRL-I and CTRL-D x16.  (The
; format as CCGMS's multixfer.s.)  Each file comes in as ZCTMP and is
; renamed to its own name (fin_rename: 63 asks).  Resident: the transfer
; overlay has no room.
MP_MAX = 18                 ; header characters kept
MP_BUF = $B800              ; (XB_RX: free until Punter starts)
MP_NAME = GUESS             ; the file's name, kept apart from XB_NAME (which
                            ; holds ZCTMP while the file comes in)

mp_batch:
    jsr dl_going
    jsr loc_enter           ; where they go
    bcc @dr
    jsr br_drvmsg
    jsr xfr_wait_key
    lda #0                  ; back, nothing said
    jmp @res
@dr: lda #0
    sta mp_n
    lda #1                  ; the first header may be in RECENT already
    sta mp_first
@file:
    ldx #15
    lda #<xs_waitsend
    ldy #>xs_waitsend
    jsr put_line_v
    jsr mp_header           ; C=1 failed (xm_err); A=1 the batch is over
    bcc @h
    jmp @fail
@h: cmp #0                  ; (test A: the flags are mp_parse's own)
    beq @one
    jmp @end
@one:
    ldx #5                  ; the file's name, as the board gave it
    lda #LGREY_C
    jsr row_blank
    ldx #6
    lda #<MP_NAME
    ldy #>MP_NAME
    jsr put_line_v
    jsr fin_tmpname
    jsr xscratch
    lda #0
    sta dl_open
    sta x_type
    sta x_strip
    sta dl_tfix
    jsr xfr_counters
    lda #<dl_write
    sta xm_out
    lda #>dl_write
    sta xm_out+1
    jsr io_live
    jsr x_recv              ; (x_proto 3: Punter)
    jsr io_quiet
    php
    lda dl_open
    beq @nc
    jsr xclose
@nc: plp
    bcs @fail
    lda dl_open
    beq @file               ; an empty file: nothing to keep
    jsr dos_status
    beq @ren
    lda #ERR_DISK
    sta xm_err
    bne @fail
@ren: ldx #16               ; the header's name back for the rename
@cn: lda MP_NAME,x
    sta XB_NAME,x
    dex
    bpl @cn
    jsr fin_rename          ; C=1: not replaced (or a drive error)
    bcs @skip
    inc mp_n
    jmp @file
@skip: jsr xscratch
    jmp @file
@fail:
    lda dl_open
    beq @f2
    jsr xscratch            ; no half files
@f2: lda mp_n
    bne @some
    lda xm_err
    cmp #ERR_USER
    bne @f3
    lda #5                  ; stopped by you
    bne @res
@f3: cmp #ERR_TIMEOUT
    bne @f4
    lda #4                  ; no answer
    bne @res
@f4: lda #6                 ; failed: the reason
    bne @res
@some: lda #<mp_stopped
    ldy #>mp_stopped
    bne @say
@end:
    lda mp_n
    bne @all
    lda #3                  ; nothing received
    bne @res
@all: lda #<mp_files
    ldy #>mp_files
@say: jsr mp_count          ; XB_NAME = "n FILES..."
    lda #1                  ; "Saved <XB_NAME>"
@res:
    sta dl_res
    jsr xfr_screen_off
    jmp dl_say

mp_header:                  ; a header: C=0 A=0 a file, its name in
    lda mp_first            ; MP_NAME; C=0 A=1 the end; C=1 failed
    beq @live
    lda #0
    sta mp_first
    jsr mp_recent           ; boards send the first one at once: it often
    bcs @part               ; came before C=+D, M
    jmp mp_parse
@part:
    sty mp_i                ; part of it (CTRL-Is, perhaps some of the name):
    lda #<SEC60             ; the rest comes live
    ldx #>SEC60
    jsr xt_set
    jsr io_live
    ldy mp_i
    bne @n
    lda mp_part
    bne @sk
    beq @w
@live:
    lda #<SEC60
    ldx #>SEC60
    jsr xt_set
    jsr io_live
@w: jsr xget                ; CTRL-I first
    bcs @to
    cmp #9
    bne @w
@sk: jsr xget               ; then past the CTRL-Is (and NULs)
    bcs @to
    cmp #0
    beq @sk
    cmp #9
    beq @sk
    ldy #0
@c: cmp #13
    beq @eol
    sta MP_BUF,y
    iny
    cpy #MP_MAX
    bcs @eol
    sty mp_i
@n: jsr xget
    bcs @to
    ldy mp_i
    cmp #0
    beq @n
    bne @c
@eol:
    jsr io_quiet
    jmp mp_parse
@to: jsr io_quiet
    lda x_cancel
    beq @tmo
    lda #ERR_USER
    bne @e
@tmo: lda #ERR_TIMEOUT
@e: sta xm_err
    sec
    rts

mp_recent:                  ; the last CTRL-I in RECENT, then NAME,T + CR:
    lda #0                  ; C=0, Y = its length in MP_BUF; C=1 not all
    sta mp_part             ; there: Y = what there is, mp_part = 1 if the
    ldx #0                  ; CTRL-Is were (Y=0 and mp_part=0: nothing)
    ldy rc_pos
@cp: lda RECENT,y           ; (the ring in order, to MP_BUF+$80)
    sta MP_BUF+$80,x
    iny
    tya
    and #127
    tay
    inx
    bpl @cp
    ldx #127
@f: lda MP_BUF+$80,x
    cmp #9
    beq @fd
    dex
    bpl @f
    ldy #0
    sec
    rts
@fd: inc mp_part
    ldy #0
@sk: inx                    ; past the CTRL-Is and NULs
    bmi @no
    lda MP_BUF+$80,x
    beq @sk
    cmp #9
    beq @sk
    ldy #0
@l: lda MP_BUF+$80,x
    cmp #13
    beq @ok
    sta MP_BUF,y
    iny
    inx
    bmi @no
    cpy #MP_MAX
    bcc @l
@ok: clc
    rts
@no: sec
    rts

mp_parse:                   ; Y characters in MP_BUF: as mp_header returns
    lda MP_BUF              ; CTRL-D: the end
    cmp #4
    beq @end
    cpy #3                  ; NAME,T
    bcc @bad
    lda MP_BUF-2,y
    cmp #','
    bne @bad
    dey
    dey
    sty mp_i                ; the name's length
    ldy #0
@nm: cpy mp_i
    beq @nd
    cpy #16
    beq @nd
    lda MP_BUF,y
    jsr pf_fold
    jsr pf_safe
    sta MP_NAME,y
    iny
    bne @nm
@nd: lda #0
    sta MP_NAME,y
    cpy #0
    beq @bad
    clc
    rts                     ; (A=0)
@end: lda #1
    clc
    rts
@bad: lda #ERR_REMOTE
    sta xm_err
    sec
    rts

mp_count:                   ; XB_NAME = mp_n (0-99) + the text at A/Y
    sta bptr
    sty bptr+1
    ldx #0
    lda mp_n
    cmp #10
    bcc @u
    ldy #'0'
@t: cmp #10
    bcc @td
    sbc #10
    iny
    bne @t
@td: sty XB_NAME
    inx
@u: ora #'0'
    sta XB_NAME,x
    inx
    ldy #0
@l: lda (bptr),y
    sta XB_NAME,x
    beq @r
    inx
    iny
    bne @l
@r: rts

mp_files:   .byte " FILE(S)", 0
mp_stopped: .byte " FILE(S), THEN IT STOPPED", 0
ds_om:      .byte "M       MULTI-PUNTER (A BATCH)", 0

; ---- the menu overlay (dialling directory, edit form, settings, saving
; the list and settings): linked to run at $A000, as the transfer overlay
; is.  It travels in ZENCOM.XFR just before it (loaded at $9000) and is
; parked in the RAM under the I/O chips ($D000-$DFFF).  ovl_menu and
; ovl_xfr exchange the park with the first 4 KB of $A000, so whichever is
; not in use keeps its state.  The transfer code is back in whenever the
; menu is drawn or a call starts (menu_start, dial_go).  Overlay code may
; leave only by JMP to menu_start or dial_go (tools/ovlcheck.py checks).
OVL_WIN   = $A0             ; pages
OVL_PARK  = $D0
OVL_PAGES = 16

ovl_menu:                   ; the menu overlay in; C=1 if there is none
    lda xfr_ok
    bne @ok
    sec
    rts
@ok: lda ovl_in
    bne @r
    lda #OVL_WIN
    jsr ovl_xchg
    lda #1
    sta ovl_in
@r: clc
    rts

ovl_xfr:                    ; the transfer overlay in
    lda ovl_in
    beq @r
    lda #OVL_WIN
    jsr ovl_xchg
    lda #0
    sta ovl_in
@r: rts

ovl_xchg:                   ; exchange 16 pages from page A with the park
    sta @a+2                ; (~0.1 s; the modem is held meanwhile)
    sta @b+2
    lda #OVL_PARK
    sta @c+2
    sta @d+2
    jsr io_quiet
    php
    sei
    lda #<sb_rti            ; an NMI (RESTORE) while the KERNAL is out
    sta $FFFA
    lda #>sb_rti
    sta $FFFB
    lda $01
    pha
    lda #$34                ; all RAM: the park is under the I/O chips
    sta $01
    lda #OVL_PAGES
    sta ovl_n
    ldy #0
@a: ldx $A000,y
@c: lda $D000,y
@b: sta $A000,y
    txa
@d: sta $D000,y
    iny
    bne @a
    inc @a+2
    inc @b+2
    inc @c+2
    inc @d+2
    dec ovl_n
    bne @a
    pla
    sta $01
    plp
    jmp io_live


; ---- the transfer overlay: ZENCOM.XFR from the load drive's current folder
xfr_load:
    lda #0
    sta xfr_ok
    jsr SETMSG              ; no "SEARCHING/LOADING" messages
    lda #xname_len
    ldx #<xname
    ldy #>xname
    jsr SETNAM
    lda #1
    ldx home_dev
    ldy #1                  ; secondary 1: load where the file says ($A000)
    jsr SETLFS
    lda #0
    jsr LOAD
    bcs @r
    ldx #2                  ; "ZX" + the same version as this program
@c: lda xfr_sig,x
    cmp xsig,x
    bne @r
    dex
    bpl @c
    inc xfr_ok
    lda #$90                ; the menu overlay came in at $9000: park it
    jmp ovl_xchg
@r: rts

xfr_find:                   ; the load drive first, else the first of 8-15
    jsr xfr_load            ; with ZENCOM.XFR becomes home_dev: a .prg run
    lda xfr_ok              ; from the Ultimate's file browser (or put in
    bne @r                  ; memory by a cartridge) leaves $BA saying 8
    lda home_dev
    sta tmp2
    lda #8
    sta home_dev
@n: cmp tmp2                ; (already tried)
    beq @s
    jsr xfr_load
    lda xfr_ok
    bne @r
@s: inc home_dev
    lda home_dev
    cmp #16
    bcc @n
    lda tmp2                ; nowhere: keep the load drive
    sta home_dev
@r: rts

xname:  .byte "ZENCOM.XFR"
xname_len = * - xname
xsig:   .byte "ZX", XFR_VER

xfr_key:                    ; C=+D / C=+U in a session (A = the key)
    ldx xfr_ok
    bne @go
    ldx #msg_noxfr-msgs
    jmp print_msg
@go: cmp #$AC
    bne @u
    jmp xfr_dl_entry        ; (fixed addresses at the top of the overlay)
@u: jmp xfr_ul_entry

ser_get: jmp (getvec)       ; -> C=0 & A=byte, or C=1 if none
ser_put: jmp (putvec)       ; A = byte to send

; =====================================================================
; Driver: 6551 ACIA, NMI-driven receive into a 256-byte ring
; =====================================================================
acia_init:
    lda #<acia_get
    sta getvec
    lda #>acia_get
    sta getvec+1
    lda #<acia_put
    sta putvec
    lda #>acia_put
    sta putvec+1
    lda #0
    sta rx_head
    sta rx_tail
    sta rts_off
    sta online
    sta lost
    sta car_seen
    sta io_depth
    sta tn_seen             ; (telnet state is per call)
    sta tn_bin_in
    sta tn_bin_out
    jsr recent_clear        ; (RAM survives a reset: no stale GOOs)
    sta ACIA+1              ; programmed reset
    lda #<(CFG+C_SPEED)     ; the speed setting (blank or bad: 9600)
    ldy #>(CFG+C_SPEED)
    jsr speed_ctrl
    sta ACIA+3
    lda #<acia_nmi
    sta NMIVEC
    lda #>acia_nmi
    sta NMIVEC+1
    lda ACIA+0              ; discard stale data
    lda ACIA+1
    lda #ACIA_CMD_ON
    sta ACIA+2
    lda #20                 ; the last call's leftovers (a "NO CARRIER" the
    jsr wait_jiffies        ; modem held while F5 had receive off) arrive
    lda rx_head             ; now: drop them, or the next call "ends"
    sta rx_tail             ; a second after it starts
    rts

acia_nmi:                   ; KERNAL $FE43 does SEI then JMP ($0318)
    pha
    txa
    pha
    lda ACIA+1
    and #$08                ; receive register full?
    beq @out                ; no: RESTORE key etc. - ignore
    lda ACIA+0
    ldx rx_head
    sta rxbuf,x
    inx
    cpx rx_tail
    beq @out                ; buffer full: drop byte
    stx rx_head
    txa
    sec
    sbc rx_tail
    cmp #RX_HIGH
    bcc @out
    lda #ACIA_CMD_HOLD      ; nearly full: drop RTS
    sta ACIA+2
    sta rts_off
@out:
    pla
    tax
    pla
    rti

acia_get:
    ldx rx_tail
    cpx rx_head
    beq @none
    lda rxbuf,x
    inc rx_tail
    ldx rts_off
    beq @ok
    pha
    lda rx_head
    sec
    sbc rx_tail
    cmp #RX_LOW
    bcs @still
    lda #0
    sta rts_off
    lda #ACIA_CMD_ON        ; drained: raise RTS
    sta ACIA+2
@still:
    pla
@ok:
    clc
    rts
@none:
    sec
    rts

acia_put:
    pha
@w: lda ACIA+1
    and #$10                ; transmit register empty?
    beq @w
    pla
    sta ACIA+0
    rts

; =====================================================================
; Driver: user port RS-232 through the KERNAL (logical file 2)
; =====================================================================
up_init:                    ; A = control register value
    pha
    jsr recent_clear
    ldx #<UP_TOP            ; the KERNAL puts its 512 bytes of RS-232
    ldy #>UP_TOP            ; buffers just below MEMTOP: by default
    clc                     ; $9E00-$9FFF, inside the BBS list.  Move
    jsr MEMTOP              ; them to $C600-$C7FF (free RAM)
    pla
    sta up_name
    lda #0
    sta up_name+1           ; 3-line handshake, no parity
    lda #2
    ldx #<up_name
    ldy #>up_name
    jsr SETNAM
    lda #2
    ldx #2
    ldy #0
    jsr SETLFS
    jsr OPEN
    ldx #2                  ; CHKIN once: in 3-line mode it is what starts
    jsr CHKIN               ; the receiver
    jsr CLRCHN
    lda #<up_get
    sta getvec
    lda #>up_get
    sta getvec+1
    lda #<up_put
    sta putvec
    lda #>up_put
    sta putvec+1
    rts

up_get:                     ; straight from the KERNAL's receive buffer
    ldy RIDBS               ; (CHKIN/GETIN/CLRCHN on every poll lost about
    cpy RIDBE               ; one byte in six at 1200 baud in VICE)
    beq @none
    lda (RIBUF),y
    inc RIDBS
    clc
    rts
@none:
    sec
    rts

up_put:
    pha
    ldx #2
    jsr CHKOUT
    pla
    jsr CHROUT
    jmp CLRCHN

; =====================================================================
; Driver: UP9600 (user port, 9600 baud), Daniel Dallmann's 1997 design:
; the modem's RXD also feeds FLAG2 and SP2; PB7 (CIA2 timer B's output)
; drives CNT2, so a start bit starts timer B and the shift register
; clocks a byte in; TXD is SP1, clocked by CIA1 timer A.  The 60 Hz
; interrupt moves to CIA1 timer B.  RTS is PB1, CTS PB6, DTR PB2.
; Off (up9_disable) around disk work and at the menu: the KERNAL's
; serial bus needs CIA1's timers back.
; =====================================================================
UP9_REV  = $C540            ; bit-reverse table, 128 bytes (free RAM)
U9_SND_PAL  = 102           ; CIA ticks a bit at 9600: PAL 985249 Hz
U9_SND_NTSC = 106           ; NTSC 1022727 Hz
U9_IRQ_PAL  = $4025         ; 60 Hz on CIA1 timer B
U9_IRQ_NTSC = $4295

up9_init:
    jsr recent_clear
    ldx #0                  ; bit-reverse table: bits 0-7 -> 7-0
@r: stx tmp
    ldy #8
@b: asl tmp
    ror
    dey
    bne @b
    sta UP9_REV,x
    inx
    bpl @r
    lda #0
    sta rx_head
    sta rx_tail
    sta rts_off
    sta online
    sta lost
    sta car_seen
    sta io_depth
    sta tn_seen
    sta tn_bin_in
    sta tn_bin_out
    lda #<up9_get
    sta getvec
    lda #>up9_get
    sta getvec+1
    lda #<up9_put
    sta putvec
    lda #>up9_put
    sta putvec+1
    lda #1
    sta up9_on
    jmp up9_enable

up9_off:                    ; at the menu: off for good
    lda up9_on
    beq @r
    jsr up9_disable
    lda #0
    sta up9_on
    sta io_depth
@r: rts

up9_enable:
    sei
    lda #<up9_irq
    sta $0314
    lda #>up9_irq
    sta $0315
    lda #<up9_nmi
    sta NMIVEC
    lda #>up9_nmi
    sta NMIVEC+1
    lda #u9_start - u9_bmi - 1  ; the next NMI is a start bit
    sta u9_bmi
    ldx #<U9_IRQ_NTSC       ; 60 Hz on CIA1 timer B
    ldy #>U9_IRQ_NTSC
    lda #U9_SND_NTSC
    sta tmp
    lda $02A6               ; KERNAL: 1 = PAL
    beq @n
    ldx #<U9_IRQ_PAL
    ldy #>U9_IRQ_PAL
    lda #U9_SND_PAL
    sta tmp
@n: stx $DC06
    sty $DC07
    lda tmp                 ; CIA1 timer A: half a bit (SP1 shifts every
    lsr                     ; second underflow)
    sta $DC04
    lda #0
    sta $DC05
    lda tmp                 ; CIA2 timer B: a bit (receive clock)
    sta $DD06
    lda #0
    sta $DD07
    lda #$41                ; CIA1 timer A on, serial port out
    sta $DC0E
    lda #1
    sta u9_out              ; (the $FF below sets it to 0 when shifted)
    sta $DC0D               ; no timer A interrupt
    sta $DC0F               ; CIA1 timer B on (continuous): 60 Hz
    lda #$92                ; CIA2 timer B stopped, its pulse on PB7
    sta $DD0F
    lda #$98                ; CIA2: NMIs on FLAG (start bit) and SDR
    bit $DD0D
    sta $DD0D
    lda #$8A                ; CIA1: IRQs on timer B (60 Hz) and SDR
    sta $DC0D
    lda #$FF
    sta $DD01               ; PB lines high (RTS on)
    sta $DC0C               ; SP1 idles high
    lda #$02                ; PB1 (RTS) the only output
    sta $DD03
    ldx rts_off             ; (still full: RTS stays off)
    beq @c
    lda #$FD
    sta $DD01
@c: cli
    rts

up9_disable:                ; RTS off; the KERNAL's IRQ, NMI and timers
    sei
    lda $DD01
    and #$FD
    sta $DD01
    lda #$7F
    sta $DD0D               ; no CIA2 NMIs
    sta $DC0D               ; no CIA1 IRQs
    bit $DD0D
    bit $DC0D
    lda #$08                ; CIA1 timer B: one-shot, stopped (the
    sta $DC0F               ; KERNAL's serial bus uses it)
    lda #$00
    sta $DC0E
    ldx #<U9_IRQ_NTSC       ; timer A: 60 Hz, as the KERNAL had it
    ldy #>U9_IRQ_NTSC
    lda $02A6
    beq @n
    ldx #<U9_IRQ_PAL
    ldy #>U9_IRQ_PAL
@n: stx $DC04
    sty $DC05
    lda #$11                ; load and start
    sta $DC0E
    lda #$81
    sta $DC0D
    lda #<$EA31
    sta $0314
    lda #>$EA31
    sta $0315
    lda #<acia_nmi          ; (ignores anything but an ACIA: RESTORE)
    sta NMIVEC
    lda #>acia_nmi
    sta NMIVEC+1
    cli
    rts

up9_irq:                    ; KERNAL $FF48 pushed A/X/Y
    lda $DC0D
    tax
    and #$08                ; SDR: 8 bits sent
    beq @t
    lda u9_out
    beq @t
    dec u9_out
@t: txa
    and #$02                ; timer B: the 60 Hz work (clock, cursor,
    beq @x                  ; keys)
    jmp $EA31
@x: jmp $EA81

up9_nmi:                    ; KERNAL $FE43 did SEI, nothing pushed
    bit $DD0D               ; CIA2?  (else RESTORE: ignore)
u9_bmi = * + 1              ; (the branch's target is switched between the
    bmi u9_start            ; two handlers: no time lost choosing)
    rti
u9_start:                   ; a start bit: timer B on (load, PB7 pulse);
    pha                     ; NMIs: SDR only ($13 = clear TA, TB, FLAG)
    lda #$13
    sta $DD0F
    sta $DD0D
    lda #u9_byte - u9_bmi - 1
    sta u9_bmi
    pla
    rti
u9_byte:
    pha
    txa
    pha
    lda #$92                ; timer B stopped, pulse on PB7; NMIs: FLAG
    sta $DD0F               ; (and the idle timer B) on again
    sta $DD0D
    lda #u9_start - u9_bmi - 1
    sta u9_bmi
    lda $DD0C               ; the byte, bit order reversed
    cmp #$80
    and #$7F
    tax
    lda UP9_REV,x
    adc #0
    ldx rx_head
    sta rxbuf,x
    inx
    cpx rx_tail
    beq @out                ; full: drop it
    stx rx_head
    txa
    sec
    sbc rx_tail
    cmp #RX_HIGH
    bcc @out
    lda $DD01               ; nearly full: RTS off
    and #$FD
    sta $DD01
    lda #1
    sta rts_off
@out:
    pla
    tax
    pla
    rti

u9_late:                    ; C=1 once 3 jiffies have passed since u9_t
    lda TIME_LO
    sec
    sbc u9_t
    cmp #3
    rts

up9_get:
    ldx rx_tail
    cpx rx_head
    beq @none
    lda rxbuf,x
    inc rx_tail
    ldx rts_off
    beq @ok
    pha
    lda rx_head
    sec
    sbc rx_tail
    cmp #RX_LOW
    bcs @still
    lda #0
    sta rts_off
    lda $DD01               ; drained: RTS on
    ora #$02
    sta $DD01
@still:
    pla
@ok:
    clc
    rts
@none:
    sec
    rts

up9_put:                    ; A = byte (keeps X and Y)
    stx u9_x
    pha
    cmp #$80                ; reverse the bits, part 1
    and #$7F
    tax
    lda TIME_LO             ; the last byte out, then CTS (PB6): 50 ms
    sta u9_t                ; at most each (a modem that doesn't drive
@w: lda u9_out              ; CTS mustn't hang us; the clock itself is
    beq @cts                ; left alone: transfers time by it)
    jsr u9_late
    bcc @w
@cts:
    lda TIME_LO
    sta u9_t
@c: lda $DD01
    and #$40
    bne @go
    jsr u9_late
    bcc @c
@go: lda UP9_REV,x          ; part 2
    adc #0
    lsr                     ; start bit (0) on top, 7 data bits
    sta $DC0C
    lda #2                  ; two SDR loads a byte
    sta u9_out
    ror                     ; bit 0 on top, then stop bits
    ora #$7F
    sta $DC0C
    pla
    ldx u9_x
    clc
    rts

; =====================================================================
; Mode switching
; =====================================================================
ansi_mode_init:
    jsr pet_cursor_off
    lda #0
    sta mode
    lda #$80                ; stop shift/C= flipping $D018
    sta SHFLAG
    jsr screen_init
    jmp term_reset

pet_mode_init:
    lda #1
    sta mode
    lda #$80                ; C=+shift must not flip the character set
    sta SHFLAG              ; (easy to hit with C=+D/U/S); a board's own
    lda #0                  ; $0E/$8E still switch it
    sta tn_state
    sta cur_vis
    sta $D020
    sta $D021
    lda caselock            ; (blue border: the lower case lock is on)
    beq @cl
    lda #6
    sta $D020
@cl:
    lda $DD00
    ora #$03                ; VIC bank 0 (KERNAL screen at $0400)
    sta $DD00
    lda #$17                ; screen $0400, lower/upper case ROM (boards
    sta $D018               ; that want graphics send $8E themselves)
    lda #$C8                ; text mode, 40 columns
    sta $D016
    lda #$1B
    sta $D011
    lda #15                 ; light grey text
    sta COLOR
    lda #$93
    jsr CHROUT
    lda #$92                ; reverse off
    jsr CHROUT
    lda #0
    sta QTSW
    sta INSRT
    rts

pet_out:                    ; incoming byte -> KERNAL screen editor
    pha
    lda caselock            ; C=+L: the board can't change the set
    beq @o
    pla
    cmp #$0E
    beq @r
    cmp #$8E
    beq @r
    pha
@o: pla
    jsr sb_check            ; (keeps A, X, Y)
    jsr CHROUT
    lda #0                  ; never get stuck in quote/insert mode
    sta QTSW
    sta INSRT
@r: rts

pet_cursor_on:
    lda #0
    sta BLNSW
    rts

pet_cursor_off:             ; stop blink and restore the cell under it
    sei
    lda #1
    sta BLNSW
    lda BLNON
    beq @x
    lda #0
    sta BLNON
    ldy PNTR
    lda GDBLN
    sta (PNT),y
    lda GDCOL
    sta (USER),y
@x: cli
    rts

; =====================================================================
; Screen setup (ANSI-80)
; =====================================================================
screen_init:
    lda #0
    sta $D020
    sta $D021
    lda $DD00
    and #$FC
    ora #$02                ; VIC bank 1
    sta $DD00
    lda #$18                ; matrix $4400, bitmap $6000
    sta $D018
    lda #$08                ; hires, 40 columns
    sta $D016
    lda #<BITMAP            ; wipe all 25 cell rows
    sta dst
    lda #>BITMAP
    sta dst+1
    lda #<8000
    sta len
    lda #>8000
    sta len+1
    lda #0
    jsr memfill
    lda #<SCREEN
    sta dst
    lda #>SCREEN
    sta dst+1
    lda #<1000
    sta len
    lda #>1000
    sta len+1
    lda #$F0
    jsr memfill
    lda #$3B                ; bitmap mode on
    sta $D011
    rts

; =====================================================================
; Terminal state
; =====================================================================
term_reset:
    lda #0
    sta sr_top              ; scroll region: the whole screen
    lda #ROWS-1
    sta sr_bot
    lda #0
    sta row
    sta col
    sta wrap
    sta tn_state
    sta an_state
    sta bold
    sta rev
    sta bg
    sta sv_row
    sta sv_col
    sta cur_vis
    lda #7
    sta fg
    jsr update_color
    ldx #0
    ldy #ROWS-1
    jmp clear_rows

; ---- telnet filter -> ansi_in ---------------------------------------
term_putc:
    ldx tn_state
    bne @s1
    cmp #$FF
    beq @to1
    jmp char_in
@to1:
    lda #1
    sta tn_state
    rts
@s1:
    dex
    bne @s2
    ldx #0                  ; byte after IAC
    stx tn_state
    cmp #$FF
    bne @n1
    jmp char_in             ; IAC IAC = literal $FF
@n1:
    cmp #$FB                ; WILL/WONT/DO/DONT
    bcc @n2
    sta tn_cmd
    lda #2
    sta tn_state
    rts
@n2:
    cmp #$FA                ; SB
    bne @x
    lda #3
    sta tn_state
@x: rts
@s2:
    dex
    bne @s3
    sta tn_opt              ; option byte
    lda #1                  ; a real negotiation: the board speaks telnet
    sta tn_seen             ; (transfers escape $FF / CR NUL; raw boards don't)
    lda #0
    sta tn_state
    lda tn_cmd
    cmp #$FB                ; WILL
    bne @do
    lda tn_opt
    beq @binin              ; BINARY: 8-bit data from the board (transfers)
    cmp #1                  ; ECHO
    beq @accept
    cmp #3                  ; SUPPRESS-GO-AHEAD
    beq @accept
    lda #$FE                ; DONT
    bne tn_reply
@binin:
    lda #1
    sta tn_bin_in
@accept:
    lda #$FD                ; DO
    bne tn_reply
@do:
    cmp #$FD                ; DO BINARY -> WILL; any other DO -> WONT
    bne @x
    lda tn_opt
    bne @wont
    lda #1
    sta tn_bin_out
    lda #$FB
    bne tn_reply
@wont:
    lda #$FC
    bne tn_reply
@s3:
    dex
    bne @s4
    cmp #$FF                ; inside SB: wait for IAC
    bne @x
    lda #4
    sta tn_state
    rts
@s4:
    cmp #$F0                ; SE ends subnegotiation
    beq @end
    lda #3
    .byte $2C
@end:
    lda #0
    sta tn_state
    rts

tn_reply:                   ; send IAC, A, tn_opt
    pha
    lda #$FF
    jsr ser_put
    pla
    jsr ser_put
    lda tn_opt
    jmp ser_put

char_in:
    ldx mode
    beq ansi_in
    ldx swapcase            ; ZenCom's own (ASCII) messages
    bne @swap
    ldx flipcase            ; F8: board sends ASCII to a PETSCII screen
    bne @swap
    ldx driver              ; text from the modem itself (ACIA, offline)
    bne @pet                ; is ASCII too: show it in PETSCII case
    ldx online
    bne @pet
@swap:
    jsr ascii_to_pet
@pet:
    jmp pet_out

flip_ascii:                 ; swap the case of an ASCII letter
    cmp #$41
    bcc @r
    cmp #$5B
    bcc @f
    cmp #$61
    bcc @r
    cmp #$7B
    bcs @r
@f: eor #$20
@r: rts

ascii_to_pet:               ; ASCII letters -> PETSCII for the charset in use
    cmp #$41
    bcc @r
    cmp #$5B
    bcc @up
    cmp #$61
    bcc @r
    cmp #$7B
    bcs @r
    and #$DF                ; a-z -> $41-$5A (lower case, or capitals in
    rts                     ; the upper case/graphics set)
@up:
    pha                     ; A-Z: shifted ($C1-$DA) only in the lower/
    lda $D018               ; upper case set; in the graphics set the
    and #$02                ; plain codes are already capitals
    beq @g
    pla
    ora #$80
    rts
@g: pla
@r: rts

; ---- ANSI / control interpreter ---------------------------------------
ansi_in:
    cmp #$08                ; any byte but BS cancels a pending DEL echo
    beq @bs
    ldx #0
    stx bsflag
@bs:
    cmp #$0A                ; any byte other than LF/NUL ends a CR LF pair
    beq @keep
    cmp #0
    beq @keep
    ldx #0
    stx crflag
@keep:
    ldx an_state
    beq @normal
    dex
    bne @csi
    jmp ansi_esc
@csi:
    jmp ansi_csi
@normal:
    cmp #$1B
    bne @n0
    lda #1
    sta an_state
    rts
@n0:
    cmp #$20
    bcc ctrl_char
    cmp #$7F
    beq @r
    bcs @high
    ldx flipcase            ; F8: board sends PETSCII-cased text
    beq @nf
    ldx swapcase            ; (but not ZenCom's own messages)
    bne @nf
    jsr flip_ascii
@nf:
    sec
    sbc #$20
    jmp put_char
@high:
    tax
    lda cp437_map-$80,x
    jmp put_char
@r: rts

ctrl_char:
    cmp #$0D                ; CR: column 0.  Offline, talking to the
    bne @c1                 ; modem (bare CR line ends), also a new line
    lda #0
    sta col
    sta wrap
    lda online              ; online: plain CR (boards redraw lines with it)
    beq @crnl
    rts
@crnl:
    jsr linefeed
    lda #1                  ; swallow an LF that directly follows
    sta crflag
    rts
@c1:
    cmp #$0A
    bne @c2
    lda crflag
    beq @lf
    lda #0                  ; CR LF: already moved down
    sta crflag
    rts
@lf:
    jmp linefeed
@c2:
    cmp #$08
    bne @c3
    lda #0
    sta wrap
    lda col
    beq @r
    dec col
    lda bsflag              ; echo of our own DEL: erase the cell as well,
    beq @r                  ; as the modem's command mode only echoes BS
    lda #0
    sta bsflag
    ldx col
    ldy col
    jmp clear_cells
@r: rts
@c3:
    cmp #$09
    bne @c4
    lda #0
    sta wrap
    lda col
    and #$F8
    clc
    adc #8
    cmp #COLS
    bcc @t
    lda #COLS-1
@t: sta col
    rts
@c4:
    cmp #$0C
    bne @r
    jmp clear_home

put_char:                   ; A = glyph index
    ldx wrap
    beq @draw
    pha
    lda #0
    sta col
    jsr linefeed
    pla
@draw:
    jsr draw_glyph
    lda col
    cmp #COLS-1
    bcs @end
    inc col
    rts
@end:
    lda #1                  ; deferred wrap, like a VT100
    sta wrap
    rts

linefeed:                   ; down a row; at the scroll region's bottom the
    lda #0                  ; region scrolls (the whole screen: fast path)
    sta wrap
    lda row
    cmp sr_bot
    beq @sc
    cmp #ROWS-1
    bcs @r                  ; (below the region, at the bottom: stay)
    inc row
@r: rts
@sc: lda sr_top
    bne @rg
    lda sr_bot
    cmp #ROWS-1
    bne @rg
    jmp scroll_up
@rg: ldx sr_top
    ldy sr_bot
    jmp region_up

clear_home:
    ldx #0
    ldy #ROWS-1
    jsr clear_rows
    lda #0
    sta row
    sta col
    sta wrap
    rts

ansi_esc:                   ; byte after ESC
    ldx #0
    stx an_state
    cmp #'['
    bne @e1
    lda #2
    sta an_state
    lda #0
    sta np
    sta priv
    ldx #7
@clr: sta par,x
    dex
    bpl @clr
    rts
@e1:
    cmp #'7'
    beq save_cur
    cmp #'8'
    beq rest_cur
    cmp #'c'
    bne @e2
    jmp term_reset
@e2:
    cmp #'D'
    bne @e3
    jmp linefeed
@e3:
    cmp #'E'
    bne @e4
    lda #0
    sta col
    jmp linefeed
@e4:
    cmp #'M'                ; reverse index: up a row; at the region's top
    bne @r                  ; the region scrolls down
    lda row
    cmp sr_top
    bne @up
    ldx sr_top
    ldy sr_bot
    jmp region_down
@up: lda row
    beq @r
    dec row
@r: rts

save_cur:
    lda row
    sta sv_row
    lda col
    sta sv_col
    rts
rest_cur:
    lda sv_row
    sta row
    lda sv_col
    sta col
    lda #0
    sta wrap
    rts

ansi_csi:                   ; collecting parameters
    cmp #$1B
    bne @c0
    lda #1                  ; ESC restarts the sequence
    sta an_state
    rts
@c0:
    cmp #'0'
    bcc @notdig
    cmp #'9'+1
    bcs @notdig
    and #$0F
    sta tmp
    ldx np
    lda par,x
    cmp #26
    bcs @sat
    asl                     ; *10 = *2 + *8
    sta tmp2
    asl
    asl
    adc tmp2
    adc tmp
    bcs @sat
    sta par,x
    rts
@sat:
    lda #255
    sta par,x
    rts
@notdig:
    cmp #';'
    bne @c1
    ldx np
    cpx #7
    bcs @r
    inx
    stx np
    rts
@c1:
    cmp #$3C                ; < = > ? mark private sequences
    bcc @c2
    cmp #$40
    bcs @c2
    sta priv
    rts
@c2:
    cmp #$40
    bcc @r                  ; intermediate bytes: ignore
    cmp #$7F
    bcs @r
    ldx #0                  ; final byte
    stx an_state
    inc np                  ; np = parameter count
    ldx priv
    bne @r                  ; ignore private modes (e.g. ?25h)
    ldx #0
@find:
    ldy csi_keys,x
    beq @r
    cmp csi_keys,x
    beq @hit
    inx
    bne @find
@hit:
    txa
    asl
    tax
    lda csi_jump+1,x
    pha
    lda csi_jump,x
    pha
@r: rts                     ; (RTS dispatches on a hit)

csi_keys:
    .byte "ABCDEFGHfdJKmsunLMr@PX", 0
csi_jump:
    .word cur_up-1, cur_down-1, cur_right-1, cur_left-1
    .word cur_nl-1, cur_pl-1, cur_col-1, cur_pos-1
    .word cur_pos-1, cur_row-1, erase_disp-1, erase_line-1
    .word sgr-1, save_cur-1, rest_cur-1, dsr-1
    .word ins_line-1, del_line-1, set_region-1
    .word ins_char-1, del_char-1, erase_char-1

get_n1:                     ; first parameter, default/minimum 1
    lda par
    bne @r
    lda #1
@r: rts

cur_up:                     ; CSI n A: up, stopping at the scroll region's
    jsr get_n1              ; top if the cursor is inside or below it
    sta tmp
    ldx #0
    lda row
    cmp sr_top
    bcc @l
    ldx sr_top
@l: stx tmp2
    lda row
    sec
    sbc tmp
    bcc @min
    cmp tmp2
    bcs @ok
@min:
    lda tmp2
@ok:
    sta row
    jmp clrwrap

cur_down:                   ; CSI n B: down, stopping at the region's bottom
    jsr get_n1              ; if the cursor is inside or above it
    sta tmp
    ldx #ROWS-1
    lda sr_bot
    cmp row
    bcc @l
    tax
@l: stx tmp2
    lda row
    clc
    adc tmp
    bcs @max
    cmp tmp2
    bcc @ok
    beq @ok
@max:
    lda tmp2
@ok:
    sta row
    jmp clrwrap

cur_right:
    jsr get_n1
    clc
    adc col
    bcs @max
    cmp #COLS
    bcc @ok
@max:
    lda #COLS-1
@ok:
    sta col
    jmp clrwrap

cur_left:
    jsr get_n1
    sta tmp
    lda col
    sec
    sbc tmp
    bcs @ok
    lda #0
@ok:
    sta col
    jmp clrwrap

cur_nl:
    jsr cur_down
    lda #0
    sta col
    rts

cur_pl:
    jsr cur_up
    lda #0
    sta col
    rts

cur_col:
    jsr get_n1
    jsr clamp_col
    sta col
    jmp clrwrap

cur_row:
    jsr get_n1
    jsr clamp_row
    sta row
    jmp clrwrap

cur_pos:
    jsr get_n1
    jsr clamp_row
    sta row
    lda par+1
    bne @c
    lda #1
@c: jsr clamp_col
    sta col
clrwrap:
    lda #0
    sta wrap
    rts

clamp_row:                  ; 1-based A -> 0..23
    sec
    sbc #1
    cmp #ROWS
    bcc @r
    lda #ROWS-1
@r: rts

clamp_col:                  ; 1-based A -> 0..79
    sec
    sbc #1
    cmp #COLS
    bcc @r
    lda #COLS-1
@r: rts

erase_disp:                 ; ESC[nJ
    lda par
    bne @e1
    ldx col                 ; 0: cursor to end of screen
    ldy #COLS-1
    jsr clear_cells
    lda row
    cmp #ROWS-1
    bcs @r
    ldx row
    inx
    ldy #ROWS-1
    jmp clear_rows
@e1:
    cmp #1
    bne @e2
    lda row                 ; 1: start of screen to cursor
    beq @line
    tay
    dey
    ldx #0
    jsr clear_rows
@line:
    ldx #0
    ldy col
    jmp clear_cells
@e2:
    jmp clear_home          ; 2/3: whole screen (homes, as ANSI.SYS)
@r: rts

erase_line:                 ; ESC[nK
    lda par
    bne @e1
    ldx col
    ldy #COLS-1
    jmp clear_cells
@e1:
    cmp #1
    bne @e2
    ldx #0
    ldy col
    jmp clear_cells
@e2:
    ldx row
    ldy row
    jmp clear_rows

sgr:                        ; ESC[...m
    ldx #0
@loop:
    cpx np
    bcc @more
    jmp update_color
@more:
    lda par,x
    bne @s1
    lda #0                  ; 0 reset
    sta bold
    sta rev
    sta bg
    lda #7
    sta fg
    jmp @next
@s1:
    cmp #1
    bne @s22
    sta bold
    jmp @next
@s22:
    cmp #22
    bne @s7
    lda #0
    sta bold
    jmp @next
@s7:
    cmp #7
    bne @s27
    lda #1
    sta rev
    bne @next
@s27:
    cmp #27
    bne @s38
    lda #0
    sta rev
    beq @next
@s38:
    cmp #38                 ; extended colour: skip the rest
    beq @done
    cmp #48
    beq @done
    cmp #39
    bne @s49
    lda #7
    sta fg
    bne @next
@s49:
    cmp #49
    bne @s30
    lda #0
    sta bg
    beq @next
@s30:
    cmp #30
    bcc @next
    cmp #38
    bcs @s40
    sbc #29                 ; C clear here: subtracts 30
    sta fg
    jmp @next
@s40:
    cmp #40
    bcc @next
    cmp #48
    bcs @next
    sbc #39                 ; subtracts 40 (C clear)
    sta bg
@next:
    inx
    jmp @loop
@done:
    jmp update_color

dsr:                        ; ESC[6n -> ESC[row;colR
    lda par
    cmp #6
    bne @r
    lda #$1B
    jsr ser_put
    lda #'['
    jsr ser_put
    ldx row
    inx
    txa
    jsr send_dec
    lda #';'
    jsr ser_put
    ldx col
    inx
    txa
    jsr send_dec
    lda #'R'
    jmp ser_put
@r: rts

send_dec:                   ; A = 1..99
    ldx #0
@t: cmp #10
    bcc @u
    sbc #10
    inx
    bne @t
@u: pha
    txa
    beq @ones
    ora #$30
    jsr ser_put
@ones:
    pla
    ora #$30
    jmp ser_put

update_color:
    lda colour_on
    beq @mono
    ldx fg
    lda bold
    beq @norm
    lda bright_map,x
    bne @fg                 ; (no bright colour maps to 0)
@norm:
    lda norm_map,x
@fg:
    asl
    asl
    asl
    asl
    sta tmp
    ldx bg
    lda norm_map,x
    ora tmp
    sta cur_color
    rts
@mono:
    lda #$F0                ; light grey on black
    ldx bold
    beq @m
    lda #$10                ; white for bold
@m: sta cur_color
    rts

; ANSI 0-7: black red green yellow blue magenta cyan white
norm_map:   .byte 0, 2, 5, 8, 6, 4, 3, 15
bright_map: .byte 11, 10, 13, 7, 14, 4, 3, 1

; =====================================================================
; Drawing
; =====================================================================
calc_bm:                    ; X = row, A = col -> ptr; A preserved
    pha
    lda #0
    sta ptr+1
    pla
    pha
    and #$FE
    asl
    asl
    rol ptr+1
    clc
    adc bm_lo,x
    sta ptr
    lda ptr+1
    adc bm_hi,x
    sta ptr+1
    pla
    rts

draw_glyph:                 ; A = glyph, at row/col with attributes
    sta gidx
    ldx row
    lda col
    jsr calc_bm             ; ptr = 8x8 cell; A = col
    lsr                     ; A = colour cell, C = odd column
    bcc @even
    jmp @odd
@even:
    adc scr_lo,x            ; colour for this cell (shared by 2 chars)
    sta cptr
    lda scr_hi,x
    adc #0
    sta cptr+1
    ldy #0
    lda cur_color
    sta (cptr),y
    ldx gidx
    lda rev
    beq @erevn
    jmp @erev
@erevn:
    lda (ptr),y
    and #$0F
    ora a:font_l+0*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$0F
    ora a:font_l+1*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$0F
    ora a:font_l+2*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$0F
    ora a:font_l+3*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$0F
    ora a:font_l+4*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$0F
    ora a:font_l+5*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$0F
    ora a:font_l+6*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$0F
    ora a:font_l+7*NUM_GLYPHS,x
    sta (ptr),y
    rts
@erev:
    lda a:font_l+0*NUM_GLYPHS,x
    eor #$F0
    sta tmp
    lda (ptr),y
    and #$0F
    ora tmp
    sta (ptr),y
    iny
    lda a:font_l+1*NUM_GLYPHS,x
    eor #$F0
    sta tmp
    lda (ptr),y
    and #$0F
    ora tmp
    sta (ptr),y
    iny
    lda a:font_l+2*NUM_GLYPHS,x
    eor #$F0
    sta tmp
    lda (ptr),y
    and #$0F
    ora tmp
    sta (ptr),y
    iny
    lda a:font_l+3*NUM_GLYPHS,x
    eor #$F0
    sta tmp
    lda (ptr),y
    and #$0F
    ora tmp
    sta (ptr),y
    iny
    lda a:font_l+4*NUM_GLYPHS,x
    eor #$F0
    sta tmp
    lda (ptr),y
    and #$0F
    ora tmp
    sta (ptr),y
    iny
    lda a:font_l+5*NUM_GLYPHS,x
    eor #$F0
    sta tmp
    lda (ptr),y
    and #$0F
    ora tmp
    sta (ptr),y
    iny
    lda a:font_l+6*NUM_GLYPHS,x
    eor #$F0
    sta tmp
    lda (ptr),y
    and #$0F
    ora tmp
    sta (ptr),y
    iny
    lda a:font_l+7*NUM_GLYPHS,x
    eor #$F0
    sta tmp
    lda (ptr),y
    and #$0F
    ora tmp
    sta (ptr),y
    rts
@odd:
    clc
    adc scr_lo,x
    sta cptr
    lda scr_hi,x
    adc #0
    sta cptr+1
    ldy #0
    lda cur_color
    sta (cptr),y
    ldx gidx
    lda rev
    beq @orevn
    jmp @orev
@orevn:
    lda (ptr),y
    and #$F0
    ora a:font_r+0*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$F0
    ora a:font_r+1*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$F0
    ora a:font_r+2*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$F0
    ora a:font_r+3*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$F0
    ora a:font_r+4*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$F0
    ora a:font_r+5*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$F0
    ora a:font_r+6*NUM_GLYPHS,x
    sta (ptr),y
    iny
    lda (ptr),y
    and #$F0
    ora a:font_r+7*NUM_GLYPHS,x
    sta (ptr),y
    rts
@orev:
    lda a:font_r+0*NUM_GLYPHS,x
    eor #$0F
    sta tmp
    lda (ptr),y
    and #$F0
    ora tmp
    sta (ptr),y
    iny
    lda a:font_r+1*NUM_GLYPHS,x
    eor #$0F
    sta tmp
    lda (ptr),y
    and #$F0
    ora tmp
    sta (ptr),y
    iny
    lda a:font_r+2*NUM_GLYPHS,x
    eor #$0F
    sta tmp
    lda (ptr),y
    and #$F0
    ora tmp
    sta (ptr),y
    iny
    lda a:font_r+3*NUM_GLYPHS,x
    eor #$0F
    sta tmp
    lda (ptr),y
    and #$F0
    ora tmp
    sta (ptr),y
    iny
    lda a:font_r+4*NUM_GLYPHS,x
    eor #$0F
    sta tmp
    lda (ptr),y
    and #$F0
    ora tmp
    sta (ptr),y
    iny
    lda a:font_r+5*NUM_GLYPHS,x
    eor #$0F
    sta tmp
    lda (ptr),y
    and #$F0
    ora tmp
    sta (ptr),y
    iny
    lda a:font_r+6*NUM_GLYPHS,x
    eor #$0F
    sta tmp
    lda (ptr),y
    and #$F0
    ora tmp
    sta (ptr),y
    iny
    lda a:font_r+7*NUM_GLYPHS,x
    eor #$0F
    sta tmp
    lda (ptr),y
    and #$F0
    ora tmp
    sta (ptr),y
    rts

cursor_show:
    lda mode
    beq @a
    jmp pet_cursor_on
@a: lda cur_vis
    bne @r
    lda row
    sta crow
    lda col
    sta ccol
    jsr cursor_xor
    lda #1
    sta cur_vis
@r: rts

cursor_hide:
    lda mode
    beq @a
    jmp pet_cursor_off
@a: lda cur_vis
    beq @r
    jsr cursor_xor
    lda #0
    sta cur_vis
@r: rts

cursor_xor:                 ; underline in the blank 8th pixel row
    ldx crow
    lda ccol
    jsr calc_bm
    ldy #7
    and #1
    beq @even
    lda #$0F
    .byte $2C
@even:
    lda #$F0
    eor (ptr),y
    sta (ptr),y
    rts

clear_cells:                ; row, cols X..Y inclusive
    stx cc_from
    sty cc_to
    lda col
    pha
    lda rev
    pha
    lda #0
    sta rev
    lda cc_from
    sta col
@l: lda #0                  ; space
    jsr draw_glyph
    lda col
    cmp cc_to
    bcs @d
    inc col
    bne @l
@d: pla
    sta rev
    pla
    sta col
    rts

clear_rows:                 ; rows X..Y inclusive (fast block fill)
    stx cr_from
    tya
    sec
    sbc cr_from
    clc
    adc #1
    sta tmp                 ; n rows
    lda bm_lo,x
    sta dst
    lda bm_hi,x
    sta dst+1
    lda #0                  ; len = n*320 = n*256 + n*64
    sta len+1
    lda tmp
    sta len
    ldy #6
@m64:
    asl len
    rol len+1
    dey
    bne @m64
    lda len+1
    clc
    adc tmp
    sta len+1
    lda #0
    jsr memfill
    ldx cr_from
    lda scr_lo,x
    sta dst
    lda scr_hi,x
    sta dst+1
    lda #0                  ; len = n*40 = n*32 + n*8
    sta len+1
    lda tmp
    asl
    asl
    asl                     ; n*8 (n<=24, fits in a byte)
    sta tmp2
    sta len
    asl len                 ; n*32 as 16 bits
    rol len+1
    asl len
    rol len+1
    lda len
    clc
    adc tmp2
    sta len
    lda len+1
    adc #0
    sta len+1
    lda cur_color
    jmp memfill

scroll_up:                  ; rows 1-23 up one; row 23 cleared
    ldx #0                  ; bitmap: all 23 rows per pass of X, top
@b1:                        ; row first, so each byte is read before the
    .repeat 23, R           ; row above overwrites it (fixed addresses)
    lda BITMAP+(R+1)*320,x
    sta BITMAP+R*320,x
    .endrep
    inx
    beq @b2
    jmp @b1
@b2:                        ; the last 64 bytes of each 320-byte row
    .repeat 23, R
    lda BITMAP+(R+1)*320+256,x
    sta BITMAP+R*320+256,x
    .endrep
    inx
    cpx #64
    beq @c0
    jmp @b2
@c0:
    ldx #0
@c1:                        ; colour matrix, 40 bytes a row
    .repeat 23, R
    lda SCREEN+(R+1)*40,x
    sta SCREEN+R*40,x
    .endrep
    inx
    cpx #40
    beq @cl
    jmp @c1
@cl:
    ldx #ROWS-1
    ldy #ROWS-1
    jmp clear_rows

memfill:                    ; A -> dst, len bytes
    ldy #0
    ldx len+1
    beq @part
@full:
    sta (dst),y
    iny
    bne @full
    inc dst+1
    dex
    bne @full
@part:
    ldx len
    beq @r
@p: sta (dst),y
    iny
    dex
    bne @p
@r: rts

; =====================================================================
; Keyboard: PETSCII -> ASCII / ANSI
; =====================================================================
mac_key:                    ; A = the key after C=+M: 1-8 sends that macro
    ldx #0                  ; through key_send (^ = Return); else nothing
    stx mac_wait
    ldx mborder
    stx $D020
    sec
    sbc #'1'
    cmp #8
    bcs @r
    asl
    asl
    asl
    asl
    asl
    clc                     ; MACROS + slot x 32
    adc #<MACROS
    ldy #>MACROS
    jmp send_text
@r: rts

key_send:
    ldx lost                ; "call ended" shown: any key clears it and
    cpx #2                  ; carries on as normal (F4/F5/F6 act below)
    bne @kl
    ldx #0
    stx lost
    stx online
@kl:
    ldx mac_wait            ; after C=+M this key picks the macro
    beq @km
    jmp mac_key
@km:
    cmp #$A7                ; C=+M: a macro, then 1-8 (yellow border till
    bne @nm                 ; then)
    lda $D020
    sta mborder
    lda #7
    sta $D020
    inc mac_wait
    rts
@nm:
    cmp #$AA                ; C=+N / C=+P: this board's username / password
    beq @ln
    cmp #$AF
    bne @np
    ldx #L_PASS
    .byte $2C               ; BIT abs: skip the LDX
@ln: ldx #L_USER
    jmp login_send
@np:
    cmp #$AE                ; C=+S: pause / carry on (red border while paused)
    bne @ns
    lda paused
    eor #1
    sta paused
    beq @go
    lda $D020
    sta pborder
    lda #2
    bne @bd
@go: lda pborder
@bd: sta $D020
    rts
@ns:
    cmp #$B6                ; C=+L: lower case lock (PETSCII): keep the
    bne @nL                 ; lower/upper set, ignore a board's $0E/$8E
    lda mode                ; (some send $8E and then lower case text)
    beq @lr
    lda caselock
    eor #1
    sta caselock
    beq @lo
    lda #$17
    sta $D018
    lda #6                  ; blue border while locked
    .byte $2C
@lo: lda #0
    sta $D020
@lr: rts
@nL:
    cmp #$BF                ; C=+B: scroll-back (PETSCII)
    bne @nB
    jmp sb_view
@nB:
    cmp #$B4                ; C=+H: the help page, then back to the call
    bne @nH
    jmp help_session
@nH:
    cmp #$AC                ; C=+D download / C=+U upload
    beq @xf
    cmp #$B8
    bne @nx
@xf: ldx #0                 ; (the nudges may come again next time)
    stx gw_n
    stx gw_shown
    stx ph_shown
    stx ph_pend
    jmp xfr_key
@nx:
    cmp #$8C                ; F8: case swap on/off (dark grey border = on)
    bne @kc
    lda flipcase
    eor #1
    sta flipcase
    beq @bk
    lda #11
@bk:
    sta $D020
    rts
@kc:
    ldx auto_state          ; waiting to redial: any key but F6 stops it
    cpx #1
    bne @ka
    cmp #$8B
    beq @ka
    jmp auto_stop
@ka:
    cmp #$8B                ; F6: auto redial on/off (not while connected)
    bne @kf6
    ldx online
    bne @kf6
    ldx auto_state
    beq @aon
    jmp auto_stop
@aon:
    jmp auto_start
@kf6:
    cmp #$8A                ; F4: redial the last ATD line
    bne @kf4
    ldx online              ; connected: F4 is just a key
    bne @kf4
    jmp redial
@kf4:
    cmp #$87                ; F5: hang up, back to the menu
    bne @k7
    jmp hang_up
@k7:
    cmp #$88                ; F7: switch mode
    bne @k0
    lda mode
    bne @toansi
    jmp pet_mode_init
@toansi:
    jmp ansi_mode_init
@k0:
    ldx mode
    beq @ansi
    jmp key_out             ; PETSCII mode: send the key as-is
@ansi:
    cmp #$0D
    beq @send
    ldx #0
    stx bsflag
    cmp #$14                ; DEL -> backspace
    bne @k1
    inc bsflag              ; next BS echoed back erases
    lda #$08
    bne @send
@k1:
    ldx #3                  ; cursor keys
@ck:
    cmp curs_keys,x
    beq @cursor
    dex
    bpl @ck
    cmp #$85                ; F1 -> ESC
    bne @k2
    lda #$1B
    bne @send
@k2:
    cmp #$86                ; F3 -> toggle colour
    bne @k3
    jmp f3_colour
@k3:
    cmp #$13                ; HOME -> ESC[H
    bne @k4
    ldx #4
    bne @cursor
@k4:
    ldx #4                  ; shifted symbols
@sk:
    cmp sym_keys,x
    beq @sym
    dex
    bpl @sk
    cmp #$41                ; unshifted letters -> lower case
    bcc @k5
    cmp #$5B
    bcs @k5
    ora #$20
    bne @send
@k5:
    cmp #$C1                ; shifted letters -> upper case
    bcc @k6
    cmp #$DB
    bcs @k6
    and #$7F
    bne @send
@k6:
    cmp #$20                ; digits, punctuation, @ [ £ ] ^ _
    bcc @ctl
    cmp #$60
    bcc @send
    rts
@ctl:
    cmp #$01                ; CTRL-A..Z
    bcc @r
    cmp #$1B
    bcs @r
@send:
    jmp key_out
@sym:
    lda sym_ascii,x
    bne @send
@cursor:
    lda curs_ansi,x         ; save before sends (KERNAL clobbers X)
    pha
    lda #$1B
    jsr ser_put
    lda #'['
    jsr ser_put
    pla
    jmp ser_put
@r: rts

curs_keys:  .byte $91, $11, $1D, $9D        ; up down right left
curs_ansi:  .byte 'A', 'B', 'C', 'D', 'H'
sym_keys:   .byte $DB, $DD, $BA, $A9, $DE   ; shift + - @ £ up-arrow
sym_ascii:  .byte '{', '}', '`', '|', '~'

; =====================================================================
; Tables and data
; =====================================================================
bm_lo:
    .repeat ROWS, I
    .byte <(BITMAP + I*320)
    .endrep
bm_hi:
    .repeat ROWS, I
    .byte >(BITMAP + I*320)
    .endrep
scr_lo:
    .repeat ROWS, I
    .byte <(SCREEN + I*40)
    .endrep
scr_hi:
    .repeat ROWS, I
    .byte >(SCREEN + I*40)
    .endrep

.include "font.inc"
.segment "CODE2"            ; $4800-$5FFF

quit_basic:                 ; Q on the menu: the modem quiet (no stray
    sei                     ; interrupts, and it hangs up), then the C64's
    lda #0                  ; own reset, as SYS 64738
    sta ACIA+1              ; (6551 programmed reset; harmless if absent)
    jmp ($FFFC)

menu_warn:                  ; row 24: ZenCom's files (the transfer code) not
    lda xfr_ok              ; found: transfers and the BBS list are off.
    bne @r                  ; Usually started away from its folder (e.g.
    ldx #0                  ; the Ultimate's file browser with drive 11's
@c: lda mw_text,x           ; default path elsewhere)
    beq @r
    cmp #$40                ; ASCII capitals -> screen codes
    bcc @s
    sbc #$40
@s: sta $0400+24*40+2,x
    lda #YELLOW_C
    sta $D800+24*40+2,x
    inx
    bne @c
@r: rts
mw_text: .byte "ZENCOM'S FILES NOT FOUND", 0

; ---- scroll-back (PETSCII): the top row is kept, just before the screen
; editor scrolls it away, in a ring of SB_LINES lines of 40 characters +
; 40 colours in the RAM under the KERNAL ROM ($E000-: writes reach the RAM
; with the ROM in; reading banks the ROM out, IRQs off, modem held).
SB_RAM   = $E000
SB_LINES = 100              ; 100 x 80 = $1F40: $E000-$FF3F

sb_check:                   ; A = the byte about to go to CHROUT
    pha
    stx sb_sx
    sty sb_sy
    cmp #$93                ; CLR: boards clear between pages, so keep the
    bne @ns                 ; page that is about to go
    jsr sb_clr
    jmp @r
@ns: ldx TBLX
    cpx #24
    bne @r
    cmp #$0D                ; Return / shifted Return / cursor down on the
    beq @sv                 ; bottom row: the screen scrolls
    cmp #$8D
    beq @sv
    cmp #$11
    beq @sv
    ldx PNTR                ; a character in the last column: it wraps
    cpx #39
    beq @pr
    cpx #79
    bne @r
@pr: cmp #$20
    bcc @r
    cmp #$80
    bcc @sv
    cmp #$A0
    bcc @r
@sv: lda #0
    jsr sb_push
    lda LDTB1+1             ; row 1 continues row 0: it goes too
    bmi @r
    lda #1
    jsr sb_push
@r: ldx sb_sx
    ldy sb_sy
    pla
    rts

sb_clr:                     ; rows 0 to the last non-blank one -> the ring
    ldx #24
@f: lda scr_row_lo,x
    sta src
    lda scr_row_hi,x
    sta src+1
    ldy #39
    lda #$20
@b: cmp (src),y
    bne @keep
    dey
    bpl @b
    dex
    bpl @f
    rts                     ; a blank screen: nothing to keep
@keep:
    stx sb_row
    lda #0
@p: pha
    jsr sb_push
    pla
    cmp sb_row
    bcs @d
    adc #1                  ; (C clear: A < sb_row)
    bne @p
@d: rts

sb_addr:                    ; A = ring line -> sb_ptr = SB_RAM + A*80
    sta sb_ptr
    lda #0
    sta sb_ptr+1
    lda sb_ptr              ; *80 = *64 + *16
    asl
    rol sb_ptr+1
    asl
    rol sb_ptr+1
    asl
    rol sb_ptr+1
    asl
    rol sb_ptr+1            ; *16
    sta sb_t
    lda sb_ptr+1
    sta sb_t+1
    lda sb_t
    asl
    rol sb_ptr+1
    asl
    rol sb_ptr+1            ; *64 (high byte so far: *16's << 2)
    clc
    adc sb_t
    sta sb_ptr
    lda sb_ptr+1
    adc sb_t+1
    adc #>SB_RAM
    sta sb_ptr+1
    rts

sb_push:                    ; A = screen row: its 40 characters and colours
    tax                     ; -> the ring
    lda scr_row_lo,x
    sta src
    lda scr_row_hi,x
    sta src+1
    lda col_row_hi,x
    sta sb_col+1
    lda scr_row_lo,x
    sta sb_col
    lda sb_head
    jsr sb_addr
    ldy #39
@c: lda (src),y
    sta (sb_ptr),y
    dey
    bpl @c
    lda sb_ptr
    clc
    adc #40
    sta sb_ptr
    bcc @k
    inc sb_ptr+1
@k: ldy #39
@cc: lda (sb_col),y
    sta (sb_ptr),y
    dey
    bpl @cc
    inc sb_head
    lda sb_head
    cmp #SB_LINES
    bcc @h
    lda #0
    sta sb_head
@h: lda sb_count
    cmp #SB_LINES
    bcs @r
    inc sb_count
@r: rts

sb_wipe:                    ; the ring emptied and zeroed (the RAM under the
    lda #0                  ; KERNAL: writes reach it with the ROM in)
    sta sb_head
    sta sb_count
    tax
    ldy #>SB_RAM
    sty @p+2
@p: sta SB_RAM,x            ; 31 whole pages ...
    inx
    bne @p
    inc @p+2
    ldy @p+2
    cpy #>(SB_RAM + SB_LINES * 80)
    bne @p
@t: sta SB_RAM + SB_LINES * 80 - $40,x   ; ... and the last $40 ($FF00-$FF3F)
    inx
    cpx #$40
    bne @t
    rts

sb_view:                    ; C=+B: page through the ring; any other key
    lda mode                ; returns.  PETSCII only for now
    bne @p
    ldx #msg_sbansi-msgs
    jmp print_msg
@p: lda sb_count
    bne @go
    rts
@go: jsr io_quiet           ; the board waits (RTS) while we look
    jsr snap_save
    lda #$17
    sta $D018
    lda #<sb_rti            ; an NMI while the KERNAL is banked out lands
    sta $FFFA               ; here (the RAM under its vectors)
    lda #>sb_rti
    sta $FFFB
    lda #0
    sta sb_pos
@draw:
    jsr sb_page
@k: jsr GETIN
    beq @k
    cmp #$91                ; up: older
    beq @up
    cmp #$11
    beq @dn
    cmp #'-'
    beq @pgu
    cmp #'+'
    beq @pgd
    jsr snap_restore        ; anything else: back
    jmp io_live
@up: lda #1
    bne @older
@pgu: lda #24
@older: clc
    adc sb_pos
    sta sb_t
    lda sb_count            ; at most count-1 (the oldest line at the top
    sec                     ; at least)
    sbc #1
    cmp sb_t
    bcs @o2
    sta sb_t
@o2: lda sb_t
    sta sb_pos
    jmp @draw
@dn: lda #1
    bne @newer
@pgd: lda #24
@newer: sta sb_t
    lda sb_pos
    sec
    sbc sb_t
    bcs @n2
    lda #0
@n2: sta sb_pos
    jmp @draw

sb_page:                    ; rows 0-23: ring lines, newest - sb_pos at the
    lda #23                 ; bottom; row 24: the footer
    sta sb_row
@r: lda #23                 ; age of this row's line = sb_pos + (23 - row)
    sec
    sbc sb_row
    clc
    adc sb_pos
    cmp sb_count
    bcs @blank
    sta sb_t                ; ring index = head - 1 - age (mod SB_LINES)
    lda sb_head
    sec
    sbc #1
    sec
    sbc sb_t
    bcs @i
    adc #SB_LINES
@i: jsr sb_addr
    ldx sb_row
    lda scr_row_lo,x
    sta dst
    sta sb_col
    lda scr_row_hi,x
    sta dst+1
    lda col_row_hi,x
    sta sb_col+1
    sei                     ; KERNAL out, I/O in: read the RAM below it
    lda #$35
    sta $01
    ldy #39
@c: lda (sb_ptr),y
    sta (dst),y
    dey
    bpl @c
    lda sb_ptr
    clc
    adc #40
    sta sb_ptr
    bcc @k
    inc sb_ptr+1
@k: ldy #39
@cc: lda (sb_ptr),y
    sta (sb_col),y
    dey
    bpl @cc
    lda #$36
    sta $01
    cli
    jmp @nx
@blank:
    ldx sb_row
    lda scr_row_lo,x
    sta dst
    lda scr_row_hi,x
    sta dst+1
    ldy #39
    lda #$20
@b: sta (dst),y
    dey
    bpl @b
@nx: dec sb_row
    bpl @r
    ldy #39                 ; the footer, reversed
@f: lda sb_foot,y
    sta $0400+24*40,y
    lda #1
    sta $D800+24*40,y
    dey
    bpl @f
    rts

scr_row_lo:
    .repeat 25, I
    .byte <($0400 + I*40)
    .endrep
scr_row_hi:
    .repeat 25, I
    .byte >($0400 + I*40)
    .endrep
col_row_hi:
    .repeat 25, I
    .byte >($D800 + I*40)
    .endrep
sb_foot:                    ; screen codes, reversed (lower/upper case set)
    .repeat 40, I
    .byte $80 | .strat(" SCROLL-BACK   CRSR + - MOVE   KEY: BACK", I)
    .endrep
sb_rti:  rti
sb_head:   .byte 0
sb_count:  .byte 0
sb_pos:    .byte 0
sb_row:    .byte 0
sb_t:      .word 0
sb_sx:     .byte 0
sb_sy:     .byte 0

.segment "CODE"             ; (CODE2 is full: this fits below $4000)
; ---- scroll regions (CSI r), insert/delete line (CSI L/M), and the
; region-aware scrolls behind them and ESC M.  General row copies (slower
; than scroll_up's unrolled copy, used only when the region isn't the
; whole screen).
region_up:                  ; X = top, Y = bottom: rows top+1..bottom up
    stx rg_t                ; one, bottom cleared
    sty rg_b
    txa
@l: cmp rg_b
    bcs @clr
    sta rg_d
    tay                     ; destination d, source d+1
    iny
    tya
    tax
    ldy rg_d
    jsr copy_row
    lda rg_d
    clc
    adc #1
    jmp @l
@clr: ldx rg_b
    ldy rg_b
    jmp clear_rows

region_down:                ; X = top, Y = bottom: rows top..bottom-1 down
    stx rg_t                ; one, top cleared
    sty rg_b
    tya
@l: cmp rg_t
    beq @clr
    bcc @clr
    sta rg_d
    tax                     ; destination d, source d-1
    dex
    ldy rg_d
    jsr copy_row
    lda rg_d
    sec
    sbc #1
    jmp @l
@clr: ldx rg_t
    ldy rg_t
    jmp clear_rows

copy_row:                   ; X = source row, Y = destination: 320 bitmap
    stx rg_x                ; bytes and 40 colours
    sty rg_y
    lda bm_lo,x
    sta src
    lda bm_hi,x
    sta src+1
    lda bm_lo,y
    sta dst
    lda bm_hi,y
    sta dst+1
    ldy #0
@a: lda (src),y
    sta (dst),y
    iny
    bne @a
    inc src+1
    inc dst+1
    ldy #63
@b: lda (src),y
    sta (dst),y
    dey
    bpl @b
    ldx rg_x
    ldy rg_y
    lda scr_lo,x
    sta src
    lda scr_hi,x
    sta src+1
    lda scr_lo,y
    sta dst
    lda scr_hi,y
    sta dst+1
    ldy #39
@c: lda (src),y
    sta (dst),y
    dey
    bpl @c
    rts

in_region:                  ; C=1: the cursor row is inside the region; A =
    lda row                 ; rows from it to the region's bottom
    cmp sr_top
    bcc @no
    lda sr_bot
    cmp row
    bcc @no
    sec
    sbc row
    clc
    adc #1
    sec
    rts
@no: clc
    rts

ins_line:                   ; CSI n L: n blank lines at the cursor row,
    jsr in_region           ; the region below pushed down
    bcc @r
    sta rg_n
    jsr get_n1
    cmp rg_n
    bcs @n
    sta rg_n
@n: ldx row
    ldy sr_bot
    jsr region_down
    dec rg_n
    bne @n
    lda #0
    sta col
    sta wrap
@r: rts

del_line:                   ; CSI n M: n lines from the cursor row gone,
    jsr in_region           ; the region below pulled up
    bcc @r
    sta rg_n
    jsr get_n1
    cmp rg_n
    bcs @n
    sta rg_n
@n: ldx row
    ldy sr_bot
    jsr region_up
    dec rg_n
    bne @n
    lda #0
    sta col
    sta wrap
@r: rts

set_region:                 ; CSI top;bottom r (1-based; defaults: the
    lda par                 ; whole screen), then home
    beq @t
    sec
    sbc #1
@t: sta rg_t
    lda par+1
    beq @bd
    sec
    sbc #1
    cmp #ROWS
    bcc @b
@bd: lda #ROWS-1
@b: cmp rg_t
    beq @r                  ; (needs two rows at least)
    bcc @r
    sta sr_bot
    lda rg_t
    sta sr_top
    lda #0
    sta row
    sta col
    sta wrap
@r: rts

sr_top:    .byte 0             ; scroll region rows
sr_bot:    .byte ROWS-1
rg_t:      .byte 0
rg_b:      .byte 0
rg_d:      .byte 0
rg_n:      .byte 0
rg_x:      .byte 0
rg_y:      .byte 0

; ---- insert / delete / erase character (CSI n @ / P / X) on the cursor's
; row.  Two 80-column characters share each bitmap byte (high nibble even
; columns, low nibble odd), so a character moves as 8 nibbles.  Colours
; stay put (a colour cell covers two characters anyway).
cell_ptr:                   ; A = column -> src = its 8 bytes; c_odd
    tax
    and #1
    sta c_odd
    txa
    lsr                     ; (column / 2) * 8, 16 bits
    sta tmp
    lda #0
    sta tmp2
    asl tmp
    rol tmp2
    asl tmp
    rol tmp2
    asl tmp
    rol tmp2
    ldx row
    lda bm_lo,x
    clc
    adc tmp
    sta src
    lda bm_hi,x
    adc tmp2
    sta src+1
    rts

cell_get:                   ; A = column -> cg = its 8 nibbles (low)
    jsr cell_ptr
    ldy #7
@l: lda (src),y
    ldx c_odd
    bne @o
    lsr
    lsr
    lsr
    lsr
    bpl @s
@o: and #$0F
@s: sta cg,y
    dey
    bpl @l
    rts

cell_put:                   ; A = column <- cg
    jsr cell_ptr
    ldy #7
@l: lda (src),y
    ldx c_odd
    bne @o
    and #$0F
    sta tmp
    lda cg,y
    asl
    asl
    asl
    asl
    ora tmp
    bne @w
    beq @w
@o: and #$F0
    ora cg,y
@w: sta (src),y
    dey
    bpl @l
    rts

ch_n:                       ; n (default 1), at most the columns left
    jsr get_n1
    sta ic_n
    lda #80
    sec
    sbc col
    cmp ic_n
    bcs @r
    sta ic_n
@r: rts

ch_blank:                   ; blank ic_n cells from column A
    sta ic_c
    ldy #7
    lda #0
@z: sta cg,y
    dey
    bpl @z
@l: lda ic_c
    jsr cell_put
    inc ic_c
    dec ic_n
    bne @l
    rts

ins_char:                   ; CSI n @: n blanks at the cursor, the rest of
    jsr ch_n                ; the row shifts right (off the end)
    lda #79
    sta ic_c
@l: lda ic_c
    sec
    sbc ic_n
    bcc @b
    cmp col
    bcc @b
    jsr cell_get
    lda ic_c
    jsr cell_put
    dec ic_c
    jmp @l
@b: lda col
    jmp ch_blank

del_char:                   ; CSI n P: n characters gone at the cursor, the
    jsr ch_n                ; rest shifts left, blanks at the end
    lda col
    sta ic_c
@l: lda ic_c
    clc
    adc ic_n
    cmp #80
    bcs @b
    jsr cell_get
    lda ic_c
    jsr cell_put
    inc ic_c
    jmp @l
@b: lda ic_c
    jmp ch_blank

erase_char:                 ; CSI n X: n blanks from the cursor, nothing moves
    jsr ch_n
    lda col
    jmp ch_blank

c_odd:     .byte 0
ic_n:      .byte 0
ic_c:      .byte 0
cg:        .res 8
.segment "CODE2"
.include "screens.inc"

; ---- variables ---------------------------------------------------------
row:       .byte 0
col:       .byte 0
wrap:      .byte 0
crow:      .byte 0
ccol:      .byte 0
cur_vis:   .byte 0
sv_row:    .byte 0
sv_col:    .byte 0
fg:        .byte 7
bg:        .byte 0
bold:      .byte 0
rev:       .byte 0
cur_color: .byte $F0
colour_on: .byte 1
tn_state:  .byte 0
tn_cmd:    .byte 0
tn_opt:    .byte 0
an_state:  .byte 0
np:        .byte 0
priv:      .byte 0
par:       .res 8
cc_from:   .byte 0
cc_to:     .byte 0
cr_from:   .byte 0
rx_head:   .byte 0
rx_tail:   .byte 0
rts_off:   .byte 0
mode:      .byte 0
crflag:    .byte 0
bsflag:    .byte 0
driver:    .byte 0              ; 0 = ACIA, 1 = user port
jingle:    .byte 0
online:    .byte 0
lost:      .byte 0
paused:    .byte 0             ; C=+S
caselock:  .byte 0             ; C=+L
hs_d018:   .byte 0             ; C=+H in PETSCII: the set to go back to
hs_d020:   .byte 0
hs_ed:     .res $F4-$D1+1      ; the screen editor's zero page, kept
fe_bar:    .byte 0             ; field_edit: down returns 2
gw_i:      .byte 0             ; GOO watch: letters matched, GOOs in a row,
gw_n:      .byte 0             ; nudge shown
gw_shown:  .byte 0
last_num:  .res 6, 0           ; a number typed on its own line (0-ended)
fin_n:     .byte 0             ; finishing screen: lines kept, first shown,
fin_top:   .byte 0             ; the bar ($FF none), scratch
fin_bar:   .byte 0
fin_t:     .byte 0
fin_t2:    .byte 0
dl_count:  .byte 0             ; DOWNLOADn names this session
rc_pos:    .byte 0
last_len:  .byte 0             ; length of the last line typed (line_buf)
cd_depth:  .res 23, 0          ; drives 8-30: folders below ZenCom's ($FF lost)
pborder:   .byte 0
lost_at:   .byte 0
nc_idx:    .byte 0
tn_bin_in: .byte 0              ; telnet BINARY agreed (board -> us)
tn_bin_out: .byte 0             ; (us -> board)
tn_seen:   .byte 0             ; the board has negotiated telnet (this call)
home_dev:  .byte 8
cur_dev:   .byte 8
ss_set:    .byte 0
xfr_ok:    .byte 0
acia_on:   .byte 0
ovl_in:    .byte 0         ; 1: the menu overlay is at $A000
cp_mac:    .byte 0         ; cfg_parse: this line is a macro
fe_case:   .byte 0         ; field_edit keeps shifted letters, takes ^
fe_mask:   .byte 0         ; field_edit shows * (a password)
mac_wait:  .byte 0         ; C=+M pressed: the next key picks a macro
mac_p:     .byte 0
mborder:   .byte 0
mp_n:      .byte 0         ; Multi-Punter: files saved
up9_on:    .byte 0         ; the UP9600 driver is running
u9_out:    .byte 0         ; SDR loads still to go out
u9_x:      .byte 0
u9_t:      .byte 0
mp_i:      .byte 0
mp_first:  .byte 0
mp_part:   .byte 0
crc32:     .res 4
pwd_key:   .res 8          ; a board's key (CRC-32 of its address, hex)
pwd_old:   .res 8          ; its key before an edit (the line to replace)
pwd_len:   .word 0
pw_n:      .word 0
st_raw:    .byte 0
pwd_had:   .byte 0
ovl_n:     .byte 0
io_depth:  .byte 0
cp_state:  .byte 0
cp_dev:    .byte 0
cp_path:   .byte 0
cp_n:      .byte 0
cw_i:      .byte 0
car_seen:  .byte 0
na_idx:    .byte 0
swapcase:  .byte 0
quick:     .byte 0
flipcase:  .byte 0
line_len:  .byte 0
auto_state: .byte 0
auto_at:   .byte 0
auto_ok:   .byte 0
ok_at:     .byte 0
msg_x:     .byte 0
n_ent:     .byte 0
list_src:  .byte 0
eof_next:  .byte 0
fld:       .byte 0
nlen:      .byte 0
hlen:      .byte 0
skip:      .byte 0
lpos:      .byte 0
dir_i:     .byte 0
list_ro:   .byte 0
save_err:  .byte 0
tlen:      .byte 0
dir_sel:   .byte 0
dir_pos:   .byte 0
dir_e:     .byte 0
w_rev:     .byte 0
w_col:     .byte 0
w_x:       .byte 0
w_y:       .byte 0
w_max:     .byte 0
w_off:     .byte 0
w_row:     .byte 0
ed_field:  .byte 0
ed_new:    .byte 0
ed_max:    .byte 0
ed_off:    .byte 0
ed_row:    .byte 0
fe_len:    .byte 0
fe_cur:    .byte 0
fe_ch:     .byte 0
fe_p:      .byte 0
dial_len:  .byte 0
up_name:   .byte 0, 0
; buffers live in free RAM above the program ($C000-$CFFF)

.include "xfr.s"            ; switches to the XFR segment: keep it last
