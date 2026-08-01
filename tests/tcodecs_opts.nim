## tcodecs_opts.nim — codec parameters as a record.
##
## The assertions that matter here are about the *bytes on the wire*, not about
## a call succeeding. `windowBits` was a literal 31, so gzip was the only zlib
## format this library could produce: `Content-Encoding: deflate` could not be
## offered and raw deflate — what permessage-deflate needs — was unreachable.
## Checking that a raw-deflate call "returned ok" would not have caught that,
## because it returned ok before too, with gzip bytes. So each format is
## identified by its actual header.

import std/syncio
import compress

proc check(ok: bool; msg: string) =
  if not ok:
    echo "FAIL: ", msg
    quit(1)

proc sample(): string =
  result = ""
  var i = 0
  while i < 3000:
    result.add "the quick brown fox jumps over the lazy dog "
    inc i

proc main =
  let data = sample()

  # --- the record restates the old literals exactly -----------------------
  # If defaultCodecOpts() drifted from what the call sites used to hardcode,
  # these two would differ. That is the property that makes it a safe base.
  let viaLiteral = gzipCompress(data)
  let viaRecord = deflateCompress(data, defaultCodecOpts())
  check(viaRecord == viaLiteral,
        "defaultCodecOpts must reproduce the previous hardcoded parameters")

  # --- gzip, identified by its header -------------------------------------
  check(viaLiteral.len > 2, "gzip output is non-trivial")
  check(viaLiteral[0] == '\x1f' and viaLiteral[1] == '\x8b',
        "gzip output carries the gzip magic")

  # --- zlib wrapper: what Content-Encoding: deflate actually means ---------
  let zlibBytes = deflateCompress(data, zlibDeflateOpts())
  check(zlibBytes.len > 2, "zlib output is non-trivial")
  check(zlibBytes[0] == '\x78',
        "zlib output carries a zlib CMF byte, not the gzip magic")
  check(not (zlibBytes[0] == '\x1f' and zlibBytes[1] == '\x8b'),
        "the format really changed rather than the call merely succeeding")
  check(deflateDecompress(zlibBytes, zlibDeflateOpts()) == data,
        "zlib-wrapped deflate round-trips")

  # --- raw deflate: no wrapper at all -------------------------------------
  let rawBytes = deflateCompress(data, rawDeflateOpts())
  check(rawBytes.len > 0, "raw deflate produced output")
  check(not (rawBytes[0] == '\x1f' and rawBytes[1] == '\x8b'),
        "raw deflate is not gzip")
  check(rawBytes[0] != '\x78', "raw deflate has no zlib wrapper either")
  check(deflateDecompress(rawBytes, rawDeflateOpts()) == data,
        "raw deflate round-trips")

  # A raw payload must not decode as a wrapped one; that is the whole point of
  # deriving the inflate window from the compressor's format.
  check(deflateDecompress(rawBytes, defaultCodecOpts()) == "",
        "raw bytes do not decode under the gzip/zlib auto-detect window")

  # --- levels are reachable and do something ------------------------------
  let fast = deflateCompress(data, fastCodecOpts())
  let best = deflateCompress(data, bestCodecOpts())
  check(fast.len > 0 and best.len > 0, "both levels produced output")
  check(best.len <= fast.len, "level 9 is not larger than level 1")
  check(deflateDecompress(fast, fastCodecOpts()) == data, "level 1 round-trips")
  check(deflateDecompress(best, bestCodecOpts()) == data, "level 9 round-trips")

  # --- brotli mode and window are reachable -------------------------------
  var textMode = defaultCodecOpts()
  textMode.brotliMode = 1              # BROTLI_MODE_TEXT
  textMode.brotliWindow = 20
  let brText = brotliCompress(data, textMode)
  check(brText.len > 0, "brotli text mode produced output")
  check(brotliDecompress(brText, defaultCodecOpts()) == data,
        "brotli text mode round-trips")

  # --- zstd through the record --------------------------------------------
  let z = zstdCompress(data, bestCodecOpts())
  check(z.len > 0, "zstd produced output")
  check(zstdDecompress(z, defaultCodecOpts()) == data, "zstd round-trips")

  # --- merge --------------------------------------------------------------
  var over = noCodecOpts()
  over.level = 1
  let merged = merge(defaultCodecOpts(), over)
  check(merged.level == 1, "the set field overrides")
  check(merged.windowBits == WindowGzip, "unset fields keep the base value")
  check(merged.maxSize == DefaultMaxSize, "including the cap")

  # The sentinel has to sit outside every valid range: raw deflate is a
  # negative windowBits, so -1 would have been unusable as "unset".
  check(CodecUnset != WindowRaw, "the unset sentinel is not a real window value")
  var rawOver = noCodecOpts()
  rawOver.windowBits = WindowRaw
  check(merge(defaultCodecOpts(), rawOver).windowBits == WindowRaw,
        "a negative field value still merges as set")

  # --- the cap still bites, through the record ----------------------------
  var tiny = defaultCodecOpts()
  tiny.maxSize = 1024
  check(deflateDecompress(viaLiteral, tiny) == "",
        "a payload inflating past the cap is refused")
  check(capOr(noCodecOpts()) == DefaultMaxSize, "an unset cap resolves to the default")

  echo "tcodecs_opts: all checks passed"

main()
