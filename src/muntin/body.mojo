"""Request-body conversion contract (M2-006)."""


trait FromBody(Deinitable, Movable):
    """An application type that a handler can take as its request body.

    The application type conforms itself, in its own module, and decides the
    body format; Muntin never names it. `App.post` passes the request body
    to `from_body` before calling the handler.

    `Deinitable`: Muntin may have to drop a converted value. A body type may
    be move-only; the handler receives the converted value by move.

    `from_body(body: String)` is the current public body-conversion input
    contract: the body as one `String`, with no headers or content type.
    `Request.body` holds bytes (M3-040); `App.post` passes them on as text
    only when they are well-formed UTF-8, and answers any other body 400
    without calling `from_body`, so a conversion never sees a replaced
    byte. Future body capabilities are added as new APIs without changing
    this one.
    """

    @staticmethod
    def from_body(body: String) raises -> Self:
        """Builds the value from the request body (a copy of
        `Request.body`'s bytes as text, unchanged). Raising rejects the
        request with 400 `Bad Request` without calling the handler."""
        ...
