## tcodecs.nim — gzip, Brotli, and Zstandard round-trips.

import std/syncio
import compress

proc check(cond: bool; msg: string) =
  if not cond:
    echo "FAIL: ", msg
    quit(1)

proc sample(): string =
  result = ""
  var i = 0
  while i < 500:
    result.add "the quick brown fox jumps over the lazy dog. "
    inc i

proc main =
  let original = sample()

  let gz = gzipCompress(original)
  check(gz.len > 2 and gz.len < original.len, "gzip did not shrink")
  check(uint8(ord(gz[0])) == 0x1f'u8 and uint8(ord(gz[1])) == 0x8b'u8, "not a gzip stream")
  check(gzipDecompress(gz) == original, "gzip round-trip mismatch")
  echo "gzip: ", original.len, " -> ", gz.len

  let br = brotliCompress(original)
  check(br.len > 0 and br.len < original.len, "brotli did not shrink")
  check(brotliDecompress(br) == original, "brotli round-trip mismatch")
  echo "br:   ", original.len, " -> ", br.len

  let zs = zstdCompress(original)
  check(zs.len > 0 and zs.len < original.len, "zstd did not shrink")
  check(zstdDecompress(zs) == original, "zstd round-trip mismatch")
  echo "zstd: ", original.len, " -> ", zs.len

  echo "tcodecs: all checks passed"

main()
