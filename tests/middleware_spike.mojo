# M3-034 middleware decision spike, library side. Not production code: it
# models a production `App` wrapped by a middleware chain, separately from the
# application module (tests/test_spike_middleware.mojo) that defines the
# middleware and handlers. Production `App` is used unchanged as the innermost
# layer: every request the chain passes on reaches `App.handle`, so 404, 405,
# the pre-handler 400s and handler errors are production's. test.sh builds
# (--Werror) and runs it through that test; check.sh builds it through
# tests/middleware_lib_only/driver.mojo. Decision and evidence: docs/history/architecture-decisions.md,
# "Middleware decision (M3-034)". Must-not-compile evidence:
# tests/middleware_fail.
#
# One chain, registration order, outermost first. Each candidate's spelling
# registers a link on the same `MwApp`, so the candidates run against the same
# request set; an application uses one of them.
#
#   Next[o]   the rest of the chain: an immutable `Pointer[MwApp, o]` and the
#             index of the next link, made in `_run`'s frame and moved into the
#             middleware (`var next: Next`). Its origin is the borrowed
#             `MwApp`'s, so it cannot outlive that borrow, and no `AnyOrigin`
#             or untracked pointer is involved (a struct field cannot hold
#             `AnyOrigin` on Mojo 1.1.0). `Movable`, not `Copyable`; its one
#             call, `next^.run(request)`, consumes it (`deinit self`), so a
#             second call or a call in a loop does not compile (`use of
#             uninitialized value 'next'`): one middleware call dispatches the
#             rest at most once, by type. `run` runs the rest and returns its
#             response (at the end of the chain, production `App.handle`).
#   F         `use(f)`: a thin function
#             `def(var Request, var Next) raises -> Response`. The stored type
#             is generic over `next`'s origin (`MiddlewareFn`); an application
#             function written with a plain `var next: Next` converts to it. No value is stored with it, so no
#             erasure and no unsafe operation; configuration is compile-time
#             only, through the function's own parameters (`use(tag["v"])`).
#   A         `use(m)`: a value of an application struct conforming to
#             `Middleware`, with runtime fields. Stored in `_ErasedMw`, a box
#             modeled on production `_Erased` (header-less here: one owner,
#             nothing to swap in a spike), whose stored invoke function is
#             generic over `next`'s origin. It names `Request` and `Next`, so
#             in production it would widen two `check_unsafe.sh` rules (the
#             storage module would name request data and import beyond `.http`).
#   A'        `use[m]()`: a compile-time value of such a struct. A thin
#             trampoline materializes `m` on every call and calls its
#             `handle`; stored like F, no erasure.
#   H         `before(h)` / `after(h)`: hooks without a `next`. `before` may
#             answer instead of the rest (`Optional[Response]`); `after` gets
#             the request and the rest's response. Nothing passes between a
#             `before` and its `after`.
#
# A raise out of a middleware or hook is the fixed 500, production's
# `_internal_error()` (no error text reaches the client), made at that
# middleware's own call: the middleware outside it gets the 500 back from its
# `next` as an ordinary response and runs the rest of its own code.
# Middleware has no error type of its own here.

from std.memory import MutOpaquePointer, OwnedPointer

from muntin import App, Request, Response
from muntin.app import _internal_error


struct Next[o: Origin[mut=False]](Movable):
    """The rest of the chain after one middleware, for the duration of its
    call."""

    var _app: Pointer[MwApp, Self.o]
    var _i: Int

    def __init__(out self, ref[Self.o] app: MwApp, i: Int):
        self._app = Pointer(to=app)
        self._i = i

    def run(deinit self, var request: Request) -> Response:
        """Runs the rest of the chain on `request` and returns its answer.
        Consumes `self`: call it as `next^.run(request^)`, at most once."""
        return self._app[]._run(self._i, request^)


comptime MiddlewareFn = def[o: Origin[mut=False]](
    var Request, var Next[o]
) raises thin -> Response
"""F: a middleware function."""

comptime BeforeHook = def(Request) raises thin -> Optional[Response]
"""H: answers instead of the rest when it returns a response."""

comptime AfterHook = def(Request, var Response) raises thin -> Response
"""H: sees the request and the rest's response; returns the answer."""


trait Middleware(Deinitable, Movable):
    """A and A': an application struct that wraps the rest of the chain."""

    def handle(self, var request: Request, var next: Next) raises -> Response:
        ...


# A: the erased box. In production this would sit in `_handler_storage.mojo`.
comptime _Box = MutOpaquePointer[MutUntrackedOrigin]
comptime _MwInvoke = def[o: Origin[mut=False]](
    _Box, var Request, var Next[o]
) raises thin -> Response


def _invoke_mw[
    M: Middleware
](box: _Box, var request: Request, var next: Next) raises -> Response:
    return box.unsafe_bitcast[M]()[].handle(request^, next^)


def _drop_mw[M: Middleware](box: _Box):
    _ = OwnedPointer[M](unsafe_from_opaque_pointer=box)


struct _ErasedMw(Movable):
    """Owns one middleware value of a type known only at `use`."""

    var _invoke: _MwInvoke
    var _drop: def(_Box) thin
    var _value: _Box

    def __init__[M: Middleware](out self, var value: M):
        self._invoke = _invoke_mw[M]
        self._drop = _drop_mw[M]
        self._value = (
            OwnedPointer(value^)
            .unsafe_take_allocation()
            .unsafe_leak()
            .unsafe_bitcast[NoneType]()
        )

    def __deinit__(deinit self):
        self._drop(self._value)

    def invoke(self, var request: Request, var next: Next) raises -> Response:
        return self._invoke(self._value, request^, next^)


# A': the trampoline for a compile-time value.
def _call_static[
    M: Middleware & ImplicitlyCopyable, //, m: M
](var request: Request, var next: Next) raises -> Response:
    return materialize[m]().handle(request^, next^)


# Placeholders for the unused fields of a link.
def _no_fn(var request: Request, var next: Next) raises -> Response:
    return _internal_error()


def _no_before(request: Request) raises -> Optional[Response]:
    return None


def _no_after(request: Request, var response: Response) raises -> Response:
    return response^


comptime _FN = 0
comptime _BOXED = 1
comptime _BEFORE = 2
comptime _AFTER = 3


struct _Link(Deinitable, Movable):
    var kind: Int
    var function: MiddlewareFn
    var boxed: Optional[_ErasedMw]
    var before: BeforeHook
    var after: AfterHook

    def __init__(out self, *, function: MiddlewareFn):
        self.kind = _FN
        self.function = function
        self.boxed = None
        self.before = _no_before
        self.after = _no_after

    def __init__(out self, *, var boxed: _ErasedMw):
        self.kind = _BOXED
        self.function = _no_fn
        self.boxed = boxed^
        self.before = _no_before
        self.after = _no_after

    def __init__(out self, *, before: BeforeHook):
        self.kind = _BEFORE
        self.function = _no_fn
        self.boxed = None
        self.before = before
        self.after = _no_after

    def __init__(out self, *, after: AfterHook):
        self.kind = _AFTER
        self.function = _no_fn
        self.boxed = None
        self.before = _no_before
        self.after = after


struct MwApp(Movable):
    """A production `App` with a middleware chain in front of it."""

    var app: App
    var _links: List[_Link]

    def __init__(out self, var app: App):
        self.app = app^
        self._links = List[_Link]()

    # F
    def use(mut self, f: MiddlewareFn):
        self._links.append(_Link(function=f))

    # A
    def use[M: Middleware](mut self, var m: M):
        self._links.append(_Link(boxed=_ErasedMw(m^)))

    # A'
    def use[M: Middleware & ImplicitlyCopyable, //, m: M](mut self):
        self._links.append(_Link(function=_call_static[m]))

    # H
    def before(mut self, h: BeforeHook):
        self._links.append(_Link(before=h))

    def after(mut self, h: AfterHook):
        self._links.append(_Link(after=h))

    def _run(self, i: Int, var request: Request) -> Response:
        if i == len(self._links):
            return self.app.handle(request)
        ref link = self._links[i]
        try:
            if link.kind == _FN:
                return link.function(request^, Next(self, i + 1))
            if link.kind == _BOXED:
                return link.boxed.value().invoke(request^, Next(self, i + 1))
            if link.kind == _BEFORE:
                var early = link.before(request)
                if early:
                    return early.take()
                return self._run(i + 1, request^)
            var response = self._run(i + 1, request.copy())
            return link.after(request, response^)
        except:
            return _internal_error()

    def handle(self, request: Request) -> Response:
        """What production `App.handle` would become: with no middleware,
        the request goes to the routes without a copy."""
        if len(self._links) == 0:
            return self.app.handle(request)
        return self._run(0, request.copy())
