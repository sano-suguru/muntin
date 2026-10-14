"""Named route values (M3-050) and application route-value types (M3-055).

`Param[name, T]` is a route value that names the placeholder it binds:
`def post_of(uid: Param["uid", Int], pid: Param["pid", Int])` on
`/users/{uid}/posts/{pid}`. It is opt-in: binding stays positional
(M3-022), and the registration rules compare each `Param`'s name with the
placeholder at its position at compile time; of a handler's two route
values, both or neither are `Param`s (docs/history/architecture-decisions.md,
"Named route values decision (M3-050)").

`FromRouteValue` makes an application type a route value: `def
get_user(id: UserId)` on `/users/{id}` (docs/history/architecture-decisions.md,
"Application route-value types decision (M3-054)").
"""


trait _NamedValue(Deinitable, Movable):
    """Marks `Param`, so the registration rules (`_kind`) and the slot
    conversion in `app.mojo` can tell a named route value at compile time
    and reach its name and value type. Private; it adds nothing to
    `Param`'s public surface."""

    comptime _placeholder: StaticString
    """The placeholder name the value binds."""
    comptime _Value: Movable & Deinitable
    """The value's type: `Int`, `String`, an `Optional` of either, or a
    `FromRouteValue` type."""

    @staticmethod
    def _wrap(var value: Self._Value) -> Self:
        """The named value holding `value`."""
        ...


struct Param[name: StaticString, T: Movable & Deinitable](
    Copyable where conforms_to(T, Copyable),
    Movable,
    _NamedValue,
):
    """A route value of type `T` bound to the placeholder `name`.

    A handler declares `uid: Param["uid", Int]` where it would declare
    `uid: Int`; `T` is a route value's type: `Int`, `String`,
    `Optional[Int]`, `Optional[String]` or a `FromRouteValue` type
    (M3-055), under the same rules as the bare type. The value is
    `uid.value`. Values still bind by position, path
    placeholders left to right, then query placeholders left to right; the
    registration fails when `name` differs from the placeholder at the
    value's position, so two `Param`s whose names are in the other order
    than the literal's are a compile error instead of each other's values. Of two route values, both
    or neither are `Param`s. The variable's own name is not compared.
    """

    comptime _placeholder = Self.name
    comptime _Value = Self.T

    var value: Self.T
    """The converted route value."""

    def __init__(out self, var value: Self.T):
        """Moves `value` in."""
        self.value = value^

    @staticmethod
    def _wrap(var value: Self._Value) -> Self:
        return Self(value^)


trait FromRouteValue(Deinitable, Movable):
    """An application type that a handler can take as a route value (M3-055).

    The application type conforms itself, in its own module, and decides
    how the text reads; Muntin never names it. A conforming type is a route
    value wherever a required `String` is: one or two per handler, on every
    method,
    from a `{name}` path segment or a `{key}` query item, and inside
    `Param[name, T]`. `App.handle` converts it with `from_route_value`
    before the handler, after the values before it and before any body.

    A type is a route value or a body, never both: one that also conforms to
    `FromBody` or `FromBytes` is rejected at registration, bare, in a
    `Param` or in a `WithHeaders`, so no conversion is picked silently.
    Conforming does not make `Optional[T]` an optional value. `Int` and
    `String` stay Muntin's own route values; a standard-library type cannot
    conform.

    `Deinitable` and `Movable` as for `FromBody`: the type may be
    move-only, and the handler receives the converted value by move.
    """

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        """Builds the value from the placeholder's text, percent-decoded
        once (in a query value, `+` is a space first) and never empty: an
        empty value is answered 400 without calling it. Raising rejects
        the request with 400 `Bad Request` without calling the handler,
        whatever raised: a fault in the conversion itself is answered 400
        too, so keep it to reading the text and leave work that can fail
        for other reasons to the handler."""
        ...
