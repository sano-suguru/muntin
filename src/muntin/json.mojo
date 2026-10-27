"""JSON request and response bodies (M3-009, derived codecs M3-083).

Decisions: docs/history/architecture-decisions.md, "JSON codec decision
(M3-008)" and "Derived JSON codecs decision (M3-082)".
`Json[T]` is a request body through the existing `FromBody` and a result
through the existing `ToResponse`, so it registers through
`App.get`/`App.post` like any other body or result; `Json(value, status=)`
chooses the result's status (M3-029, "JSON response status decision
(M3-028)"). `T` converts by hand (`FromJson`, `ToJson`) or is a
`JsonFields` struct whose codec is derived from its fields, or a `List` or
`Optional` of one. The codec is Muntin's own: a strict
parser for the RFC 8259 grammar with Muntin's limits (duplicate member names
rejected, nesting depth 64, a body limit of 1 MiB unless
`Json[T, limit=n]`, `float()` finite) and a writer.

Only documented Mojo 1.1.0 features are used: conditional conformance with
`where`-gated methods, `conforms_to`, reflection of a struct's fields, and
safe std types. The parsed document lives in M3-004's sealed `_Shared` box,
so no copy of a `JsonValue` can clear or replace the document another copy
reads. A derived reader builds a `JsonFields` struct through the storage
module's `_build_record` (its `__init__` never runs) and reaches a generic
field's type through the guarded rebind helpers `_as` and `_view`, as
`app.mojo` does for route values.
"""

from std.collections import Optional

from std.reflection import reflect

from ._field_built import _FieldBuilt
from ._handler_storage import _Shared
from ._handler_storage import _build_record
from ._rebind import _as, _view
from .body import FromBody, _BodyFault, _MAX_BODY_BYTES
from .http import Failure, Headers, Rejection, Response, ToResponse, _failed

comptime _MAX_DEPTH = 64
"""Nesting cap for untrusted input: an array or object nested deeper than
this is rejected (400 through `from_body`), so the recursive parser's stack
is bounded."""

comptime _LARGEST_LIMIT = 4_294_967_295
"""The largest `Json[T]` limit: the tape's spans are `UInt32` offsets into
the body, exact only below 2^32 bytes (`_check_limit`).

Every `UInt32` the parser stores is at most the body's length `n`, which
`_parse_json` checks against the limit before reading: an offset is at
most `n` (a string's `start` is one past its opening quote, before its
closing one), and each parsed value takes at least one byte of the body,
so a stored node index, a container's `count` and the length of `kids`
(one entry per value but the root) are each below `n`. No test parses a body near 2^32 bytes."""

comptime _EXPONENT_CAP = 1 << 40
"""Where `_to_float64` stops reading an exponent's digits. A literal's digit
count moves its decimal exponent by at most its length, at most
`_LARGEST_LIMIT`, and the result is zero or out of range once the
magnitude passes about 1,100 (800 kept digits, 324 below the smallest
double); so any exponent read up to this cap, or saturated at it, decides
the same result."""

comptime _LIMIT_NEGATIVE = (
    "Json's limit is negative; a limit is a byte count, 0 or more"
)

comptime _LIMIT_TOO_LARGE = (
    "Json's limit is over 4294967295 bytes, the longest body its parser"
    " addresses"
)


def _check_limit[limit: Int]():
    """`Json[T]`'s limit is from 0 to `_LARGEST_LIMIT`: checked where its
    `from_body` or `_from_text` is instantiated (a route or a raw handler's
    call)."""
    comptime assert limit <= _LARGEST_LIMIT, _LIMIT_TOO_LARGE
    comptime assert limit >= 0, _LIMIT_NEGATIVE


# Node kinds of the parsed tape.
comptime _NULL = 0
comptime _FALSE = 1
comptime _TRUE = 2
comptime _NUMBER = 3
comptime _STRING = 4
comptime _ARRAY = 5
comptime _OBJECT = 6

# `_Node.flags` bits.
comptime _ESCAPED = 1  # the string value holds escapes
comptime _KEY_ESCAPED = 2  # the member name holds escapes
comptime _HAS_KEY = 4  # the node is an object member


@fieldwise_init
struct _Node(Copyable, Movable):
    """One value of a parsed document, in document order, owning no text:
    spans point into the document's copy of the body (decoded on access).
    28 bytes, plus 4 in the child table."""

    var kind: UInt8
    var flags: UInt8
    # Byte span of a number literal, or of a string's contents (inside the
    # quotes, escapes undecoded).
    var start: UInt32
    var end: UInt32
    # Byte span of the member name's contents, when `_HAS_KEY`.
    var key_start: UInt32
    var key_end: UInt32
    # Elements or members, and where their node indices start in `kids`.
    var count: UInt32
    var kids: UInt32


struct _Doc(Movable):
    """A parsed document: the body text, the nodes, and one table of child
    node indices, contiguous per container (constant-time element access).
    """

    var text: String
    var nodes: List[_Node]
    var kids: List[UInt32]

    def __init__(
        out self,
        var text: String,
        var nodes: List[_Node],
        var kids: List[UInt32],
    ):
        self.text = text^
        self.nodes = nodes^
        self.kids = kids^


def _is_ws(c: Int) -> Bool:
    return c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D


def _is_digit(c: Int) -> Bool:
    return c >= ord("0") and c <= ord("9")


def _hex(c: Int) raises -> Int:
    if c >= ord("0") and c <= ord("9"):
        return c - ord("0")
    if c >= ord("a") and c <= ord("f"):
        return c - ord("a") + 10
    if c >= ord("A") and c <= ord("F"):
        return c - ord("A") + 10
    raise Error("invalid JSON: bad \\u escape")


def _u4(text: String, at: Int) raises -> Int:
    var b = text.as_bytes()
    if at + 4 > len(b):
        raise Error("invalid JSON: bad \\u escape")
    var v = 0
    for k in range(4):
        v = v * 16 + _hex(Int(b[at + k]))
    return v


def _decode(text: String, start: Int, end: Int) raises -> String:
    """Decodes the escapes of a string's contents `text[start:end]`, which
    the parser has already validated. Runs between escapes are copied as
    they are (the text is valid UTF-8)."""
    var b = text.as_bytes()
    var out = String()
    var run = start
    var i = start
    while i < end:
        if Int(b[i]) != ord("\\"):
            i += 1
            continue
        out += String(text[byte=run:i])
        var e = Int(b[i + 1])
        i += 2
        if e == ord('"'):
            out += '"'
        elif e == ord("\\"):
            out += "\\"
        elif e == ord("/"):
            out += "/"
        elif e == ord("b"):
            out += chr(0x08)
        elif e == ord("f"):
            out += chr(0x0C)
        elif e == ord("n"):
            out += "\n"
        elif e == ord("r"):
            out += "\r"
        elif e == ord("t"):
            out += "\t"
        else:
            var cp = _u4(text, i)
            i += 4
            if cp >= 0xD800 and cp <= 0xDBFF:
                var lo = _u4(text, i + 2)
                i += 6
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
            out += chr(cp)
        run = i
    out += String(text[byte=run:end])
    return out^


comptime _MAX_DIGITS = 800
"""Significant digits `_to_float64` keeps. A decimal halfway between two
doubles has at most 768 (reached at 2^-1075 times a large odd number, such
as the one between the largest subnormal and the smallest normal), so no
halfway point lies strictly between the first 800 digits and the literal:
those digits and whether a nonzero digit follows them decide the rounding
(`test_float_is_correctly_rounded` reads 768-digit ones)."""


def _pow2(k: Int) -> Float64:
    """2^k for -1022 <= k <= 1023, exactly: every factor it multiplies in
    is a normal power of two, so no product rounds."""
    var base = Float64(2) if k >= 0 else Float64(0.5)
    var e = k if k >= 0 else -k
    var r = Float64(1)
    while e > 0:
        if e & 1 != 0:
            r *= base
        base *= base
        e >>= 1
    return r


def _pow10(k: Int) -> Float64:
    """10^k for 0 <= k <= 22, exactly (5^22 < 2^53)."""
    var r = Float64(1)
    for _ in range(k):
        r *= 10
    return r


# Unsigned integers of any size for `_to_float64`: 64-bit limbs, least
# significant first, no zero limb on top (zero is the empty list).

comptime _LOW = UInt128(UInt64.MAX)


def _big_mul_add(mut a: List[UInt64], m: UInt64, add: UInt64):
    """`a = a * m + add`."""
    var carry = UInt128(add)
    for k in range(len(a)):
        var x = UInt128(a[k]) * UInt128(m) + carry
        a[k] = UInt64(x & _LOW)
        carry = x >> 64
    if carry != 0:
        a.append(UInt64(carry))


def _big_mul_pow5(mut a: List[UInt64], k: Int):
    var e = k
    while e >= 27:
        _big_mul_add(a, 7_450_580_596_923_828_125, 0)  # 5^27 < 2^64
        e -= 27
    var m: UInt64 = 1
    for _ in range(e):
        m *= 5
    _big_mul_add(a, m, 0)


def _big_bits(a: List[UInt64]) -> Int:
    if len(a) == 0:
        return 0
    var top = a[len(a) - 1]
    var n = 0
    while top != 0:
        top >>= 1
        n += 1
    return (len(a) - 1) * 64 + n


def _big_shl(mut a: List[UInt64], s: Int):
    if len(a) == 0 or s == 0:
        return
    var r = UInt128(s % 64)
    var out = List[UInt64](capacity=len(a) + s // 64 + 1)
    for _ in range(s // 64):
        out.append(0)
    var carry: UInt128 = 0
    for k in range(len(a)):
        var x = (UInt128(a[k]) << r) | carry
        out.append(UInt64(x & _LOW))
        carry = x >> 64
    if carry != 0:
        out.append(UInt64(carry))
    a = out^


def _big_shr(a: List[UInt64], s: Int) -> UInt128:
    """`a >> s`, for a result below 2^128."""
    var out: UInt128 = 0
    for k in range(s // 64, len(a)):
        var at = 64 * k - s
        if at < 0:
            out |= UInt128(a[k]) >> UInt128(-at)
        elif at < 128:
            out |= UInt128(a[k]) << UInt128(at)
    return out


def _big_cmp(a: List[UInt64], b: List[UInt64]) -> Int:
    if len(a) != len(b):
        return -1 if len(a) < len(b) else 1
    var k = len(a) - 1
    while k >= 0:
        if a[k] != b[k]:
            return -1 if a[k] < b[k] else 1
        k -= 1
    return 0


def _big_sub(mut a: List[UInt64], b: List[UInt64]):
    """`a -= b`, for `a >= b`."""
    var borrow: UInt128 = 0
    for k in range(len(a)):
        var y = (UInt128(b[k]) if k < len(b) else 0) + borrow
        var x = UInt128(a[k])
        borrow = 1 if x < y else 0
        a[k] = UInt64((x + (borrow << 64) - y) & _LOW)
    while len(a) > 0 and a[len(a) - 1] == 0:
        _ = a.pop()


def _to_float64(text: String) raises -> Float64:
    """The literal's value rounded to the nearest double, ties to even, for
    a literal the parser has validated. Raises when that rounding gives
    infinity (a magnitude of at least 2^1024 - 2^970); a magnitude of at most
    2^-1075 rounds to a zero of the literal's sign."""
    comptime assert _EXPONENT_CAP > _LARGEST_LIMIT + 1_124, (
        "_EXPONENT_CAP must exceed the longest JSON body by the 1,124"
        " decimal places in which a literal's digits still change its double"
    )
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    var negative = Int(b[0]) == ord("-")
    if negative:
        i = 1
    # The value is the significant digits, as an integer, times 10^scale.
    var digits = List[UInt8]()
    var significant = 0
    var dropped_nonzero = False
    var scale = 0
    var fraction = False
    while i < n:
        var c = Int(b[i])
        if c == ord("e") or c == ord("E"):
            break
        i += 1
        if c == ord("."):
            fraction = True
            continue
        if fraction:
            scale -= 1
        if significant == 0 and c == ord("0"):
            continue
        significant += 1
        if len(digits) < _MAX_DIGITS:
            digits.append(UInt8(c - ord("0")))
        elif c != ord("0"):
            dropped_nonzero = True
    if i < n:
        i += 1
        var exponent_negative = Int(b[i]) == ord("-")
        if Int(b[i]) == ord("+") or exponent_negative:
            i += 1
        var exponent = 0
        while i < n:
            # Past `_EXPONENT_CAP` the result is zero or out of range
            # whatever the digits, which `_LARGEST_LIMIT` keeps far fewer.
            if exponent < _EXPONENT_CAP:
                exponent = exponent * 10 + Int(b[i]) - ord("0")
            i += 1
        scale += -exponent if exponent_negative else exponent
    var zero = -Float64(0) if negative else Float64(0)
    if significant == 0:
        return zero
    scale += significant - len(digits)
    while digits[len(digits) - 1] == 0:
        _ = digits.pop()
        scale += 1
    var kept = len(digits)
    # The value is in [10^(kept - 1 + scale), 10^(kept + scale)).
    if kept - 1 + scale >= 309:
        raise Error("JSON number is out of range")
    if kept + scale <= -324:
        return zero  # under half the smallest double

    # An integer up to 2^53 times or over an exact power of ten: one
    # correctly rounded operation (Clinger's fast path).
    if kept <= 19 and not dropped_nonzero and scale >= -22 and scale <= 22:
        var m: UInt64 = 0
        for k in range(kept):
            m = m * 10 + UInt64(digits[k])
        if m <= UInt64(1) << 53:
            var x = Float64(Int(m))
            x = x * _pow10(scale) if scale >= 0 else x / _pow10(-scale)
            return -x if negative else x

    # Otherwise exactly: the value is num / den * 2^scale (10^scale split
    # into 5^scale and 2^scale), and q, the leading 63 or 64 bits of
    # num / den, is estimated from the top bits and then corrected with
    # whole numbers, so the estimate's error costs time, never accuracy.
    var num = List[UInt64]()
    var k = 0
    while k < kept:
        var chunk: UInt64 = 0
        var m: UInt64 = 1
        while k < kept and m < 10_000_000_000_000_000_000:
            chunk = chunk * 10 + UInt64(digits[k])
            m *= 10
            k += 1
        _big_mul_add(num, m, chunk)
    var den: List[UInt64] = [UInt64(1)]
    if scale >= 0:
        _big_mul_pow5(num, scale)
    else:
        _big_mul_pow5(den, -scale)
    # q = floor(num * 2^s / den) is in [2^62, 2^64).
    var s = 63 - (_big_bits(num) - _big_bits(den))
    if s >= 0:
        _big_shl(num, s)
    else:
        _big_shl(den, -s)
    var top = max(_big_bits(den) - 64, 0)
    var q = _big_shr(num, top) // _big_shr(den, top)
    q = min(q, UInt128(UInt64.MAX))
    var product = den.copy()
    _big_mul_add(product, UInt64(q), 0)
    while _big_cmp(product, num) > 0:
        q -= 1
        _big_sub(product, den)
    _big_sub(num, product)
    while _big_cmp(num, den) >= 0:
        q += 1
        _big_sub(num, den)
    var inexact = dropped_nonzero or len(num) > 0

    # The value is q * 2^(scale - s), so its leading bit is 2^t.
    var h = 63 if q >> 63 != 0 else 62
    var t = h - s + scale
    if t > 1023:
        raise Error("JSON number is out of range")
    # Significand bits: 53, fewer below 2^-1022 (subnormal), none below
    # 2^-1075, where the value rounds to zero.
    var p = 53 if t >= -1022 else t + 1075
    if p < 0:
        return zero
    var drop = UInt128(h + 1 - p)
    var m = q >> drop
    var half = (q >> (drop - 1)) & 1 != 0
    var rest = q & ((UInt128(1) << (drop - 1)) - 1) != 0 or inexact
    if half and (rest or m & 1 != 0):
        m += 1
    if t == 1023 and m == UInt128(1) << 53:
        raise Error("JSON number is out of range")
    # m * 2^e is the double: one exact step, or two below 2^-1022 (the
    # first stays normal, the second lands on the representable result).
    var e = t - p + 1
    var x = Float64(Int(m))
    if e >= -1022:
        x *= _pow2(e)
    else:
        x = x * _pow2(e + 52) * _pow2(-52)
    return -x if negative else x


struct _Parser:
    """Recursive descent over the body's bytes: the RFC 8259 grammar,
    strictly, plus Muntin's limits (duplicate names, depth, size). Rejects:
    comments, trailing commas, single quotes, leading zeros, `+` signs,
    `NaN`/`Infinity`, a byte order mark, unescaped control bytes in strings,
    bad escapes, lone surrogates, duplicate member names, trailing content,
    an empty body, and nesting deeper than `_MAX_DEPTH`. Linear in the body
    up to an O(m log m) sort of each object's m member names (duplicates),
    and nodes store spans, not copies."""

    var text: String
    var i: Int
    var n: Int
    var nodes: List[_Node]
    var kids: List[UInt32]

    def __init__(out self, var text: String):
        self.n = text.byte_length()
        self.text = text^
        self.i = 0
        self.nodes = List[_Node]()
        self.kids = List[UInt32]()

    def _peek(self) -> Int:
        if self.i >= self.n:
            return -1
        return Int(self.text.as_bytes()[self.i])

    def _ws(mut self):
        while self.i < self.n and _is_ws(Int(self.text.as_bytes()[self.i])):
            self.i += 1

    def _expect_word(mut self, word: StaticString) raises:
        for c in word.as_bytes():
            if self._peek() != Int(c):
                raise Error("invalid JSON: bad literal")
            self.i += 1

    def _string(mut self) raises -> Bool:
        """Validates a string at its opening quote and moves past its
        closing quote. Returns whether it holds escapes."""
        self.i += 1
        var escaped = False
        while True:
            var c = self._peek()
            if c < 0:
                raise Error("invalid JSON: unterminated string")
            if c == ord('"'):
                self.i += 1
                return escaped
            if c < 0x20:
                raise Error("invalid JSON: control byte in string")
            self.i += 1
            if c != ord("\\"):
                continue
            escaped = True
            var e = self._peek()
            self.i += 1
            if (
                e == ord('"')
                or e == ord("\\")
                or e == ord("/")
                or e == ord("b")
                or e == ord("f")
                or e == ord("n")
                or e == ord("r")
                or e == ord("t")
            ):
                continue
            if e != ord("u"):
                raise Error("invalid JSON: bad escape")
            var cp = _u4(self.text, self.i)
            self.i += 4
            if cp >= 0xD800 and cp <= 0xDBFF:
                if self._peek() != ord("\\"):
                    raise Error("invalid JSON: lone surrogate")
                self.i += 1
                if self._peek() != ord("u"):
                    raise Error("invalid JSON: lone surrogate")
                self.i += 1
                var lo = _u4(self.text, self.i)
                self.i += 4
                if lo < 0xDC00 or lo > 0xDFFF:
                    raise Error("invalid JSON: lone surrogate")
            elif cp >= 0xDC00 and cp <= 0xDFFF:
                raise Error("invalid JSON: lone surrogate")

    def _number(mut self) raises:
        if self._peek() == ord("-"):
            self.i += 1
        if self._peek() == ord("0"):
            self.i += 1
        elif _is_digit(self._peek()):
            while _is_digit(self._peek()):
                self.i += 1
        else:
            raise Error("invalid JSON: bad number")
        if self._peek() == ord("."):
            self.i += 1
            if not _is_digit(self._peek()):
                raise Error("invalid JSON: bad number")
            while _is_digit(self._peek()):
                self.i += 1
        if self._peek() == ord("e") or self._peek() == ord("E"):
            self.i += 1
            if self._peek() == ord("+") or self._peek() == ord("-"):
                self.i += 1
            if not _is_digit(self._peek()):
                raise Error("invalid JSON: bad number")
            while _is_digit(self._peek()):
                self.i += 1

    def value(
        mut self, key_start: Int, key_end: Int, key_flags: Int, depth: Int
    ) raises -> Int:
        """Parses one value and returns its node index."""
        self._ws()
        var c = self._peek()
        var at = len(self.nodes)
        self.nodes.append(
            _Node(
                UInt8(_NULL),
                UInt8(key_flags),
                UInt32(self.i),
                UInt32(self.i),
                UInt32(key_start),
                UInt32(key_end),
                UInt32(0),
                UInt32(0),
            )
        )
        var kind = _NULL
        if c == ord("{") or c == ord("["):
            if depth >= _MAX_DEPTH:
                raise Error("invalid JSON: nesting too deep")
            var obj = c == ord("{")
            kind = _OBJECT if obj else _ARRAY
            self.i += 1
            self._ws()
            var close = ord("}") if obj else ord("]")
            var children = List[UInt32]()
            var names = List[String]()
            if self._peek() == close:
                self.i += 1
            else:
                while True:
                    var ks = 0
                    var ke = 0
                    var kf = 0
                    if obj:
                        self._ws()
                        if self._peek() != ord('"'):
                            raise Error("invalid JSON: expected member name")
                        ks = self.i + 1
                        var esc = self._string()
                        ke = self.i - 1
                        kf = _HAS_KEY | (_KEY_ESCAPED if esc else 0)
                        var name = _decode(
                            self.text, ks, ke
                        ) if esc else String(self.text[byte=ks:ke])
                        names.append(name^)
                        self._ws()
                        if self._peek() != ord(":"):
                            raise Error("invalid JSON: expected ':'")
                        self.i += 1
                    children.append(UInt32(self.value(ks, ke, kf, depth + 1)))
                    self._ws()
                    var d = self._peek()
                    self.i += 1
                    if d == close:
                        break
                    if d != ord(","):
                        raise Error("invalid JSON: expected ',' or close")
            # Duplicate names: sort and compare neighbours, O(m log m) and
            # deterministic (a hash set's cost would depend on a hash seed
            # an attacker can precompute collisions for).
            sort(names)
            for k in range(1, len(names)):
                if names[k] == names[k - 1]:
                    raise Error("invalid JSON: duplicate member")
            self.nodes[at].count = UInt32(len(children))
            self.nodes[at].kids = UInt32(len(self.kids))
            self.kids.extend(children^)
        elif c == ord('"'):
            kind = _STRING
            self.nodes[at].start = UInt32(self.i + 1)
            if self._string():
                self.nodes[at].flags |= UInt8(_ESCAPED)
            self.nodes[at].end = UInt32(self.i - 1)
        elif c == ord("t"):
            kind = _TRUE
            self._expect_word("true")
        elif c == ord("f"):
            kind = _FALSE
            self._expect_word("false")
        elif c == ord("n"):
            self._expect_word("null")
        elif c == ord("-") or _is_digit(c):
            kind = _NUMBER
            self._number()
            self.nodes[at].end = UInt32(self.i)
        else:
            raise Error("invalid JSON: unexpected byte")
        self.nodes[at].kind = UInt8(kind)
        return at


def _parse_json(text: String, max_bytes: Int) raises -> JsonValue:
    """Parses one JSON text (the RFC 8259 grammar with Muntin's limits; see
    `_Parser`) and returns its top-level value. Raises on anything else, and
    on a text longer than `max_bytes` (a `Json[T]`'s limit, M3-089), before
    reading it: a parsed document costs up to about 37 bytes per body byte,
    so `max_bytes` bounds one parse, a raw handler's `from_body` call
    included. The document keeps one copy of `text`: the parser's, moved
    into it."""
    if text.byte_length() > max_bytes:
        raise Error("JSON body too large")
    var p = _Parser(text)
    _ = p.value(0, 0, 0, 0)
    p._ws()
    if p.i != p.n:
        raise Error("invalid JSON: trailing content")
    var body = String()
    var nodes = List[_Node]()
    var kids = List[UInt32]()
    swap(body, p.text)
    swap(nodes, p.nodes)
    swap(kids, p.kids)
    return JsonValue(_doc=_Shared(_Doc(body^, nodes^, kids^)), _at=0)


struct JsonValue(Copyable, Movable, Sized):
    """A read-only position in a parsed JSON document.

    `FromJson.from_json` receives the top-level value of a request body and
    reads the fields it needs through the accessors. Every accessor raises
    when the value is not of the asked kind, so a `from_json` that reads a
    wrong or missing field raises, and the request is answered 400 before
    the handler. Accessors return values, never references into the
    document.

    The document is held in a shared, sealed box: copies of a `JsonValue`
    share it (one reference count increment, no copy), and no copy can
    clear or replace it on an ordinary path. Positions are made only by the
    parser and the accessors: the initializer's keyword-only arguments are
    internal, and `_doc`/`_at` are not API.
    """

    var _doc: _Shared[_Doc]
    var _at: Int

    def __init__(out self, *, _doc: _Shared[_Doc], _at: Int):
        self._doc = _doc.copy()
        self._at = _at

    def _node(self) -> _Node:
        return self._doc.owned()[].nodes[self._at].copy()

    def _kind(self) -> Int:
        return Int(self._node().kind)

    def _child(self, k: Int) -> JsonValue:
        var at = Int(self._doc.owned()[].kids[Int(self._node().kids) + k])
        return JsonValue(_doc=self._doc, _at=at)

    def _name(self) raises -> String:
        """The member name of an object member."""
        var n = self._node()
        ref doc = self._doc.owned()[]
        if n.flags & UInt8(_KEY_ESCAPED):
            return _decode(doc.text, Int(n.key_start), Int(n.key_end))
        return String(doc.text[byte = Int(n.key_start) : Int(n.key_end)])

    def is_null(self) -> Bool:
        """Whether the value is `null`."""
        return self._kind() == _NULL

    def bool(self) raises -> Bool:
        """The value of `true` or `false`; raises for any other kind."""
        var k = self._kind()
        if k == _TRUE:
            return True
        if k == _FALSE:
            return False
        raise Error("JSON value is not a boolean")

    def _literal(self) -> String:
        var n = self._node()
        return String(
            self._doc.owned()[].text[byte = Int(n.start) : Int(n.end)]
        )

    def int(self) raises -> Int:
        """An integer literal (no fraction, no exponent) that fits `Int`;
        raises for any other number or kind. Exact."""
        if self._kind() != _NUMBER:
            raise Error("JSON value is not a number")
        var t = self._literal()
        if t.find(".") >= 0 or t.find("e") >= 0 or t.find("E") >= 0:
            raise Error("JSON number is not an integer")
        try:
            return Int(t)
        except:
            # `Int`'s own message quotes the literal, which the client sent.
            raise Error("JSON number is out of Int range")

    def float(self) raises -> Float64:
        """A number literal of any length, rounded to the nearest `Float64`
        (ties to even). Raises when that rounding gives infinity, and for any
        other kind."""
        if self._kind() != _NUMBER:
            raise Error("JSON value is not a number")
        return _to_float64(self._literal())

    def string(self) raises -> String:
        """The string's contents, escapes decoded (a copy); raises for any
        other kind."""
        if self._kind() != _STRING:
            raise Error("JSON value is not a string")
        var n = self._node()
        if n.flags & UInt8(_ESCAPED):
            return _decode(self._doc.owned()[].text, Int(n.start), Int(n.end))
        return self._literal()

    def __len__(self) -> Int:
        """Elements of an array, members of an object, 0 otherwise."""
        var k = self._kind()
        if k == _ARRAY or k == _OBJECT:
            return Int(self._node().count)
        return 0

    def __getitem__(self, index: Int) raises -> JsonValue:
        """The `index`th array element, in constant time; raises when the
        value is not an array or `index` is out of range."""
        if self._kind() != _ARRAY:
            raise Error("JSON value is not an array")
        if index < 0 or index >= Int(self._node().count):
            raise Error("JSON array index out of range")
        return self._child(index)

    def get(self, name: String) raises -> Optional[JsonValue]:
        """The member `name` of an object, or `None` when it is absent; a
        member present as `null` is a value (`is_null()`). Raises when the
        value is not an object. Linear in the object's members."""
        if self._kind() != _OBJECT:
            raise Error("JSON value is not an object")
        ref doc = self._doc.owned()[]
        for k in range(Int(self._node().count)):
            var at = Int(doc.kids[Int(self._node().kids) + k])
            ref m = doc.nodes[at]
            var ks = Int(m.key_start)
            var ke = Int(m.key_end)
            var same: Bool
            if m.flags & UInt8(_KEY_ESCAPED):
                same = _decode(doc.text, ks, ke) == name
            else:
                same = (
                    ke - ks == name.byte_length()
                    and String(doc.text[byte=ks:ke]) == name
                )
            if same:
                return JsonValue(_doc=self._doc, _at=at)
        return None

    def __getitem__(self, name: String) raises -> JsonValue:
        """The member `name` of an object; raises when it is absent (the
        error names it, M3-084) or the value is not an object."""
        var found = self.get(name)
        if not found:
            raise Error('JSON member "', name, '" is missing')
        return found.take()

    def read[T: Movable & Deinitable](self) raises -> T:
        """The value as `T` by the derived rules of `Json[T]`: `T` is any
        kind a `JsonFields` field may have (M3-082), so a hand-written
        `from_json` reads a `JsonFields` struct, or a `List` or `Optional`
        of one, without writing its members by hand. A failure's message
        starts with the member path below this value (`tags[0]: ...`); a
        `T` that cannot be read fails to build, naming its innermost
        field."""
        comptime assert _call_refusal[T, True]() == "", _call_refusal[T, True]()
        return _read_json[T](self)

    def read[T: Movable & Deinitable](self, name: String) raises -> T:
        """The member `name` as `T`, as a derived reader reads a field of
        that name: an absent or `null` member is an empty `Optional`, any
        other `T` requires the member. A failure's message starts with the
        path from this value (`place.city: ...`, `place: JSON member is
        missing`)."""
        comptime assert _call_refusal[T, True]() == "", _call_refusal[T, True]()
        try:
            return _read_named[T](self, name)
        except f:
            raise Error(f.text())


trait FromJson(Deinitable, Movable):
    """An application type that `Json[T]` builds from a parsed request body.

    The application conforms its own type, in its own module, and reads the
    fields it needs; Muntin never names it. Unknown members are ignored
    unless `from_json` reads them."""

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        """Builds the value from the body's top-level JSON value. Raising
        rejects the request with 400 `Bad Request` without calling the
        handler."""
        ...


trait ToJson:
    """An application type that `Json[T]` writes as a response body.

    The application conforms its own type and writes it through the writer.
    Raising, or leaving the writer unbalanced, is a response-serialization
    failure: the response is the fixed 500, never the handler's error
    conversion, since the handler has already returned."""

    def write_json(self, mut out: JsonWriter) raises:
        """Writes the value as one JSON value."""
        ...


comptime _IN_ARRAY = 0
comptime _IN_OBJECT = 1


struct JsonWriter(Movable):
    """Builds one JSON text for `ToJson.write_json`.

    Separators are its job. It raises on a structural misuse (a value
    without a member name inside an object, a name outside one, a name
    repeated in one object, found at `end_object`, an unmatched close, a
    second top-level value) and on a non-finite number, which JSON cannot
    represent. Strings escape `"`, `\\` and every byte below 0x20; finite
    floats are written as `String(Float64)` prints them (on Mojo 1.1.0 not
    always the text of the same double; docs/ARCHITECTURE.md)."""

    var _out: String
    var _stack: List[Int]
    var _counts: List[Int]
    var _names: List[List[String]]
    var _named: Bool
    var _done: Bool

    def __init__(out self):
        self._out = String()
        self._stack = List[Int]()
        self._counts = List[Int]()
        self._names = List[List[String]]()
        self._named = False
        self._done = False

    def _before_value(mut self) raises:
        if len(self._stack) == 0:
            if self._done:
                raise Error("JSON writer: second top-level value")
            self._done = True
            return
        if self._stack[len(self._stack) - 1] == _IN_OBJECT:
            if not self._named:
                raise Error("JSON writer: value without a member name")
            self._named = False
            return
        if self._counts[len(self._counts) - 1] > 0:
            self._out += ","
        self._counts[len(self._counts) - 1] += 1

    def name(mut self, name: String) raises:
        """The next member's name, inside an object. A name repeated in one
        object raises at `end_object`."""
        if (
            len(self._stack) == 0
            or self._stack[len(self._stack) - 1] != _IN_OBJECT
        ):
            raise Error("JSON writer: member name outside an object")
        if self._named:
            raise Error("JSON writer: member name without a value")
        self._names[len(self._names) - 1].append(name)
        if self._counts[len(self._counts) - 1] > 0:
            self._out += ","
        self._counts[len(self._counts) - 1] += 1
        _escape_into(self._out, name)
        self._out += ":"
        self._named = True

    def begin_object(mut self) raises:
        self._before_value()
        self._out += "{"
        self._stack.append(_IN_OBJECT)
        self._counts.append(0)
        self._names.append(List[String]())

    def end_object(mut self) raises:
        """Closes the open object; raises if none is open, a name has no
        value, or a name was repeated in it."""
        if (
            len(self._stack) == 0
            or self._stack[len(self._stack) - 1] != _IN_OBJECT
            or self._named
        ):
            raise Error("JSON writer: unmatched end_object")
        # Repeated names: sorted and compared as neighbours, as the parser
        # does (a hash set's cost would depend on a predictable seed, and
        # names may come from request data).
        var names = self._names.pop()
        sort(names)
        for k in range(1, len(names)):
            if names[k] == names[k - 1]:
                raise Error("JSON writer: duplicate member name")
        _ = self._stack.pop()
        _ = self._counts.pop()
        self._out += "}"

    def begin_array(mut self) raises:
        self._before_value()
        self._out += "["
        self._stack.append(_IN_ARRAY)
        self._counts.append(0)

    def end_array(mut self) raises:
        if (
            len(self._stack) == 0
            or self._stack[len(self._stack) - 1] != _IN_ARRAY
        ):
            raise Error("JSON writer: unmatched end_array")
        _ = self._stack.pop()
        _ = self._counts.pop()
        self._out += "]"

    def null(mut self) raises:
        self._before_value()
        self._out += "null"

    def bool(mut self, value: Bool) raises:
        self._before_value()
        self._out += "true" if value else "false"

    def int(mut self, value: Int) raises:
        self._before_value()
        self._out += String(value)

    def float(mut self, value: Float64) raises:
        """A finite number; raises on NaN or infinity."""
        if (
            value != value
            or value > Float64.MAX_FINITE
            or value < -Float64.MAX_FINITE
        ):
            raise Error("JSON writer: non-finite number")
        self._before_value()
        self._out += String(value)

    def string(mut self, value: String) raises:
        self._before_value()
        _escape_into(self._out, value)

    # `value` and `field` are chosen by the value's type: Int, Float64, Bool,
    # String, a `ToJson` type or a `JsonFields` struct (M3-087), and an
    # `Optional` (empty: null) or a `List` (an array) of one of those. Each
    # combination is its own overload: on Mojo 1.1.0 a generic `value[T]`
    # cannot forward to the overload of its `T` (it resolves to the
    # `Optional` one by implicit conversion), and an unsupported type then
    # fails where it is called, `no matching method`. A `JsonFields` struct
    # is written by the derived rules, and its overloads exclude a `ToJson`
    # one, whose own writer takes over (without the `where`, such a type
    # matches both: ambiguous); a field of it that cannot be written fails
    # the overload's `comptime assert` when the codec is instantiated.

    def value(mut self, value: Int) raises:
        self.int(value)

    def value(mut self, value: Float64) raises:
        """A finite number; raises on NaN or infinity."""
        self.float(value)

    def value(mut self, value: Bool) raises:
        self.bool(value)

    def value(mut self, value: String) raises:
        self.string(value)

    def value[T: ToJson](mut self, value: T) raises:
        """A nested application value, written by its own `write_json`."""
        value.write_json(self)

    def value(mut self, value: Optional[Int]) raises:
        if value:
            self.int(value.value())
        else:
            self.null()

    def value(mut self, value: Optional[Float64]) raises:
        if value:
            self.float(value.value())
        else:
            self.null()

    def value(mut self, value: Optional[Bool]) raises:
        if value:
            self.bool(value.value())
        else:
            self.null()

    def value(mut self, value: Optional[String]) raises:
        if value:
            self.string(value.value())
        else:
            self.null()

    def value[T: ToJson](mut self, value: Optional[T]) raises:
        """The value, or null when empty."""
        if value:
            value.value().write_json(self)
        else:
            self.null()

    def value(mut self, value: List[Int]) raises:
        self.begin_array()
        for v in value:
            self.int(v)
        self.end_array()

    def value(mut self, value: List[Float64]) raises:
        self.begin_array()
        for v in value:
            self.float(v)
        self.end_array()

    def value(mut self, value: List[Bool]) raises:
        self.begin_array()
        for v in value:
            self.bool(v)
        self.end_array()

    def value(mut self, value: List[String]) raises:
        self.begin_array()
        for v in value:
            self.string(v)
        self.end_array()

    def value[T: ToJson](mut self, value: List[T]) raises:
        """An array of the elements. Indexed, not iterated: `List` iteration
        requires `Copyable` elements, so a move-only `T` works."""
        self.begin_array()
        for i in range(len(value)):
            value[i].write_json(self)
        self.end_array()

    def value[
        T: JsonFields
    ](mut self, value: T) raises where not conforms_to(T, ToJson):
        """A `JsonFields` struct, written as `Json[T]` writes it (M3-087). A
        field that cannot be written fails its `comptime assert`, naming
        it."""
        comptime assert _call_refusal[T, False]() == "", _call_refusal[
            T, False
        ]()
        _write_value(self, value)

    def value[
        T: JsonFields
    ](mut self, value: Optional[T]) raises where not conforms_to(T, ToJson):
        comptime assert _call_refusal[T, False]() == "", _call_refusal[
            T, False
        ]()
        _write_value(self, value)

    def value[
        T: JsonFields
    ](mut self, value: List[T]) raises where not conforms_to(T, ToJson):
        comptime assert _call_refusal[T, False]() == "", _call_refusal[
            T, False
        ]()
        _write_value(self, value)

    def field(mut self, name: String, value: Int) raises:
        """One object member: `name(name)`, then `value(value)`."""
        self.name(name)
        self.value(value)

    def field(mut self, name: String, value: Float64) raises:
        self.name(name)
        self.value(value)

    def field(mut self, name: String, value: Bool) raises:
        self.name(name)
        self.value(value)

    def field(mut self, name: String, value: String) raises:
        self.name(name)
        self.value(value)

    def field[T: ToJson](mut self, name: String, value: T) raises:
        self.name(name)
        self.value(value)

    def field(mut self, name: String, value: Optional[Int]) raises:
        self.name(name)
        self.value(value)

    def field(mut self, name: String, value: Optional[Float64]) raises:
        self.name(name)
        self.value(value)

    def field(mut self, name: String, value: Optional[Bool]) raises:
        self.name(name)
        self.value(value)

    def field(mut self, name: String, value: Optional[String]) raises:
        self.name(name)
        self.value(value)

    def field[T: ToJson](mut self, name: String, value: Optional[T]) raises:
        self.name(name)
        self.value(value)

    def field(mut self, name: String, value: List[Int]) raises:
        self.name(name)
        self.value(value)

    def field(mut self, name: String, value: List[Float64]) raises:
        self.name(name)
        self.value(value)

    def field(mut self, name: String, value: List[Bool]) raises:
        self.name(name)
        self.value(value)

    def field(mut self, name: String, value: List[String]) raises:
        self.name(name)
        self.value(value)

    def field[T: ToJson](mut self, name: String, value: List[T]) raises:
        self.name(name)
        self.value(value)

    def field[
        T: JsonFields
    ](mut self, name: String, value: T) raises where not conforms_to(T, ToJson):
        self.name(name)
        self.value(value)

    def field[
        T: JsonFields
    ](mut self, name: String, value: Optional[T]) raises where not conforms_to(
        T, ToJson
    ):
        self.name(name)
        self.value(value)

    def field[
        T: JsonFields
    ](mut self, name: String, value: List[T]) raises where not conforms_to(
        T, ToJson
    ):
        self.name(name)
        self.value(value)

    def _holds(self, name: String) -> Bool:
        """Whether the open object already has a member `name` (the
        derived-member check of `App.openapi`'s additions)."""
        if len(self._names) == 0:
            return False
        for n in self._names[len(self._names) - 1]:
            if n == name:
                return True
        return False

    def _copy(mut self, value: JsonValue) raises:
        """`value` as parsed: a number keeps its literal, an object its
        members' order (`App.openapi`'s additions)."""
        var k = value._kind()
        if k == _NULL:
            self.null()
        elif k == _TRUE or k == _FALSE:
            self.bool(k == _TRUE)
        elif k == _NUMBER:
            self._before_value()
            self._out += value._literal()
        elif k == _STRING:
            self.string(value.string())
        elif k == _ARRAY:
            self.begin_array()
            for i in range(len(value)):
                self._copy(value._child(i))
            self.end_array()
        else:
            self.begin_object()
            for i in range(len(value)):
                var member = value._child(i)
                self.name(member._name())
                self._copy(member)
            self.end_object()

    def _finish(deinit self) raises -> String:
        """The text; raises if the document is empty or unfinished."""
        if len(self._stack) != 0 or not self._done:
            raise Error("JSON writer: incomplete document")
        return self._out^


def _escape_into(mut out: String, value: String):
    out += '"'
    var run = 0
    var bytes = value.as_bytes()
    for i in range(len(bytes)):
        var c = Int(bytes[i])
        if c != ord('"') and c != ord("\\") and c >= 0x20:
            continue
        out += String(value[byte=run:i])
        if c == ord('"'):
            out += '\\"'
        elif c == ord("\\"):
            out += "\\\\"
        elif c == 0x0A:
            out += "\\n"
        elif c == 0x0D:
            out += "\\r"
        elif c == 0x09:
            out += "\\t"
        else:
            out += "\\u00"
            out += "0123456789abcdef"[byte=c >> 4]
            out += "0123456789abcdef"[byte=c & 15]
        run = i + 1
    out += String(value[byte = run : len(bytes)])
    out += '"'


trait _JsonBody:
    """Marks `Json`, so the body adapters in `app.mojo` can tell a JSON
    body at compile time and run the request `Content-Type` and size steps
    before `from_body` (as `_InjectedState` marks `State`), and the
    registration rules read its refusals: empty when the body can be read
    (`_read_refusal`) or the result written (`_write_refusal`), else the
    message naming what cannot (M3-083). Private; it adds nothing to
    `Json`'s public surface."""

    comptime _read_refusal: String
    comptime _write_refusal: String

    @staticmethod
    def _schema[reading: Bool](mut out: JsonWriter) raises:
        """The JSON Schema of the value read (`reading`) or written
        (`App.openapi`, M3-091)."""
        ...


trait _JsonText:
    """`Json`'s body conversion in its two steps (M3-084), so a typed route
    reports a body that is not JSON (`Rejection.JSON`) apart from a failed
    conversion (`Rejection.FROM_JSON`): a `from_json` raise, or a derived
    reader's failure prefixed with its member path. Private; a carrier does not
    conform, and converts its `Json[T]` through it."""

    @staticmethod
    def _from_text(text: String) raises _BodyFault -> Self:
        ...


struct Json[T: Movable & Deinitable, *, limit: Int = _MAX_BODY_BYTES](
    Deinitable,
    FromBody where (
        conforms_to(T, FromJson)
        or conforms_to(T, JsonFields)
        or conforms_to(T, Iterable)
    ),
    Movable,
    ToResponse where (
        conforms_to(T, ToJson)
        or conforms_to(T, JsonFields)
        or conforms_to(T, Iterable)
    ),
    _JsonBody,
    _JsonText,
):
    """A JSON request body or response body around an application value.

    `T` is a `FromJson` (read) or `ToJson` (written) type, a `JsonFields`
    struct (both, derived from its fields, M3-083), or a `List` or
    `Optional` of one; the registration rules refuse any other `T`, naming
    the innermost field that cannot be read or written (`_refusal`).

    As a body: a typed route requires exactly one request
    `Content-Type` field whose media type is `application/json` (else 415)
    and a body of at most `limit` bytes, 1 MiB unless the route's type says
    another (`Json[T, limit=64 * 1024]`, M3-089; else 413); `limit` is the
    body's `max_bytes`, from 0 to 2^32 - 1 (`_LARGEST_LIMIT`), checked at
    compile time where the body is read, and means nothing on a result. The body is then parsed strictly
    and the value built, either failing answers 400, all
    before the handler. As a result: the value is written as the
    body and the response has the status given to the initializer (200 by
    default) and exactly `Content-Type: application/json`; a serialization
    failure is the fixed 500, whatever the status. A status that never
    carries content (1xx, 204, 205, 304) has no body and no fields, and
    the value is not written (M3-093). The value
    is moved in and out (`Json(v^)`, `body^.take()`), so a move-only `T`
    works. A handler may borrow the body (`body: Json[T]`, read
    `body.value`) or own it (`var body`).
    """

    comptime max_bytes = Self.limit
    comptime _read_refusal: String = _refusal[Self.T, True]()
    comptime _write_refusal: String = _refusal[Self.T, False]()

    var value: Self.T
    # The result's status, read once by `to_response`. A body built by
    # `from_body` holds the default, which nothing on the request path reads.
    var _status: Int

    def __init__(out self, var value: Self.T, *, status: Int = 200):
        """Moves `value` in. `status` is the response's status when the
        value is a result (not validated, as for `Response`)."""
        self.value = value^
        self._status = status

    def take(deinit self) -> Self.T:
        """Moves the value out (`body^.take()`): a field cannot be moved
        out of the middle of a `Json` on Mojo 1.1.0."""
        return self.value^

    @staticmethod
    def _schema[reading: Bool](mut out: JsonWriter) raises:
        _write_schema[Self.T, reading](out)

    @staticmethod
    def from_body(
        body: String,
    ) raises -> Self where (
        conforms_to(Self.T, FromJson)
        or conforms_to(Self.T, JsonFields)
        or conforms_to(Self.T, Iterable)
    ):
        """Parses `body` and builds the value (`T.from_json`, or derived
        from a `JsonFields` struct's fields). Raises on malformed JSON, a
        body over its `limit`, or a failed conversion, whose message a derived
        reader prefixes with the member path (`notes[2].text: ...`). A typed
        route answers the `Content-Type` and size steps before calling it;
        a raw handler may call it directly, and its error model applies to
        the raise."""
        comptime assert _refusal[Self.T, True]() == "", _refusal[Self.T, True]()
        _check_limit[Self.max_bytes]()
        return Self(_read_json[Self.T](_parse_json(body, Self.max_bytes)))

    @staticmethod
    def _from_text(text: String) raises _BodyFault -> Self:
        """`from_body` on a typed route: the parse and the conversion raise
        `Rejection.JSON` and `Rejection.FROM_JSON` (M3-084)."""
        comptime assert _refusal[Self.T, True]() == "", _refusal[Self.T, True]()
        _check_limit[Self.max_bytes]()
        var value: JsonValue
        try:
            value = _parse_json(text, Self.max_bytes)
        except e:
            raise _BodyFault(Rejection.JSON, String(e))
        try:
            return Self(_read_value[Self.T](value))
        except f:
            raise _BodyFault(Rejection.FROM_JSON, f.text())

    def to_response(
        var self,
    ) -> Response where (
        conforms_to(Self.T, ToJson)
        or conforms_to(Self.T, JsonFields)
        or conforms_to(Self.T, Iterable)
    ):
        """The chosen status (200 by default) with the written body and
        exactly `Content-Type: application/json`. A raising or unbalanced
        `write_json`, or a non-finite number, answers the fixed 500
        (`Internal Server Error`, no fields) instead, whatever the status,
        carrying a `Failure.RESPONSE` report of the error's text (M3-058);
        no partial body is sent. A status that never carries content (1xx,
        204, 205, 304) answers with no body and no fields, and the value is
        not written, so it cannot fail (M3-093)."""
        comptime assert _refusal[Self.T, False]() == "", _refusal[
            Self.T, False
        ]()
        if _never_carries_content(self._status):
            return Response(self._status, "")
        var out = JsonWriter()
        try:
            _write_value(out, self.value)
            var r = Response(self._status, out^._finish())
            r.headers.set("Content-Type", "application/json")
            return r^
        except e:
            return _failed(Failure.RESPONSE, String(e))


def _never_carries_content(status: Int) -> Bool:
    """Whether a response of `status` never carries content (RFC 9110:
    1xx, 204 and 304 have none, and a 205 must have none), the set M3-026's
    `HEAD` rule names too."""
    return (
        (status >= 100 and status <= 199)
        or status == 204
        or status == 205
        or status == 304
    )


def _json_content_type(headers: Headers) -> Bool:
    """The request rule for a JSON body: exactly one `Content-Type` field
    whose media type (the text before any `;`, SP/HTAB trimmed) is
    `application/json`, ASCII case-insensitively (bytes, not Unicode case
    folding: `applİcation/json` is not it). Parameters (such as
    `charset=utf-8`) are not interpreted: RFC 8259 defines none, and the
    body is read as UTF-8. `+json` types are not `application/json`."""
    var fields = headers.get_all("content-type")
    if len(fields) != 1:
        return False
    var v = fields[0]
    var semi = v.find(";")
    var media = String(v[byte=:semi]) if semi >= 0 else v
    var bytes = media.as_bytes()
    var a = 0
    var z = len(bytes)
    while a < z and (Int(bytes[a]) == 0x20 or Int(bytes[a]) == 0x09):
        a += 1
    while z > a and (Int(bytes[z - 1]) == 0x20 or Int(bytes[z - 1]) == 0x09):
        z -= 1
    var want = "application/json".as_bytes()
    if z - a != len(want):
        return False
    for k in range(len(want)):
        var c = Int(bytes[a + k])
        if c >= ord("A") and c <= ord("Z"):
            c += 32
        if c != Int(want[k]):
            return False
    return True


# Derived codecs (M3-083, decision M3-082).


trait JsonFields(_FieldBuilt):
    """Marks an application struct whose JSON form is an object with one
    member per field, named after the field, so `Json[T]` reads and writes
    it without a hand-written `from_json` or `write_json` (M3-083).

    A field is an `Int`, `Float64`, `Bool`, `String`, a `FromJson` (read)
    or `ToJson` (written) type, a `JsonFields` struct, or a `List` or
    `Optional` (not of an `Optional`) of one. An `Optional` member may be
    absent or `null`; every other member is required; unknown members are
    ignored. Conforming consents to Muntin building the value field by field
    without running any of its initializers (as for `RouteValues`), so a
    conforming struct is a receiving DTO: any combination of field values
    must be valid to hold, use and destroy. A type with an invariant is
    built from a checked DTO by its own constructor, or read by a
    hand-written `from_json`. A hand-written `FromJson` or `ToJson` on the
    same type takes that direction over."""

    pass


struct _MemberFault(Movable):
    """A derived read's failure: the member path from the top-level value
    (`.notes[2].text`, innermost segment prepended last) and the message."""

    var path: String
    var message: String

    def __init__(out self, var path: String, var message: String):
        self.path = path^
        self.message = message^

    def text(self) -> String:
        """`notes[2].text: message`, or the message alone at the top."""
        if not self.path:
            return self.message
        var at = 1 if self.path.startswith(".") else 0
        return String(self.path[byte=at:]) + ": " + self.message


def _scalar[F: AnyType]() -> Bool:
    return F == Int or F == Float64 or F == Bool or F == String


def _kind_ok[F: AnyType, reading: Bool]() -> Bool:
    """Whether a derived codec reads (`reading`) or writes `F`."""
    comptime if _scalar[F]():
        return True
    elif reading and conforms_to(F, FromJson):
        return True
    elif not reading and conforms_to(F, ToJson):
        return True
    elif conforms_to(F, JsonFields):
        return _fields_ok[F, reading]()
    elif conforms_to(F, Iterable):
        comptime E = F.IteratorType[ImmutAnyOrigin].Element
        comptime if conforms_to(E, Movable & Deinitable):
            comptime if F == List[E]:
                return _kind_ok[E, reading]()
            elif F == Optional[E]:
                # `Optional[Optional[X]]` would write some-none as `null`,
                # which reads back as none.
                comptime if _is_optional[E]():
                    return False
                return _kind_ok[E, reading]()
        return False
    else:
        return False


def _is_optional[T: AnyType]() -> Bool:
    comptime if conforms_to(T, Iterable):
        comptime E = T.IteratorType[ImmutAnyOrigin].Element
        comptime if conforms_to(E, Movable & Deinitable):
            return T == Optional[E]
    return False


def _fields_ok[T: AnyType, reading: Bool]() -> Bool:
    comptime r = reflect[T]
    comptime types = r.field_types()
    comptime for i in range(r.field_count()):
        comptime if not _kind_ok[types[i], reading]():
            return False
    return True


def _refusal[T: AnyType, reading: Bool]() -> String:
    """Empty when `Json[T]` can be read (`reading`) or written; else the
    registration message, naming the innermost field that cannot."""
    comptime if _kind_ok[T, reading]():
        return ""
    var inner = _innermost[T, reading]()
    if inner:
        return inner
    return (
        "Json["
        + String(reflect[T].name())
        + "] cannot be "
        + ("read" if reading else "written")
    )


def _call_refusal[T: AnyType, reading: Bool]() -> String:
    """`_refusal` for a hand-written codec's call (`JsonValue.read`,
    `JsonWriter.value` and `field`, M3-087): the type itself, not
    `Json[T]`, when no field is to blame."""
    comptime if _kind_ok[T, reading]():
        return ""
    var inner = _innermost[T, reading]()
    if inner:
        return inner
    return (
        String(reflect[T].name())
        + " cannot be "
        + ("read" if reading else "written")
        + ": a derived value is an Int, Float64, Bool, String, a "
        + ("FromJson" if reading else "ToJson")
        + " type, a JsonFields struct, or a List or Optional of one"
    )


def _innermost[F: AnyType, reading: Bool]() -> String:
    """The message naming the innermost field that cannot be read or
    written, when `F` is a `JsonFields` struct, or a `List` or `Optional`
    of one, that has one; else empty (the refused type is `F` itself)."""
    comptime if reading and conforms_to(F, FromJson):
        return ""
    elif not reading and conforms_to(F, ToJson):
        return ""
    elif conforms_to(F, JsonFields):
        comptime r = reflect[F]
        comptime names = r.field_names()
        comptime types = r.field_types()
        comptime for i in range(r.field_count()):
            comptime if not _kind_ok[types[i], reading]():
                var inner = _innermost[types[i], reading]()
                if inner:
                    return inner
                return (
                    "field "
                    + String(materialize[names[i]]())
                    + " of the JsonFields struct "
                    + String(r.name())
                    + " has type "
                    + String(reflect[types[i]].name())
                    + ", which cannot be "
                    + ("read" if reading else "written")
                    + ": a derived field is an Int, Float64, Bool, String, a "
                    + ("FromJson" if reading else "ToJson")
                    + " type, a JsonFields struct, or a List or Optional of"
                    + " one"
                )
        return ""
    elif conforms_to(F, Iterable):
        comptime E = F.IteratorType[ImmutAnyOrigin].Element
        comptime if conforms_to(E, Movable & Deinitable):
            comptime if F == List[E] or (
                F == Optional[E] and not _is_optional[E]()
            ):
                return _innermost[E, reading]()
        return ""
    else:
        return ""


def _write_value[F: AnyType](mut out: JsonWriter, ref f: F) raises:
    comptime if F == Int:
        out.int(_view[Int](f))
    elif F == Float64:
        out.float(_view[Float64](f))
    elif F == Bool:
        out.bool(_view[Bool](f))
    elif F == String:
        out.string(_view[String](f))
    elif conforms_to(F, ToJson):
        f.write_json(out)
    elif conforms_to(F, JsonFields):
        comptime r = reflect[F]
        comptime names = r.field_names()
        comptime types = r.field_types()
        out.begin_object()
        comptime for i in range(r.field_count()):
            out.name(String(materialize[names[i]]()))
            _write_value[types[i]](out, r.field_ref[i](f))
        out.end_object()
    elif conforms_to(F, Iterable):
        comptime E = F.IteratorType[ImmutAnyOrigin].Element
        comptime if conforms_to(E, Movable & Deinitable):
            comptime if F == List[E]:
                ref l = _view[List[E]](f)
                out.begin_array()
                for i in range(len(l)):
                    _write_value[E](out, l[i])
                out.end_array()
            elif F == Optional[E]:
                ref o = _view[Optional[E]](f)
                if o:
                    _write_value[E](out, o.value())
                else:
                    out.null()
            else:
                comptime assert False, "not a JSON kind"
        else:
            comptime assert False, "not a JSON kind"
    else:
        comptime assert False, "not a JSON kind"


def _read_json[F: Movable & Deinitable](v: JsonValue) raises -> F:
    """`F` from a parsed document, its failure's message prefixed with the
    member path (`Json.from_body`)."""
    try:
        return _read_value[F](v)
    except f:
        raise Error(f.text())


def _read_member[
    F: Movable & Deinitable, i: Int
](value: JsonValue, names: List[String]) raises _MemberFault -> F:
    """Field `i` of a derived struct (`_read_named`)."""
    return _read_named[F](value, names[i])


def _read_named[
    F: Movable & Deinitable
](value: JsonValue, name: String) raises _MemberFault -> F:
    """The member `name`: an absent or `null` member is an empty
    `Optional`; any other field requires its member. A failure's path gains
    the member. The one rule of a derived field and `JsonValue.read`."""
    var m: Optional[JsonValue]
    try:
        m = value.get(name)
    except e:
        raise _MemberFault("", String(e))
    comptime if conforms_to(F, Iterable):
        comptime E = F.IteratorType[ImmutAnyOrigin].Element
        comptime if conforms_to(E, Movable & Deinitable):
            comptime if F == Optional[E]:
                if not m or m.value().is_null():
                    return _as[Optional[E], F](Optional[E]())
    if not m:
        raise _MemberFault("." + name, "JSON member is missing")
    try:
        return _read_value[F](m.value())
    except f:
        raise _MemberFault("." + name + f.path, f.message)


def _read_list[
    E: Movable & Deinitable
](v: JsonValue) raises _MemberFault -> List[E]:
    # Bounded here, not refined where it is called: a refined `E` does not
    # make `List[E]` `Deinitable` there.
    if v._kind() != _ARRAY:
        raise _MemberFault("", "JSON value is not an array")
    var l = List[E](capacity=len(v))
    for i in range(len(v)):
        try:
            l.append(_read_value[E](v._child(i)))
        except f:
            raise _MemberFault("[" + String(i) + "]" + f.path, f.message)
    return l^


def _read_value[F: Movable & Deinitable](v: JsonValue) raises _MemberFault -> F:
    """`F` from `v`. A failure is raised with an empty path; each enclosing
    member or element prepends its own segment."""
    comptime if _scalar[F]():
        try:
            comptime if F == Int:
                return _as[Int, F](v.int())
            elif F == Float64:
                return _as[Float64, F](v.float())
            elif F == Bool:
                return _as[Bool, F](v.bool())
            else:
                return _as[String, F](v.string())
        except e:
            raise _MemberFault("", String(e))
    elif conforms_to(F, FromJson):
        try:
            return F.from_json(v)
        except e:
            raise _MemberFault("", String(e))
    elif conforms_to(F, JsonFields):
        comptime r = reflect[F]
        comptime names = r.field_names()
        if v._kind() != _OBJECT:
            raise _MemberFault("", "JSON value is not an object")
        var ns = List[String](capacity=r.field_count())
        comptime for i in range(r.field_count()):
            ns.append(String(materialize[names[i]]()))
        return _build_record[F, _MemberFault, _read_member, 0](v, ns)
    elif conforms_to(F, Iterable):
        comptime E = F.IteratorType[ImmutAnyOrigin].Element
        comptime if conforms_to(E, Movable & Deinitable):
            comptime if F == List[E]:
                return _as_list[E, F](_read_list[E](v))
            else:
                comptime assert F == Optional[E], "not a JSON kind"
                return _as_optional[E, F](v)
        else:
            comptime assert conforms_to(
                E, Movable & Deinitable
            ), "not a JSON kind"
            raise _MemberFault("", "not a JSON kind")
    else:
        comptime assert conforms_to(F, Iterable), "not a JSON kind"
        raise _MemberFault("", "not a JSON kind")


def _as_list[
    E: Movable & Deinitable, F: Movable & Deinitable
](var l: List[E]) -> F:
    return _as[List[E], F](l^)


def _as_optional[
    E: Movable & Deinitable, F: Movable & Deinitable
](v: JsonValue) raises _MemberFault -> F:
    if v.is_null():
        return _as[Optional[E], F](Optional[E]())
    return _as[Optional[E], F](Optional(_read_value[E](v)))


# Schemas (M3-091): the JSON Schema of what the derived codec
# reads (`reading`) or writes, by the same rules as `_kind_ok`. A
# hand-written direction has no schema source, so it is `{}` (any value).


def _write_schema[F: AnyType, reading: Bool](mut out: JsonWriter) raises:
    comptime if F == Int:
        out.begin_object()
        out.field("type", "integer")
        out.field("format", "int64")
        out.field("minimum", Int.MIN)
        out.field("maximum", Int.MAX)
        out.end_object()
    elif F == Float64:
        out.begin_object()
        out.field("type", "number")
        out.field("format", "double")
        out.end_object()
    elif F == Bool:
        out.begin_object()
        out.field("type", "boolean")
        out.end_object()
    elif F == String:
        out.begin_object()
        out.field("type", "string")
        out.end_object()
    elif reading and conforms_to(F, FromJson):
        out.begin_object()
        out.end_object()
    elif not reading and conforms_to(F, ToJson):
        out.begin_object()
        out.end_object()
    elif conforms_to(F, JsonFields):
        comptime r = reflect[F]
        comptime names = r.field_names()
        comptime types = r.field_types()
        out.begin_object()
        out.field("type", "object")
        out.name("properties")
        out.begin_object()
        comptime for i in range(r.field_count()):
            out.name(String(materialize[names[i]]()))
            _write_schema[types[i], reading](out)
        out.end_object()
        out.name("required")
        out.begin_array()
        comptime for i in range(r.field_count()):
            # A read takes an absent `Optional` member; a write always
            # writes the member (`null` when empty).
            comptime if not (reading and _is_optional[types[i]]()):
                out.string(String(materialize[names[i]]()))
        out.end_array()
        comptime if not reading:
            out.field("additionalProperties", False)
        out.end_object()
    elif conforms_to(F, Iterable):
        comptime E = F.IteratorType[ImmutAnyOrigin].Element
        comptime if conforms_to(E, Movable & Deinitable):
            comptime if F == List[E]:
                out.begin_object()
                out.field("type", "array")
                out.name("items")
                _write_schema[E, reading](out)
                out.end_object()
            elif F == Optional[E]:
                out.begin_object()
                out.name("anyOf")
                out.begin_array()
                _write_schema[E, reading](out)
                out.begin_object()
                out.field("type", "null")
                out.end_object()
                out.end_array()
                out.end_object()
            else:
                comptime assert False, "not a JSON kind"
        else:
            comptime assert False, "not a JSON kind"
    else:
        comptime assert False, "not a JSON kind"
