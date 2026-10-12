; =====================================================================
; ZENCOM.XFR - file transfers, loaded at $A000 into the RAM under the
; BASIC ROM.  Built with zencom.s (shares its symbols) into its own file
; by the linker (see zencom.cfg).  Keys: C=+D download, C=+U upload.
;
; XMODEM: receive CRC or checksum, 128 or 1K (STX) blocks; send 128-byte
; blocks, CRC or checksum as the receiver asks.  The engine reads and
; writes through xm_in / xm_out so the emulator tests can drive it.
; =====================================================================
.segment "XFRADDR"
    .word $9000             ; the menu overlay first (see ovl_menu)
.segment "XFR"
xfr_sig:    .byte "ZX", XFR_VER
xfr_dl_entry: jmp xfr_download      ; fixed entry points ($A003, $A006): the
xfr_ul_entry: jmp xfr_upload        ; main program only ever calls these

xptr     = $3C              ; zero page: block pointers / vectors
xptr2    = $3E
xm_out   = $40              ; (receive) write xo_len bytes at XB_PEND; C=1 error
xm_in    = $42              ; (send) fill XB_RX, A = count (0 = end); C=1 error

XB_RX    = $B800            ; a block as received / to send (1024)
XB_PEND  = $BC00            ; the block waiting to be written (1024)
XB_DIR   = $C000            ; directory listing: 48 x 20 bytes (free RAM)
XB_NAME  = $C3C0            ; file name being edited (16 + 0)
XB_PATH  = $C3E0            ; the folder being browsed (39 + 0)
SES_DPATH = $C410           ; this session's downloads folder (39 + 0)
SES_UPATH = $C440           ; this session's uploads folder (39 + 0)
XB_OPATH = $C470            ; the folder before a move (39 + 0)
DIR_MAX  = 48
DIR_ESZ  = 20               ; +0 name (16+0), +17 type letter, +18 blocks

SOH = $01
C_STX = $02
EOT = $04
ACK = $06
NAK = $15
CAN = $18
SUB = $1A
SEC1  = 60                  ; jiffies
SEC3  = 180
SEC10 = 600
SEC60 = 3600

ERR_TIMEOUT = 1
ERR_RETRY   = 2
ERR_SEQ     = 3
ERR_REMOTE  = 4
ERR_USER    = 5
ERR_DISK    = 6

; ---- timers: deadline = now + A/X jiffies (16-bit), xt_over C=1 when passed
xt_set:
    sta x_t
    stx x_t+1
    sei
    lda TIME_LO
    clc
    adc x_t
    sta t_dl
    lda TIME_MID
    adc x_t+1
    sta t_dh
    cli
    rts
xt_over:
    sei
    lda TIME_LO
    sec
    sbc t_dl
    lda TIME_MID
    sbc t_dh
    cli
    bmi @no
    sec
    rts
@no: clc
    rts

; ---- one data byte from the board, telnet undone.  C=0 A = byte; C=1
; timeout (or <- pressed: x_cancel = 1)
xget:
@l: jsr ser_get
    bcc @got
    jsr GETIN
    cmp #$5F
    beq @cancel
    jsr xt_over
    bcc @l
    rts
@cancel:
    lda #1
    sta x_cancel
    sec
    rts
@got:
    ldx tn_seen             ; raw TCP boards (no telnet: e.g. C64 boards
    bne @tn                 ; behind a plain bridge) send $FF and CR as
    clc                     ; they are
    rts
@tn: ldx tn_state            ; inside a telnet command: the terminal's job
    beq @plain
    jsr term_putc
    jmp @l
@plain:
    cmp #$FF
    bne @cr
@ff: jsr ser_get            ; IAC: the next byte decides
    bcc @f2
    jsr xt_over
    bcc @ff
    rts
@f2: cmp #$FF
    beq @data               ; IAC IAC = a data $FF
    pha
    lda #$FF
    jsr term_putc
    pla
    jsr term_putc
    jmp @l
@cr: ldx x_crnul            ; non-binary telnet sends CR as CR NUL
    beq @c2
    ldx #0
    stx x_crnul
    cmp #0
    beq @l
@c2: cmp #$0D
    bne @data
    ldx tn_bin_in
    bne @data
    ldx #1
    stx x_crnul
@data:
    clc
    rts

; ---- one byte to the board: $FF doubled; CR NUL unless binary
xput:
    ldx tn_seen             ; raw boards: no escaping
    bne @tn
    jmp ser_put
@tn:
    pha
    jsr ser_put
    pla
    cmp #$FF
    bne @cr
    lda #$FF
    jmp ser_put
@cr: cmp #$0D
    bne @r
    ldx tn_bin_out
    bne @r
    lda #0
    jmp ser_put
@r: rts

x_drain:                    ; discard what piled up while the modem was
    lda #12                 ; held (e.g. a receiver's repeated GOOs):
    sta x_dl2               ; 1/4 s windows until a quiet one, 3 s at most
@w: lda #15
    ldx #0
    jsr xt_set
    lda #0
    sta x_dh2
@l: jsr ser_get
    bcs @n
    inc x_dh2
@n: jsr xt_over
    bcc @l
    lda x_dh2
    beq @r
    dec x_dl2
    bne @w
@r: rts

xpurge:                     ; discard input until a second of quiet
    lda #<SEC1
    ldx #>SEC1
    jsr xt_set
    jsr xget
    bcc xpurge
    rts

; ---- CRC-16/XMODEM (poly $1021) and 8-bit sum over XB_RX, xm_len bytes
crc_add:
    eor crc_hi
    sta crc_hi
    ldx #8
@l: asl crc_lo
    rol crc_hi
    bcc @n
    lda crc_hi
    eor #$10
    sta crc_hi
    lda crc_lo
    eor #$21
    sta crc_lo
@n: dex
    bne @l
    rts

xm_calc:
    lda #0
    sta crc_hi
    sta crc_lo
    sta x_sum
    lda #<XB_RX
    sta xptr
    lda #>XB_RX
    sta xptr+1
    lda xm_len
    sta x_n
    lda xm_len+1
    sta x_n+1
@l: ldy #0
    lda (xptr),y
    pha
    clc
    adc x_sum
    sta x_sum
    pla
    jsr crc_add
    inc xptr
    bne @d
    inc xptr+1
@d: lda x_n
    bne @dl
    dec x_n+1
@dl: dec x_n
    lda x_n
    ora x_n+1
    bne @l
    rts

xm_reset:                   ; counters for a new transfer
    lda #0
    sta xm_nblk
    sta xm_nblk+1
    sta xm_bytes
    sta xm_bytes+1
    sta xm_bytes+2
    sta xm_retries
    sta xm_try
    sta x_cancel
    sta x_crnul
    sta xm_pend
    lda #1
    sta xm_blk
    sta xm_crc
    rts

xm_count:                   ; one more block of A bytes (A = 0: 256)
    inc xm_nblk
    bne @b
    inc xm_nblk+1
@b: clc
    adc xm_bytes
    sta xm_bytes
    bcc @r
    inc xm_bytes+1
    bne @r
    inc xm_bytes+2
@r: rts

xm_fail:                    ; A = reason -> xm_err, C=1
    sta xm_err
    sec
    rts

; ---- receive: C=0 done; C=1 failed (xm_err)
xm_recv:
    jsr xm_reset
@start:
    lda #'C'                ; ask for CRC; after 3 tries, for checksums
    ldx xm_crc
    bne @s
    lda #NAK
@s: jsr xput
    lda #<SEC3
    ldx #>SEC3
    jsr xt_set
    jsr xget
    bcc @hdr
    lda x_cancel
    beq @s1
    jmp @ucancel
@s1: inc xm_try
    lda xm_try
    cmp #4
    bne @s2
    lda #0
    sta xm_crc
    lda xm_try
@s2: cmp #10
    bcc @start
    lda #ERR_TIMEOUT
    jmp xm_fail
@pkt:
    lda #<SEC10
    ldx #>SEC10
    jsr xt_set
    jsr xget
    bcc @hdr
    lda x_cancel
    beq @pn
    jmp @ucancel
@pn: jmp @nak
@hdr:
    cmp #SOH
    bne @h1
    lda #128
    sta xm_len
    lda #0
    sta xm_len+1
    jmp @body
@h1: cmp #C_STX
    bne @h2
    lda #0
    sta xm_len
    lda #4
    sta xm_len+1
    jmp @body
@h2: cmp #EOT
    bne @h3
    jmp @eot
@h3: cmp #CAN
    bne @pkt                ; noise between packets: ignore
    lda #<SEC1
    ldx #>SEC1
    jsr xt_set
    jsr xget
    bcs @pkt
    cmp #CAN
    bne @pkt
    lda #ERR_REMOTE
    jmp xm_fail
@bj: jmp @bad
@body:
    jsr @get1
    bcs @bj
    sta x_b1
    jsr @get1
    bcs @bj
    sta x_b2
    lda #<XB_RX
    sta xptr
    lda #>XB_RX
    sta xptr+1
    lda xm_len
    sta x_n
    lda xm_len+1
    sta x_n+1
@dl: jsr @get1
    bcs @bad
    ldy #0
    sta (xptr),y
    inc xptr
    bne @dc
    inc xptr+1
@dc: lda x_n
    bne @dd
    dec x_n+1
@dd: dec x_n
    lda x_n
    ora x_n+1
    bne @dl
    jsr @get1               ; CRC high (or the sum)
    bcs @bad
    sta x_c1
    lda xm_crc
    beq @chk
    jsr @get1
    bcs @bad
    sta x_c2
@chk:
    lda x_b1                ; block number and its complement
    eor #$FF
    cmp x_b2
    bne @bad
    jsr xm_calc
    lda xm_crc
    beq @sum
    lda crc_hi
    cmp x_c1
    bne @bad
    lda crc_lo
    cmp x_c2
    bne @bad
    jmp @good
@sum:
    lda x_sum
    cmp x_c1
    bne @bad
@good:
    lda x_b1
    cmp xm_blk
    beq @new
    clc
    adc #1
    cmp xm_blk
    bne @seq
    lda #ACK                ; the last block again: our ACK was lost
    jsr xput
    jmp @pkt
@bad:
    lda x_cancel
    beq @bn
    jmp @ucancel
@bn: jmp @nak
@seq:
    jsr xm_can
    lda #ERR_SEQ
    jmp xm_fail
@new:
    jsr xm_flush            ; write the previous block
    bcc @ok
    jsr xm_can
    lda #ERR_DISK
    jmp xm_fail
@ok: jsr xm_keep            ; and hold this one
    inc xm_blk
    lda #0
    sta xm_try
    lda xm_len
    ldx xm_len+1
    beq @c1
    lda #0                  ; 1K: count it as 4 x 256
    jsr xm_count
    lda #0
    jsr xm_count
    lda #0
    jsr xm_count
    dec xm_nblk             ; (one block, not four)
    lda #0
@c1: jsr xm_count
    lda #ACK
    jsr xput
    jsr xfr_progress
    jmp @pkt
@nak:
    jsr xpurge
    lda x_cancel
    bne @ucancel
    inc xm_retries
    inc xm_try
    lda xm_try
    cmp #10
    bcc @n1
    jsr xm_can
    lda #ERR_RETRY
    jmp xm_fail
@n1: lda xm_nblk            ; nothing yet: still asking to start
    ora xm_nblk+1
    bne @n2
    jmp @start
@n2: lda #NAK
    jsr xput
    jsr xfr_progress
    jmp @pkt
@eot:
    jsr dl_guess            ; (one block only: not decided yet)
    lda x_strip             ; SEQ: drop the ^Z padding of the last block
    beq @e1
@st: lda x_plen
    ora x_plen+1
    beq @e1
    lda x_plen              ; last byte = XB_PEND + len - 1
    sec
    sbc #1
    sta xptr
    lda x_plen+1
    sbc #0
    clc
    adc #>XB_PEND
    sta xptr+1
    ldy #0
    lda (xptr),y
    cmp #SUB
    bne @e1
    lda x_plen
    bne @sd
    dec x_plen+1
@sd: dec x_plen
    jmp @st
@e1: jsr xm_flush
    bcc @e2
    lda #ERR_DISK
    jmp xm_fail
@e2: lda #ACK
    jsr xput
    clc
    rts
@ucancel:
    jsr xm_can
    lda #ERR_USER
    jmp xm_fail
@get1:                      ; one byte, a second to arrive
    lda #<SEC1
    ldx #>SEC1
    jsr xt_set
    jmp xget

xm_can:                     ; tell the other side to stop
    lda #CAN
    jsr xput
    lda #CAN
    jsr xput
    lda #CAN
    jmp xput

xm_keep:                    ; XB_RX -> XB_PEND (xm_len bytes)
    lda xm_len
    sta x_plen
    lda xm_len+1
    sta x_plen+1
    lda #1
    sta xm_pend
    ldx #4                  ; (copy 1 KB: cheaper than counting)
    ldy #0
@l: lda XB_RX,y
    sta XB_PEND,y
    lda XB_RX+$100,y
    sta XB_PEND+$100,y
    lda XB_RX+$200,y
    sta XB_PEND+$200,y
    lda XB_RX+$300,y
    sta XB_PEND+$300,y
    iny
    bne @l
    rts

xm_flush:                   ; write the held block, if any; C=1 error
    lda xm_pend
    bne @w
    clc
    rts
@w: lda #0
    sta xm_pend
    lda x_plen
    sta xo_len
    lda x_plen+1
    sta xo_len+1
    jmp (xm_out)

; ---- send: C=0 done; C=1 failed (xm_err)
xm_send:
    jsr xm_reset
    lda #128
    sta xm_len
    lda #0
    sta xm_len+1
    lda #<SEC60
    ldx #>SEC60
    jsr xt_set
@w: jsr xget                ; wait for the receiver to ask
    bcc @w1
    lda x_cancel
    beq @wto
    jmp @ucancel
@wto: lda #ERR_TIMEOUT
    jmp xm_fail
@w1: cmp #'C'
    beq @hs
    cmp #NAK
    beq @hs
    cmp #CAN
    bne @w
    jmp @can
@hs: sta xm_hs              ; the latest request wins: while a slow drive
    lda #30                 ; (1541) opened the file, the receiver's C's
    ldx #0                  ; and NAKs piled up, and answering each in
    jsr xt_set              ; turn put us out of step
@dr: jsr xget
    bcs @dq
    cmp #'C'
    beq @hs
    cmp #NAK
    beq @hs
    cmp #CAN
    bne @dr
    jmp @can
@dq: lda x_cancel
    beq @dk
    jmp @ucancel
@dk: lda xm_hs
    cmp #NAK
    bne @gocrc
@gosum:
    lda #0
    sta xm_crc
@gocrc:
    lda xm_crc              ; K (1K): 1024-byte blocks, CRC only
    beq @next
    lda x_proto
    cmp #3
    bne @next
    lda #4
    sta xm_len+1
    lda #0
    sta xm_len
@next:
    lda xm_len+1
    beq @f128
    jsr xm_fill1k           ; C=1 error; Z=1 nothing left
    bcs @fe
    bne @pd
    jmp @eot
@fe: jsr xm_can
    lda #ERR_DISK
    jmp xm_fail
@f128:
    jsr @fill
    bcc @nf
    jsr xm_can
    lda #ERR_DISK
    jmp xm_fail
@nf: cmp #0
    bne @data
    jmp @eot
@data:
    sta x_cnt
    tay                     ; pad with ^Z
    lda #SUB
@pad: cpy #128
    bcs @pd
    sta XB_RX,y
    iny
    bne @pad
@pd: lda #0
    sta xm_try
@send:
    jsr xm_calc
    lda #SOH
    ldx xm_len+1
    beq @h
    lda #C_STX              ; (1K)
@h: jsr xput
    lda xm_blk
    jsr xput
    lda xm_blk
    eor #$FF
    jsr xput
    lda #<XB_RX             ; xm_len bytes (128 or 1024)
    sta xptr
    lda #>XB_RX
    sta xptr+1
    lda xm_len
    sta x_n
    lda xm_len+1
    sta x_n+1
@sl: ldy #0
    lda (xptr),y
    jsr xput
    inc xptr
    bne @s2
    inc xptr+1
@s2: lda x_n
    bne @s3
    dec x_n+1
@s3: dec x_n
    lda x_n
    ora x_n+1
    bne @sl
    lda xm_crc
    beq @ssum
    lda crc_hi
    jsr xput
    lda crc_lo
    jsr xput
    jmp @ans0
@ssum:
    lda x_sum
    jsr xput
@ans0:
    lda #<SEC10
    ldx #>SEC10
    jsr xt_set
@ans:
    jsr xget
    bcs @to
    cmp #ACK
    beq @acked
    cmp #NAK
    bne @nn
    lda xm_len+1            ; (1K: CRC or nothing)
    bne @retry
    lda xm_blk              ; a NAK to the first block: the receiver may
    cmp #1                  ; have given up on CRC while we were slow (a
    bne @retry              ; 1541 opening the file): checksum from now
    lda #0                  ; on (never back: a late NAK flipped it back
    sta xm_crc              ; to CRC once, out of step with the receiver)
    jmp @retry
@nn: cmp #'C'
    beq @retry
    cmp #CAN
    bne @ans
    jmp @can
@acked:
    inc xm_blk
    lda xm_len+1
    beq @a128
    jsr xm_count1k
    jmp @a2
@a128:
    lda x_cnt
    jsr xm_count
@a2:
    jsr xfr_progress
    jmp @next
@to: lda x_cancel
    beq @retry
    jmp @ucancel
@retry:
    inc xm_retries
    inc xm_try
    lda xm_try
    cmp #10
    bcc @r1
    jsr xm_can
    lda #ERR_RETRY
    jmp xm_fail
@r1: jsr xfr_progress
    jmp @send
@eot:
    lda #0
    sta xm_try
@e1: lda #EOT
    jsr xput
    lda #<SEC10
    ldx #>SEC10
    jsr xt_set
@e2: jsr xget
    bcs @e3
    cmp #ACK
    beq @done
    cmp #NAK
    beq @e3
    jmp @e2
@e3: lda x_cancel
    bne @ucancel
    inc xm_try
    lda xm_try
    cmp #10
    bcc @e1
    lda #ERR_RETRY
    jmp xm_fail
@done:
    clc
    rts
@can:
    lda #<SEC1
    ldx #>SEC1
    jsr xt_set
    jsr xget
    bcs @cn
    cmp #CAN
    bne @cn
    lda #ERR_REMOTE
    jmp xm_fail
@cn: jmp @w
@ucancel:
    jsr xm_can
    lda #ERR_USER
    jmp xm_fail
@fill:
    jmp (xm_in)

.segment "CODE"             ; (resident: the transfer overlay is full)
xm_fill1k:                  ; up to 8 reads of 128 (xm_in) -> XB_RX as one
    lda #0                  ; 1K block, ^Z after the data.  C=1 error;
    sta x_n                 ; Z=1 (A=0) nothing was left
    sta x_n+1
@chunk:
    lda x_eof               ; (the reader says so itself, but no 8th try
    bne @end                ; is needed once it has)
    jsr xm_fill128
    bcc @got
    rts                     ; (C=1: a read error)
@got:
    cmp #0                  ; (the reader's flags are its own)
    beq @end
    tay                     ; XB_RX[0..A) -> XB_PEND + x_n
    sta x_c1
    lda #<XB_PEND
    clc
    adc x_n
    sta xptr2
    lda #>XB_PEND
    adc x_n+1
    sta xptr2+1
    dey
@cp: lda XB_RX,y
    sta (xptr2),y
    dey
    cpy #$FF
    bne @cp
    lda x_n
    clc
    adc x_c1
    sta x_n
    bcc @c
    inc x_n+1
@c: lda x_c1
    cmp #128                ; a short read: the file ended
    bne @end
    lda x_n+1
    cmp #4
    bcc @chunk
@end:
    lda x_n                 ; the count, for the progress
    sta x_t1k
    lda x_n+1
    sta x_t1k+1
    ora x_n
    bne @have
    clc                     ; nothing left: Z=1, C=0
    rts
@have:
    ldx #0                  ; XB_PEND -> XB_RX, ^Z past the data
@pg: lda XB_PEND,x
    sta XB_RX,x
    lda XB_PEND+$100,x
    sta XB_RX+$100,x
    lda XB_PEND+$200,x
    sta XB_RX+$200,x
    lda XB_PEND+$300,x
    sta XB_RX+$300,x
    inx
    bne @pg
    lda #<XB_RX
    clc
    adc x_n
    sta xptr2
    lda #>XB_RX
    adc x_n+1
    sta xptr2+1
    ldy #0
@z: lda xptr2+1
    cmp #>(XB_RX+1024)
    bcs @ok
    lda #SUB
    sta (xptr2),y
    inc xptr2
    bne @z
    inc xptr2+1
    bne @z
@ok: lda #1                 ; Z=0
    clc
@r: rts
xm_fill128:
    jmp (xm_in)

xm_count1k:                 ; the 1K block's data, counted as the receiver
    lda x_t1k+1             ; counts 1K (in 256s)
    beq @last
    lda #0
    jsr xm_count
    dec x_t1k+1
    jmp xm_count1k
@last:
    lda x_t1k
    beq @r
    jmp xm_count
@r: rts
.segment "XFR"

; =====================================================================
; Punter (C1), the C64 boards' own protocol.  Blocks: a 7-byte header -
; additive and cyclic 16-bit checksums (low byte first) over byte 4 on,
; the size of the NEXT block, a 16-bit block number ($FFxx = the last) -
; then up to 248 data bytes.  3-letter tokens (GOO BAD ACK S/B SYN) are
; resent until the expected answer comes.  File type and data travel in
; two phases.  Receive follows the long-standing receivers (cf. CGTerm).
; =====================================================================
PT_MAX = 248                ; data bytes a block

pt_token:                   ; send the token at A/Y (3 bytes)
    sta xptr2
    sty xptr2+1
    ldy #0
@l: sty x_y
    lda (xptr2),y
    jsr xput
    ldy x_y
    iny
    cpy #3
    bne @l
    rts

pt_get3:                    ; 3 bytes into pt_tok, a second each; C=1 timeout
    ldx #0
@l: stx pt_i
    lda #<SEC1
    ldx #>SEC1
    jsr xt_set
    jsr xget
    bcs @r
    ldx pt_i
    sta pt_tok,x
    inx
    cpx #3
    bne @l
    clc
@r: rts

pt_is:                      ; Z=1 if pt_tok equals the token at A/Y
    sta xptr2
    sty xptr2+1
    ldy #2
@l: lda (xptr2),y
    cmp pt_tok,y
    bne @r
    dey
    bpl @l
    lda #0                  ; (Z=1)
@r: rts

pt_hand:                    ; send pt_snd until pt_want comes back; C=1 fail
    lda #10
    sta pt_err
@again:
    lda pt_patience         ; seconds of resending before giving up
    sta pt_tmo
@send:
    lda pt_snd
    ldy pt_snd+1
    jsr pt_token
@rd: jsr pt_get3
    bcc @got
    lda x_cancel
    bne @fail
    dec pt_tmo
    bne @send
@fail:
    sec
    rts
@got:
    lda pt_want
    ldy pt_want+1
    jsr pt_is
    bne @nw
    clc
    rts
@nw: dec pt_err             ; anything else - including our own token,
                            ; which C1 senders use to open - say it again
    bne @send
    beq @fail

pt_hs:                      ; handshake: X = send token, Y = wait token
    lda pt_tab_lo,x         ; (indexes into pt_tab)
    sta pt_snd
    lda pt_tab_hi,x
    sta pt_snd+1
    lda pt_tab_lo,y
    sta pt_want
    lda pt_tab_hi,y
    sta pt_want+1
    jmp pt_hand

T_GOO = 0
T_BAD = 1
T_ACK = 2
T_SB  = 3
T_SYN = 4
pt_tab_lo: .byte <tk_goo, <tk_bad, <tk_ack, <tk_sb, <tk_syn
pt_tab_hi: .byte >tk_goo, >tk_bad, >tk_ack, >tk_sb, >tk_syn
tk_goo: .byte "GOO"
tk_bad: .byte "BAD"
tk_ack: .byte "ACK"
tk_sb:  .byte "S/B"
tk_syn: .byte "SYN"

pt_sum:                     ; checksums of XB_RX[4..pt_len) -> pt_add, pt_cyc
    lda #0
    sta pt_add
    sta pt_add+1
    sta pt_cyc
    sta pt_cyc+1
    ldy #4
@l: cpy pt_len
    bcs @r
    lda XB_RX,y
    pha
    clc
    adc pt_add
    sta pt_add
    bcc @n
    inc pt_add+1
@n: pla
    eor pt_cyc
    sta pt_cyc
    asl pt_cyc              ; rotate the 16 bits left one
    rol pt_cyc+1
    bcc @nc
    inc pt_cyc              ; (the bit out of the top comes in at the bottom)
@nc: iny
    bne @l
@r: rts

pt_rblock:                  ; receive a pt_len-byte block into XB_RX; C=1 fail
    lda #10
    sta pt_err
@restart:
    lda #<tk_sb
    ldy #>tk_sb
    jsr pt_token
    ldx #0
@b: stx pt_i
    lda #<SEC3
    ldx #>SEC3
    jsr xt_set
    jsr xget
    bcc @got
    lda x_cancel
    bne @f
    lda pt_i                ; "S/B" back instead of a block: they gave up
    cmp #3
    bne @bad
    lda #<tk_sb
    ldy #>tk_sb
    jsr pt_is3
    bne @bad
    lda #ERR_REMOTE
    sta xm_err
@f: sec
    rts
@got:
    ldx pt_i
    sta XB_RX,x
    inx
    cpx #4                  ; "ACK" where a block should start: resync
    bne @n4
    lda #<tk_ack
    ldy #>tk_ack
    jsr pt_is3
    bne @n4
    lda XB_RX+3
    cmp #'A'
    beq @restart
    sta XB_RX               ; (a late ACK: keep the byte after it)
    ldx #1
@n4: cpx pt_len
    bcc @b
    jsr pt_sum
    lda pt_add
    cmp XB_RX
    bne @bad
    lda pt_add+1
    cmp XB_RX+1
    bne @bad
    lda pt_cyc
    cmp XB_RX+2
    bne @bad
    lda pt_cyc+1
    cmp XB_RX+3
    bne @bad
    ldx #T_GOO              ; good: GOO until ACK
    ldy #T_ACK
    jmp pt_hs
@bad:
    inc xm_retries
    jsr xfr_progress
    dec pt_err
    beq @f
    ldx #T_BAD
    ldy #T_ACK
    jsr pt_hs
    bcs @f
    jmp @restart

pt_is3:                     ; compare XB_RX[0..2] with the token at A/Y
    sta xptr2
    sty xptr2+1
    ldy #2
@l: lda (xptr2),y
    cmp XB_RX,y
    bne @r
    dey
    bpl @l
    lda #0
@r: rts

; ---- receive: C=0 done; C=1 failed (xm_err)
pt_recv:
    jsr x_drain
    jsr xm_reset
    lda #ERR_TIMEOUT
    sta xm_err
    lda #60                 ; the board may take a while to start sending
    sta pt_patience
    ldx #T_GOO              ; phase A: the file type
    ldy #T_ACK
    jsr pt_hs
    lda #10
    sta pt_patience
    bcc @k1
    jmp @fail
@k1:
    lda #8
    sta pt_len
    jsr pt_rblock
    bcc @k2
    jmp @fail
@k2: lda XB_RX+7             ; the file type: 0 PRG, 1 SEQ
    sta pt_ftype
    ldx #T_GOO
    ldy #T_ACK
    jsr pt_hs
    bcc @k3
    jmp @fail
@k3:
    ldx #T_SB
    ldy #T_SYN
    jsr pt_hs
    bcc @k4
    jmp @fail
@k4:
    ldx #T_SYN
    ldy #T_SB
    jsr pt_hs
    bcc @k5
    jmp @fail
@k5:
    ldx #T_GOO              ; phase B: the data
    ldy #T_ACK
    jsr pt_hs
    bcc @k6
    jmp @fail
@k6:
    lda #7                  ; the header block (no data)
    sta pt_len
    jsr pt_rblock
    bcc @k7
    jmp @fail
@k7:
@blk:
    lda XB_RX+6             ; block number $FFxx: that was the last
    cmp #$FF
    beq @end
    lda XB_RX+4             ; the next block's size
    cmp #7
    bcc @end
    sta pt_len
    jsr pt_rblock
    bcc @k8
    jmp @fail
@k8:
    lda pt_len              ; its data -> the file
    sec
    sbc #7
    beq @blk
    sta xo_len
    lda #0
    sta xo_len+1
    ldy #0
@cp: lda XB_RX+7,y
    sta XB_PEND,y
    iny
    cpy xo_len
    bne @cp
    lda xo_len
    jsr xm_count
    jsr xfr_progress
    jsr @out
    bcc @blk
    lda #ERR_DISK
    sta xm_err
    sec
    rts
@end:
    ldx #T_SB               ; the end: S/B until SYN, SYN until S/B
    ldy #T_SYN
    jsr pt_hs
    bcs @ok
    ldx #T_SYN
    ldy #T_SB
    jsr pt_hs
@ok: clc
    rts
@fail:
    lda x_cancel
    beq @f2
    lda #ERR_USER
    sta xm_err
@f2: sec
    rts
@out:
    jmp (xm_out)

; ---- send: answers the receiver's tokens.  Reads one chunk ahead, as a
; block carries the size of the next.
pt_send:
    jsr x_drain
    jsr xm_reset
    lda #0
    sta pt_phase
    sta pt_done
    sta pt_unacked
    sta pt_blk
    sta pt_blk+1
    sta x_eof
    lda #PT_MAX
    sta x_want
    lda #8                  ; phase A block: the file type
    sta pt_blen
    lda #$FF
    sta XB_PEND+5
    sta XB_PEND+6
    lda #0
    sta XB_PEND+4
    lda x_type              ; 0 = PRG, 1 = SEQ
    cmp #'S'
    beq @t1
    lda #0
    .byte $2C
@t1: lda #1
    sta XB_PEND+7
    jsr pt_seal
@loop:
    lda #<SEC10
    ldx #>SEC10
    jsr xt_set
    jsr pt_get3w            ; a token (sliding: noise is skipped)
    bcc @tok
    lda x_cancel
    bne @cancel
    inc xm_try
    lda xm_try
    cmp #10
    bcc @loop
    lda #ERR_TIMEOUT
    jmp xm_fail
@cancel:
    lda #ERR_USER
    jmp xm_fail
@tok:
    lda #0
    sta xm_try
    lda #<tk_goo
    ldy #>tk_goo
    jsr pt_is
    bne @t2
    lda pt_unacked          ; GOO: the block got through
    beq @ackit
    lda #0
    sta pt_unacked
    jsr pt_next
    bcc @ackit
    jsr xm_can
    lda #ERR_DISK
    jmp xm_fail
@ackit:
    lda #<tk_ack
    ldy #>tk_ack
    jsr pt_token
    jmp @loop
@t2: lda #<tk_bad
    ldy #>tk_bad
    jsr pt_is
    bne @t3
    lda #0                  ; BAD: send it again when asked
    sta pt_unacked
    inc xm_retries
    jsr xfr_progress
    jmp @ackit
@t3: lda #<tk_sb
    ldy #>tk_sb
    jsr pt_is
    bne @t4
    lda pt_done             ; S/B: the block, or SYN when the phase is done
    beq @sendb
    lda #<tk_syn
    ldy #>tk_syn
    jsr pt_token
    jmp @loop
@sendb:
    ldy #0
@sb: sty x_y
    lda XB_PEND,y
    jsr xput
    ldy x_y
    iny
    cpy pt_blen
    bne @sb
    lda #1
    sta pt_unacked
    jmp @loop
@t4: lda #<tk_syn
    ldy #>tk_syn
    jsr pt_is
    bne @loop2
    lda #<tk_sb             ; SYN: answer S/B; the phase is over
    ldy #>tk_sb
    jsr pt_token
    lda pt_done
    beq @loop2
    lda pt_phase
    bne @fin
    inc pt_phase            ; phase B: start with the header block
    lda #0
    sta pt_done
    jsr pt_header
    bcc @loop2
    lda #ERR_DISK
    jmp xm_fail
@fin:
    clc
    rts
@loop2:
    jmp @loop

pt_get3w:                   ; a token, skipping noise; C=1 timeout
    lda #0
    sta pt_i
@l: jsr xget
    bcs @r
    ldx pt_i
    cpx #3
    bne @st
    ldx pt_tok+1            ; full: slide left
    stx pt_tok
    ldx pt_tok+2
    stx pt_tok+1
    sta pt_tok+2
    jmp @chk
@st: sta pt_tok,x
    inc pt_i
    lda pt_i
    cmp #3
    bne @l
@chk:
    ldx #4                  ; one of the five?
@k: stx pt_k
    lda pt_tab_lo,x
    ldy pt_tab_hi,x
    jsr pt_is
    beq @ok
    ldx pt_k
    dex
    bpl @k
    bmi @l
@ok: clc
@r: rts

pt_header:                  ; phase B's first block: no data
    jsr pt_fill             ; the first chunk -> XB_RX (A bytes)
    bcs @r
    sta pt_nrx
    lda #7
    sta pt_blen
    lda #0
    sta XB_PEND+5
    sta XB_PEND+6
    jsr pt_sizes
    jsr pt_seal
    clc
@r: rts

pt_next:                    ; after a GOO: the next block (or the phase ends)
    lda pt_phase
    beq @done               ; phase A had one block
    lda XB_PEND+6           ; that was the last block
    cmp #$FF
    beq @done
    lda pt_nrx              ; this block: the chunk read ahead
    clc
    adc #7
    sta pt_blen
    ldy #0
@cp: cpy pt_nrx
    beq @cpd
    lda XB_RX,y
    sta XB_PEND+7,y
    iny
    bne @cp
@cpd:
    lda pt_nrx
    jsr xm_count
    jsr xfr_progress
    inc pt_blk
    bne @b
    inc pt_blk+1
@b: lda pt_blk
    sta XB_PEND+5
    lda pt_blk+1
    sta XB_PEND+6
    jsr pt_fill             ; and the one after it
    bcs @r
    sta pt_nrx
    jsr pt_sizes
    jsr pt_seal
    clc
@r: rts
@done:
    lda #1
    sta pt_done
    clc
    rts

pt_fill: jmp (xm_in)         ; (ul_read; the tests' stub)

pt_sizes:                   ; header byte 4 = next size; none left: last
    lda pt_nrx
    beq @last
    clc
    adc #7
    sta XB_PEND+4
    rts
@last:
    lda #0
    sta XB_PEND+4
    lda #$FF
    sta XB_PEND+5
    sta XB_PEND+6
    rts

pt_seal:                    ; checksums of the block in XB_PEND, bytes 4 on
    lda #0
    sta pt_add
    sta pt_add+1
    sta pt_cyc
    sta pt_cyc+1
    ldy #4
@l: cpy pt_blen
    bcs @w
    lda XB_PEND,y
    pha
    clc
    adc pt_add
    sta pt_add
    bcc @n
    inc pt_add+1
@n: pla
    eor pt_cyc
    sta pt_cyc
    asl pt_cyc
    rol pt_cyc+1
    bcc @nc
    inc pt_cyc
@nc: iny
    bne @l
@w: lda pt_add
    sta XB_PEND
    lda pt_add+1
    sta XB_PEND+1
    lda pt_cyc
    sta XB_PEND+2
    lda pt_cyc+1
    sta XB_PEND+3
    rts

; =====================================================================
; The transfer screens (40-column text, upper case/graphics set)
; =====================================================================
x_recv:                     ; by the chosen protocol
    lda x_proto
    beq @x
    jmp pt_recv
@x: jmp xm_recv
x_send:
    lda x_proto
    beq @x
    cmp #3                  ; K: XMODEM-1K
    beq @x
    jmp pt_send
@x: lda #128
    sta x_want
    jmp xm_send

xfr_screen_on:              ; from a session: save the mode, text screen;
    jsr io_quiet            ; the modem held (and only let go for the
    jsr cursor_hide         ; transfer itself).  PETSCII: the board's
    lda mode                ; screen is kept (SNAP); ANSI: the bitmap just
    sta x_mode              ; stays where it is
    beq @a
    jsr snap_save
@a: jsr pet_mode_init
    lda #$15
    sta $D018
    lda #$80
    sta SHFLAG
    jmp pet_cursor_off

xfr_screen_off:             ; back to the board's screen, as it was
    jsr io_live
    lda x_mode
    sta mode
    bne @p
    jmp ansi_show
@p: jmp snap_restore

xfr_wait_key:               ; footer, then any key
    ldx #FOOT2
    lda #<xf_anykey
    ldy #>xf_anykey
    jsr put_line_c
@k: jsr GETIN
    beq @k
    rts

xfr_proto:                  ; row 3: X or P; C=1 cancel; x_proto 0 XMODEM,
    ldx #2                  ; 1 Punter, 2 L (location).  Return: Punter if
    lda #<xl_proto          ; the board is already sending Punter's GOOs
    ldy #>xl_proto
    jsr put_label
    jsr recent_goo
    lda #0
    rol
    sta x_pdef
    beq @xv
    lda #<xv_protp
    ldy #>xv_protp
    bne @pv
@xv: lda #<xv_proto
    ldy #>xv_proto
@pv: ldx #3
    jsr put_line_v
@k: jsr GETIN
    beq @k
    cmp #$5F
    beq @c
    cmp #13
    bne @k1
    lda x_pdef
    jmp @set
@k1: and #$7F
    cmp #'X'
    beq @x
    cmp #'L'
    beq @l
    cmp #'K'
    beq @k1k
    cmp #'P'
    bne @k
    lda #1
    bne @set
@k1k: lda x_lok             ; (uploads only)
    bne @k
    lda #3
    bne @set
@x: lda #0
    beq @set
@l: lda x_lok               ; (downloads only)
    beq @k
    lda #2
@set: sta x_proto
    cmp #2
    beq @done
    ldx #3                  ; the choice, on its own
    lda #LGREY_C
    jsr row_blank
    lda x_proto
    beq @sx
    cmp #3
    bne @sp
    lda #<xs_x1k
    ldy #>xs_x1k
    bne @sw
@sp: lda #<xs_punter
    ldy #>xs_punter
    bne @sw
@sx: lda #<xs_xmodem
    ldy #>xs_xmodem
@sw: ldx #3
    jsr put_line_v
@done: clc
    rts
@c: sec
    rts

xfr_counters:               ; labels for the progress rows
    ldx #11
    lda #<xl_blocks
    ldy #>xl_blocks
    jsr put_label
    ldx #12
    lda #<xl_bytes
    ldy #>xl_bytes
    jsr put_label
    ldx #13
    lda #<xl_retries
    ldy #>xl_retries
    jsr put_label
    ; fall through
xfr_progress:               ; the counters (also called by the engine)
    lda xm_nblk
    sta num
    lda xm_nblk+1
    sta num+1
    lda #0
    sta num+2
    ldx #11
    jsr @show
    lda xm_bytes
    sta num
    lda xm_bytes+1
    sta num+1
    lda xm_bytes+2
    sta num+2
    ldx #12
    jsr @show
    lda xm_retries
    sta num
    lda #0
    sta num+1
    sta num+2
    ldx #13
@show:
    jsr row_ptrs
    lda #LGREY_C
    sta w_col
    lda #0
    sta w_rev
    ldy #10
@b: lda #' '                ; (put_ch leaves the colour in A)
    jsr put_ch
    iny
    cpy #20
    bne @b
    jsr num_str
    lda #<numbuf
    ldy #>numbuf
    ldx #10
    jmp put_str_at

num_str:                    ; num (24-bit) -> numbuf, no leading zeros
    ldx #0                  ; power of ten index
    stx x_y                 ; output position
    stx x_nz
@p: ldy #'0'
@s: lda num                 ; num -= pow[x] while it fits
    sec
    sbc pow_lo,x
    sta x_t
    lda num+1
    sbc pow_mid,x
    sta x_t+1
    lda num+2
    sbc pow_hi,x
    bcc @d
    sta num+2
    lda x_t+1
    sta num+1
    lda x_t
    sta num
    iny
    bne @s
@d: tya
    cmp #'0'
    bne @put
    ldy x_nz
    bne @put2
    cpx #7                  ; always print the last digit
    bne @nx
@put2:
    lda #'0'
@put:
    ldy x_y
    sta numbuf,y
    inc x_y
    lda #1
    sta x_nz
@nx: inx
    cpx #8
    bne @p
    ldy x_y
    lda #0
    sta numbuf,y
    rts
pow_lo:  .byte <10000000 & $FF, <1000000 & $FF, <100000 & $FF, <10000, <1000, <100, <10, <1
pow_mid: .byte >10000000 & $FF, >1000000 & $FF, >100000 & $FF, >10000, >1000, >100, >10, >1
pow_hi:  .byte ^10000000, ^1000000, ^100000, 0, 0, 0, 0, 0

; ---- download (C=+D)
xfr_download:               ; C=+D: a detour from the board and back
    jsr xfr_screen_on
    lda #0                  ; T: the type is guessed unless chosen
    sta x_force
    jsr dl_guess_name       ; (the file, as far as the board's screen says)
    lda #0                  ; this session's downloads folder, else settings
    jsr loc_start
@again:
    jsr dl_start            ; the screen; a key: C=1 back, else x_proto
    bcc @k
    lda #0                  ; back to the board, nothing said
    jmp @back
@k: lda x_proto
    cmp #3                  ; M: a Multi-Punter batch (mp_batch)
    bne @k2
    jmp mp_batch
@k2: cmp #2
    bne @go
    lda #0                  ; L: pick a folder
    jsr br_run
    bcs @bc
    jsr loc_keep
    jmp @again
@bc: lda #0                 ; cancelled: as it was
    jsr loc_start
    jmp @again
@go: jsr dl_going           ; the choice shown; "<- stops"
    jsr loc_enter           ; where it goes
    bcc @dr
    jsr br_drvmsg
    jsr xfr_wait_key
    jmp @again
@dr: jsr fin_tmpname        ; into ZCTMP (opened when data comes), named
    jsr xscratch            ; at the end; none left from before
    lda #0
    sta dl_open
    sta x_type
    sta x_strip
    sta dl_tfix
    jsr dl_force            ; T chose PRG or SEQ: no guessing
    jsr xfr_counters
    ldx #15
    lda #<xs_waitsend
    ldy #>xs_waitsend
    jsr put_line_v
    lda #<dl_write
    sta xm_out
    lda #>dl_write
    sta xm_out+1
    jsr io_live             ; the modem live for the transfer
    jsr x_recv
    jsr io_quiet
    php
    lda dl_open
    beq @nc
    jsr xclose
@nc: plp
    bcs @failed
    lda dl_open
    beq @none
    jsr dos_status          ; e.g. 72, DISK FULL on the last block
    beq @good
    lda #ERR_DISK
    sta xm_err
    jmp @failed
@good:
    jsr dl_finish           ; name it (C=1: discarded)
    bcs @disc
    lda #1                  ; "Saved <name>"
    jmp @back
@disc: jsr xscratch
    lda #2
    jmp @back
@none: lda #3
    jmp @back
@failed:
    lda dl_open
    beq @f2
    jsr xscratch            ; no half files
@f2: lda xm_err
    cmp #ERR_TIMEOUT        ; no answer: offer the other protocol
    bne @f3
    jsr dl_noanswer         ; C=1: back; else x_proto set
    bcs @f4
    jmp @go
@f4: lda #4
    jmp @back
@f3: cmp #ERR_USER
    bne @f5
    lda #5                  ; stopped by you
    jmp @back
@f5: lda #6                 ; failed: the reason
@back:
    sta dl_res
    jsr xfr_screen_off
    jmp dl_say              ; one line on the board's screen

xfr_result:                 ; A/Y = "RECEIVED"/"SENT": "... NAME (n BYTES)"
    jsr dir_msg
    lda #<XB_NAME
    ldy #>XB_NAME
    ldx #10
    jsr dir_msg_at
    lda xm_bytes
    sta num
    lda xm_bytes+1
    sta num+1
    lda xm_bytes+2
    sta num+2
    jsr num_str
    ldx #MSG_ROW+1
    lda #<numbuf
    ldy #>numbuf
    jsr put_line_v
    lda #<xs_bytes
    ldy #>xs_bytes
    ldx w_x
    jmp put_str_at

xfr_err_msg:                ; xm_err -> row 22 (disk: with the drive's words)
    ldx xm_err
    lda xe_lo-1,x
    ldy xe_hi-1,x
    jsr dir_msg
    lda xm_err
    cmp #ERR_DISK
    bne @r
    lda #<dos_msg
    ldy #>dos_msg
    ldx #12
    jmp dir_msg_at
@r: rts

xopen:                      ; open XB_NAME,<x_type>,<A: R or W> as file 4
    sta x_rw
    ldx #0                  ; build the name in CMD_BUF
@n: lda XB_NAME,x
    beq @t
    sta CMD_BUF,x
    inx
    bne @n
@t: lda #','
    sta CMD_BUF,x
    inx
    lda x_type
    sta CMD_BUF,x
    inx
    lda #','
    sta CMD_BUF,x
    inx
    lda x_rw
    sta CMD_BUF,x
    inx
    stx x_y
    lda #0                  ; the command channel first, open until xclose:
    tax                     ; closing it closes every file on a CBM drive
    tay                     ; (1541, SD2IEC), so a status check in between
    jsr SETNAM              ; would end this file (seen in VICE)
    lda #15
    ldx cur_dev
    ldy #15
    jsr SETLFS
    jsr OPEN
    bcs @fail
    lda x_y
    ldx #<CMD_BUF
    ldy #>CMD_BUF
    jsr SETNAM
    lda #4
    ldx cur_dev
    ldy #4
    jsr SETLFS
    jsr OPEN
    bcs @fail
    jsr dos_read            ; (no "exists?" here: ZCTMP is scratched first,
    beq @ok                 ; and the real name is checked at the end)
@fail:
    jsr xclose
    sec
    rts
@ok: clc
    rts

xclose:                     ; the file, then the command channel
    jsr CLRCHN
    lda #4
    jsr CLOSE
    lda #15
    jmp CLOSE

xscratch:                   ; S:<name>
    ldx #0
    lda #'S'
    sta CMD_BUF
    lda #':'
    sta CMD_BUF+1
@n: lda XB_NAME,x
    beq @d
    sta CMD_BUF+2,x
    inx
    bne @n
@d: txa
    clc
    adc #2
    ldx #<CMD_BUF
    ldy #>CMD_BUF
    jmp dos_cmd

dl_write:                   ; xo_len bytes at XB_PEND -> file 4; C=1 error
    jsr io_quiet
    jsr dl_write2
    jmp io_live
dl_write2:
    lda xo_len
    ora xo_len+1
    beq @ok
    lda dl_open             ; the first data: now the type is known, open
    bne @w
    jsr dl_guess
    lda #'W'
    jsr xopen
    bcs @err2
    inc dl_open
@w: ldx #4
    jsr CHKOUT
    bcs @err
    lda #<XB_PEND
    sta xptr2
    lda #>XB_PEND
    sta xptr2+1
@l: ldy #0
    lda (xptr2),y
    jsr CHROUT
    inc xptr2
    bne @c
    inc xptr2+1
@c: lda xo_len
    bne @d
    dec xo_len+1
@d: dec xo_len
    lda xo_len
    ora xo_len+1
    bne @l
    jsr CLRCHN
    lda STATUS
    and #$83                ; device gone / write timeout
    bne @err
@ok: clc
    rts
@err:
    jsr CLRCHN
@err2: sec
    rts

; ---- upload (C=+U): pick a file from the uploads location
xfr_upload:
    jsr xfr_screen_on
    lda #0
    sta x_lok
@pick:
    lda #$93
    jsr CHROUT
    ldx #0
    lda #<xt_up
    ldy #>xt_up
    jsr title_bar
    lda #1                  ; this session's uploads folder, else settings
    jsr loc_start
    lda #1                  ; pick a file (folders open)
    jsr br_run
    bcc @chosen
    jmp @out
@chosen:
    jsr loc_keep
@go: lda x_sel              ; the chosen entry -> XB_NAME, x_type
    jsr ul_entry
    ldy #17
    lda (xptr),y
    cmp #'P'
    beq @ty
    cmp #'S'
    beq @ty
    cmp #'U'
    beq @ty
    lda #<xs_cantsend
    ldy #>xs_cantsend
    jsr dir_msg
@kw: jsr GETIN
    beq @kw
    jmp @pick
@ty: sta x_type
    ldy #0
@nm: lda (xptr),y
    sta XB_NAME,y
    beq @nd
    iny
    cpy #16
    bne @nm
    lda #0
    sta XB_NAME,y
@nd: lda #$93
    jsr CHROUT
    ldx #0
    lda #<xt_up
    ldy #>xt_up
    jsr title_bar
    ldx #FOOT2
    lda #<xf_cancel
    ldy #>xf_cancel
    jsr put_line_c
    jsr xfr_proto
    bcc @p
    jmp @out
@p: ldx #5
    lda #<xl_name
    ldy #>xl_name
    jsr put_label
    ldx #6
    lda #<XB_NAME
    ldy #>XB_NAME
    jsr put_line_v
    lda #'R'
    jsr xopen
    bcc @op
    jmp @drvfail
@op: jsr xfr_counters
    ldx #15
    lda #<xs_waitask
    ldy #>xs_waitask
    jsr put_line_v
    lda #<ul_read
    sta xm_in
    lda #>ul_read
    sta xm_in+1
    lda #0
    sta x_eof
    jsr io_live
    jsr x_send
    jsr io_quiet
    php
    jsr xclose
    plp
    bcs @failed
    lda #<xs_sent
    ldy #>xs_sent
    jsr xfr_result
    jmp @end
@failed:
    jsr xfr_err_msg
@end:
    jsr xfr_wait_key
@out:
    jmp xfr_screen_off
@drvfail:
    jsr br_drvmsg
    jmp @end

ul_entry:                   ; A = index -> xptr = XB_DIR + A*20
    sta x_t
    lda #0
    sta xptr+1
    lda x_t                 ; x16 + x4
    asl
    asl
    sta x_t+1               ; x4
    asl
    asl                     ; x16 (index < 64: fits)
    clc
    adc x_t+1
    bcc @n
    inc xptr+1
@n: clc
    adc #<XB_DIR
    sta xptr
    lda xptr+1
    adc #>XB_DIR
    sta xptr+1
    rts

ul_read:                    ; up to 128 bytes of file 4 -> XB_RX; A = count
    jsr io_quiet
    jsr ul_read2
    jmp io_live
ul_read2:
    lda x_eof
    beq @go
    lda #0
    clc
    rts
@go: ldx #4
    jsr CHKIN
    bcs @err
    lda #0
    sta x_cnt
@l: jsr CHRIN
    ldy x_cnt
    sta XB_RX,y
    inc x_cnt
    lda STATUS
    bne @st
    lda x_cnt
    cmp x_want
    bne @l
    beq @d
@st: and #$40               ; end of file (this byte was the last)
    beq @err
    inc x_eof
@d: jsr CLRCHN
    lda x_cnt
    clc
    rts
@err:
    jsr CLRCHN
    sec
    rts

ul_readdir:                 ; "$" of the uploads location -> XB_DIR
    lda #0
    sta x_nfiles
    sta x_first
    lda #1
    ldx #<xs_dollar
    ldy #>xs_dollar
    jsr SETNAM
    lda #2
    ldx cur_dev
    ldy #0
    jsr SETLFS
    jsr OPEN
    bcs @xj0
    ldx #2
    jsr CHKIN
    bcc @ok0
@xj0: jmp @x
@ok0:
    jsr @b                  ; load address
    jsr @b
    jmp @line
@xj: jmp @x
@lj: jmp @line
@line:
    jsr @b                  ; link (0 0 = the end)
    sta x_t
    jsr @b
    ora x_t
    beq @xj
    lda STATUS
    bne @xj
    jsr @b                  ; blocks
    sta x_bl
    jsr @b
    sta x_bh
    ldy #0                  ; the text, to CMD_BUF
@t: jsr @b
    sta CMD_BUF,y
    beq @te
    iny
    cpy #40
    bcc @t
    dey
@te: lda #0
    sta CMD_BUF,y
    lda x_first             ; the first line is the disk name
    bne @parse
    inc x_first
    jmp @line
@parse:
    ldy #0                  ; find the opening quote
@q: lda CMD_BUF,y
    beq @lj
    iny
    cmp #'"'
    bne @q
    lda x_nfiles
    cmp #DIR_MAX
    bcs @lj
    jsr ul_entry
    ldx #0
@nm: lda CMD_BUF,y          ; the name, to the closing quote
    beq @lj
    iny
    cmp #'"'
    beq @nmd
    stx x_t
    sty x_t+1
    ldy x_t
    sta (xptr),y
    ldy x_t+1
    inx
    cpx #16
    bcc @nm
@nmd:
    txa
    sty x_t+1
    tay
    lda #0
    sta (xptr),y
    ldy x_t+1
@sp: lda CMD_BUF,y          ; the type: first letter after the spaces
    bne @sp1
    jmp @line
@sp1:
    iny
    cmp #' '
    beq @sp
    cmp #'*'                ; (splat file: still open)
    beq @sp
    ldy #17
    sta (xptr),y
    iny
    lda x_bl
    sta (xptr),y
    iny
    lda x_bh
    sta (xptr),y
    inc x_nfiles
    jmp @line
@x: jsr CLRCHN
    lda #2
    jmp CLOSE
@b: jsr CHRIN               ; one byte (0 if the drive stops)
    pha
    lda STATUS
    and #$82
    beq @bo
    pla
    lda #0
    rts
@bo: pla
    rts

ul_draw:                    ; the file list with a bar (rows 2-21)
    ldx #0
@r: stx x_row
    txa
    clc
    adc #2
    tax
    lda #LGREY_C
    jsr row_blank
    lda x_row               ; which file: page start + row
    jsr ul_top
    clc
    adc x_row
    cmp x_nfiles
    bcs @nx
    sta x_t
    jsr ul_entry
    lda #0
    sta w_rev
    lda #LGREY_C
    sta w_col
    lda x_t
    cmp x_sel
    bne @n
    lda #$80
    sta w_rev
    lda #CYAN_C
    sta w_col
    ldy #39
@bar: lda #$A0
    sta (dst),y
    lda #CYAN_C
    sta (cptr),y
    dey
    bpl @bar
@n: lda xptr                ; name at column 1
    sta bptr
    lda xptr+1
    sta bptr+1
    ldy #1
    jsr put_bptr
    ldy #17
    lda (xptr),y            ; type at column 20
    ldy #20
    jsr put_ch
    ldy #18                 ; blocks at column 24
    lda (xptr),y
    sta num
    iny
    lda (xptr),y
    sta num+1
    lda #0
    sta num+2
    jsr num_str
    lda #<numbuf
    ldy #>numbuf
    ldx #24
    jsr put_str_at
@nx: ldx x_row
    inx
    cpx #20
    beq @rd
    jmp @r
@rd:
    ldx #FOOT1
    lda #<xf_pick
    ldy #>xf_pick
    jsr put_line_c
    ldx #FOOT2
    lda #<xf_cancel
    ldy #>xf_cancel
    jmp put_line_c

ul_top:                     ; first file on x_sel's page (20 a page)
    lda x_sel
    ldx #0
@l: cmp #20
    bcc @d
    sbc #20
    inx
    bne @l
@d: lda #0
@m: dex
    bmi @r
    clc
    adc #20
    bne @m
@r: rts

; ---- locations and the folder browser.  A transfer reads or writes in
; x_bdev + XB_PATH: this session's choice (ses_*), else the settings.
loc_start:                  ; A = 0 downloads, 1 uploads
    sta x_dir
    tax
    lda ses_ddev,x
    beq @cfg
    sta x_bdev
    lda ses_plo,x
    sta bptr
    lda #>SES_DPATH
    sta bptr+1
    bne @copy
@cfg: lda loc_dev+1,x       ; (L_DOWN = 1, L_UP = 2)
    jsr cfg_dev
    sta x_bdev
    ldx x_dir
    lda loc_path+1,x
    clc
    adc #<CFG
    sta bptr
    lda #>CFG
    adc #0
    sta bptr+1
@copy:
    ldy #0
@c: lda (bptr),y
    sta XB_PATH,y
    beq @r
    iny
    cpy #39
    bne @c
    lda #0
    sta XB_PATH,y
@r: rts

loc_keep:                   ; the session keeps x_bdev + XB_PATH
    ldx x_dir
    lda x_bdev
    sta ses_ddev,x
    lda ses_plo,x
    sta bptr
    lda #>SES_DPATH
    sta bptr+1
    ldy #0
@c: lda XB_PATH,y
    sta (bptr),y
    beq @r
    iny
    bne @c
@r: rts

loc_enter:                  ; drive x_bdev, into XB_PATH.  C=1: failed
    lda x_bdev
    sta cur_dev
    ldx #<XB_PATH
    ldy #>XB_PATH
    jmp dos_go

loc_show:                   ; row ls_row (1): DRIVE nn  FOLDER
    ldx ls_row
    lda #CYAN_C
    jsr row_blank
    lda #CYAN_C
    sta w_col
    lda #0
    sta w_rev
    sta num+1
    sta num+2
    lda x_bdev
    sta num
    jsr num_str
    lda #<xl_drive
    ldy #>xl_drive
    ldx #1
    jsr put_str_at
    lda #<numbuf
    ldy #>numbuf
    ldx #7
    jsr put_str_at
    ldy #0                  ; the folder: its last 29 characters
@n: lda XB_PATH,y
    beq @e
    iny
    bne @n
@e: tya
    beq @blank
    sec
    sbc #29
    bcs @o
    lda #0
@o: clc
    adc #<XB_PATH
    tax
    lda #>XB_PATH
    adc #0
    tay
    txa
    bne @w                  ; (XB_PATH is never at $xx00)
@blank:
    lda x_bdev
    cmp home_dev
    bne @cur
    lda #<xl_zc
    ldy #>xl_zc
    bne @w
@cur: lda #<xl_cur
    ldy #>xl_cur
@w: ldx #10
    jmp put_str_at

br_drvmsg:                  ; row 22: DRIVE: <the drive's words>
    lda #<xm_drive
    ldy #>xm_drive
    jsr dir_msg
    lda #<dos_msg
    ldy #>dos_msg
    ldx #8
    jmp dir_msg_at

br_run:                     ; A = 0 pick a folder (S), 1 pick a file.  C=1:
    sta x_bmode             ; cancelled (or the drive failed: said, key
    lda #0                  ; waited for).  C=0: x_sel = the file (mode 1)
    sta x_hasold
@go: jsr loc_enter
    bcc @rd
    lda x_hasold
    bne @back
    jsr br_drvmsg           ; the starting place failed
    jsr xfr_wait_key
    sec
    rts
@back:                      ; a new place failed: say so, go back
    jsr br_restore
    jsr loc_enter
    bcs @go                 ; (x_hasold is 0 now: reports and leaves)
    jsr br_list
    jsr br_drvmsg
    jmp @k
@rd: jsr br_list
    lda x_nfiles
    bne @k
    lda #<xs_nofiles
    ldy #>xs_nofiles
    jsr dir_msg
@k: jsr GETIN
    beq @k
    cmp #$5F
    bne @k1
    sec
    rts
@k1: cmp #$11
    beq @dn
    cmp #$91
    beq @up
    cmp #13
    beq @ret
    cmp #$14
    beq @del
    and #$7F
    cmp #'D'
    beq @drv
    cmp #'S'
    bne @k
    lda x_bmode             ; S: this folder (downloads)
    bne @k
    clc
    rts
@dn: ldx x_sel
    inx
    cpx x_nfiles
    bcs @k
    stx x_sel
    jsr br_draw
    jmp @k
@up: ldx x_sel
    beq @k
    dex
    stx x_sel
    jsr br_draw
    jmp @k
@ret: lda x_nfiles
    beq @k
    lda x_sel
    jsr ul_entry
    ldy #17
    lda (xptr),y
    cmp #'D'
    beq @into
    lda x_bmode
    beq @k
    clc
    rts
@into: jsr br_save
    jsr path_add
    bcs @k
    jmp @go
@del: jsr br_save
    jsr path_up
    bcs @k
    jmp @go
@drv: jsr br_save
    jsr br_nextdrv
    jmp @go

br_list:                    ; read the folder, bar at the top, draw
    jsr ul_readdir
    lda #0
    sta x_sel
br_draw:
    ldx #MSG_ROW
    lda #YELLOW_C
    jsr row_blank
    jsr ul_draw
    jsr loc_show
    lda x_bmode
    bne @r
    ldx #FOOT1
    lda #<xf_here
    ldy #>xf_here
    jmp put_line_c
@r: rts

br_save:                    ; remember where we are (to go back to)
    lda x_bdev
    sta x_odev
    ldy #0
@c: lda XB_PATH,y
    sta XB_OPATH,y
    beq @r
    iny
    bne @c
@r: lda #1
    sta x_hasold
    rts

br_restore:
    lda x_odev
    sta x_bdev
    ldy #0
@c: lda XB_OPATH,y
    sta XB_PATH,y
    beq @r
    iny
    bne @c
@r: lda #0
    sta x_hasold
    rts

br_nextdrv:                 ; D: the next drive (8-15) that answers
    lda #8
    sta x_t
    ldx x_bdev
@n: inx
    cpx #16
    bcc @c
    ldx #8
@c: stx cur_dev
    jsr dev_present
    bcc @ok
    ldx cur_dev
    dec x_t
    bne @n
    rts                     ; none: stay
@ok: lda cur_dev
    sta x_bdev
    lda #0
    sta XB_PATH
    rts

path_add:                   ; XB_PATH += "/" + the name at (xptr).  C=1: no
    ldy #0                  ; ".." is up; "." is nothing
    lda (xptr),y
    cmp #'.'
    bne @a
    iny
    lda (xptr),y
    beq @no
    cmp #'.'
    bne @a
    iny
    lda (xptr),y
    bne @a
    jmp path_up
@no: sec
    rts
@a: ldy #0
@e: lda XB_PATH,y
    beq @end
    iny
    bne @e
@end: sty x_t
    tya
    beq @nm
    lda XB_PATH-1,y
    cmp #'/'
    beq @nm
    lda #'/'
    sta XB_PATH,y
    iny
@nm: ldx #0
@c: sty x_y
    txa
    tay
    lda (xptr),y
    ldy x_y
    sta XB_PATH,y
    cmp #0                  ; (LDY just set the flags)
    beq @ok
    inx
    iny
    cpy #39
    bcc @c
    ldy x_t                 ; too long: as it was
    lda #0
    sta XB_PATH,y
    sec
    rts
@ok: clc
    rts

path_up:                    ; XB_PATH up one level.  C=1: at the top
    ldy #0
    ldx #$FF                ; the last "/"
@l: lda XB_PATH,y
    beq @e
    cmp #'/'
    bne @n
    tya
    tax
@n: iny
    bne @l
@e: tya
    beq @top                ; blank: ZenCom's folder (or the drive's own)
    txa
    bmi @all                ; "NAME": back to blank
    beq @root               ; "/NAME": to "/"
    lda #0
    sta XB_PATH,x
    clc
    rts
@root: cpy #1
    beq @top                ; "/" itself
    lda #0
    sta XB_PATH+1
    clc
    rts
@all: lda #0
    sta XB_PATH
    clc
    rts
@top: sec
    rts

ses_plo: .byte <SES_DPATH, <SES_UPATH

.segment "CODE2"            ; (main program, $4800-: the overlay is full)
.segment "CODE"             ; (CODE2 is full)
; ---- a download's name, offered: the last "NAME =" or "NAME:" in the
; board's recent text, else the last line typed (not an AT command).
; Letters to one case; characters a drive won't take become "-".
dl_prefill:
    ldx rc_pos              ; the ring, oldest first, case folded -> XB_RX
    ldy #0
@lin: lda RECENT,x
    jsr pf_fold
    sta XB_RX,y
    inx
    txa
    and #$7F
    tax
    iny
    bpl @lin
    lda #$FF                ; the last "NAME"
    sta x_t
    ldy #0
@f: lda XB_RX,y
    cmp #'N'
    bne @fn
    lda XB_RX+1,y
    cmp #'A'
    bne @fn
    lda XB_RX+2,y
    cmp #'M'
    bne @fn
    lda XB_RX+3,y
    cmp #'E'
    bne @fn
    tya                     ; then spaces and "=" or ":" (not a heading)
    clc
    adc #4
    tax
@s2: lda XB_RX,x
    cmp #' '
    bne @s3
    inx
    bpl @s2
    bmi @fn
@s3: cmp #'='
    beq @ok
    cmp #':'
    bne @fn
@ok: inx
    stx x_t
@fn: iny
    cpy #124
    bcc @f
    ldy x_t
    bmi @typed
    jsr @sp
    ldx #0                  ; copy to the end of the line
@c: cpy #128
    bcs @end
    lda XB_RX,y
    cmp #' '
    bcc @end
    jsr pf_safe
    sta XB_NAME,x
    iny
    inx
    cpx #16
    bcc @c
@end: jmp pf_trim
@sp: cpy #128               ; skip spaces; A = the next character
    bcs @sp0
    lda XB_RX,y
    cmp #' '
    bne @spr
    iny
    bne @sp
@sp0: lda #0
@spr: rts
@typed:
    ldx #0                  ; else the last line typed that could be a name
@t: lda NAME_LINE,x
    beq @td
    jsr pf_fold
    jsr pf_safe
    sta XB_NAME,x
    inx
    cpx #16
    bcc @t
@td: jmp pf_trim
@r: rts

pf_trim:                    ; XB_NAME: end it at X, drop trailing spaces
    lda #0
    sta XB_NAME,x
@b: dex
    bmi @r
    lda XB_NAME,x
    cmp #' '
    bne @r
    lda #0
    sta XB_NAME,x
    beq @b
@r: rts

pf_fold:                    ; PETSCII capitals ($C1-$DA) and ASCII small
    cmp #$C1                ; letters -> $41-$5A
    bcc @a
    cmp #$DB
    bcs @r
    and #$7F
    rts
@a: cmp #$61
    bcc @r
    cmp #$7B
    bcs @r
    and #$DF
@r: rts

pf_safe:                    ; A drive-safe character: , : * ? = " / @ $ -> -
    stx x_y                 ; (keeps X and Y)
    ldx #pf_bad_n-1
@l: cmp pf_bad,x
    beq @dash
    dex
    bpl @l
    ldx x_y
    rts
@dash: lda #'-'
    ldx x_y
    rts
pf_bad: .byte ",:*?=", $22, "/@$"
pf_bad_n = * - pf_bad

recent_goo:                 ; C=1: "GOOGOO" in the board's recent text (a
    ldx #0                  ; Punter sender waiting; one GOO could be
@l: ldy #0                  ; "GOOD...")
@m: lda RECENT,x
    cmp pf_goo,y
    bne @n
    inx
    iny
    cpy #6
    bcc @m
    sec
    rts
@n: inx
    cpx #123                ; (the last place GOOGOO fits: 122)
    bcc @l
    clc
    rts
pf_goo: .byte "GOOGOO"

recent_xm:                  ; C=1: "XMODEM" (any case) in the board's recent
    ldx #0                  ; text: Return then picks XMODEM, even in a
@l: ldy #0                  ; PETSCII session
@m: lda RECENT,x
    jsr pf_fold
    cmp pf_xm,y
    bne @n
    inx
    iny
    cpy #6
    bcc @m
    sec
    rts
@n: inx
    cpx #123
    bcc @l
    clc
    rts
pf_xm: .byte "XMODEM"

phrase_watch:               ; A = a byte from the board (kept): "RECEIVE
    pha                     ; MODE", "START YOUR", "BEGIN YOUR", "START XMODEM"
    lda ph_pend             ; = the board may be ready to send: say so once,
    beq @nw                 ; at the end of the board's line (said at once,
    pla                     ; it split the line: "START YOU" .. "R XMODEM")
    pha
    cmp #$0D
    beq @say
    cmp #$0A
    beq @say
    jsr pf_fold             ; "UPLOAD" on the same line: the board wants
    ldx ph_up               ; us to send, so no "press C=+D"
    cmp ph_uw,x
    beq @u1
    ldx #0
    cmp ph_uw
    bne @u0
@u1: inx
    cpx #6
    bcc @u0
    ldx #0
    stx ph_pend
@u0: stx ph_up
    jmp @r
@say: lda #0
    sta ph_up
    sta ph_pend
    lda #<msg_maybe         ; (the msgs table is full: say takes an address)
    ldy #>msg_maybe
    jsr say
    jmp @r
@nw: lda ph_shown           ; (cleared by C=+D and at each call)
    bne @r
    pla
    pha
    jsr pf_fold
    sta ph_c
    ldx #PH_N-1
@p: lda ph_start,x          ; X = pattern: next letter wanted at start+idx
    clc
    adc ph_idx,x
    tay
    lda ph_text,y
    cmp ph_c
    bne @miss
    inc ph_idx,x
    lda ph_text+1,y         ; the end of this phrase?
    bne @nx
    lda #1
    sta ph_shown
    sta ph_pend
    jsr ph_reset
    jmp @r
@miss:
    ldy ph_start,x          ; restart (this letter may begin it again)
    lda ph_text,y
    cmp ph_c
    beq @one
    lda #0
    .byte $2C
@one: lda #1
    sta ph_idx,x
@nx: dex
    bpl @p
@r: pla
    rts
ph_reset:
    lda #0
    ldx #PH_N-1
@z: sta ph_idx,x
    dex
    bpl @z
    rts
ph_text:  .byte "RECEIVE MODE", 0, "START YOUR", 0, "BEGIN YOUR", 0, "START XMODEM", 0
ph_start: .byte 0, 13, 24, 35
PH_N = 4
ph_idx:   .res PH_N
ph_c:     .byte 0
msg_maybe: .byte 13, 10, "-- Board may be sending: press C=+D --", 0
ph_shown: .byte 0
ph_pend:  .byte 0
ph_up:    .byte 0
ph_uw:    .byte "UPLOAD"

.segment "CODE2"
; ---- the download round trip: start screen, choices, result line -----
GUESS    = $C520            ; the file's name as guessed at C=+D (16 + 0)

dl_guess_name:              ; at C=+D: what the board's screen says -> GUESS
    jsr fin_prepare
    ldx #16
@c: lda XB_NAME,x
    sta GUESS,x
    dex
    bpl @c
    rts

dl_start:                   ; the start screen; waits for a key.  C=1: back
    lda #$93                ; to the board; else x_proto = 0 XMODEM,
    jsr CHROUT              ; 1 Punter, 2 L (choose the folder)
    ldx #0
    lda #<xt_down
    ldy #>xt_down
    jsr title_bar
    ldx #1                  ; where it goes, labelled
    lda #<ds_to
    ldy #>ds_to
    jsr put_label
    lda #2
    sta ls_row
    jsr loc_show
    lda #1
    sta ls_row
    ldx #3
    lda #<ds_l
    ldy #>ds_l
    jsr put_line_c
    ldx #5
    lda #<ds_file
    ldy #>ds_file
    jsr put_label
    lda GUESS
    beq @ng
    ldx #6
    lda #<GUESS
    ldy #>GUESS
    jsr put_line_v
    ldx #7
    lda #<ds_conf
    ldy #>ds_conf
    jsr put_line_c
    jmp @pr
@ng: ldx #6
    lda #<ds_noname
    ldy #>ds_noname
    jsr put_line_v
@pr: ldx #9
    lda #<xl_proto
    ldy #>xl_proto
    jsr put_label
    jsr recent_goo          ; the default: Punter if the board is sending
    lda #0                  ; it, or in PETSCII (C64 boards); else XMODEM
    rol
    sta x_pdef
    bne @dp
    lda x_mode
    beq @dx
    jsr recent_xm           ; PETSCII, but the board just said XMODEM
    bcs @dx
    lda #1
    sta x_pdef
    lda #<ds_rp
    ldy #>ds_rp
    bne @d1
@dp: lda #<ds_rps
    ldy #>ds_rps
    bne @d1
@dx: lda #<ds_rx
    ldy #>ds_rx
@d1: ldx #10
    jsr put_line_v
    lda x_pdef
    bne @ox
    lda #<ds_op
    ldy #>ds_op
    bne @o1
@ox: lda #<ds_ox
    ldy #>ds_ox
@o1: ldx #11
    jsr put_line_v
    ldx #12
    lda #<ds_om
    ldy #>ds_om
    jsr put_line_v
    jsr dl_tshow            ; row 14: T  TYPE  GUESS / PRG / SEQ
    ldx #FOOT1
    lda #<ds_go
    ldy #>ds_go
    jsr put_line_c
    ldx #FOOT2
    lda #<ds_back
    ldy #>ds_back
    jsr put_line_c
    lda x_bdev              ; say now if that drive isn't there
    sta cur_dev
    jsr dev_present
    bcc @k
    jsr br_drvmsg
@k: jsr GETIN
    beq @k
    cmp #$5F
    beq @c
    cmp #13
    bne @k1
    lda x_pdef
    jmp @set
@k1: and #$7F
    cmp #'L'
    beq @l
    cmp #'X'
    beq @x
    cmp #'M'
    beq @m
    cmp #'T'
    beq @t
    cmp #'P'
    bne @k
    lda #1
    bne @set
@t: jsr dl_tnext            ; the next type; stay on this screen
    jmp @k
@m: lda #3
    bne @set
@x: lda #0
    beq @set
@l: lda #2
@set: sta x_proto
    clc
    rts
@c: sec
    rts

dl_going:                   ; the choice made: rows 8-10 and the footer
    ldx #10
    lda #LGREY_C
    jsr row_blank
    ldx #11
    lda #LGREY_C
    jsr row_blank
    ldx #12
    lda #LGREY_C
    jsr row_blank
    ldx #3                  ; (no more folder changes)
    lda #LGREY_C
    jsr row_blank
    lda x_proto
    beq @x
    lda #<xs_punter
    ldy #>xs_punter
    bne @w
@x: lda #<xs_xmodem
    ldy #>xs_xmodem
@w: ldx #10
    jsr put_line_v
    ldx #MSG_ROW
    lda #YELLOW_C
    jsr row_blank
    ldx #FOOT2
    lda #LGREY_C
    jsr row_blank
    ldx #FOOT1
    lda #<ds_stop
    ldy #>ds_stop
    jmp put_line_c

dl_noanswer:                ; no answer: P / X try again, <- back (C=1)
    lda #<xe1
    ldy #>xe1
    jsr dir_msg
    ldx #FOOT1
    lda #<ds_retry
    ldy #>ds_retry
    jsr put_line_c
@k: jsr GETIN
    beq @k
    cmp #$5F
    beq @c
    and #$7F
    cmp #'P'
    beq @p
    cmp #'X'
    bne @k
    lda #0
    beq @s
@p: lda #1
@s: sta x_proto
    clc
    rts
@c: sec
    rts

dl_say:                     ; back on the board's screen: one line for the
    lda dl_res              ; result (0: nothing to say)
    bne @s
    rts
@s: cmp #1
    bne @n2
    lda #<dr_saved          ; Saved <name>. ...
    ldy #>dr_saved
    jsr say
    lda #<XB_NAME
    ldy #>XB_NAME
    jsr say
    lda #<dr_saved2
    ldy #>dr_saved2
    jmp say
@n2: cmp #6
    bne @n3
    lda #<dr_failed         ; Download failed: <reason>. Nothing saved
    ldy #>dr_failed
    jsr say
    ldx xm_err
    lda xe_lo-1,x
    ldy xe_hi-1,x
    jsr say
    lda #<dr_nothing
    ldy #>dr_nothing
    jmp say
@n3: tax                    ; 2-5: a fixed line
    lda dr_lo-2,x
    ldy dr_hi-2,x
    jmp say

say:                        ; A/Y = 0-terminated text, shown in the session
    sta bptr                ; as print_msg does (either mode)
    sty bptr+1
    jsr cursor_hide
    lda #1
    sta swapcase
    ldy #0
@l: lda (bptr),y
    beq @d
    sty sy_y
    jsr char_in
    ldy sy_y
    iny
    bne @l
@d: lda #0
    sta swapcase
    rts

ds_to:     .byte "SAVES TO", 0
ds_l:      .byte "L CHANGES WHERE IT GOES", 0
ds_file:   .byte "SAVE AS", 0
ds_conf:   .byte "(ZENCOM WILL ASK YOU TO CONFIRM IT)", 0
ds_noname: .byte "(ZENCOM WILL ASK YOU FOR A NAME)", 0
ds_rps:    .byte "RETURN  PUNTER  (THE BOARD IS SENDING)", 0
ds_rp:     .byte "RETURN  PUNTER", 0
ds_rx:     .byte "RETURN  XMODEM", 0
ds_ox:     .byte "X       XMODEM INSTEAD", 0
ds_op:     .byte "P       PUNTER INSTEAD", 0
ds_go:     .byte "RETURN STARTS THE DOWNLOAD", 0
ds_back:   .byte "<- BACK TO THE BOARD", 0
ds_stop:   .byte "<- STOPS IT (YOU STAY CONNECTED)", 0
ds_retry:  .byte "P TRY PUNTER  X TRY XMODEM  <- BACK", 0
; the first line of each file ZenCom writes: what it is, where to edit it
; (the readers skip # lines)
h_list:    .byte "#ZENCOM BBS LIST (D ON THE MENU): NAME|HOST:PORT|A OR P|*|NOTE", $0A, 0
h_cfg:     .byte "#ZENCOM SETTINGS (S ON THE MENU)", $0A, 0
h_mac:     .byte "#ZENCOM MACROS (M ON THE MENU), PLAIN TEXT", $0A, 0
dr_saved:  .byte 13, 10, "-- Saved ", 0
dr_saved2: .byte ". Back on the board: press Return if it's quiet --", 13, 10, 0
dr_failed: .byte 13, 10, "-- Download failed: ", 0
dr_nothing: .byte ". Nothing saved --", 13, 10, 0
dr_disc:   .byte 13, 10, "-- Download discarded: nothing saved --", 13, 10, 0
dr_none:   .byte 13, 10, "-- Nothing was received --", 13, 10, 0
dr_noans:  .byte 13, 10, "-- No answer from the board: nothing saved --", 13, 10, 0
dr_stop:   .byte 13, 10, "-- Download stopped: nothing saved. If the board is still sending, it will give up (or press CTRL-X twice) --", 13, 10, 0
dr_lo: .byte <dr_disc, <dr_none, <dr_noans, <dr_stop
dr_hi: .byte >dr_disc, >dr_none, >dr_noans, >dr_stop
dl_res:    .byte 0
dl_tfix:   .byte 0             ; the board said SEQ, the content is a program
sy_y:      .byte 0

; ---- downloads: name at the end (all in CODE2) ------------------------
SNAP     = $6000            ; PETSCII mode: the board's screen at C=+D (the
                            ; ANSI bitmap's memory: unused in PETSCII mode)
LNBUF    = $B900            ; the finishing screen's lines: 40 bytes each
                            ; (the transfer blocks' memory, free by then)
FIN_ROWS = 14               ; lines shown (rows 8-21)

goo_watch:                  ; A = a byte from the board (kept): two GOOs
    jsr phrase_watch        ; (and the board's words for "start it now")
    pha                     ; running = a Punter sender waiting: say so
    ldx gw_i                ; once
    cmp pf_goo,x
    bne @miss
    inx
    cpx #3
    bcc @st
    ldx #0
    inc gw_n
    lda gw_n
    cmp #2
    bcc @st
    lda gw_shown
    bne @st
    inc gw_shown
    stx gw_i
    lda ph_shown            ; already nudged ("may be ready"): once is enough
    bne @q
    ldx #msg_goo-msgs
    jsr print_msg
@q: pla
    rts
@miss:
    ldx #0
    stx gw_n
    stx gw_shown
    cmp #'G'
    bne @st
    inx
@st: stx gw_i
    pla
    rts

num_keep:                   ; Return: a line of 1-5 digits -> last_num
    ldx line_len
    beq @r
    cpx #6
    bcs @r
    ldy #0
@c: lda line_buf,y
    cmp #'0'
    bcc @r
    cmp #'9'+1
    bcs @r
    iny
    cpy line_len
    bne @c
    ldy #0
@cp: lda line_buf,y
    sta last_num,y
    iny
    cpy line_len
    bne @cp
    lda #0
    sta last_num,y
@r: rts

dl_guess:                   ; the file's type, once: Punter says; XMODEM:
    lda x_type              ; text-looking first bytes = SEQ, else PRG.
    bne @r                  ; Either way, a file that starts like a BASIC
    jsr dl_isprog           ; program ($0801 + a SYS line) is a PRG
    bcc @np
    lda x_proto             ; (note when that overrules the board)
    beq @prg
    lda pt_ftype
    beq @prg
    inc dl_tfix
    bne @prg
@np: lda x_proto
    beq @xm
    lda pt_ftype
    bne @seq
    beq @prg
@xm: lda XB_PEND
    jsr @txt
    bcc @prg
    lda XB_PEND+1
    jsr @txt
    bcc @prg
@seq: lda #'S'
    sta x_type
    lda #1
    sta x_strip
    rts
@prg: lda #'P'
    sta x_type
@r: rts
@txt: cmp #$0D              ; C=1: CR, $20-$7E, PETSCII capitals
    beq @y
    cmp #$20
    bcc @n
    cmp #$7F
    bcc @y
    cmp #$C1
    bcc @n
    cmp #$DB
    bcc @y
@n: clc
    rts
@y: sec
    rts

dl_isprog:                  ; C=1: XB_PEND starts like a BASIC program:
    lda XB_PEND             ; loads at $0801 with a SYS ($9E) in its first
    cmp #$01                ; line
    bne @n
    lda XB_PEND+1
    cmp #$08
    bne @n
    ldx #6
@s: lda XB_PEND,x
    cmp #$9E
    beq @y
    inx
    cpx #16
    bcc @s
@n: clc
    rts
@y: sec
    rts

sc2a:                       ; screen code -> A-Z 0-9 etc. ("." if not text)
    and #$7F
    bne @a
    lda #'@'
    rts
@a: cmp #$1B
    bcs @b
    ora #$40                ; 1-26: letters
    rts
@b: cmp #$40
    bcc @r                  ; $1B-$3F: as they are
    cmp #$41
    bcc @dot
    cmp #$5B
    bcc @r                  ; $41-$5A: capitals (lower/upper set)
@dot: lda #'.'
@r: rts

bm_char:                    ; ANSI bitmap: row at xptr2, A = column (0-39)
    lsr                     ; -> A = the character (ASCII, capitals; "."
    php                     ; if no glyph matches)
    asl
    asl
    asl
    tay
    plp
    ldx #0
    bcs @odd
@e: lda (xptr2),y
    lsr
    lsr
    lsr
    lsr
    sta bm_cr,x
    iny
    inx
    cpx #8
    bne @e
    beq @find
@odd: lda (xptr2),y
    and #$0F
    sta bm_cr,x
    iny
    inx
    cpx #8
    bne @odd
@find: jsr bm_match
    bcc @got
    ldx #7                  ; reverse video: inverted
@inv: lda bm_cr,x
    eor #$0F
    sta bm_cr,x
    dex
    bpl @inv
    jsr bm_match
    bcc @got
@dot: lda #'.'
    rts
@got: txa
    clc
    adc #$20
    cmp #$61
    bcc @r
    cmp #$7B
    bcs @dot
    and #$DF
@r: rts

bm_match:                   ; X = the glyph (0-94, ASCII - $20); C=1 none
    ldx #0
@g: lda bm_cr
    cmp a:font_r+0*NUM_GLYPHS,x
    bne @n
    lda bm_cr+1
    cmp a:font_r+1*NUM_GLYPHS,x
    bne @n
    lda bm_cr+2
    cmp a:font_r+2*NUM_GLYPHS,x
    bne @n
    lda bm_cr+3
    cmp a:font_r+3*NUM_GLYPHS,x
    bne @n
    lda bm_cr+4
    cmp a:font_r+4*NUM_GLYPHS,x
    bne @n
    lda bm_cr+5
    cmp a:font_r+5*NUM_GLYPHS,x
    bne @n
    lda bm_cr+6
    cmp a:font_r+6*NUM_GLYPHS,x
    bne @n
    lda bm_cr+7
    cmp a:font_r+7*NUM_GLYPHS,x
    bne @n
    clc
    rts
@n: inx
    cpx #95
    bne @g
    sec
    rts

fin_build:                  ; the board's screen -> LNBUF, blank rows left
                            ; (x_mode: the session's mode; the transfer
                            ; screen is PETSCII whichever it was)
    lda #<LNBUF             ; out; fin_n = lines
    sta bptr
    lda #>LNBUF
    sta bptr+1
    lda #0
    sta fin_n
    sta fin_t               ; row
    lda #<SNAP              ; (SNAP = BITMAP: either way the same start)
    sta xptr2
    lda #>SNAP
    sta xptr2+1
@row: ldy #0
@col: sty fin_t2
    lda x_mode
    beq @an
    lda (xptr2),y
    jsr sc2a
    jmp @put
@an: tya
    jsr bm_char
@put: ldy fin_t2
    sta (bptr),y
    iny
    cpy #39
    bcc @col
    lda #0
    sta (bptr),y
    ldy #0                  ; ZenCom's own lines ("-- ...") aren't names
    lda (bptr),y
    cmp #'-'
    bne @bl
    iny
    lda (bptr),y
    cmp #'-'
    beq @next
    ldy #0                  ; blank?
@bl: lda (bptr),y
    beq @next
    cmp #' '
    bne @keep
    iny
    bne @bl
@keep: inc fin_n
    lda bptr
    clc
    adc #40
    sta bptr
    bcc @next
    inc bptr+1
@next: lda x_mode             ; next row: 40 bytes (screen) or 320 (bitmap)
    beq @b320
    lda #40
    ldx #0
    beq @add
@b320: lda #<320
    ldx #>320
@add: clc
    adc xptr2
    sta xptr2
    txa
    adc xptr2+1
    sta xptr2+1
    inc fin_t
    lda fin_t
    ldx x_mode
    beq @r24
    cmp #25
    bcc @row
    rts
@r24: cmp #24
    bcc @row
    rts

ln_ptr:                     ; A = line -> bptr = LNBUF + A*40
    tax
    lda #<LNBUF
    sta bptr
    lda #>LNBUF
    sta bptr+1
@l: dex
    bmi @r
    lda bptr
    clc
    adc #40
    sta bptr
    bcc @l
    inc bptr+1
    bne @l
@r: rts

ln_alnum:                   ; A: C=1 digit or letter; Z: digit (with C=1)
    cmp #'0'
    bcc @n
    cmp #'9'+1
    bcc @d
    cmp #'A'
    bcc @n
    cmp #'Z'+1
    bcs @n
    sec
    lda #1                  ; (Z clear: a letter)
    rts
@d: sec
    lda #0                  ; (Z set: a digit)
    rts
@n: clc
    rts

lx_name:                    ; A = line: its file name -> XB_NAME.  Skips a
    jsr ln_ptr              ; leading number ("123 NAME"), keeps one that
    ldy #0                  ; is part of the name ("4!SPY"); ends at two
@s: lda (bptr),y            ; spaces (the next column)
    beq @none
    jsr ln_alnum
    bcs @a
    iny
    cpy #39
    bcc @s
@none: ldx #0
    jmp pf_trim
@a: bne @nm                 ; a letter: the name starts here
    sty fin_t               ; a number: a list's own number, or the name's?
@d: iny
    lda (bptr),y
    jsr ln_alnum
    bcc @dsep
    beq @d
    ldy fin_t               ; digits run into letters: part of the name
    jmp @nm
@dsep: cmp #' '
    beq @sp
    cmp #'.'
    beq @sp1
    cmp #')'
    beq @sp1
    cmp #':'
    beq @sp1
    ldy fin_t               ; "4!..." etc.: part of the name
    jmp @nm
@sp1: iny
@sp: lda (bptr),y
    cmp #' '
    bne @nm
    iny
    cpy #39
    bcc @sp
    bcs @none
@nm: ldx #0
@c: lda (bptr),y
    beq @end
    cmp #' '
    bne @ch
    iny                     ; two spaces: the end
    lda (bptr),y
    dey
    cmp #' '
    beq @end
    lda #' '
@ch: jsr pf_safe
    sta XB_NAME,x
    iny
    inx
    cpx #16
    bcc @c
@end: jmp pf_trim

lx_numeq:                   ; A = line: C=1 if its first number is last_num
    jsr ln_ptr
    ldy #0
@s: lda (bptr),y
    beq @no
    jsr ln_alnum
    bcs @a
    iny
    cpy #39
    bcc @s
    bcs @no
@a: bne @no                 ; starts with a letter
    ldx #0
@c: lda last_num,x
    beq @end
    cmp (bptr),y
    bne @no
    inx
    iny
    bne @c
@end: lda (bptr),y          ; and no more digits after it
    cmp #'0'
    bcc @yes
    cmp #'9'+1
    bcc @no
@yes: sec
    rts
@no: clc
    rts

dl_finish:                  ; after a download into ZCTMP: name it.  C=0
    jsr fin_prepare         ; renamed (XB_NAME = the name); C=1 the user
    jmp fin_named           ; discarded it (XB_NAME = ZCTMP again)

fin_prepare:                ; the board's lines, the bar, the guessed name
    ldx #16                 ; (XB_NAME; blank if no guess)
    lda #0
@z: sta XB_NAME,x
    dex
    bpl @z
    jsr dl_prefill          ; FILE NAME = ..., or what was typed
    jsr fin_build
    lda fin_n
    sec
    sbc #FIN_ROWS
    bcs @tp
    lda #0
@tp: sta fin_top
    lda #$FF
    sta fin_bar
    lda last_num            ; the list line with the number typed
    beq @nb
    lda fin_n
    sta fin_t2
@f: dec fin_t2
    lda fin_t2
    bmi @nb
    cmp fin_top
    bcc @nb
    jsr lx_numeq
    bcc @f
    lda fin_t2
    sta fin_bar
    jsr lx_name
@nb: rts

fin_named:
    lda XB_NAME
    bne @scr
    inc dl_count            ; DOWNLOADn
    ldx #0
@dn: lda fin_dl,x
    sta XB_NAME,x
    inx
    cpx #8
    bne @dn
    lda dl_count
@m: cmp #10
    bcc @dg
    sbc #10
    bcs @m
@dg: ora #'0'
    sta XB_NAME+8
    lda #0
    sta XB_NAME+9
@scr: jsr fin_screen
@ed: jsr fin_draw
    lda #<XB_NAME
    sta eptr
    lda #>XB_NAME
    sta eptr+1
    lda #5
    sta ed_row
    lda #0
    sta ed_off
    lda #16
    sta ed_max
    lda #1
    sta fe_bar
    jsr field_edit
    php
    pha
    lda #0
    sta fe_bar
    pla
    plp
    bcs @disc
    cmp #1
    beq @up
    cmp #2
    beq @down
    lda XB_NAME             ; Return: rename (unless blank)
    beq @ed
    jsr fin_rename
    bcs @ed
    rts                     ; (C=0)
@up: lda fin_bar
    cmp #$FF
    beq @last
    cmp fin_top
    beq @ed
    dec fin_bar
    jmp @pick
@down: lda fin_bar
    cmp #$FF
    beq @last
    clc
    adc #1
    cmp fin_n
    bcs @ed
    sta fin_bar
    jmp @pick
@last: lda fin_n
    beq @ed
    sec
    sbc #1
    sta fin_bar
@pick: lda fin_bar
    jsr lx_name
    jmp @ed
@disc: jsr fin_tmpname      ; the caller scratches ZCTMP
    sec
    rts

fin_tmpname:                ; XB_NAME = ZCTMP
    ldx #5
@c: lda fin_tmp,x
    sta XB_NAME,x
    dex
    bpl @c
    rts

fin_screen:
    lda #$93
    jsr CHROUT
    ldx #0
    lda #<xt_down
    ldy #>xt_down
    jsr title_bar
    jsr loc_show
    ldx #2
    lda #YELLOW_C
    jsr row_blank
    lda #YELLOW_C
    sta w_col
    lda #0
    sta w_rev
    lda #<fs_got
    ldy #>fs_got
    ldx #1
    jsr put_str_at
    ldx #4
    lda #<fs_saveas
    ldy #>fs_saveas
    jsr put_label
    jsr dl_tchosen          ; T chose it: say so (C=1, A/Y the text)
    bcs @tw
    lda x_type              ; the type, and where it came from
    cmp #'S'
    bne @p
    lda x_proto
    bne @sb
    lda #<fs_seqg
    ldy #>fs_seqg
    bne @tw
@sb: lda #<fs_seqb
    ldy #>fs_seqb
    bne @tw
@p: lda dl_tfix             ; a program, though the board said SEQ
    beq @p2
    lda #<fs_prgf
    ldy #>fs_prgf
    bne @tw
@p2: lda x_proto
    bne @pb
    lda #<fs_prgg
    ldy #>fs_prgg
    bne @tw
@pb: lda #<fs_prgb
    ldy #>fs_prgb
@tw: ldx #6
    jsr put_line_v
    lda fin_n
    beq @f
    ldx #7
    lda #<fs_from
    ldy #>fs_from
    jsr put_label
@f: ldx #FOOT1
    lda #<fs_keys
    ldy #>fs_keys
    jsr put_line_c
    ldx #FOOT2
    lda #<fs_disc
    ldy #>fs_disc
    jmp put_line_c

fin_draw:                   ; rows 8-21: the lines, the bar; row 22 a note
    lda #0
    sta fin_t
@r: lda fin_t
    clc
    adc #8
    tax
    lda #LGREY_C
    jsr row_blank
    lda fin_t
    clc
    adc fin_top
    cmp fin_n
    bcs @nx
    sta fin_t2
    lda #0
    sta w_rev
    lda #LGREY_C
    sta w_col
    lda fin_t2
    cmp fin_bar
    bne @n
    lda #$80
    sta w_rev
    lda #CYAN_C
    sta w_col
    ldy #39
@bar: lda #$A0
    sta (dst),y
    lda #CYAN_C
    sta (cptr),y
    dey
    bpl @bar
@n: lda fin_t2
    jsr ln_ptr
    ldy #0
    jsr put_bptr
@nx: inc fin_t
    lda fin_t
    cmp #FIN_ROWS
    bcc @r
    ldx #MSG_ROW            ; a Zipcode part: keep its name
    lda #YELLOW_C
    jsr row_blank
    lda XB_NAME+1
    cmp #'!'
    bne @rt
    lda XB_NAME
    cmp #'1'
    bcc @rt
    cmp #'5'
    bcs @rt
    lda #<fs_zip
    ldy #>fs_zip
    jmp dir_msg
@rt: rts

fin_rename:                 ; R:<XB_NAME>=ZCTMP; 63 (exists): ask.  C=1 not
@again:                     ; done (said why)
    ldx #0
    lda #'R'
    sta CMD_BUF
    lda #':'
    sta CMD_BUF+1
@n: lda XB_NAME,x
    beq @e
    sta CMD_BUF+2,x
    inx
    bne @n
@e: lda #'='
    sta CMD_BUF+2,x
    inx
    ldy #0
@t: lda fin_tmp,y
    beq @l
    sta CMD_BUF+2,x
    inx
    iny
    bne @t
@l: txa
    clc
    adc #2
    ldx #<CMD_BUF
    ldy #>CMD_BUF
    jsr dos_cmd
    cmp #0
    beq @ok
    cmp #63
    bne @err
    lda #<fs_exists
    ldy #>fs_exists
    jsr dir_msg
@yn: jsr GETIN
    beq @yn
    and #$7F
    cmp #'Y'
    bne @no
    jsr xscratch            ; the old one goes
    jmp @again
@no: ldx #MSG_ROW
    lda #YELLOW_C
    jsr row_blank
    sec
    rts
@err: jsr br_drvmsg
    sec
    rts
@ok: clc
    rts

fin_tmp:   .byte "ZCTMP", 0
fin_dl:    .byte "DOWNLOAD"
fs_got:    .byte "RECEIVED. NAME THE FILE:", 0
fs_saveas: .byte "SAVE AS", 0
fs_prgb:   .byte "TYPE  PRG (FROM THE BOARD)", 0
fs_prgc:   .byte "TYPE  PRG (YOUR CHOICE)", 0
fs_seqc:   .byte "TYPE  SEQ (YOUR CHOICE)", 0
fs_seqb:   .byte "TYPE  SEQ (FROM THE BOARD)", 0
fs_prgg:   .byte "TYPE  PRG (GUESSED)", 0
fs_seqg:   .byte "TYPE  SEQ (GUESSED)", 0
fs_prgf:   .byte "TYPE  PRG (A PROGRAM; BOARD SAID SEQ)", 0
fs_from:   .byte "FROM THE BOARD'S SCREEN", 0
fs_keys:   .byte "RETURN SAVES  CRSR PICKS  TYPE TO EDIT", 0
fs_disc:   .byte "<- DISCARDS THE FILE", 0
fs_exists: .byte "THAT NAME EXISTS. REPLACE IT? Y/N", 0
fs_zip:    .byte "A ZIPCODE DISK PART: KEEP THE N! NAME", 0
bm_cr:     .res 8
.segment "XFR"

; ---- texts
xt_down:    .byte "ZENCOM  DOWNLOAD", 0
xt_up:      .byte "ZENCOM  UPLOAD", 0
xl_proto:   .byte "PROTOCOL", 0
xv_proto:   .byte "X XMODEM (RETURN)  K 1K  P PUNTER", 0
xv_protp:   .byte "P PUNTER (RETURN)  X XMODEM  K 1K", 0
xs_xmodem:  .byte "XMODEM", 0
xs_x1k:     .byte "XMODEM-1K", 0
xs_punter:  .byte "PUNTER", 0
xl_name:    .byte "FILE NAME", 0
xl_blocks:  .byte "BLOCKS", 0
xl_bytes:   .byte "BYTES", 0
xl_retries: .byte "RETRIES", 0
xs_waitsend: .byte "WAITING FOR THE BOARD TO SEND...", 0
xs_waitask: .byte "WAITING FOR THE BOARD TO ASK...", 0
xs_sent:    .byte "SENT", 0
xs_bytes:   .byte " BYTES", 0
xs_nofiles: .byte "NOTHING IN THIS FOLDER", 0
xs_cantsend: .byte "ONLY PRG, SEQ AND USR FILES CAN BE SENT", 0
xs_dollar:  .byte "$"
xm_drive:   .byte "DRIVE:", 0
xf_cancel:  .byte "<- CANCELS", 0
xf_anykey:  .byte "PRESS A KEY", 0
xf_pick:    .byte "RETURN SEND/OPEN  DEL UP  D DRIVE", 0
xf_here:    .byte "RETURN OPEN DEL UP D DRIVE S SAVE HERE", 0
xl_drive:   .byte "DRIVE", 0
xl_zc:      .byte "ZENCOM'S FOLDER", 0
xl_cur:     .byte "ITS CURRENT FOLDER", 0
xe_lo: .byte <xe1, <xe2, <xe3, <xe4, <xe5, <xe6
xe_hi: .byte >xe1, >xe2, >xe3, >xe4, >xe5, >xe6
xe1: .byte "NO ANSWER FROM THE BOARD", 0
xe2: .byte "TOO MANY ERRORS", 0
xe3: .byte "BLOCKS OUT OF ORDER", 0
xe4: .byte "CANCELLED BY THE BOARD", 0
xe5: .byte "CANCELLED", 0
xe6: .byte "DISK ERROR:", 0

; ---- variables (in the overlay: RAM under the BASIC ROM)
ses_ddev:   .byte 0             ; this session's download / upload drive
ses_udev:   .byte 0             ; (0: the settings)
x_dir:      .byte 0
x_bmode:    .byte 0
x_bdev:     .byte 0
x_odev:     .byte 0
x_hasold:   .byte 0
x_lok:      .byte 0
ls_row:     .byte 1
x_pdef:     .byte 0
x_auto:     .byte 0
dl_open:    .byte 0
pt_ftype:   .byte 0
t_dl:       .byte 0
t_dh:       .byte 0
x_t:        .byte 0, 0
x_cancel:   .byte 0
x_crnul:    .byte 0
crc_hi:     .byte 0
crc_lo:     .byte 0
x_sum:      .byte 0
x_n:        .byte 0, 0
xm_len:     .byte 0, 0
xm_blk:     .byte 0
xm_crc:     .byte 0
xm_hs:      .byte 0
xm_try:     .byte 0
xm_retries: .byte 0
xm_nblk:    .byte 0, 0
xm_bytes:   .byte 0, 0, 0
xm_err:     .byte 0
xm_pend:    .byte 0
x_plen:     .byte 0, 0
xo_len:     .byte 0, 0
x_b1:       .byte 0
x_b2:       .byte 0
x_c1:       .byte 0
x_c2:       .byte 0
x_strip:    .byte 0
x_cnt:      .byte 0
x_y:        .byte 0
x_nz:       .byte 0
x_mode:     .byte 0
x_type:     .byte 0
x_rw:       .byte 0
x_eof:      .byte 0
x_nfiles:   .byte 0
x_first:    .byte 0
x_sel:      .byte 0
x_row:      .byte 0
x_bl:       .byte 0
x_bh:       .byte 0
num:        .byte 0, 0, 0
x_proto:    .byte 0
x_want:     .byte 128
x_t1k:      .word 0         ; a 1K block's data bytes
x_force:    .byte 0         ; T on the start screen: 0 guess, 1 PRG, 2 SEQ
pt_tok:     .byte 0, 0, 0
pt_i:       .byte 0
pt_k:       .byte 0
pt_err:     .byte 0
pt_tmo:     .byte 0
pt_snd:     .byte 0, 0
pt_want:    .byte 0, 0
pt_len:     .byte 0
pt_add:     .byte 0, 0
pt_cyc:     .byte 0, 0
pt_phase:   .byte 0
pt_done:    .byte 0
pt_unacked: .byte 0
pt_blk:     .byte 0, 0
pt_blen:    .byte 0
pt_nrx:     .byte 0
pt_patience: .byte 10
x_dl2:      .byte 0
x_dh2:      .byte 0
numbuf:     .res 10
