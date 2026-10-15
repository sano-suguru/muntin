"""Named route values (M3-050).

`Param[name, T]` is a route value that names the placeholder it binds:
`def post_of(uid: Param["uid", Int], pid: Param["pid", Int])` on
`/users/{uid}/posts/{pid}`. It is opt-in: binding stays positional
(M3-022), and the registration rules compare each `Param`'s name with the
placeholder at its position at compile time; of a handler's two route
values, both or neither are `Param`s (docs/history/architecture-decisions.md,
"Named route values decision (M3-050)").
"""


trait _NamedValue(Deinitable, Movable):
    """Marks `Param`, so the registration rules (`_kind`) and the slot
    conversion in `app.mojo` can tell a named route value at compile time
    and reach its name and value type. Private; it adds nothing to
    `Param`'s public surface."""

    comptime _placeholder: StaticString
    """The placeholder name the value binds."""
    comptime _Value: Movable & Deinitable
    """The value's type: `Int`, `String` or an `Optional` of either."""

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
    `Optional[Int]` or `Optional[String]`, under the same rules as the bare
    type. The value is `uid.value`. Values still bind by position, path
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
