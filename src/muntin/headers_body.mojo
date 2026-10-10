"""Typed request-header access for `post` bodies (M3-013).

`WithHeaders[B]` carries the request's header fields beside a body in the
existing body slot of `App.post` (docs/history/architecture-decisions.md, "Typed header access
decision (M3-012)"). It is not itself a `FromBody`: the body slot in
`app.mojo` accepts `FromBody` or the private `_HeaderCarrier`, so a body
alone never produces a carrier without the request's fields.
"""

from .body import FromBody, FromBytes
from .http import Headers
from .json import _JsonBody


trait _HeaderCarrier(Deinitable, Movable):
    """Marks `WithHeaders`, so the registration rules and body slot in
    `app.mojo` can tell a carrier at compile time (as `_JsonBody` marks `Json`).
    Private; it adds nothing to `WithHeaders`'s public surface."""

    @staticmethod
    def _from_parts(body: String, var headers: Headers) raises -> Self:
        """Builds the carrier from the request body and the rebuilt fields;
        raises only when the body's `from_body` raises."""
        ...

    @staticmethod
    def _two_conversions() -> Bool:
        """Whether the carried body type also conforms to `FromBytes`
        (M3-041), so `_kind` rejects the carrier as it rejects such a body
        alone: a carrier converts with `from_body`, and Muntin never picks
        one of two conversions silently."""
        ...


struct WithHeaders[B: FromBody](
    Deinitable,
    Movable,
    _HeaderCarrier,
    _JsonBody where conforms_to(B, _JsonBody),
):
    """A request body and the request's header fields, as one `post` body.

    A handler declares `input: WithHeaders[B]` (or `var input`) where it
    would declare a body `B`, in the body slot of `App.post`, stateless or
    stateful. `input.headers` is the request's
    `Headers`: every field in order, with its casing, repeated names as
    separate fields and empty values kept; `get` matches names ASCII
    case-insensitively. Muntin chooses no status for these fields and gives
    them no meaning: a missing field is `None` and its status is the
    handler's error type to choose. Two existing checks still answer before
    the handler: a `Json[T]` body's `Content-Type` verdict (415), and the
    rebuild of a field an in-memory `Headers` holds invalidly (the fixed
    500). `input.body` is converted by `B.from_body` as a bare body would be
    (bytes that are not UTF-8, or a raise, are 400 before the handler), and a
    `WithHeaders[Json[T]]` body keeps the JSON `Content-Type` (415) and size
    (413) steps.

    `WithHeaders` is accepted in the body slot but is not a `FromBody`, so a
    generic `B: FromBody` does not accept it. Building one by hand takes an
    explicit `Headers`: `WithHeaders(body^, headers^)`.
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
    def _from_parts(body: String, var headers: Headers) raises -> Self:
        return Self(Self.B.from_body(body), headers^)

    @staticmethod
    def _two_conversions() -> Bool:
        return conforms_to(Self.B, FromBytes)
