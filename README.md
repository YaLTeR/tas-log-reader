# TAS Log Reader

TAS Log Reader, Zig version.

Purpose:

- Get acquainted with Zig
- Get acquainted with lower-level GObject
- I know about undefined behavior and use it to my advantage

## Usage

Build and run: `zig build run -- ./example-tas-log.log`

Build with Tracy and optimizations:

```
zig build -Dtracy="/path/to/tracy-0-14-checkout/" -Doptimize=ReleaseFast
```
