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

from std.collections import Optional
from muntin import FromBody, Headers, Request, Response, ToResponse
from muntin._handler_storage import _Shared


# Nesting cap for untrusted input: an array or object nested deeper than this
# is rejected (400 through `from_body`), so a hostile body cannot exhaust the
# parser's stack.
comptime MAX_DEPTH = 64

# Node kinds of the parsed tape.
comptime _NULL = 0
comptime _FALSE = 1
comptime _TRUE = 2
comptime _NUMBER = 3
comptime _STRING = 4
comptime _ARRAY = 5
comptime _OBJECT = 6


@fieldwise_init
struct _Node(Copyable, Movable):
    """One value of a parsed document, in document order. A container's
    children follow it; `end` is the index one past its subtree, so the next
    sibling of a child at `i` is at `nodes[i].end`."""

    var kind: Int
    # Decoded text of a string; the literal of a number; empty otherwise.
    var text: String
    # Decoded member name when the node is an object member; empty otherwise.
    var key: String
    # Number of children (array elements or object members).
    var count: Int
    var end: Int


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


struct _Parser:
    """Strict RFC 8259 recursive descent over the body's bytes. Rejects:
    comments, trailing commas, single quotes, leading zeros, `+` signs,
    `NaN`/`Infinity`, a byte order mark, unescaped control bytes in strings,
    bad escapes, lone surrogates, duplicate member names, trailing content,
    an empty body, and nesting deeper than `MAX_DEPTH`."""

    var text: String
    var b: List[UInt8]
    var i: Int
    var nodes: List[_Node]

    def __init__(out self, text: String):
        self.text = text
        self.b = List[UInt8](text.as_bytes())
        self.i = 0
        self.nodes = List[_Node]()

    def _peek(self) -> Int:
        if self.i >= len(self.b):
            return -1
        return Int(self.b[self.i])

    def _ws(mut self):
        while self.i < len(self.b) and _is_ws(Int(self.b[self.i])):
            self.i += 1

    def _expect_word(mut self, word: StaticString) raises:
        for c in word.as_bytes():
            if self._peek() != Int(c):
                raise Error("invalid JSON: bad literal")
            self.i += 1

    def _string(mut self) raises -> String:
        # At the opening quote. The input is a valid UTF-8 `String`, so runs
        # between ASCII delimiters are copied as they are.
        self.i += 1
        var out = String()
        var run = self.i
        while True:
            var c = self._peek()
            if c < 0:
                raise Error("invalid JSON: unterminated string")
            if c == ord('"'):
                out += String(self.text[byte = run : self.i])
                self.i += 1
                return out^
            if c < 0x20:
                raise Error("invalid JSON: control byte in string")
            if c != ord("\\"):
                self.i += 1
                continue
            out += String(self.text[byte = run : self.i])
            self.i += 1
            var e = self._peek()
            self.i += 1
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
            elif e == ord("u"):
                var cp = self._u4()
                if cp >= 0xD800 and cp <= 0xDBFF:
                    if self._peek() != ord("\\"):
                        raise Error("invalid JSON: lone surrogate")
                    self.i += 1
                    if self._peek() != ord("u"):
                        raise Error("invalid JSON: lone surrogate")
                    self.i += 1
                    var lo = self._u4()
                    if lo < 0xDC00 or lo > 0xDFFF:
                        raise Error("invalid JSON: lone surrogate")
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                elif cp >= 0xDC00 and cp <= 0xDFFF:
                    raise Error("invalid JSON: lone surrogate")
                out += chr(cp)
            else:
                raise Error("invalid JSON: bad escape")
            run = self.i

    def _u4(mut self) raises -> Int:
        if self.i + 4 > len(self.b):
            raise Error("invalid JSON: bad \\u escape")
        var v = 0
        for _ in range(4):
            v = v * 16 + _hex(Int(self.b[self.i]))
            self.i += 1
        return v

    def _number(mut self) raises -> String:
        var start = self.i
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
        return String(self.text[byte = start : self.i])

    def value(mut self, key: String, depth: Int) raises:
        self._ws()
        var c = self._peek()
        var at = len(self.nodes)
        if c == ord("{") or c == ord("["):
            if depth >= MAX_DEPTH:
                raise Error("invalid JSON: nesting too deep")
            var obj = c == ord("{")
            self.nodes.append(
                _Node(_OBJECT if obj else _ARRAY, String(), key, 0, 0)
            )
            self.i += 1
            self._ws()
            var close = ord("}") if obj else ord("]")
            var count = 0
            var names = List[String]()
            if self._peek() == close:
                self.i += 1
            else:
                while True:
                    var name = String()
                    if obj:
                        self._ws()
                        if self._peek() != ord('"'):
                            raise Error("invalid JSON: expected member name")
                        name = self._string()
                        for n in names:
                            if n == name:
                                raise Error("invalid JSON: duplicate member")
                        names.append(name)
                        self._ws()
                        if self._peek() != ord(":"):
                            raise Error("invalid JSON: expected ':'")
                        self.i += 1
                    self.value(name, depth + 1)
                    count += 1
                    self._ws()
                    var d = self._peek()
                    self.i += 1
                    if d == close:
                        break
                    if d != ord(","):
                        raise Error("invalid JSON: expected ',' or close")
            self.nodes[at].count = count
        elif c == ord('"'):
            var s = self._string()
            self.nodes.append(_Node(_STRING, s^, key, 0, 0))
        elif c == ord("t"):
            self._expect_word("true")
            self.nodes.append(_Node(_TRUE, String(), key, 0, 0))
        elif c == ord("f"):
            self._expect_word("false")
            self.nodes.append(_Node(_FALSE, String(), key, 0, 0))
        elif c == ord("n"):
            self._expect_word("null")
            self.nodes.append(_Node(_NULL, String(), key, 0, 0))
        elif c == ord("-") or _is_digit(c):
            var n = self._number()
            self.nodes.append(_Node(_NUMBER, n^, key, 0, 0))
        else:
            raise Error("invalid JSON: unexpected byte")
        self.nodes[at].end = len(self.nodes)


def parse_json(text: String) raises -> JsonValue:
    """Parses one JSON text (RFC 8259, strict; see `_Parser`). Raises on
    anything else; through `Json.from_body` that is 400."""
    var p = _Parser(text)
    p.value(String(), 0)
    p._ws()
    if p.i != len(p.b):
        raise Error("invalid JSON: trailing content")
    var nodes = List[_Node]()
    swap(nodes, p.nodes)
    return JsonValue(_Shared(nodes^), 0)


struct JsonValue(Copyable, Movable, Sized):
    """A read-only position in a parsed JSON document. The tape is held in
    M3-004's sealed `_Shared` box: copies share it (one reference count
    increment, no tape copy), and no handle can replace or mutate it on an
    ordinary path, so a position stays valid. Accessors return values,
    never references into it. Every accessor raises when the value
    is not of the asked kind, so a `from_json` that reads a wrong or missing
    field raises, and `Json.from_body` answers 400."""

    var _doc: _Shared[List[_Node]]
    var _at: Int

    def __init__(out self, doc: _Shared[List[_Node]], at: Int):
        self._doc = doc.copy()
        self._at = at

    def _kind(self) -> Int:
        return self._doc.owned()[][self._at].kind

    def is_null(self) -> Bool:
        return self._kind() == _NULL

    def bool(self) raises -> Bool:
        var k = self._kind()
        if k == _TRUE:
            return True
        if k == _FALSE:
            return False
        raise Error("JSON value is not a boolean")

    def int(self) raises -> Int:
        """An integer literal (no fraction, no exponent) that fits `Int`."""
        if self._kind() != _NUMBER:
            raise Error("JSON value is not a number")
        ref t = self._doc.owned()[][self._at].text
        if t.find(".") >= 0 or t.find("e") >= 0 or t.find("E") >= 0:
            raise Error("JSON number is not an integer")
        return Int(t)

    def float(self) raises -> Float64:
        """Any number literal, as a finite `Float64`. Raises when it
        overflows, and (Mojo 1.1.0 `atof`) when it has more significant
        digits than `atof` supports."""
        if self._kind() != _NUMBER:
            raise Error("JSON value is not a number")
        var x = atof(self._doc.owned()[][self._at].text)
        if x != x or x > Float64.MAX_FINITE or x < -Float64.MAX_FINITE:
            raise Error("JSON number is out of range")
        return x

    def string(self) raises -> String:
        if self._kind() != _STRING:
            raise Error("JSON value is not a string")
        return self._doc.owned()[][self._at].text

    def __len__(self) -> Int:
        """Elements of an array, members of an object, 0 otherwise."""
        var k = self._kind()
        if k == _ARRAY or k == _OBJECT:
            return self._doc.owned()[][self._at].count
        return 0

    def __getitem__(self, index: Int) raises -> JsonValue:
        """The `index`th array element."""
        if self._kind() != _ARRAY:
            raise Error("JSON value is not an array")
        if index < 0 or index >= self._doc.owned()[][self._at].count:
            raise Error("JSON array index out of range")
        var at = self._at + 1
        for _ in range(index):
            at = self._doc.owned()[][at].end
        return JsonValue(self._doc, at)

    def get(self, name: String) raises -> Optional[JsonValue]:
        """The member `name` of an object, or `None` when it is absent. A
        member present as `null` is a value (`is_null()`)."""
        if self._kind() != _OBJECT:
            raise Error("JSON value is not an object")
        var at = self._at + 1
        for _ in range(self._doc.owned()[][self._at].count):
            if self._doc.owned()[][at].key == name:
                return JsonValue(self._doc, at)
            at = self._doc.owned()[][at].end
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
    name outside one, an unmatched close, a second top-level value) and on
    a non-finite number, which JSON cannot represent."""

    var _out: String
    var _stack: List[Int]
    var _counts: List[Int]
    var _named: Bool
    var _done: Bool

    def __init__(out self):
        self._out = String()
        self._stack = List[Int]()
        self._counts = List[Int]()
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

    def end_object(mut self) raises:
        if (
            len(self._stack) == 0
            or self._stack[len(self._stack) - 1] != _IN_OBJECT
            or self._named
        ):
            raise Error("JSON writer: unmatched end_object")
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
    `application/json`, ASCII case-insensitively. Parameters (such as
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
    return String(media[byte=a:z]).lower() == "application/json"


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
