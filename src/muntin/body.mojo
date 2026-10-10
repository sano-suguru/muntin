"""Request-body conversion contracts: text (M2-006) and bytes (M3-041)."""


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
    this one: a body of any bytes is `FromBytes` (M3-041).
    """

    @staticmethod
    def from_body(body: String) raises -> Self:
        """Builds the value from the request body (a copy of
        `Request.body`'s bytes as text, unchanged). Raising rejects the
        request with 400 `Bad Request` without calling the handler."""
        ...


trait FromBytes(Deinitable, Movable):
    """An application type that a handler can take as its request body,
    built from the body's bytes, whatever they are (M3-041).

    It is the binary counterpart of `FromBody`, accepted wherever a
    `FromBody` body is: `App.post`, `put` and `patch` pass the request's
    body bytes to `from_bytes` before calling the handler, exactly as
    received (or as middleware replaced them), with no UTF-8 check and no
    text conversion. A type conforms to one of the two traits, never both:
    a body type that conforms to both is rejected at registration.

    `Deinitable` and `Movable` as for `FromBody`: a bytes body type may be
    move-only, and the handler receives the converted value by move.
    """

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        """Builds the value from the request body's bytes (`Request.body`,
        borrowed and read-only: a value that keeps them copies them with
        `body.copy()`). Raising rejects the request with 400 `Bad Request`
        without calling the handler."""
        ...
