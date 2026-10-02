"""Muntin-owned HTTP request and response values."""


struct Request(Copyable, Movable):
    """An application-level HTTP request, independent of any transport.

    Built from the raw request target, which Muntin splits at the first `?`:
    `path` is the text before it and is what routes match; `query` is the
    text after it, undecoded (empty when there is no `?`). Backends pass the
    target as received and never split it themselves, so every backend gets
    the same rule.
    """

    var method: String
    var path: String
    var query: String
    var body: String

    def __init__(out self, method: String, target: String, body: String = ""):
        self.method = method
        var mark = target.find("?")
        if mark < 0:
            self.path = target
            self.query = String()
        else:
            self.path = String(target[byte=:mark])
            self.query = String(target[byte = mark + 1 :])
        self.body = body


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
    one field out of a value with others). Non-raising: what a failed
    conversion means belongs to the application-error model, which does not
    exist yet.
    """

    def to_response(var self) -> Response:
        ...


struct Response(Copyable, Movable, ToResponse):
    """An application-level HTTP response, independent of any transport."""

    var status: Int
    var body: String

    def __init__(out self, status: Int, body: String):
        self.status = status
        self.body = body

    @staticmethod
    def text(body: String, status: Int = 200) -> Response:
        """Builds a plain-text response."""
        return Response(status, body)

    def text(self) -> String:
        """Returns the response body as text."""
        return self.body

    def to_response(var self) -> Response:
        """Returns this response unchanged, by move: a handler declared
        `-> Response` is answered with exactly the response it built."""
        return self^
