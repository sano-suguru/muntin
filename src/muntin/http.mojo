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


struct Response(Copyable, Movable):
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
