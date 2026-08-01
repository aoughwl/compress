## compress — one-shot general-purpose compression codecs for the aoughwl stack.
##
## Raw byte-string codecs over the system libraries: gzip/zlib (`libz.so.1`),
## Brotli (`libbrotlienc`/`libbrotlidec`), and Zstandard (`libzstd.so.1`). No
## streaming state — each call takes and returns a `string`. These are protocol-
## agnostic: `http` layers HTTP `Content-Encoding` negotiation on top, and any
## binary protocol (WebSocket permessage-deflate, on-disk blobs, …) can reuse
## them directly.
##
## Two API flavours per operation:
##
## * The string-returning procs (`gzipCompress`, `gzipDecompress`, …) return the
##   payload directly and signal failure with the empty string `""`. Convenient,
##   but a genuinely-empty result is indistinguishable from an error.
## * The `try*` procs (`tryGzipCompress`, `tryGzipDecompress`, …) return a small
##   `CompressResult` object carrying an explicit `ok` flag alongside `data`, so
##   a failure (`ok = false`) is unambiguous. Empty **input** always succeeds
##   with empty `data` (`ok = true`, `data = ""`). The string procs are thin
##   wrappers over these.
##
## Every decompressor is bounded by a `maxSize` cap (default 16 MiB) and aborts
## rather than materialise an oversized output — this closes the decompression-
## bomb hole where a tiny payload inflates to gigabytes.
##
## Streaming note: this package is deliberately one-shot — the whole input and
## output live in memory. A chunked/streaming codec (feeding fixed-size blocks
## through a retained `z_stream`/`ZSTD_DCtx`) is out of scope here; layer it in a
## separate API if you need to bound memory below `maxSize` for huge payloads.

type
  CompressResult* = object
    ## Outcome of a `try*` codec call. `ok` is the success signal; `data` is the
    ## payload. On failure `ok = false` and `data = ""`. On empty input
    ## `ok = true` and `data = ""` (a legitimately-empty success).
    ok*: bool
    data*: string

const DefaultMaxSize = 16 * 1024 * 1024   ## 16 MiB decompression cap.

const
  zlib = "libz.so.1"
  brotliEnc = "libbrotlienc.so.1"
  brotliDec = "libbrotlidec.so.1"
  zstdLib = "libzstd.so.1"

# ---------------------------------------------------------------------------
# gzip / zlib
# ---------------------------------------------------------------------------

type
  ZStream = object
    ## Matches the C `z_stream` layout on LP64 (size 112).
    nextIn: nil pointer      # 0
    availIn: uint32          # 8
    totalIn: uint            # 16
    nextOut: nil pointer     # 24
    availOut: uint32         # 32
    totalOut: uint           # 40
    msg: nil pointer         # 48
    state: nil pointer       # 56
    zalloc: nil pointer      # 64
    zfree: nil pointer       # 72
    opaque: nil pointer      # 80
    dataType: int32          # 88
    adler: uint              # 96
    reserved: uint           # 104

proc deflateInit2Raw(strm: ptr ZStream; level, meth, windowBits, memLevel, strategy: cint;
                   version: cstring; streamSize: cint): cint {.cdecl, importc: "deflateInit2_", dynlib: zlib.}
proc deflate(strm: ptr ZStream; flush: cint): cint {.cdecl, importc: "deflate", dynlib: zlib.}
proc deflateEnd(strm: ptr ZStream): cint {.cdecl, importc: "deflateEnd", dynlib: zlib.}
proc inflateInit2Raw(strm: ptr ZStream; windowBits: cint; version: cstring;
                   streamSize: cint): cint {.cdecl, importc: "inflateInit2_", dynlib: zlib.}
proc inflate(strm: ptr ZStream; flush: cint): cint {.cdecl, importc: "inflate", dynlib: zlib.}
proc inflateEnd(strm: ptr ZStream): cint {.cdecl, importc: "inflateEnd", dynlib: zlib.}
proc zlibVersion(): cstring {.cdecl, importc: "zlibVersion", dynlib: zlib.}

const
  Z_FINISH = cint(4)
  Z_NO_FLUSH = cint(0)
  Z_OK = cint(0)
  Z_STREAM_END = cint(1)
  Z_DEFLATED = cint(8)
  GZIP_WINDOW = cint(31)   # 15 (max window) + 16 (gzip wrapper)

proc tryGzipCompress*(data: string; level = 6): CompressResult =
  ## Compress `data` into the gzip format (`Content-Encoding: gzip`).
  ## Empty input → `ok = true`, empty `data`.
  result = CompressResult(ok: false, data: "")
  if data.len == 0:
    result.ok = true
    return result
  var strm = default(ZStream)
  if deflateInit2Raw(addr strm, cint(level), Z_DEFLATED, GZIP_WINDOW, cint(8), cint(0),
                   zlibVersion(), cint(sizeof(ZStream))) != Z_OK:
    return result
  var inCopy = data
  strm.nextIn = cast[pointer](toCString(inCopy))
  strm.availIn = uint32(data.len)
  var outBuf = default(array[16384, char])
  while true:
    strm.nextOut = addr outBuf[0]
    strm.availOut = uint32(outBuf.len)
    let rc = deflate(addr strm, Z_FINISH)
    let produced = outBuf.len - int(strm.availOut)
    var i = 0
    while i < produced:
      result.data.add outBuf[i]
      inc i
    if rc == Z_STREAM_END:
      break
    if rc < Z_OK:
      discard deflateEnd(addr strm)
      return CompressResult(ok: false, data: "")
  discard deflateEnd(addr strm)
  result.ok = true

proc gzipCompress*(data: string; level = 6): string =
  ## Compress `data` into the gzip format (`Content-Encoding: gzip`). "" on error.
  tryGzipCompress(data, level).data

proc tryGzipDecompress*(data: string; maxSize = DefaultMaxSize): CompressResult =
  ## Decompress a gzip (or zlib) payload, bounded by `maxSize`: if the inflated
  ## output would exceed `maxSize` the call aborts with `ok = false` (this closes
  ## the decompression-bomb hole). Empty input → `ok = true`, empty `data`.
  result = CompressResult(ok: false, data: "")
  if data.len == 0:
    result.ok = true
    return result
  var strm = default(ZStream)
  # windowBits 15+32 → auto-detect gzip or zlib header.
  if inflateInit2Raw(addr strm, cint(47), zlibVersion(), cint(sizeof(ZStream))) != Z_OK:
    return result
  var inCopy = data
  strm.nextIn = cast[pointer](toCString(inCopy))
  strm.availIn = uint32(data.len)
  var outBuf = default(array[16384, char])
  while true:
    strm.nextOut = addr outBuf[0]
    strm.availOut = uint32(outBuf.len)
    let rc = inflate(addr strm, Z_NO_FLUSH)
    let produced = outBuf.len - int(strm.availOut)
    if result.data.len + produced > maxSize:
      # Decompression bomb: output would exceed the cap. Abort as failure.
      discard inflateEnd(addr strm)
      return CompressResult(ok: false, data: "")
    var i = 0
    while i < produced:
      result.data.add outBuf[i]
      inc i
    if rc == Z_STREAM_END:
      break
    if rc < Z_OK:
      discard inflateEnd(addr strm)
      return CompressResult(ok: false, data: "")
    if strm.availIn == 0'u32 and produced == 0:
      break
  discard inflateEnd(addr strm)
  result.ok = true

proc gzipDecompress*(data: string; maxSize = DefaultMaxSize): string =
  ## Decompress a gzip (or zlib) payload, bounded by `maxSize`. "" on error
  ## (including a payload that inflates past `maxSize`).
  tryGzipDecompress(data, maxSize).data

# ---------------------------------------------------------------------------
# Brotli
# ---------------------------------------------------------------------------

proc BrotliEncoderCompress(quality, lgwin, mode: cint; inputSize: csize_t; input: pointer;
                           encodedSize: ptr csize_t; encoded: pointer): cint {.cdecl, importc: "BrotliEncoderCompress", dynlib: brotliEnc.}
proc BrotliEncoderMaxCompressedSize(inputSize: csize_t): csize_t {.cdecl, importc: "BrotliEncoderMaxCompressedSize", dynlib: brotliEnc.}
proc BrotliDecoderDecompress(encodedSize: csize_t; encoded: pointer;
                             decodedSize: ptr csize_t; decoded: pointer): cint {.cdecl, importc: "BrotliDecoderDecompress", dynlib: brotliDec.}

const
  BROTLI_MODE_GENERIC = cint(0)
  BROTLI_DECODER_RESULT_SUCCESS = cint(1)

proc collectOut(p: pointer; n: int): string =
  result = ""
  let a = cast[ptr UncheckedArray[char]](p)
  var i = 0
  while i < n:
    result.add a[i]
    inc i

proc tryBrotliCompress*(data: string; quality = 5): CompressResult =
  ## Compress `data` with Brotli (`Content-Encoding: br`).
  ## Empty input → `ok = true`, empty `data`.
  result = CompressResult(ok: false, data: "")
  if data.len == 0:
    result.ok = true
    return result
  let cap = int(BrotliEncoderMaxCompressedSize(csize_t(data.len)))
  if cap <= 0: return result
  var outBuf = newString(cap)
  var outLen = csize_t(cap)
  var inCopy = data
  let inPtr = cast[pointer](toCString(inCopy))
  let rc = BrotliEncoderCompress(cint(quality), cint(22), BROTLI_MODE_GENERIC,
                                 csize_t(data.len), inPtr, addr outLen,
                                 cast[pointer](toCString(outBuf)))
  if rc == cint(0): return result
  result.data = collectOut(cast[pointer](toCString(outBuf)), int(outLen))
  result.ok = true

proc brotliCompress*(data: string; quality = 5): string =
  ## Compress `data` with Brotli (`Content-Encoding: br`). "" on error.
  tryBrotliCompress(data, quality).data

proc tryBrotliDecompress*(data: string; maxSize = DefaultMaxSize): CompressResult =
  ## Decompress a Brotli payload, bounded by `maxSize` (the output buffer is
  ## sized to the cap, so inflation past it fails). Empty input → `ok = true`,
  ## empty `data`.
  result = CompressResult(ok: false, data: "")
  if data.len == 0:
    result.ok = true
    return result
  var inCopy = data
  let inPtr = cast[pointer](toCString(inCopy))
  # Brotli carries no decompressed size, so start from a guess and double until
  # it fits or the cap is reached. `maxSize` is a LIMIT: sizing the first buffer
  # to it meant every small payload cost 16 MiB. A too-small output buffer and a
  # corrupt payload both report ERROR, so a genuinely broken input costs a few
  # doublings before failing — bounded, and cheap next to the old allocation.
  var room = data.len * 4
  if room < 1024: room = 1024
  if room > maxSize: room = maxSize
  while true:
    var outBuf = newString(room)
    var outLen = csize_t(room)
    let rc = BrotliDecoderDecompress(csize_t(data.len), inPtr,
                                     addr outLen, cast[pointer](toCString(outBuf)))
    if rc == BROTLI_DECODER_RESULT_SUCCESS:
      result.data = collectOut(cast[pointer](toCString(outBuf)), int(outLen))
      result.ok = true
      return result
    if room >= maxSize:
      return result                     # genuinely broken, or past the cap
    room = room * 2
    if room > maxSize: room = maxSize

proc brotliDecompress*(data: string; maxSize = DefaultMaxSize): string =
  ## Decompress a Brotli payload, bounded by `maxSize`. "" on error.
  tryBrotliDecompress(data, maxSize).data

# ---------------------------------------------------------------------------
# Zstandard
# ---------------------------------------------------------------------------

proc ZSTD_compress(dst: pointer; dstCap: csize_t; src: pointer; srcSize: csize_t;
                   level: cint): csize_t {.cdecl, importc: "ZSTD_compress", dynlib: zstdLib.}
proc ZSTD_decompress(dst: pointer; dstCap: csize_t; src: pointer;
                     srcSize: csize_t): csize_t {.cdecl, importc: "ZSTD_decompress", dynlib: zstdLib.}
proc ZSTD_compressBound(srcSize: csize_t): csize_t {.cdecl, importc: "ZSTD_compressBound", dynlib: zstdLib.}
proc ZSTD_isError(code: csize_t): cuint {.cdecl, importc: "ZSTD_isError", dynlib: zstdLib.}
proc ZSTD_getFrameContentSize(src: pointer; srcSize: csize_t): culonglong
  {.cdecl, importc: "ZSTD_getFrameContentSize", dynlib: zstdLib.}

const
  # ZSTD_CONTENTSIZE_UNKNOWN = 0ULL - 1, ZSTD_CONTENTSIZE_ERROR = 0ULL - 2
  ZstdContentSizeUnknown = high(culonglong)
  ZstdContentSizeError = high(culonglong) - culonglong(1)

proc tryZstdCompress*(data: string; level = 3): CompressResult =
  ## Compress `data` with Zstandard (`Content-Encoding: zstd`).
  ## Empty input → `ok = true`, empty `data`.
  result = CompressResult(ok: false, data: "")
  if data.len == 0:
    result.ok = true
    return result
  let cap = int(ZSTD_compressBound(csize_t(data.len)))
  if cap <= 0: return result
  var outBuf = newString(cap)
  var inCopy = data
  let inPtr = cast[pointer](toCString(inCopy))
  let n = ZSTD_compress(cast[pointer](toCString(outBuf)), csize_t(cap), inPtr,
                        csize_t(data.len), cint(level))
  if ZSTD_isError(n) != cuint(0): return result
  result.data = collectOut(cast[pointer](toCString(outBuf)), int(n))
  result.ok = true

proc zstdCompress*(data: string; level = 3): string =
  ## Compress `data` with Zstandard (`Content-Encoding: zstd`). "" on error.
  tryZstdCompress(data, level).data

proc tryZstdDecompress*(data: string; maxSize = DefaultMaxSize): CompressResult =
  ## Decompress a Zstandard payload, bounded by `maxSize` (the output buffer is
  ## sized to the cap, so inflation past it fails). Empty input → `ok = true`,
  ## empty `data`.
  result = CompressResult(ok: false, data: "")
  if data.len == 0:
    result.ok = true
    return result
  var inCopy = data
  let inPtr = cast[pointer](toCString(inCopy))
  # A zstd frame header usually records the decompressed size. Use it instead of
  # allocating the whole cap: `maxSize` is a LIMIT, and sizing every buffer to it
  # meant a 100-byte payload still cost 16 MiB.
  var room = maxSize
  let declared = ZSTD_getFrameContentSize(inPtr, csize_t(data.len))
  if declared == ZstdContentSizeError:
    return result
  if declared != ZstdContentSizeUnknown:
    if declared > culonglong(maxSize):
      return result                     # would inflate past the cap
    room = int(declared)
    if room == 0:
      result.ok = true
      return result
  var outBuf = newString(room)
  let n = ZSTD_decompress(cast[pointer](toCString(outBuf)), csize_t(room),
                          inPtr, csize_t(data.len))
  if ZSTD_isError(n) != cuint(0): return result
  result.data = collectOut(cast[pointer](toCString(outBuf)), int(n))
  result.ok = true

proc zstdDecompress*(data: string; maxSize = DefaultMaxSize): string =
  ## Decompress a Zstandard payload, bounded by `maxSize`. "" on error.
  tryZstdDecompress(data, maxSize).data
