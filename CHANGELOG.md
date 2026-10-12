# Changelog

ZenCom follows semantic versioning (MAJOR.MINOR.PATCH): PATCH for fixes,
MINOR for new features that break nothing, MAJOR for changes that break
something existing (for example the settings file or BBS list format).
The version lives in `VERSION` and is shown on the menu and help screens.
Until 1.0.0, 0.x versions may still change things.

## 0.9.0 (2026-10-12)

The first public release, renumbered: the 1.1-1.5.0 below were private
development versions, numbered before any release was planned.  0.9.0
is 1.5.0 plus the fixes after it; 1.0.0 will be the first stable release.

### Added since 1.5.0
- Per-board logins: the directory's edit form takes a username and
  password (shown as *); dial the board from the directory, then C= N /
  C= P send them.  Kept in ZENCOM.PWD (plain text), keyed by a CRC-32
  fingerprint of the address so the file names no board; a login only
  goes to the address it was saved for.  Kept through redials, forgotten
  at the menu.  Deleting a board removes its login.
- The menu says which mode suits which boards; each session opens with
  where help is (C= H) and how to get back (F5).
- XMODEM-1K uploads: K on the upload screen (1024-byte blocks with CRC).
- The download's type: T on the start screen chooses PRG or SEQ instead of
  the guess (a drive can't change a file's type afterwards).

### Changed since 1.5.0
- Every file ZenCom writes starts with a # line saying what it is and where
  to edit it (BBSLIST, ZENCOM.CFG, ZENCOM.MAC, ZENCOM.PWD); # lines are
  skipped when read.  The disk carries all of them, the last three holding
  just that line, and READER, a small BASIC program that shows README,
  QUICKREF and LICENCE a page at a time.
- The scroll-back is emptied and wiped when you go back to the menu, as the
  typed text is (passwords a board echoes).
- Menu: A and P share a row, so the four connections fit with space.
- UP9600 ships marked (BETA) on the menu (option 4): it
  sends correctly in VICE, but VICE's UP9600 emulation garbles received
  text for every driver (CCGMS's too), and no real UP9600 modem has tried
  it yet.  Reports welcome.
- Macros live in their own file, ZENCOM.MAC (beside ZENCOM.CFG), so the
  settings can be shared without them.  Same `M1=`..`M8=` lines, saved the
  same safe way.

## 1.5.0 (2026-10-11)

### Added
- Macros: M on the menu edits eight macros of up to 31 characters (^ sends
  Return; case is kept). In a call, C=+M then 1-8 sends one (yellow border
  while it waits for the digit). Kept as `M1=`..`M8=` lines in ZENCOM.CFG,
  as plain text.
- SwiftLink speed: settings screen and `SPEED=` in ZENCOM.CFG (1200, 2400,
  4800, 9600, 19200, 38400; blank = 9600).
- Multi-Punter downloads: C=+D, then M, receives a batch, each file saved
  under the name the board sends (unsafe characters become -).
- UP9600 user-port driver (menu option 4, 9600 baud). **Untested on real
  hardware**: sending works in VICE, but VICE's UP9600 emulation garbles
  received text (CCGMS notes the same), so receiving is unproven.

### Changed
- The typed line and the name kept from it are wiped (not just
  forgotten) when a call ends or you go back to the menu (passwords).

Older ZENCOM.CFG files load as before; older versions ignore the new lines.

## 1.4.7 (2026-10-11)

### Changed (room for new features; nothing should look different)
- The dialling directory, board editor, settings screen and list/settings
  saving moved into a menu overlay (3.5 KB) carried in ZENCOM.XFR. It is
  parked in the RAM under the I/O chips and swapped with the transfer code
  only while those screens are open (~0.1 s). The main program's code area
  now has 4.6 KB free (it had 203 bytes).
- The main program's code now runs on to $43FF (1 KB the VIC never reads).
- `make` checks the overlay rules (`tools/ovlcheck.py`).
- Without ZENCOM.XFR, D and S on the menu now do nothing (the menu already
  says ZenCom's files were not found).
- ZENCOM.XFR is 9.9 KB (was 5.8); ZENCOM is 11.0 KB (was 12.9).

## 1.4.6 (2026-10-11)

### Fixed (from a download on Retro Campus)
- The typed name kept its first word: only a download command (D, DL) is
  dropped now, so "a mind is born" stays "A MIND IS BORN".
- Return picks XMODEM when the board has just mentioned XMODEM, even in a
  PETSCII session (Punter stays the default otherwise there).
- "PLEASE START XMODEM TRANSFER" brings the "press C=+D" nudge.

## 1.4.5 (2026-10-11)

### Changed
- No built-in list of boards: with no BBS list file the directory starts
  empty ("NO LIST YET: A ADDS"); the starter list ships beside ZenCom.
- The help page is one colour below its title bar.
- Unused code and texts removed: about 500 bytes freed for new features.

## 1.4.4 (2026-10-11)

### Fixed
- No "press C=+D" nudge when the board says "start your XMODEM upload":
  it is waiting for you to send. The nudge is shorter, so it fits a
  40-column line: "-- Board may be sending: press C=+D --".

## 1.4.3 (2026-10-11)

### Fixed
- Downloads and uploads failed on real Commodore drives (1541 and others):
  ZenCom checked the drive's status by opening and closing its command
  channel while the file was open, and closing the command channel closes
  every file on the drive. Found in VICE; confirmed fixed on the Ultimate's
  1541 emulation.
- XMODEM uploads from a slow drive: requests the board sent while the
  drive was opening the file piled up and put ZenCom out of step. ZenCom
  now follows the board's latest request, and drops to checksum mode if
  the first block is refused.
- The "board may be ready to send" nudge waits for the end of the board's
  line instead of splitting it.
- User port: received bytes are read straight from the RS-232 buffer
  (fewer lost characters in VICE at 1200 baud; still not reliable there).

### Added
- `tools/vicetest.py`: ZenCom in VICE with a stock 1541 and a SwiftLink or
  user-port modem (`tools/vice_modem.py`), PAL or NTSC.
- `tools/hwtest_1541.py`: the same transfers on the C64 Ultimate from a
  1541 disk image in drive 8.

## 1.4.2 (2026-10-11)

### Fixed
- The download's guessed name was often a one-letter answer ("P", "Y"):
  boards ask for the protocol or "are you sure?" after the file name, and
  the last line typed won. ZenCom now remembers the last typed line that
  could be a name (4+ characters with a letter, not an AT command), and
  drops a leading command word ("D SKATE.PRG" -> SKATE.PRG).

## 1.4.1 (2026-10-11)

### Added
- MIT licence. The help page shows the copyright and the contact address,
  zencom@neuroportal.net.

## 1.4.0 (2026-10-11)

### Added
- Scroll-back (C=+B) keeps pages the board clears, not only lines that
  scroll off the top: most C64 boards clear the screen between pages, so
  scroll-back used to show only older text.

## 1.3.2 (2026-10-11)

### Fixed
- The settings screen's hint about folders lost its last letters.

## 1.3.1 (2026-10-11)

### Fixed
- The screen went black for half a second on each auto-redial blip (seen
  over HDMI): the sound chip's volume now stays up between sounds rather
  than going from off to full each time.

## 1.3.0 (2026-10-10)

### Added
- ANSI: insert, delete and erase character (CSI @ / P / X).
- ANSI: cursor up and down stop at the scroll region's edges, as on a VT100.
- A nudge ("the board may be ready to send: press C=+D") when the board's
  text says "receive mode", "start your" or "begin your", for boards that
  use XMODEM as well as Punter.

## 1.2.0 (2026-10-10)

Everything since 1.1 (2026-10-08).

### Added
- File transfers: XMODEM (CRC, 1K, checksum) and Punter, download and
  upload, from a separate transfer file (`ZENCOM.XFR`).
- Downloads as a round trip: C=+D shows where the file goes (L to change),
  the guessed name and the protocol, and waits for Return. You name the
  file at the end, picked from the board's own screen, then return to the
  board's screen as you left it, with one line saying what happened.
- A nudge when a C64 board starts sending Punter ("press C=+D").
- The file type is checked: a file that starts like a BASIC program is
  saved as PRG even if the board says SEQ.
- Folder browser on the transfer screens; short folder names in settings
  are folders inside ZenCom's own folder.
- Settings (S on the menu): drives and folders for the BBS list,
  downloads, uploads and ZenCom's own files.
- C=+S pause, C=+B scroll-back (PETSCII), C=+H help during a call, C=+L
  lower-case lock (PETSCII).
- ANSI: scroll regions, reverse scroll, insert/delete line.
- Auto-redial blip; F3 monochrome repaints the whole screen.
- Q on the menu quits to BASIC with a proper reset.
- The menu warns when ZenCom's own files aren't found.
- A smaller, packed program file that loads in about half the time.

### Fixed
- A stray "call ended" straight after CONNECT on the next call.
- Telnet settings no longer carry over from one call to the next.
- Folders on the Ultimate's SD card (going up a level).
- C=+shift no longer flips the character set mid-session.

## 1.1 (2026-10-08)

The first version shown on screen: ANSI-80 and PETSCII-40 terminal,
telnet, BBS directory, redial and auto-redial, hang-up, help.
