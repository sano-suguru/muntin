"""Request-body conversion contracts: text (M2-006) and bytes (M3-041)."""


trait _FromBodyOrBytes(Deinitable, Movable):
    """What `FromBody` and `FromBytes` share, and nothing more: the bound of
    `WithHeaders[B]` (M3-042), so a carrier holds a body with either
    conversion and an ordinary type with neither is rejected where the
    carrier is declared. It is a private marker, not a closed set: Mojo
    1.1.0 does not stop a type conforming to it directly, and such a type
    passes the declaration; `_kind` rejects it at registration as a body of
    no conversion, so `_kind` is the final check. An application conforms
    to `FromBody` or `FromBytes`, never to this alone."""

    pass


trait FromBody(_FromBodyOrBytes):
    """An application type that a handler can take as its request body.

    The application type conforms itself, in its own module, and decides the
    body format; Muntin never names it. `App.post` (`put`, `patch`) passes
    the request body to `from_body` before calling the handler.

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


trait FromBytes(_FromBodyOrBytes):
    """An application type that a handler can take as its request body,
    built from the body's bytes, whatever they are (M3-041).

    It is the binary counterpart of `FromBody`, accepted wherever a
    `FromBody` body is, inside `WithHeaders[B]` too (M3-042): `App.post`,
    `put` and `patch` pass the request's body bytes to `from_bytes` before
    calling the handler, exactly as received (or as middleware replaced
    them), with no UTF-8 check and no text conversion. A type conforms to
    one of the two traits, never both: a body type that conforms to both is
    rejected at registration.

    `Deinitable` and `Movable` as for `FromBody`: a bytes body type may be
    move-only, and the handler receives the converted value by move.

    `max_bytes` (M3-043) is the longest body, in bytes, the type accepts:
    a longer one is answered 413 `Content Too Large` without calling
    `from_bytes` or the handler, after the route values and, in a carrier,
    before the field rebuild. Every type declares it, so a missing or
    misspelled limit does not compile; `Int.MAX`, which no body exceeds,
    is no limit. A negative value is rejected at registration. It measures
    the body `App.handle` holds after middleware, which the backend has
    already received in full: it is not a receive limit, which is the
    network backend's own configuration.
    """

    comptime max_bytes: Int
    """The longest body the type accepts, in bytes (0 or more): a type
    declares `comptime max_bytes = 64 * 1024` once (or a refining trait
    gives a default); `Int.MAX` is no limit."""

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        """Builds the value from the request body's bytes (`Request.body`,
        borrowed and read-only: a value that keeps them copies them with
        `body.copy()`). Raising rejects the request with 400 `Bad Request`
        without calling the handler."""
        ...


def _body_text(body: List[UInt8]) raises -> String:
    """The text a `FromBody` conversion receives: a copy of the body bytes
    when they are well-formed UTF-8 (M3-040). Raises when they are not, and
    the body slot answers 400, as for a `from_body` raise; no byte is
    replaced, so a typed body never receives a U+FFFD the client did not
    send. A bare body and a carrier's (`WithHeaders._from_parts`) read
    their text through it alone."""
    return String(from_utf8=Span(body))
