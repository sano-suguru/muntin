# M3-002 headers decision spike, library side. Not production code: it
# models the selected representation (candidate A, `Headers`), the
# `Request`/`Response` fields that would carry it, and the raw-handler
# transport (R1: header names and values as extra raw argument strings
# through the production `_Erased`, unchanged), separately from the
# application module (tests/test_spike_headers.mojo). Rejected candidates B
# (a dictionary keyed by the lowercased name) and C (one comma-joined value
# per name) are modeled too, so their information loss is executable.
# check.sh builds it through that test (--Werror) and through
# tests/headers_lib_only/driver.mojo; test.sh runs it. Decision and
# evidence: docs/ARCHITECTURE.md, "Headers decision (M3-002)". Must-not-
# compile evidence: tests/headers_fail.

from std.collections import Dict, Optional

from muntin import Response
from muntin._handler_storage import _Erased


# Validation, matching what pinned Flare's strict parser accepts inbound
# (RFC 9110 token names; field values of visible ASCII, SP, HTAB) and
# additionally bytes >= 0x80, which a Mojo `String` holds as UTF-8. CR, LF,
# NUL and the other control bytes are never accepted, so no `Headers`
# value can carry a line break onto the wire.


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
    for b in value.as_bytes():
        var c = Int(b)
        if c == 9:
            continue
        if c < 32 or c == 127:
            return False
    return True


def _lower_ascii(s: String) -> String:
    var out = String()
    for b in s.as_bytes():
        var c = Int(b)
        if c >= ord("A") and c <= ord("Z"):
            out += chr(c + 32)
        else:
            out += chr(c)
    return out^


def _same_name(a: String, b: String) -> Bool:
    if a.byte_length() != b.byte_length():
        return False
    return _lower_ascii(a) == _lower_ascii(b)


struct Headers(Copyable, Movable, Sized):
    """Candidate A: ordered header fields, as received or added.

    Each field keeps its name's original casing and its position; repeated
    names are separate fields in order. Lookup compares names ASCII
    case-insensitively. `add` and `set` reject an invalid name or value, so
    a `Headers` value never holds a byte that could break a header line.
    """

    var _names: List[String]
    var _values: List[String]

    def __init__(out self):
        self._names = List[String]()
        self._values = List[String]()

    def add(mut self, name: String, value: String) raises:
        """Appends a field; earlier fields with the same name stay."""
        if not _valid_name(name):
            raise Error("invalid header name")
        if not _valid_value(value):
            raise Error("invalid header value")
        self._names.append(name)
        self._values.append(value)

    def set(mut self, name: String, value: String) raises:
        """Removes every field named `name`, then appends one."""
        if not _valid_name(name):
            raise Error("invalid header name")
        if not _valid_value(value):
            raise Error("invalid header value")
        var names = List[String]()
        var values = List[String]()
        for i in range(len(self._names)):
            if not _same_name(self._names[i], name):
                names.append(self._names[i])
                values.append(self._values[i])
        self._names = names^
        self._values = values^
        self._names.append(name)
        self._values.append(value)

    def get(self, name: String) -> Optional[String]:
        """The first field's value, or `None` when there is none (an empty
        value is a value)."""
        for i in range(len(self._names)):
            if _same_name(self._names[i], name):
                return self._values[i]
        return None

    def get_all(self, name: String) -> List[String]:
        """Every value for `name`, in order."""
        var out = List[String]()
        for i in range(len(self._names)):
            if _same_name(self._names[i], name):
                out.append(self._values[i])
        return out^

    def __len__(self) -> Int:
        return len(self._names)

    def name(self, i: Int) -> String:
        """The `i`th field's name, as received or added."""
        return self._names[i]

    def value(self, i: Int) -> String:
        return self._values[i]


struct HRequest(Copyable, Movable):
    """Production `Request` with the `headers` field the slice would add.
    The existing initializer keeps its arguments; headers default to none."""

    var method: String
    var path: String
    var query: String
    var body: String
    var headers: Headers

    def __init__(
        out self,
        method: String,
        target: String,
        body: String = "",
        headers: Headers = Headers(),
    ):
        self.method = method
        var mark = target.find("?")
        if mark < 0:
            self.path = target
            self.query = String()
        else:
            self.path = String(target[byte=:mark])
            self.query = String(target[byte = mark + 1 :])
        self.body = body
        self.headers = headers.copy()


struct HResponse(Copyable, Movable):
    """Production `Response` with a `headers` field; `text` sets none, so
    no existing response's wire bytes change (no default Content-Type)."""

    var status: Int
    var body: String
    var headers: Headers

    def __init__(out self, status: Int, body: String):
        self.status = status
        self.body = body
        self.headers = Headers()

    @staticmethod
    def text(body: String, status: Int = 200) -> HResponse:
        return HResponse(status, body)


# R1: the raw transport. `App.handle` would append each field's name and
# value after the four raw strings; the raw adapter rebuilds the request.
# `_Call`, `_Erased` and `_Route` are unchanged.


def raw_args(request: HRequest) -> List[String]:
    """The raw argument strings `App.handle` would pass a raw route."""
    var args = List[String]()
    args.append(request.method)
    args.append(request.path)
    args.append(request.query)
    args.append(request.body)
    for i in range(len(request.headers)):
        args.append(request.headers.name(i))
        args.append(request.headers.value(i))
    return args^


def _call_raw_h(
    handler: def(var HRequest) thin -> HResponse, args: List[String]
) raises -> Response:
    """`_call_raw` rebuilding the headers too. The `HResponse` is carried
    back as status and body plus its fields in the body, so the test can
    compare what crossed the box."""
    var target = args[1]
    if args[2].byte_length() > 0:
        target += "?" + args[2]
    var headers = Headers()
    var i = 4
    while i + 1 < len(args):
        headers.add(args[i], args[i + 1])
        i += 2
    var result = handler(HRequest(args[0], target, args[3], headers))
    var out = result.body
    for j in range(len(result.headers)):
        out += "|" + result.headers.name(j) + "=" + result.headers.value(j)
    return Response(result.status, out)


def box_raw(handler: def(var HRequest) thin -> HResponse) -> _Erased:
    return _Erased.__init__[call=_call_raw_h](handler)


# Rejected candidates, modeled to show what they lose.


struct DictHeaders(Movable):
    """Candidate B: values grouped under the lowercased name."""

    var fields: Dict[String, List[String]]
    var order: List[String]

    def __init__(out self):
        self.fields = Dict[String, List[String]]()
        self.order = List[String]()

    def add(mut self, name: String, value: String) raises:
        var key = _lower_ascii(name)
        if key not in self.fields:
            self.fields[key] = List[String]()
            self.order.append(key)
        self.fields[key].append(value)

    def flatten(self) raises -> List[String]:
        """Name/value pairs as a backend would emit them."""
        var out = List[String]()
        for key in self.order:
            for value in self.fields[key]:
                out.append(key + ": " + value)
        return out^


struct JoinedHeaders(Movable):
    """Candidate C: one comma-joined value per lowercased name (RFC 9110
    list syntax)."""

    var names: List[String]
    var values: List[String]

    def __init__(out self):
        self.names = List[String]()
        self.values = List[String]()

    def add(mut self, name: String, value: String):
        var key = _lower_ascii(name)
        for i in range(len(self.names)):
            if self.names[i] == key:
                self.values[i] += ", " + value
                return
        self.names.append(key)
        self.values.append(value)

    def get(self, name: String) -> String:
        var key = _lower_ascii(name)
        for i in range(len(self.names)):
            if self.names[i] == key:
                return self.values[i]
        return ""
