## codecopts.nim — codec parameters as a record.
##
## Each codec here took a level and a cap as loose parameters, and every other
## knob the underlying library exposes was a literal at the FFI call site:
## windowBits fixed at gzip, memLevel 8, strategy 0, brotli mode generic and
## lgwin 22. Two consequences worth naming:
##
## * `windowBits` being welded to 31 meant zlib-wrapped and raw deflate output
##   were both unreachable, so `Content-Encoding: deflate` could not be offered
##   at all and raw deflate — what WebSocket permessage-deflate actually needs —
##   had to be reimplemented elsewhere.
## * `DefaultMaxSize` was private and duplicated as a literal in three places,
##   so a caller could not even read the cap it was subject to.
##
## `CodecOpts` carries all of it. Fields left at `CodecUnset` inherit, so
## `merge` follows the same scope ladder as the rest of the stack.

const
  CodecUnset* = -1000
    ## Inherit this field. Not -1: several of these parameters take genuinely
    ## negative values (raw deflate is windowBits -15, zstd accepts negative
    ## levels), so the sentinel has to sit outside every valid range.

  DefaultMaxSize* = 16 * 1024 * 1024
    ## The decompression cap, in bytes. Public now: a caller subject to a
    ## bound should be able to read it.

  DefaultLevel* = 6              ## zlib deflate level
  DefaultMemLevel* = 8           ## zlib memLevel
  DefaultStrategy* = 0           ## Z_DEFAULT_STRATEGY
  DefaultBrotliQuality* = 5
  DefaultBrotliWindow* = 22      ## lgwin
  DefaultBrotliMode* = 0         ## BROTLI_MODE_GENERIC
  DefaultZstdLevel* = 3

  # windowBits, which is really a format selector wearing a size's clothes.
  WindowGzip* = 31               ## 15 + 16: gzip wrapper
  WindowZlib* = 15               ## zlib wrapper — Content-Encoding: deflate
  WindowRaw* = -15               ## no wrapper — permessage-deflate
  WindowAuto* = 47               ## 15 + 32: detect gzip or zlib when inflating

type
  CodecOpts* = object
    ## Parameters for every codec in this module. One record rather than one
    ## per codec, because a caller's compression policy is usually a single
    ## decision ("compress hard", "compress cheaply") applied to whichever
    ## codec the negotiation picked.
    level*: int                  ## zlib deflate level, 0-9
    windowBits*: int             ## format selector; see the Window* constants
    memLevel*: int               ## zlib memLevel, 1-9
    strategy*: int               ## zlib strategy
    brotliQuality*: int          ## 0-11
    brotliWindow*: int           ## lgwin, 10-24
    brotliMode*: int             ## 0 generic, 1 text, 2 font
    zstdLevel*: int
    maxSize*: int                ## decompression cap in bytes; 0 = unbounded

proc defaultCodecOpts*(): CodecOpts =
  ## Exactly the values that were previously literals at the call sites.
  ## Compressing with this record produces byte-identical output to the old
  ## parameterless calls, which is what makes it a safe base.
  CodecOpts(
    level: DefaultLevel, windowBits: WindowGzip, memLevel: DefaultMemLevel,
    strategy: DefaultStrategy, brotliQuality: DefaultBrotliQuality,
    brotliWindow: DefaultBrotliWindow, brotliMode: DefaultBrotliMode,
    zstdLevel: DefaultZstdLevel, maxSize: DefaultMaxSize)

proc noCodecOpts*(): CodecOpts =
  ## The empty override: every field inherits.
  CodecOpts(
    level: CodecUnset, windowBits: CodecUnset, memLevel: CodecUnset,
    strategy: CodecUnset, brotliQuality: CodecUnset, brotliWindow: CodecUnset,
    brotliMode: CodecUnset, zstdLevel: CodecUnset, maxSize: CodecUnset)

proc fastCodecOpts*(): CodecOpts =
  ## Speed over ratio, for a path where CPU is the scarce resource.
  result = defaultCodecOpts()
  result.level = 1
  result.brotliQuality = 1
  result.zstdLevel = 1

proc bestCodecOpts*(): CodecOpts =
  ## Ratio over speed, for content compressed once and served many times.
  result = defaultCodecOpts()
  result.level = 9
  result.brotliQuality = 11
  result.zstdLevel = 19

proc rawDeflateOpts*(): CodecOpts =
  ## Raw deflate: no gzip or zlib wrapper. This is the framing WebSocket
  ## permessage-deflate uses, and it was unreachable while windowBits was a
  ## literal.
  result = defaultCodecOpts()
  result.windowBits = WindowRaw

proc zlibDeflateOpts*(): CodecOpts =
  ## The zlib wrapper — what `Content-Encoding: deflate` actually means.
  result = defaultCodecOpts()
  result.windowBits = WindowZlib

proc merge*(base: CodecOpts; over: CodecOpts): CodecOpts =
  ## A field set in `over` wins; `CodecUnset` inherits.
  result = base
  if over.level != CodecUnset: result.level = over.level
  if over.windowBits != CodecUnset: result.windowBits = over.windowBits
  if over.memLevel != CodecUnset: result.memLevel = over.memLevel
  if over.strategy != CodecUnset: result.strategy = over.strategy
  if over.brotliQuality != CodecUnset: result.brotliQuality = over.brotliQuality
  if over.brotliWindow != CodecUnset: result.brotliWindow = over.brotliWindow
  if over.brotliMode != CodecUnset: result.brotliMode = over.brotliMode
  if over.zstdLevel != CodecUnset: result.zstdLevel = over.zstdLevel
  if over.maxSize != CodecUnset: result.maxSize = over.maxSize

proc inflateWindow*(opts: CodecOpts): int =
  ## The windowBits to inflate with. A compressor's `windowBits` names the
  ## wrapper it wrote; the decompressor needs the matching value, and for the
  ## two wrapped formats it can simply auto-detect. Getting this wrong is
  ## silent — inflate just fails — so it is derived rather than asked for.
  if opts.windowBits == WindowRaw: WindowRaw else: WindowAuto

proc capOr*(opts: CodecOpts; fallback = DefaultMaxSize): int =
  ## The decompression cap to enforce, resolving unset to the default.
  if opts.maxSize == CodecUnset: fallback else: opts.maxSize
