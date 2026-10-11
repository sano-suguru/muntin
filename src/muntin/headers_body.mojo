"""Typed request-header access for `post`, `put` and `patch` bodies (M3-013).

`WithHeaders[B]` carries the request's header fields beside a body in the
existing body slot of `App.post`, `put` and `patch`
(docs/history/architecture-decisions.md, "Typed header access decision
(M3-012)"). It is not itself a `FromBody` or a `FromBytes`: the
body slot in `app.mojo` accepts `FromBody`, `FromBytes` (M3-041) or the
private `_HeaderCarrier`, so a body alone never produces a carrier without
the request's fields. A carrier's body is a `FromBody` or, since M3-042, a
`FromBytes` (the bound `_FromBodyOrBytes`), converted as a bare body of its
type is.
"""

from .body import FromBody, FromBytes, _FromBodyOrBytes, _body_text
from .http import Headers
from .json import _JsonBody


trait _HeaderCarrier(Deinitable, Movable):
    """Marks `WithHeaders`, so the registration rules and body slot in
    `app.mojo` can tell a carrier at compile time (as `_JsonBody` marks `Json`).
    Private; it adds nothing to `WithHeaders`'s public surface."""

    @staticmethod
    def _from_parts(body: List[UInt8], var headers: Headers) raises -> Self:
        """Builds the carrier from the request's body bytes, borrowed, and
        the rebuilt fields, converting the bytes as a bare body of the
        carried type: `from_bytes` on them unread and uncopied, or
        `from_body` on their text (M3-042). Raises when that conversion
        raises or, for a text body, when the bytes are not UTF-8."""
        ...

    @staticmethod
    def _max_bytes() -> Int:
        """The carried body type's limit: its `max_bytes` for a `FromBytes`
        (M3-043), else `Int.MAX`, no limit (a text body has no Muntin limit
        of its own; a `Json[T]` body's 1 MiB step is the JSON one)."""
        ...

    @staticmethod
    def _conversions() -> Int:
        """How many of `FromBody` and `FromBytes` the carried body type
        conforms to. `_kind` accepts the carrier only for exactly one: two
        is rejected as such a body alone is (M3-041), and Muntin never picks
        a conversion silently; none (a type conforming only to the private
        bound) is rejected as a body of no conversion."""
        ...


struct WithHeaders[B: _FromBodyOrBytes](
    Deinitable,
    Movable,
    _HeaderCarrier,
    _JsonBody where conforms_to(B, _JsonBody),
):
    """A request body and the request's header fields, as one body.

    A handler declares `input: WithHeaders[B]` (or `var input`) where it
    would declare a body `B`, in the body slot of `App.post`, `put` or
    `patch`, stateless or stateful. `input.headers` is the request's
    `Headers`: every field in order, with its casing, repeated names as
    separate fields and empty values kept; `get` matches names ASCII
    case-insensitively. Muntin chooses no status for these fields and gives
    them no meaning: a missing field is `None` and its status is the
    handler's error type to choose. Two existing checks still answer before
    the handler: a `Json[T]` body's `Content-Type` verdict (415), and the
    rebuild of a field an in-memory `Headers` holds invalidly (the fixed
    500). `input.body` is converted as a bare body of its type would be: a
    `FromBody` by `B.from_body` (bytes that are not UTF-8, or a raise, are
    400 before the handler; a `WithHeaders[Json[T]]` body keeps the JSON
    `Content-Type` (415) and size (413) steps), a `FromBytes` by
    `B.from_bytes` on the body's bytes, whatever they are (a raise is 400
    before the handler; no `Content-Type` rule; a body longer than
    `B.max_bytes` is 413 before the field rebuild and `from_bytes`,
    M3-043).

    `WithHeaders` is accepted in the body slot but is neither a `FromBody`
    nor a `FromBytes`, so a generic `B: FromBody` does not accept it.
    Building one by hand takes an explicit `Headers`:
    `WithHeaders(body^, headers^)`. A `B` that conforms to both `FromBody`
    and `FromBytes` is rejected at registration, as such a body alone is
    (M3-041).
    """

    var headers: Headers
    """The request's header fields."""
    var body: Self.B
    """The converted request body."""

    def __init__(out self, var body: Self.B, var headers: Headers):
        """Moves `body` and `headers` in."""
        self.body = body^
        self.headers = headers^

    def take_body(deinit self) -> Self.B:
        """Moves the body out (`input^.take_body()`): a field cannot be
        moved out of the middle of a value on Mojo 1.1.0."""
        return self.body^

    @staticmethod
    def _from_parts(body: List[UInt8], var headers: Headers) raises -> Self:
        comptime if conforms_to(Self.B, FromBytes):
            # The bytes as received, borrowed: no UTF-8 read, no copy.
            return Self(Self.B.from_bytes(body), headers^)
        else:
            comptime assert conforms_to(Self.B, FromBody)
            return Self(Self.B.from_body(_body_text(body)), headers^)

    @staticmethod
    def _max_bytes() -> Int:
        comptime if conforms_to(Self.B, FromBytes):
            return Self.B.max_bytes
        else:
            return Int.MAX

    @staticmethod
    def _conversions() -> Int:
        return Int(conforms_to(Self.B, FromBody)) + Int(
            conforms_to(Self.B, FromBytes)
        )
