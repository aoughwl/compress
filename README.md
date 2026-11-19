> **Moved.** This library now lives in [aoughwl/std](https://github.com/aoughwl/std/tree/main/compress) (directory `compress/`), with its full history. This repository is kept as a redirect; new work happens in `aoughwl/std`.

# compress

**One-shot compression codecs** for the [aoughwl](https://aoughwl.github.io)
stack — gzip, Brotli, and Zstandard — over the system libraries. Protocol-
agnostic `string → string`: no streaming state, no HTTP assumptions.

```nim
import compress

let gz = gzipCompress("...")          # Content-Encoding: gzip
let back = gzipDecompress(gz)
let br = brotliCompress("...")        # Content-Encoding: br
let zs = zstdCompress("...")          # Content-Encoding: zstd
```

## What it does

| Codec | Functions | Library |
|---|---|---|
| gzip / zlib | `gzipCompress` / `gzipDecompress` | `libz.so.1` |
| Brotli | `brotliCompress` / `brotliDecompress` | `libbrotlienc` / `libbrotlidec` |
| Zstandard | `zstdCompress` / `zstdDecompress` | `libzstd.so.1` |

Each is a single call over an in-memory `string`. Decompressors are bounded by a
`maxSize` argument. `""` signals an error (bad input, library failure).

## Why its own repo

The codecs are general-purpose: [`http`](https://github.com/aoughwl/http) layers
`Content-Encoding` negotiation (`pickEncoding` / `encodeFor`) on top for HTTP, but
a WebSocket (`permessage-deflate`), an on-disk blob store, or any binary protocol
can depend on just this package without pulling in HTTP.

## Design notes

- The zlib `z_stream` struct is hand-laid to the LP64 C ABI (no zlib headers
  needed); gzip uses window bits 31 (deflate) / 47 (auto-detect inflate).
- Brotli and Zstd use their one-shot APIs (`BrotliEncoderCompress`,
  `ZSTD_compress`), sized via `BrotliEncoderMaxCompressedSize` / `ZSTD_compressBound`.

## Testing

```
nimony c -r --path:. tests/tcodecs.nim
```

Round-trips a compressible sample through all three codecs (verifying each shrinks
it and restores it byte-for-byte; gzip additionally checks the `1f 8b` magic).

## Requirements

Nimony; `libz`, `libbrotlienc`/`libbrotlidec`, `libzstd` (all standard on Linux).

## License

MIT.
