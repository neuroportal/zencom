# ZenCom - build with the cc65 suite (brew install cc65 / apt install cc65)
CA65 = ca65
LD65 = ld65
EXO  = exomizer   # brew install exomizer: packs the .prg (build/zencom.prg is the plain one)

all: dist/zencom.prg

dist/zencom.prg: src/zencom.s src/xfr.s src/font.inc src/screens.inc src/zencom.cfg tools/ovlcheck.py
	mkdir -p build dist
	$(CA65) -t none -g -I src src/zencom.s -o build/zencom.o -l build/zencom.lst
	$(LD65) -C src/zencom.cfg -Ln build/zencom.lbl -o build/zencom.prg build/zencom.o
	python3 tools/ovlcheck.py      # the overlay rules (see ovl_menu)
	$(EXO) sfx sys -q -n -o $@ build/zencom.prg   # -n: no flashing corner character

font: tools/gen_font.py
	python3 tools/gen_font.py > src/font.inc

src/screens.inc: tools/gen_screens.py VERSION
	python3 tools/gen_screens.py > $@

screens: src/screens.inc

VER := $(shell tr A-Z a-z < VERSION)
D64 := build/zencom-$(VER).d64

# the release disk: ZENCOM, ZENCOM.XFR, a starter BBSLIST, READER (shows
# the next three), the read-me (without the build section), a quick
# reference, the licence, and ZENCOM.CFG/.MAC/.PWD holding only the header
# line that says what each is for.  For a GitHub Release, not committed.  Needs VICE's c1541.
d64: $(D64)

$(D64): dist/zencom.prg data/bbslist.seq README.md docs/QUICKREF.md LICENSE tools/mkreadme.py tools/reader.bas Makefile
	mkdir -p build
	python3 tools/mkreadme.py README.md build/readme.seq
	python3 tools/mkreadme.py docs/QUICKREF.md build/quickref.seq
	python3 tools/mkreadme.py LICENSE build/licence.seq
	petcat -w2 -o build/reader.prg -- tools/reader.bas
	printf '#ZENCOM SETTINGS (S ON THE MENU)\n' > build/empty.cfg
	printf '#ZENCOM MACROS (M ON THE MENU), PLAIN TEXT\n' > build/empty.mac
	printf '#ZENCOM LOGINS (E IN THE DIRECTORY): KEY|USER|PASSWORD\n' > build/empty.pwd
	rm -f $@
	c1541 -format "zencom $(VER),zc" d64 $@ \
	  -write dist/zencom.prg zencom \
	  -write dist/zencom.xfr zencom.xfr \
	  -write data/bbslist.seq bbslist,s \
	  -write build/reader.prg reader \
	  -write build/readme.seq readme,s \
	  -write build/quickref.seq quickref,s \
	  -write build/licence.seq licence,s \
	  -write build/empty.cfg zencom.cfg,s \
	  -write build/empty.mac zencom.mac,s \
	  -write build/empty.pwd zencom.pwd,s > /dev/null
	c1541 -attach $@ -list 2>/dev/null | grep -v '^Unit\|^D64\|OPENCBM'

clean:
	rm -rf build

.PHONY: all font screens clean d64

# The C64 Ultimate's address for the hardware tools: set C64_IP, or put
#   C64_IP = 192.168.1.64
# in local.mk (git-ignored).
-include local.mk

check-ip:
	@test -n "$(C64_IP)" || { echo "Set C64_IP (or put C64_IP = <address> in local.mk)"; exit 1; }

run: dist/zencom.prg check-ip
	curl -X POST --data-binary @$< http://$(C64_IP)/v1/runners:run_prg

hwtest: dist/zencom.prg check-ip
	C64_IP=$(C64_IP) python3 tools/hwtest.py

hwtest-online: dist/zencom.prg check-ip
	C64_IP=$(C64_IP) python3 tools/hwtest.py --online

bbslist: check-ip
	C64_IP=$(C64_IP) python3 tools/bbslist.py upload

.PHONY: run hwtest hwtest-online bbslist check-ip
