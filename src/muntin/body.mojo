"""Request-body conversion contracts: text (M2-006) and bytes (M3-041)."""

from .http import Rejection

comptime _MAX_BODY_BYTES = 1_048_576
"""The default body limit, 1 MiB (M3-089): `FromBody.max_bytes`'s and
`Json[T]`'s `limit`'s, one constant so the two stay the same. A typed route
answers a longer body 413 before reading it (`_slot` in `app.mojo`)."""


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

    `max_bytes` (M3-089) is the longest body, in bytes, Muntin passes to
    `from_body` when it dispatches a typed route, measured before the UTF-8
    read: `App.handle` answers a longer one 413 `Content Too Large` without
    reading it or calling `from_body` or the handler, at the step of a
    `FromBytes` body's limit (M3-043). Unlike `FromBytes`, the trait gives
    it a default, 1 MiB, `Json[T]`'s since M3-009, so a type that declares
    nothing, or misspells the member, is limited, never unlimited; a type
    declares `comptime max_bytes = 8 << 20` to raise it and `Int.MAX` for
    no limit. A trait refining `FromBody` cannot give it another default
    (Mojo 1.1.0 rejects the conflicting defaults where a type conforms).
    A negative value is rejected at registration. A direct call to an
    application's `from_body` is not limited; `Json[T].from_body` checks
    its own limit.
    """

    comptime max_bytes: Int = _MAX_BODY_BYTES
    """The longest body Muntin passes to `from_body` on a typed route, in
    bytes (0 or more); 1 MiB unless the type declares another; `Int.MAX` is
    no limit."""

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

    `max_bytes` (M3-043) is the longest body, in bytes, Muntin passes to
    `from_bytes` when it dispatches a typed route: `App.handle` answers a
    longer one 413 `Content Too Large` without calling `from_bytes` or the
    handler, after the route values and, in a carrier, before the field
    rebuild. It is not a precondition of `from_bytes` itself: a direct call
    is not limited. A type whose traits give `max_bytes` no default must
    declare it, so a missing or misspelled limit does not compile there;
    under a refining trait's default a misspelled override compiles and
    inherits the default. `Int.MAX`, which no body exceeds, is no limit. A negative
    value is rejected at registration. It measures
    the body `App.handle` holds after middleware, which the backend has
    already received in full: it is not a receive limit, which is the
    network backend's own configuration.
    """

    comptime max_bytes: Int
    """The longest body Muntin passes to `from_bytes` on a typed route, in
    bytes (0 or more): a type declares `comptime max_bytes = 64 * 1024`
    once (or inherits a refining trait's default); `Int.MAX` is no
    limit."""

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        """Builds the value from the request body's bytes (`Request.body`,
        borrowed and read-only: a value that keeps them copies them with
        `body.copy()`). Raising rejects the request with 400 `Bad Request`
        without calling the handler."""
        ...


@fieldwise_init
struct _BodyFault(Movable):
    """A body conversion's failure (M3-084): the `Rejection` step that
    failed and its message, Muntin's own text for `Rejection.UTF8` and
    `Rejection.JSON`, the raised error's text for a `FROM_` step."""

    var step: String
    var message: String


comptime _NOT_UTF8 = "not UTF-8"
"""The message of a `Rejection.UTF8`, and of a route value whose decoded
bytes are not UTF-8."""


def _body_text(body: List[UInt8]) raises -> String:
    """The text a `FromBody` conversion receives: a copy of the body bytes
    when they are well-formed UTF-8 (M3-040). Raises when they are not, and
    the body slot answers 400, as for a `from_body` raise; no byte is
    replaced, so a typed body never receives a U+FFFD the client did not
    send. A bare body and a carrier's (`WithHeaders._from_parts`) read
    their text through it alone."""
    return String(from_utf8=Span(body))
