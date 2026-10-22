"""Muntin-owned HTTP request and response values."""

from std.collections import Optional


# Header validation (docs/history/architecture-decisions.md, "Headers decision
# (M3-002)"): names are RFC 9110 tokens; values hold no control byte other than
# HTAB, and do not begin or end with SP or HTAB (RFC 9110 field-value). Bytes
# 0x80 and up are the UTF-8 a `String` holds. No field added through `Headers`
# can carry CR, LF or NUL.


def _is_token_byte(b: UInt8) -> Bool:
    var c = Int(b)
    if c >= ord("0") and c <= ord("9"):
        return True
    if c >= ord("a") and c <= ord("z"):
        return True
    if c >= ord("A") and c <= ord("Z"):
        return True
    for t in "!#$%&'*+-.^_`|~".as_bytes():
        if b == t:
            return True
    return False


def _valid_name(name: String) -> Bool:
    if name.byte_length() == 0:
        return False
    for b in name.as_bytes():
        if not _is_token_byte(b):
            return False
    return True


def _valid_value(value: String) -> Bool:
    var bytes = value.as_bytes()
    if len(bytes) > 0:
        var first = Int(bytes[0])
        var last = Int(bytes[len(bytes) - 1])
        if first == 32 or first == 9 or last == 32 or last == 9:
            return False
    for b in bytes:
        var c = Int(b)
        if c == 9:
            continue
        if c < 32 or c == 127:
            return False
    return True


def _same_name(a: String, b: String) -> Bool:
    """ASCII case-insensitive name comparison."""
    var x = a.as_bytes()
    var y = b.as_bytes()
    if len(x) != len(y):
        return False
    for i in range(len(x)):
        var c = Int(x[i])
        var d = Int(y[i])
        if c >= ord("A") and c <= ord("Z"):
            c += 32
        if d >= ord("A") and d <= ord("Z"):
            d += 32
        if c != d:
            return False
    return True


@fieldwise_init
struct _Field(Copyable, Movable):
    var name: String
    var value: String


struct Headers(Copyable, Movable, Sized):
    """HTTP header fields, in order.

    Each field keeps its position and its name's casing, as received or
    added; a repeated name is several fields, in order (`Set-Cookie`, or
    `X-A` then `x-a`). Lookup compares names ASCII case-insensitively.
    Nothing is joined, reordered or trimmed.

    `add` and `set` reject a name that is not an RFC 9110 token and a value
    with a control byte (other than HTAB) or with SP/HTAB at either end, so
    no field added through them can break a header line. They raise; in a
    raising handler that error is the fixed 500 or its `ToErrorResponse`.
    Copies are explicit (`.copy()`).
    """

    var _fields: List[_Field]

    def __init__(out self):
        self._fields = List[_Field]()

    def add(mut self, name: String, value: String) raises:
        """Appends a field; earlier fields with the same name stay."""
        if not _valid_name(name):
            raise Error("invalid header name")
        if not _valid_value(value):
            raise Error("invalid header value")
        self._fields.append(_Field(name, value))

    def set(mut self, name: String, value: String) raises:
        """Removes every field named `name` (in any casing), then appends
        one."""
        if not _valid_name(name):
            raise Error("invalid header name")
        if not _valid_value(value):
            raise Error("invalid header value")
        var fields = List[_Field]()
        for i in range(len(self._fields)):
            if not _same_name(self._fields[i].name, name):
                fields.append(self._fields[i].copy())
        self._fields = fields^
        self._fields.append(_Field(name, value))

    def get(self, name: String) -> Optional[String]:
        """The first field's value, or `None` when there is none. An empty
        value is a value."""
        for i in range(len(self._fields)):
            if _same_name(self._fields[i].name, name):
                return self._fields[i].value
        return None

    def get_all(self, name: String) -> List[String]:
        """Every value for `name`, in order; empty when there is none."""
        var out = List[String]()
        for i in range(len(self._fields)):
            if _same_name(self._fields[i].name, name):
                out.append(self._fields[i].value)
        return out^

    def __len__(self) -> Int:
        """The number of fields, repeats included."""
        return len(self._fields)

    def name(self, i: Int) -> String:
        """The `i`th field's name, as received or added."""
        return self._fields[i].name

    def value(self, i: Int) -> String:
        """The `i`th field's value."""
        return self._fields[i].value


struct Request(Copyable, Movable):
    """An application-level HTTP request, independent of any transport.

    Built from the raw request target, which Muntin splits at the first `?`:
    `path` is the text before it and is what routes match; `query` is the
    text after it, undecoded (empty when there is no `?`). Backends pass the
    target as received and never split it themselves, so every backend gets
    the same rule.

    `body` is the request body's bytes exactly as the backend received them
    (empty when there is none), whatever they are: the one representation of
    the body (docs/history/architecture-decisions.md, "Binary request and
    response bodies decision (M3-040)"). `text()` reads them as UTF-8 and
    raises when they are not; nothing replaces a byte.

    `headers` are the request's header fields as the backend received them
    (empty when built without any); a raw handler reads them, typed
    handlers do not (docs/history/architecture-decisions.md, "Headers decision (M3-002)").
    """

    var method: String
    var path: String
    var query: String
    var body: List[UInt8]
    var headers: Headers

    def __init__(
        out self,
        method: String,
        target: String,
        body: String = "",
        var headers: Headers = Headers(),
    ):
        """Splits `target` at its first `?`, copies the bytes of the text
        `body` and takes `headers` by move (pass `headers^` or
        `headers.copy()`)."""
        self = Request(method, target, List(body.as_bytes()), headers^)

    def __init__(
        out self,
        method: String,
        target: String,
        var body: List[UInt8],
        var headers: Headers = Headers(),
    ):
        """Splits `target` at its first `?` and takes the body's bytes and
        `headers` by move (pass `body^` or `body.copy()`)."""
        self.method = method
        var mark = target.find("?")
        if mark < 0:
            self.path = target
            self.query = String()
        else:
            self.path = String(target[byte=:mark])
            self.query = String(target[byte = mark + 1 :])
        self.body = body^
        self.headers = headers^

    def text(self) raises -> String:
        """The body as text: a copy of its bytes when they are well-formed
        UTF-8. Raises when they are not; no byte is replaced."""
        return String(from_utf8=Span(self.body))


trait ToResponse(Deinitable, Movable):
    """A handler result type that converts itself to a `Response`.

    The application conforms its own result type, in its own module, and
    decides status and body; Muntin never names the type. A handler
    declared `-> R` for such an `R` is accepted by `App.get`/`App.post`, and
    its result is converted once, after the handler returns. `Response`
    conforms, so a handler declared `-> Response` chooses its response
    directly. `String` results need no conformance: they are 200 text.

    `var self`: Muntin owns the result and hands it over, so a conversion
    can move fields into the `Response`, and a move-only type works. An
    implementation may declare `self`, `var self`, or `deinit self` (to move
    one field out of a value with others). Non-raising: a failed conversion
    would need its own answer, which no error model decides yet.

    Only returned values convert with `to_response`. A raised value is a
    handler error even if its type conforms; see `ToErrorResponse`.
    """

    def to_response(var self) -> Response:
        ...


trait ToErrorResponse(Deinitable):
    """A handler error type that converts itself to a `Response`.

    A handler declared `raises T` for such a `T` is answered with
    `T.to_error_response()` when it raises, instead of the fixed 500. The
    application opts in by declaring the conformance on its own error type
    (directly, through a trait that refines this one, or as a conditional
    conformance); Muntin never names the type. Any other error type, and a
    bare `raises` (`Error`), stays the fixed 500. Separate from
    `ToResponse`: a type conforming to both converts a returned value with
    `to_response` and a raised one with `to_error_response`.

    `var self`: the caught error is handed over and consumed once, after the
    handler raised; the result conversion does not run. Move-only types
    work, and an implementation may declare `self`, `var self` or
    `deinit self`. Non-raising: a raising implementation does not conform.
    """

    def to_error_response(var self) -> Response:
        ...


struct Failure(Copyable, Movable, Writable):
    """What Muntin dropped when it answered with the fixed 500
    (docs/history/architecture-decisions.md, "Dropped error report decision
    (M3-058)").

    `source` is the step that dropped it, one of `Failure.HANDLER` (a
    handler error whose type does not convert), `Failure.MIDDLEWARE` (a
    raise out of a middleware), `Failure.RESPONSE` (a result conversion,
    `Json[T]`'s serialization) and `Failure.MUNTIN` (Muntin's own internal
    failures). `message` is the error's text when its type is `Writable`
    (`Error` included), else `<`, its type's module-qualified name and `>`.
    Written as `source: message`.

    `message` is never sent to the client, but it is not safe log text: it
    may hold secrets, control characters and values the client sent.
    Escaping and masking it in a log are the application's.

    Its initializer takes only `_`-prefixed keyword arguments; only Muntin
    builds one, and a `Response` built by the application carries none.
    """

    comptime HANDLER = "handler"
    comptime MIDDLEWARE = "middleware"
    comptime RESPONSE = "response"
    comptime MUNTIN = "muntin"

    var source: String
    var message: String

    def __init__(out self, *, _source: String, _message: String):
        self.source = _source
        self.message = _message

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.source, ": ", self.message)


struct Rejection(Copyable, Movable, Writable):
    """Why Muntin answered a request 400 `Bad Request` before the handler
    (docs/history/architecture-decisions.md, "Request rejection report
    decision (M3-084)").

    `step` is the conversion that failed, one of `Rejection.PATH` (a path
    route value's decoding or `Int` parse), `Rejection.QUERY` (a query
    value missing, repeated, empty, or its decoding or `Int` parse),
    `Rejection.FROM_ROUTE_VALUE`, `Rejection.UTF8` (a text body that is not
    UTF-8), `Rejection.JSON` (a `Json[T]` body that is not one JSON value),
    `Rejection.FROM_BODY`, `Rejection.FROM_BYTES` and `Rejection.FROM_JSON`
    (a conversion raised). `name` is the route value's
    placeholder name for the first three, else empty. `message` is Muntin's
    own fixed text for `PATH`, `QUERY`, `UTF8` and `JSON`, which never
    holds a byte of the request, and the raised error's text for the
    `FROM_` steps, which may: a standard-library conversion such as
    `Int(text)` quotes its input. Escaping and masking it in a log are the
    application's. Nothing tells a conversion's server-side fault from bad
    input but its message.
    Written as `step name: message`, or `step: message` without a name.

    Its initializer takes only `_`-prefixed keyword arguments; only Muntin
    builds one, and a `Response` built by the application carries none.
    """

    comptime PATH = "path"
    comptime QUERY = "query"
    comptime FROM_ROUTE_VALUE = "from_route_value"
    comptime UTF8 = "utf-8"
    comptime JSON = "json"
    comptime FROM_BODY = "from_body"
    comptime FROM_BYTES = "from_bytes"
    comptime FROM_JSON = "from_json"

    var step: String
    var name: String
    var message: String

    def __init__(out self, *, _step: String, _name: String, _message: String):
        self.step = _step
        self.name = _name
        self.message = _message

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.step)
        if self.name.byte_length() > 0:
            writer.write(" ", self.name)
        writer.write(": ", self.message)


@fieldwise_init
struct _Report(Copyable, Movable):
    """A response's report: a `Failure` (the fixed 500) or a `Rejection`
    (Muntin's 400), one list element so `Response` keeps its size."""

    var failure: List[Failure]
    var rejection: List[Rejection]
    var at: Int
    """A rejected route value's position among the route values, -1 once
    `App.handle` has named it (or for any other step)."""


struct Response(Copyable, Movable, ToResponse):
    """An application-level HTTP response, independent of any transport.

    `body` is the response body's bytes, sent as they are: text built with
    `Response(status, text)` or `Response.text` is its UTF-8 bytes, and
    `Response(status, bytes^)` sends any bytes (M3-040). `text()` reads them
    back as UTF-8 and raises when they are not.

    `headers` start empty; Muntin adds none by default (no `Content-Type`,
    for text or bytes). A backend writes them in order, except the fields it
    owns or that are connection-specific
    (docs/history/architecture-decisions.md, "Headers decision (M3-002)").

    `failure()` is the report of what Muntin dropped when it made this
    response as the fixed 500 (M3-058), and `rejection()` the report of why
    Muntin answered 400 before the handler (M3-084); each is `None` on any
    other response. No public initializer sets them; copies and edits of the
    status, body or fields keep them, and no backend sends them.
    """

    var status: Int
    var body: List[UInt8]
    var headers: Headers
    # The report, or empty; at most one, added only by `_failed` or
    # `_rejected_by` (docs/history/architecture-decisions.md, "Dropped error
    # report amendment (M3-059)", "Request rejection report decision
    # (M3-084)").
    var _report: List[_Report]

    def __init__(out self, status: Int, body: String):
        """A response whose body is the bytes of the text `body`."""
        self = Response(status, List(body.as_bytes()))

    def __init__(out self, status: Int, var body: List[UInt8]):
        """A response whose body is `body`'s bytes, taken by move (pass
        `body^` or `body.copy()`)."""
        self.status = status
        self.body = body^
        self.headers = Headers()
        self._report = List[_Report]()

    @staticmethod
    def text(body: String, status: Int = 200) -> Response:
        """Builds a plain-text response."""
        return Response(status, body)

    def text(self) raises -> String:
        """The body as text: a copy of its bytes when they are well-formed
        UTF-8. Raises when they are not; no byte is replaced."""
        return String(from_utf8=Span(self.body))

    def failure(self) -> Optional[Failure]:
        """A copy of the report of what Muntin dropped when it made this
        response as the fixed 500 (M3-058); `None` on any other response,
        and on one the application builds."""
        if self._report and self._report[0].failure:
            return self._report[0].failure[0].copy()
        return None

    def rejection(self) -> Optional[Rejection]:
        """A copy of the report of why Muntin answered this response as its
        400 before the handler (M3-084); `None` on any other response, and
        on one the application builds."""
        if self._report and self._report[0].rejection:
            return self._report[0].rejection[0].copy()
        return None

    def to_response(var self) -> Response:
        """Returns this response unchanged, by move: a handler declared
        `-> Response` is answered with exactly the response it built."""
        return self^


def _failed(source: StaticString, message: String) -> Response:
    """The fixed 500, `Internal Server Error` with no fields, carrying a
    `Failure` of `source` and `message` (M3-058). The message never reaches
    the body or a field."""
    var response = Response.text("Internal Server Error", status=500)
    response._report.append(
        _Report(
            failure=[Failure(_source=source, _message=message)],
            rejection=[],
            at=-1,
        )
    )
    return response^


def _rejected_by(
    step: String, name: String, message: String, at: Int = -1
) -> Response:
    """Muntin's 400, `Bad Request` with no fields, carrying a `Rejection` of
    `step`, `name` and `message` (M3-084); `at` is a route value's position
    that `App.handle` turns into its name. Nothing of it reaches the body or
    a field."""
    var response = Response.text("Bad Request", status=400)
    response._report.append(
        _Report(
            failure=[],
            rejection=[Rejection(_step=step, _name=name, _message=message)],
            at=at,
        )
    )
    return response^
