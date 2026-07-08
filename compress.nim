## compress — one-shot general-purpose compression codecs for the aoughwl stack.
##
## Raw byte-string codecs over the system libraries: gzip/zlib (`libz.so.1`),
## Brotli (`libbrotlienc`/`libbrotlidec`), and Zstandard (`libzstd.so.1`). No
## streaming state — each call takes and returns a `string`. These are protocol-
## agnostic: `http` layers HTTP `Content-Encoding` negotiation on top, and any
## binary protocol (WebSocket permessage-deflate, on-disk blobs, …) can reuse
## them directly.

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

proc gzipCompress*(data: string; level = 6): string =
  ## Compress `data` into the gzip format (`Content-Encoding: gzip`). "" on error.
  result = ""
  var strm = default(ZStream)
  if deflateInit2Raw(addr strm, cint(level), Z_DEFLATED, GZIP_WINDOW, cint(8), cint(0),
                   zlibVersion(), cint(sizeof(ZStream))) != Z_OK:
    return ""
  var inCopy = data
  if data.len > 0:
    strm.nextIn = cast[pointer](toCString(inCopy))
  else:
    strm.nextIn = cast[pointer](0)
  strm.availIn = uint32(data.len)
  var outBuf = default(array[16384, char])
  while true:
    strm.nextOut = addr outBuf[0]
    strm.availOut = uint32(outBuf.len)
    let rc = deflate(addr strm, Z_FINISH)
    let produced = outBuf.len - int(strm.availOut)
    var i = 0
    while i < produced:
      result.add outBuf[i]
      inc i
    if rc == Z_STREAM_END:
      break
    if rc < Z_OK:
      discard deflateEnd(addr strm)
      return ""
  discard deflateEnd(addr strm)

proc gzipDecompress*(data: string): string =
  ## Decompress a gzip (or zlib) payload. "" on error.
  result = ""
  if data.len == 0: return ""
  var strm = default(ZStream)
  # windowBits 15+32 → auto-detect gzip or zlib header.
  if inflateInit2Raw(addr strm, cint(47), zlibVersion(), cint(sizeof(ZStream))) != Z_OK:
    return ""
  var inCopy = data
  strm.nextIn = cast[pointer](toCString(inCopy))
  strm.availIn = uint32(data.len)
  var outBuf = default(array[16384, char])
  while true:
    strm.nextOut = addr outBuf[0]
    strm.availOut = uint32(outBuf.len)
    let rc = inflate(addr strm, Z_NO_FLUSH)
    let produced = outBuf.len - int(strm.availOut)
    var i = 0
    while i < produced:
      result.add outBuf[i]
      inc i
    if rc == Z_STREAM_END:
      break
    if rc < Z_OK:
      discard inflateEnd(addr strm)
      return ""
    if strm.availIn == 0'u32 and produced == 0:
      break
  discard inflateEnd(addr strm)

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

proc brotliCompress*(data: string; quality = 5): string =
  ## Compress `data` with Brotli (`Content-Encoding: br`). "" on error.
  result = ""
  let cap = int(BrotliEncoderMaxCompressedSize(csize_t(data.len)))
  if cap <= 0: return ""
  var outBuf = newString(cap)
  var outLen = csize_t(cap)
  var inCopy = data
  var inPtr = cast[pointer](0)
  if data.len > 0: inPtr = cast[pointer](toCString(inCopy))
  let rc = BrotliEncoderCompress(cint(quality), cint(22), BROTLI_MODE_GENERIC,
                                 csize_t(data.len), inPtr, addr outLen,
                                 cast[pointer](toCString(outBuf)))
  if rc == cint(0): return ""
  collectOut(cast[pointer](toCString(outBuf)), int(outLen))

proc brotliDecompress*(data: string; maxSize = 16 * 1024 * 1024): string =
  ## Decompress a Brotli payload, bounded by `maxSize`. "" on error.
  result = ""
  if data.len == 0: return ""
  var outBuf = newString(maxSize)
  var outLen = csize_t(maxSize)
  var inCopy = data
  let rc = BrotliDecoderDecompress(csize_t(data.len), cast[pointer](toCString(inCopy)),
                                   addr outLen, cast[pointer](toCString(outBuf)))
  if rc != BROTLI_DECODER_RESULT_SUCCESS: return ""
  collectOut(cast[pointer](toCString(outBuf)), int(outLen))

# ---------------------------------------------------------------------------
# Zstandard
# ---------------------------------------------------------------------------

proc ZSTD_compress(dst: pointer; dstCap: csize_t; src: pointer; srcSize: csize_t;
                   level: cint): csize_t {.cdecl, importc: "ZSTD_compress", dynlib: zstdLib.}
proc ZSTD_decompress(dst: pointer; dstCap: csize_t; src: pointer;
                     srcSize: csize_t): csize_t {.cdecl, importc: "ZSTD_decompress", dynlib: zstdLib.}
proc ZSTD_compressBound(srcSize: csize_t): csize_t {.cdecl, importc: "ZSTD_compressBound", dynlib: zstdLib.}
proc ZSTD_isError(code: csize_t): cuint {.cdecl, importc: "ZSTD_isError", dynlib: zstdLib.}

proc zstdCompress*(data: string; level = 3): string =
  ## Compress `data` with Zstandard (`Content-Encoding: zstd`). "" on error.
  result = ""
  let cap = int(ZSTD_compressBound(csize_t(data.len)))
  if cap <= 0: return ""
  var outBuf = newString(cap)
  var inCopy = data
  var inPtr = cast[pointer](0)
  if data.len > 0: inPtr = cast[pointer](toCString(inCopy))
  let n = ZSTD_compress(cast[pointer](toCString(outBuf)), csize_t(cap), inPtr,
                        csize_t(data.len), cint(level))
  if ZSTD_isError(n) != cuint(0): return ""
  collectOut(cast[pointer](toCString(outBuf)), int(n))

proc zstdDecompress*(data: string; maxSize = 16 * 1024 * 1024): string =
  ## Decompress a Zstandard payload, bounded by `maxSize`. "" on error.
  result = ""
  if data.len == 0: return ""
  var outBuf = newString(maxSize)
  var inCopy = data
  let n = ZSTD_decompress(cast[pointer](toCString(outBuf)), csize_t(maxSize),
                          cast[pointer](toCString(inCopy)), csize_t(data.len))
  if ZSTD_isError(n) != cuint(0): return ""
  collectOut(cast[pointer](toCString(outBuf)), int(n))
