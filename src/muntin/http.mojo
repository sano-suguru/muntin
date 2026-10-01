"""Muntin-owned HTTP request and response values."""


struct Request(Copyable, Movable):
    """An application-level HTTP request, independent of any transport."""

    var method: String
    var path: String
    var body: String

    def __init__(out self, method: String, path: String, body: String = ""):
        self.method = method
        self.path = path
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
