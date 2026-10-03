# M3-008 JSON codec decision spike, library side. Not production code: it
# models the selected contract (candidate A with the application traits of
# candidate B: a Muntin-owned `Json[T]` wrapper that is a `FromBody` and a
# `ToResponse` through the existing traits, for `T: FromJson` / `T: ToJson`),
# the Muntin-owned strict codec the wrapper uses (`JsonValue`, `parse_json`,
# `JsonWriter`), the request Content-Type rule, and a mirror of the body
# adapters' steps with the selected order (`model_post`, `model_post_int`).
# The application module is tests/test_spike_json.mojo; check.sh builds this
# file through it (--Werror) and through tests/json_lib_only/driver.mojo;
# test.sh runs it. Decision and evidence: docs/ARCHITECTURE.md, "JSON codec
# decision (M3-008)". Must-not-compile evidence: tests/json_fail.
#
# Only documented Mojo 1.1.0 features are used: conditional conformance with
# `where`-gated methods (manual/generics.mdx, "Conditional trait
# conformance"), `conforms_to` in `comptime if`, and safe std types.

from std.collections import Optional, Set
from muntin import FromBody, Headers, Request, Response, ToResponse
from muntin._handler_storage import _Shared


# Nesting cap for untrusted input: an array or object nested deeper than this
# is rejected (400 through `from_body`), so the recursive parser's stack is
# bounded.
comptime MAX_DEPTH = 64

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
    About 24 bytes, plus 4 in the child table."""

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
    node indices, contiguous per container (O(1) element access)."""

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


struct _Parser:
    """Strict RFC 8259 recursive descent over the body's bytes. Rejects:
    comments, trailing commas, single quotes, leading zeros, `+` signs,
    `NaN`/`Infinity`, a byte order mark, unescaped control bytes in strings,
    bad escapes, lone surrogates, duplicate member names, trailing content,
    an empty body, and nesting deeper than `MAX_DEPTH`. Linear in the body:
    duplicate names are found with a hash set per object, and nodes store
    spans, not copies."""

    var text: String
    var i: Int
    var n: Int
    var nodes: List[_Node]
    var kids: List[UInt32]

    def __init__(out self, text: String):
        self.text = text
        self.i = 0
        self.n = text.byte_length()
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
            if depth >= MAX_DEPTH:
                raise Error("invalid JSON: nesting too deep")
            var obj = c == ord("{")
            kind = _OBJECT if obj else _ARRAY
            self.i += 1
            self._ws()
            var close = ord("}") if obj else ord("]")
            var children = List[UInt32]()
            var names = Set[String]()
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
                        if name in names:
                            raise Error("invalid JSON: duplicate member")
                        names.add(name^)
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


def parse_json(text: String) raises -> JsonValue:
    """Parses one JSON text (RFC 8259, strict; see `_Parser`). Raises on
    anything else; through `Json.from_body` that is 400. Keeps one copy of
    the text (production would hold the request body it already has)."""
    var p = _Parser(text)
    _ = p.value(0, 0, 0, 0)
    p._ws()
    if p.i != p.n:
        raise Error("invalid JSON: trailing content")
    var nodes = List[_Node]()
    var kids = List[UInt32]()
    swap(nodes, p.nodes)
    swap(kids, p.kids)
    return JsonValue(_doc=_Shared(_Doc(text, nodes^, kids^)), _at=0)


struct JsonValue(Copyable, Movable, Sized):
    """A read-only position in a parsed JSON document. The document is held
    in M3-004's sealed `_Shared` box: copies share it (one reference count
    increment, no copy), and no handle can replace or mutate it on an
    ordinary path, so a position stays valid. Positions are made only by
    the parser and the accessors (the initializer's arguments are internal).
    Accessors return values, never references into the document. Every
    accessor raises when the value is not of the asked kind, so a
    `from_json` that reads a wrong or missing field raises, and
    `Json.from_body` answers 400."""

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

    def is_null(self) -> Bool:
        return self._kind() == _NULL

    def bool(self) raises -> Bool:
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
        """An integer literal (no fraction, no exponent) that fits `Int`."""
        if self._kind() != _NUMBER:
            raise Error("JSON value is not a number")
        var t = self._literal()
        if t.find(".") >= 0 or t.find("e") >= 0 or t.find("E") >= 0:
            raise Error("JSON number is not an integer")
        return Int(t)

    def float(self) raises -> Float64:
        """A number literal as a finite `Float64`, through Mojo 1.1.0's
        `atof`: not always correctly rounded, and raising on long literals
        (docs/ARCHITECTURE.md, "JSON codec decision (M3-008)")."""
        if self._kind() != _NUMBER:
            raise Error("JSON value is not a number")
        var x = atof(self._literal())
        if x != x or x > Float64.MAX_FINITE or x < -Float64.MAX_FINITE:
            raise Error("JSON number is out of range")
        return x

    def string(self) raises -> String:
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
        """The `index`th array element, in constant time."""
        if self._kind() != _ARRAY:
            raise Error("JSON value is not an array")
        if index < 0 or index >= Int(self._node().count):
            raise Error("JSON array index out of range")
        return self._child(index)

    def get(self, name: String) raises -> Optional[JsonValue]:
        """The member `name` of an object, or `None` when it is absent. A
        member present as `null` is a value (`is_null()`). Linear in the
        object's members."""
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
        """The member `name` of an object; raises when it is absent."""
        var found = self.get(name)
        if not found:
            raise Error("JSON member is missing")
        return found.take()


trait FromJson(Deinitable, Movable):
    """An application type that `Json[T]` builds from a parsed request body.
    The application conforms its own type and reads the fields it needs;
    raising rejects the request with 400."""

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        ...


trait ToJson:
    """An application type that `Json[T]` writes as a response body. The
    application conforms its own type and writes it through the writer;
    raising (or leaving the writer unbalanced) is a response-serialization
    failure, answered with the fixed 500, never with the handler's error
    conversion."""

    def write_json(self, mut out: JsonWriter) raises:
        ...


comptime _IN_ARRAY = 0
comptime _IN_OBJECT = 1


struct JsonWriter(Movable):
    """Builds one JSON text. Separators are its job; it raises on a
    structural misuse (a value without a member name inside an object, a
    name outside one, a name repeated in one object, which Muntin's parser
    rejects, an unmatched close, a second top-level value) and on a
    non-finite number, which JSON cannot represent."""

    var _out: String
    var _stack: List[Int]
    var _counts: List[Int]
    var _names: List[Set[String]]
    var _named: Bool
    var _done: Bool

    def __init__(out self):
        self._out = String()
        self._stack = List[Int]()
        self._counts = List[Int]()
        self._names = List[Set[String]]()
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
        if (
            len(self._stack) == 0
            or self._stack[len(self._stack) - 1] != _IN_OBJECT
        ):
            raise Error("JSON writer: member name outside an object")
        if self._named:
            raise Error("JSON writer: member name without a value")
        if name in self._names[len(self._names) - 1]:
            raise Error("JSON writer: duplicate member name")
        self._names[len(self._names) - 1].add(name)
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
        self._names.append(Set[String]())

    def end_object(mut self) raises:
        if (
            len(self._stack) == 0
            or self._stack[len(self._stack) - 1] != _IN_OBJECT
            or self._named
        ):
            raise Error("JSON writer: unmatched end_object")
        _ = self._stack.pop()
        _ = self._counts.pop()
        _ = self._names.pop()
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

    def value[T: ToJson](mut self, value: T) raises:
        """A nested application value, written by its own `write_json`."""
        value.write_json(self)

    def finish(deinit self) raises -> String:
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
    """Private marker: a body type whose conversion is the JSON codec's. The
    body adapters check the request Content-Type for it (selected rule)."""

    pass


struct Json[T: Movable & Deinitable](
    Deinitable,
    FromBody where conforms_to(T, FromJson),
    Movable,
    ToResponse where conforms_to(T, ToJson),
    _JsonBody,
):
    """A JSON request body or response body around an application value.

    As a body (`T: FromJson`): the request body is parsed strictly and
    `T.from_json` builds the value; either failing is 400 before the
    handler. As a result (`T: ToJson`): `T.write_json` writes the body, and
    the response is 200 with `Content-Type: application/json`; a writer
    failure is the fixed 500. The value is moved in and out (`Json(v^)`,
    `body^.take()`), so a move-only `T` works."""

    var value: Self.T

    def __init__(out self, var value: Self.T):
        self.value = value^

    def take(deinit self) -> Self.T:
        """Moves the value out (`body^.take()`): a field cannot be moved
        out of the middle of a `Json` on Mojo 1.1.0."""
        return self.value^

    @staticmethod
    def from_body(
        body: String,
    ) raises -> Self where conforms_to(Self.T, FromJson):
        return Self(Self.T.from_json(parse_json(body)))

    def to_response(var self) -> Response where conforms_to(Self.T, ToJson):
        var out = JsonWriter()
        try:
            self.value.write_json(out)
            var r = Response(200, out^.finish())
            r.headers.set("Content-Type", "application/json")
            return r^
        except:
            return _serialization_failure()


def _serialization_failure() -> Response:
    """Same bytes as the fixed 500 for a handler error, reached on a
    different path: the handler returned, its error conversion never runs."""
    return Response.text("Internal Server Error", status=500)


def json_content_type(headers: Headers) -> Bool:
    """The selected request rule: exactly one `Content-Type` field whose
    media type (the text before any `;`, SP/HTAB trimmed) is
    `application/json`, ASCII case-insensitively (bytes, not Unicode case
    folding: `applİcation/json` is not it). Parameters (such as
    `charset=utf-8`) are not interpreted: RFC 8259 defines none, and the
    body is read as UTF-8."""
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


def _unsupported_media_type() -> Response:
    return Response.text("Unsupported Media Type", status=415)


def model_post[
    B: FromBody, R: ToResponse, E: Deinitable
](handler: def(var B) thin raises E -> R, request: Request) -> Response:
    """Mirror of `_call_body` with the selected Content-Type step: for a JSON
    body (`_JsonBody`), a request without `application/json` is 415 before
    `from_body`; other bodies are unchanged. A handler error is the fixed
    500 here (the production adapter's `_handler_error` is unchanged by the
    decision)."""
    comptime if conforms_to(B, _JsonBody):
        if not json_content_type(request.headers):
            return _unsupported_media_type()
    var body: B
    try:
        body = B.from_body(request.body)
    except:
        return Response.text("Bad Request", status=400)
    try:
        return handler(body^).to_response()
    except:
        return Response.text("Internal Server Error", status=500)


def model_post_int[
    B: FromBody, R: ToResponse, E: Deinitable
](
    handler: def(Int, var B) thin raises E -> R,
    segment: String,
    request: Request,
) -> Response:
    """Mirror of `_call_int_body`: the route value converts first (400),
    then the Content-Type step (415), then the body (400)."""
    var id: Int
    try:
        id = Int(segment)
    except:
        return Response.text("Bad Request", status=400)
    comptime if conforms_to(B, _JsonBody):
        if not json_content_type(request.headers):
            return _unsupported_media_type()
    var body: B
    try:
        body = B.from_body(request.body)
    except:
        return Response.text("Bad Request", status=400)
    try:
        return handler(id, body^).to_response()
    except:
        return Response.text("Internal Server Error", status=500)


def json_response[T: ToJson](value: T, status: Int = 200) raises -> Response:
    """Candidate C (rejected), modeled: a response helper only. It covers no
    request side, and it raises inside the handler, so a serialization
    failure becomes a handler error (`ToErrorResponse` or the fixed 500)."""
    var out = JsonWriter()
    value.write_json(out)
    var r = Response(status, out^.finish())
    r.headers.set("Content-Type", "application/json")
    return r^
