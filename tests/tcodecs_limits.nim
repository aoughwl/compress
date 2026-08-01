## tcodecs_limits.nim — the decompression cap still holds after the buffers
## stopped being pre-sized to it.
##
## `maxSize` is a LIMIT on the decompressed output. It used to be implemented by
## allocating exactly that many bytes up front, so a 100-byte payload cost
## 16 MiB. zstd now reads the size from the frame header and brotli grows into
## it — which means the cap is enforced by explicit checks rather than by the
## buffer simply being too small, so it needs its own test.

import std/syncio
import compress

proc check(ok: bool; msg: string) =
  if not ok:
    echo "FAIL: ", msg
    quit(1)

proc payload(n: int): string =
  ## Compressible but not trivially so, so the codecs actually emit a frame.
  result = ""
  var i = 0
  while i < n:
    result.add char(ord('a') + (i mod 26))
    inc i

proc main =
  let small = payload(64)
  let big = payload(100000)

  # --- round-trips are exact at both ends of the size range --------------
  for original in [small, big]:
    let g = gzipCompress(original)
    check(g.len > 0, "gzip compress")
    check(gzipDecompress(g) == original, "gzip round-trip")

    let b = brotliCompress(original)
    check(b.len > 0, "brotli compress")
    check(brotliDecompress(b) == original, "brotli round-trip")

    let z = zstdCompress(original)
    check(z.len > 0, "zstd compress")
    check(zstdDecompress(z) == original, "zstd round-trip")

  # --- the cap is still enforced ----------------------------------------
  # 100000 bytes of output against a 1000-byte cap must fail, not truncate.
  let gb = gzipCompress(big)
  let bb = brotliCompress(big)
  let zb = zstdCompress(big)

  let gr = tryGzipDecompress(gb, 1000)
  check(not gr.ok, "gzip must refuse output past maxSize")

  let br = tryBrotliDecompress(bb, 1000)
  check(not br.ok, "brotli must refuse output past maxSize")

  let zr = tryZstdDecompress(zb, 1000)
  check(not zr.ok, "zstd must refuse output past maxSize")
  check(zr.data.len == 0, "no partial data on a refused zstd decompress")

  # a cap exactly at the payload size still succeeds (off-by-one guard)
  let zexact = tryZstdDecompress(zb, big.len)
  check(zexact.ok and zexact.data == big, "zstd cap exactly at output size")
  let bexact = tryBrotliDecompress(bb, big.len)
  check(bexact.ok and bexact.data == big, "brotli cap exactly at output size")

  # --- garbage in, clean failure out ------------------------------------
  check(not tryZstdDecompress("not a zstd frame at all").ok, "zstd garbage")
  check(not tryBrotliDecompress("\xff\xff\xff\xff\xff\xff").ok, "brotli garbage")

  echo "tcodecs_limits: all checks passed"

main()
