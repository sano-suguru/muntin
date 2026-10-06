"""Application state: a shared, read-only handle a handler receives.

Decision and evidence: docs/history/architecture-decisions.md, "Application state decision
(M3-001)". A handler takes state exactly when its registration passes one,
`app.get["/users/{id}"](get_user, users)`; `State[S]` is then the handler's
first parameter.
"""

from ._handler_storage import _Shared


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
        """Moves `value` into a new shared allocation."""
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
