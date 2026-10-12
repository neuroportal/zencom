# ZenCom quick reference

ZenCom was built to make browsing and using BBSes as easy as possible,
especially if you have never used one before.

## Getting on a board

1. `LOAD"ZENCOM",8` then `RUN` (ZENCOM.XFR must be on the same disk).
2. Press **F1** (PETSCII, for C64 boards) or **F2** (ANSI, for PC-style
   boards). Or press **1**-**4** for your modem, then **A** or **P**.
3. Type `ATD host:port` and Return, for example `ATD bbs.example.com:23`.
   Or press **D** on the menu, pick a board and press Return.
4. **F5** hangs up and goes back to the menu.

## Menu

| Key | |
|---|---|
| 1 | SwiftLink / Ultimate modem |
| 2 / 3 | User-port modem, 1200 / 2400 |
| 4 | UP9600 (beta) |
| F1 / F2 | Quick start: PETSCII / ANSI |
| D | Dialling directory |
| S | Settings (drives, folders, speed) |
| M | Macros |
| H | Help |
| Q | Quit to BASIC |

## During a call

| Key | |
|---|---|
| F1 | ESC (ANSI) |
| F3 | Colour on/off (ANSI) |
| F4 | Redial |
| F5 | Hang up, menu |
| F6 | Auto redial every minute |
| F7 | Switch ANSI / PETSCII |
| F8 | Swap case of the board's text |
| C= D | Download |
| C= U | Upload |
| C= N | Send username |
| C= P | Send password |
| C= M, 1-8 | Send a macro |
| C= S | Pause / carry on |
| C= L | Lower case lock (PETSCII) |
| C= B | Scroll back (PETSCII) |
| C= H | Help |

## Downloading (C= D)

Return starts it (ZenCom picks the protocol). **X** XMODEM, **P** Punter,
**M** Multi-Punter batch, **T** file type, **L** where it goes,
**←** back to the board. At the end, confirm the name with Return.

## Uploading (C= U)

Pick the file, Return, then **X** XMODEM, **K** XMODEM-1K or **P** Punter.

## Directory (D)

Return dials. **A** add, **E** edit, **X** delete, **B** bookmark,
**I** info, **+**/**-** page, **←** back.

**Logins:** E on a board takes a username and password. Dial it from
here, then C= N / C= P send them. Kept in ZENCOM.PWD as plain text.

## Macros (M)

Eight lines; `^` sends Return. In a call: C= M, then 1-8. Kept in
ZENCOM.MAC as plain text.

## The manual

`LOAD"READER",8` and `RUN` shows README, this page and the licence.

## If something goes wrong

- Modem says ERROR: check Shift Lock is off, type it again.
- Menu says ZenCom's files not found: ZENCOM.XFR isn't with ZENCOM.
- Board looks wrong: try F7 (the other mode) or F8 (swap case).

zencom@neuroportal.net
