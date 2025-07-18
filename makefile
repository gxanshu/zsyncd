.PHONY: build release clean

build:
	zig build -Doptimize=Debug

release:
	zig build -Doptimize=ReleaseFast

clean:
	rm -rf .zig-cache zig-out
