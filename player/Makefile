LIBUSB_CFLAGS = -I/opt/homebrew/include/libusb-1.0
LIBUSB_LDFLAGS = -L/opt/homebrew/lib -lusb-1.0

all: psvr2player

cpsvr2.o: cpsvr2.c cpsvr2.h
	clang -O2 -Wall $(LIBUSB_CFLAGS) -c cpsvr2.c -o cpsvr2.o

lut.o: lut.c
	clang -O2 -c lut.c -o lut.o

psvr2player: main.swift overlay.swift cpsvr2.o lut.o cpsvr2.h
	swiftc -O -import-objc-header cpsvr2.h main.swift overlay.swift cpsvr2.o lut.o \
		$(LIBUSB_LDFLAGS) \
		-framework AppKit -framework Metal -framework MetalKit \
		-framework AVFoundation -framework CoreAudio -framework CoreVideo \
		-o psvr2player

clean:
	rm -f psvr2player cpsvr2.o lut.o

.PHONY: all clean
