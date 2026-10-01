"""Request-body conversion contract (M2-006)."""


trait FromBody(Deinitable, Movable):
    """An application type that a handler can take as its request body.

    The application type conforms itself, in its own module, and decides the
    body format; Muntin never names it. `App.post` passes the request body
    to `from_body` before calling the handler.

    `Deinitable`: Muntin may have to drop a converted value. A body type may
    be move-only; the handler receives the converted value by move.

    The `body: String` argument fits the current `Request`, which carries
    the body as one `String` and no headers or content type. It is the
    first-slice shape, not a permanent promise.
    """

    @staticmethod
    def from_body(body: String) raises -> Self:
        """Builds the value from the request body (a copy of
        `Request.body`, unchanged). Raising rejects the request with 400
        `Bad Request` without calling the handler."""
        ...
