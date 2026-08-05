LIBUSB_CFLAGS = -I/opt/homebrew/include/libusb-1.0
LIBUSB_LDFLAGS = -L/opt/homebrew/lib -lusb-1.0

APP = PSVR2Player.app

all: $(APP)

cpsvr2.o: cpsvr2.c cpsvr2.h
	clang -O2 -Wall $(LIBUSB_CFLAGS) -c cpsvr2.c -o cpsvr2.o

lut.o: lut.c
	clang -O2 -c lut.c -o lut.o

psvr2player: main.swift overlay.swift sweeper.swift cpsvr2.o lut.o cpsvr2.h
	swiftc -O -import-objc-header cpsvr2.h main.swift overlay.swift sweeper.swift cpsvr2.o lut.o \
		$(LIBUSB_LDFLAGS) \
		-framework AppKit -framework Metal -framework MetalKit \
		-framework AVFoundation -framework CoreAudio -framework CoreVideo \
		-o psvr2player

# Бандл нужен не только для запуска из Finder: без Info.plist macOS не может
# показать запрос доступа к внешним дискам, и чтение тома зависает навсегда
$(APP): psvr2player Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	cp psvr2player $(APP)/Contents/MacOS/psvr2player
	codesign --force --deep --sign - $(APP)
	@echo "Готово: $(APP) — запуск ./play [файл]"

clean:
	rm -rf psvr2player cpsvr2.o lut.o $(APP)

.PHONY: all clean
