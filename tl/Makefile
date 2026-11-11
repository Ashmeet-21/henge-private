# Henge's translation layer for Mac apps: the loader and its tests (Mac).
# make -C tl test: each test program runs natively and through the loader, and the two outputs must match.
B = build
CC = xcrun clang
CFLAGS = -O2 -g -Wall -Wextra -Wno-unused-parameter -fblocks
GUEST = -target arm64-apple-macos13
LOADER = loader/tl_loader.c loader/tl_tlv.S

TESTS = $(B)/hello $(B)/hello-opcodes $(B)/fnd $(B)/fnd-opcodes $(B)/swifty $(B)/cxx $(B)/FW.app/Contents/MacOS/fwapp

all: $(B)/tlrun $(TESTS)

$(B):
	mkdir -p $(B)

$(B)/tlrun: tools/tlrun.c $(LOADER) loader/tl_loader.h | $(B)
	$(CC) $(CFLAGS) tools/tlrun.c $(LOADER) -o $@

$(B)/hello: tests/hello.c | $(B)
	$(CC) $(GUEST) -O1 $< -o $@
$(B)/hello-opcodes: tests/hello.c | $(B)
	$(CC) -target arm64-apple-macos11 -O1 -Wl,-no_fixup_chains $< -o $@
$(B)/fnd: tests/fnd.m | $(B)
	$(CC) $(GUEST) -O1 -fobjc-arc -framework Foundation $< -o $@
$(B)/fnd-opcodes: tests/fnd.m | $(B)
	$(CC) -target arm64-apple-macos11 -O1 -fobjc-arc -framework Foundation -Wl,-no_fixup_chains $< -o $@
$(B)/swifty: tests/swifty.swift | $(B)
	xcrun swiftc -target arm64-apple-macos13 -O -module-name swifty $< -o $@
$(B)/cxx: tests/cxx.cpp | $(B)
	$(CC) $(GUEST) -O1 -std=c++17 $< -lc++ -o $@

# An app bundle whose executable links a library inside it through @rpath.
$(B)/FW.app/Contents/MacOS/fwapp: tests/fwapp.m tests/fw.m | $(B)
	mkdir -p $(B)/FW.app/Contents/MacOS $(B)/FW.app/Contents/Frameworks
	$(CC) $(GUEST) -O1 -fobjc-arc -dynamiclib -install_name @rpath/libtlfw.dylib -framework Foundation tests/fw.m -o $(B)/FW.app/Contents/Frameworks/libtlfw.dylib
	$(CC) $(GUEST) -O1 -fobjc-arc -framework Foundation -rpath @executable_path/../Frameworks tests/fwapp.m $(B)/FW.app/Contents/Frameworks/libtlfw.dylib -o $@

test: all
	@fail=0; for t in $(TESTS); do \
	  native=$$($$t one two 2>/dev/null); loaded=$$(TLRUN_REPORT=1 $(B)/tlrun $$t one two 2>$(B)/stderr.txt); rc=$$?; \
	  if [ $$rc -eq 0 ] && [ "$$native" = "$$loaded" ] && echo "$$loaded" | grep -q '^PASS'; then echo "ok   $$t: $$(grep 'not in dyld' $(B)/stderr.txt | sed 's/.*bytes, //')"; \
	  else echo "FAIL $$t (exit $$rc)"; echo "  native: $$native"; echo "  loaded: $$loaded"; sed 's/^/  /' $(B)/stderr.txt; fail=1; fi; done; exit $$fail

clean:
	rm -rf $(B)

.PHONY: all test clean
