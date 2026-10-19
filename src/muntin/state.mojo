"""Application state: a shared, read-only handle a handler receives.

Decision and evidence: docs/history/architecture-decisions.md, "Application state decision
(M3-001)". A handler takes state exactly when its registration passes one,
`app.get["/users/{id}"](get_user, users)`; `State[S]` is then the handler's
first parameter.

A state's type may not borrow: "State borrowing decision (M3-074)".
"""

from std.reflection import reflect

from ._handler_storage import _Shared


def _may_borrow[S: AnyType]() -> Bool:
    """Whether `S`'s reflected name shows `{}` anywhere in it, a type
    argument's included: how Mojo 1.1.0 prints every origin, and beside a
    parameter pack, whose element types it does not print
    (`Tuple[<unprintable>, {}]`) (M3-074).

    A value borrows a local only through that local's origin in its type. A
    module-level declaration cannot name a local's origin and a struct
    cannot be declared inside a function, so that origin reaches a field
    only as a parameter of `S` or of a type in its name, where it prints as
    `{}` or hides in a pack. A function-valued parameter prints as
    `<unprintable>` alone and is admitted: it is a compile-time value with
    no address, and a field typed from what it returns needs a concrete
    result type, whose origins are then parameters of the struct, which
    print, or `AnyOrigin`; a parameter of an open type cannot be called
    (tests/state_fail/state_function_parameter_*.mojo). `AnyOrigin` behind
    a trait's associated type escapes the name
    (tests/state_known_gaps/state_any_origin_associated_type.mojo), a
    toolchain-wide hole; no check found on Mojo 1.1.0 refuses it and still
    admits owned states (docs/history/deferrals.md, "Closing `State`'s
    `AnyOrigin` hole"). The format is undocumented; the fixtures under tests/state_fail that refuse
    a borrowing state fail if it stops showing origins.
    """
    comptime name = reflect[S].name()
    return name.find("{}") >= 0


trait _InjectedState:
    """Marks `State`, so `App.post` can tell injected state from a request
    body at compile time (M3-006). Private; it adds nothing to `State`."""

    pass


struct State[S: Movable & Deinitable](Copyable, Movable, _InjectedState):
    """A shared, read-only handle to one application value of type `S`.

    The application builds it once, `State(Users(...))`, and passes it at
    every registration whose handler takes it. Copies share the one value
    (reference counted); the value is destroyed when the last handle, the
    application's or a route's, goes away. A registration keeps one copy;
    handlers borrow the route's handle, so a request copies and allocates
    nothing.

    `state[]` is an immutable reference to the value through every handle,
    borrowed, `mut` or owned. A value that must change while the
    application serves keeps that mutability in its own fields, under its
    own rules. `_shared` is internal: Mojo has no private fields, so it is
    reachable by name, but it is not API.
    """

    var _shared: _Shared[Self.S]

    def __init__(out self, var value: Self.S):
        """Moves `value` into a new shared allocation.

        `S`'s name may not show an origin or a pack (`_may_borrow`): a route
        erases its state and the `App`'s type does not carry `S`'s origins,
        so nothing would keep a borrowed value alive for the `App` (M3-074).
        """
        comptime assert not _may_borrow[Self.S](), (
            "State takes a value that owns its data; this type's name shows an"
            " origin or a parameter pack ({}), so it may borrow a value the"
            " App outlives: "
            + reflect[Self.S].name()
        )
        self._shared = _Shared(value^)

    def __getitem__(self) -> ref[origin_of(self._shared.owned()[])] Self.S:
        """The shared value, read-only, as long as this handle lives.

        The reference is immutable whatever handle it is taken through, and
        it is interior to this handle: using it after the handle is
        reassigned or moved is a compile error (`use of invalidated
        interior reference`, tests/state_get_fail), and it cannot be
        returned from a function as a reference into the handle. Another
        handle cannot replace or mutate the value on ordinary paths
        (docs/history/architecture-decisions.md, "State storage decision (M3-004)").
        """
        return self._shared.owned()[]
