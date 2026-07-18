## tcodecs.nim — gzip, Brotli, and Zstandard round-trips, plus the maxSize
## decompression cap and the try* success/failure signal.

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

  # --- round-trips through all three codecs ---
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

  # --- try* variants round-trip and report ok=true ---
  let tg = tryGzipDecompress(gz)
  check(tg.ok and tg.data == original, "tryGzipDecompress round-trip")
  let tgc = tryGzipCompress(original)
  check(tgc.ok and gzipDecompress(tgc.data) == original, "tryGzipCompress round-trip")
  let tb = tryBrotliDecompress(br)
  check(tb.ok and tb.data == original, "tryBrotliDecompress round-trip")
  let tz = tryZstdDecompress(zs)
  check(tz.ok and tz.data == original, "tryZstdDecompress round-trip")

  # --- maxSize cap rejects an over-large gzip payload (decompression bomb) ---
  # `gz` inflates to ~22 KB; a 1 KB cap must abort.
  let capped = tryGzipDecompress(gz, maxSize = 1000)
  check(not capped.ok, "maxSize cap should reject over-large gzip (ok)")
  check(capped.data.len == 0, "capped decompress must yield no data")
  check(gzipDecompress(gz, maxSize = 1000).len == 0, "string wrapper honours maxSize cap")
  # The same payload succeeds under a generous cap.
  let uncapped = tryGzipDecompress(gz, maxSize = 1024 * 1024)
  check(uncapped.ok and uncapped.data == original, "generous cap should still succeed")

  # --- try* distinguishes FAILURE from legitimately-EMPTY ---
  # Genuine failure: garbage that is not a gzip stream.
  let fail = tryGzipDecompress("this is definitely not a gzip stream!!")
  check(not fail.ok, "garbage input must report ok=false")
  check(fail.data.len == 0, "failed op must yield no data")
  # Empty input: success with empty data (ok=true), NOT a failure.
  let emptyDec = tryGzipDecompress("")
  check(emptyDec.ok and emptyDec.data.len == 0, "empty input decompress → ok=true, empty data")
  let emptyEnc = tryGzipCompress("")
  check(emptyEnc.ok and emptyEnc.data.len == 0, "empty input compress → ok=true, empty data")
  check(tryBrotliCompress("").ok, "empty brotli compress → ok=true")
  check(tryZstdCompress("").ok, "empty zstd compress → ok=true")
  check(tryBrotliDecompress("").ok and tryZstdDecompress("").ok, "empty br/zstd decompress → ok=true")
  # The old "" sentinel is genuinely ambiguous — prove both paths return "".
  check(gzipDecompress("this is definitely not a gzip stream!!").len == 0, "string API: failure → \"\"")
  check(gzipDecompress("").len == 0, "string API: empty → \"\" (same as failure — the ambiguity)")

  echo "tcodecs: all checks passed"

main()
