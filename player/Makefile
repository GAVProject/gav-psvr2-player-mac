BREW_PREFIX := $(shell brew --prefix)
LIBUSB_CFLAGS = -I$(BREW_PREFIX)/include/libusb-1.0
LIBUSB_LDFLAGS = -L$(BREW_PREFIX)/lib -lusb-1.0

APP = PSVR2Player.app

all: $(APP)

cpsvr2.o: cpsvr2.c cpsvr2.h
	clang -O2 -Wall $(LIBUSB_CFLAGS) -c cpsvr2.c -o cpsvr2.o

lut.o: lut.c
	clang -O2 -c lut.c -o lut.o

psvr2player: main.swift overlay.swift sweeper.swift meta.swift passthrough.swift cpsvr2.o lut.o cpsvr2.h
	swiftc -O -import-objc-header cpsvr2.h main.swift overlay.swift sweeper.swift meta.swift passthrough.swift cpsvr2.o lut.o \
		$(LIBUSB_LDFLAGS) \
		-framework AppKit -framework Metal -framework MetalKit \
		-framework AVFoundation -framework CoreAudio -framework CoreVideo \
		-o psvr2player

# The bundle is needed for more than launching from Finder: without Info.plist
# macOS cannot show the external-disk access prompt, and reading the volume hangs forever
$(APP): psvr2player Info.plist environment.jpg
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/Info.plist
	cp psvr2player $(APP)/Contents/MacOS/psvr2player
	cp environment.jpg $(APP)/Contents/Resources/environment.jpg
	codesign --force --deep --sign - $(APP)
	@echo "Done: $(APP) — run ./play [file]"

clean:
	rm -rf psvr2player cpsvr2.o lut.o $(APP)

.PHONY: all clean
