# M2 handler-storage decision spike, library side. Not production code: it
# models what Muntin's library module could contain, separately from the
# application module (tests/test_spike_handler_storage.mojo) that registers
# handlers, so app-defined types cross a module boundary as they would in a
# real application. check.sh builds it through that test (--Werror) and
# test.sh runs it; src/muntin is unchanged. Decision and evidence:
# docs/ARCHITECTURE.md, "Handler storage decision (M2)".

from std.builtin.rebind import downcast
from std.memory import MutOpaquePointer, OwnedPointer

from muntin import Request, Response


# ---------------------------------------------------------------------------
# Shared pieces: positional capture of `{name}` path segments, strict Int.


def _count_params(path: StaticString) -> Int:
    var n = 0
    for b in path.as_bytes():
        if Int(b) == ord("{"):
            n += 1
    return n


def _match(pattern: String, path: String, mut args: List[String]) -> Bool:
    var want = pattern.split("/")
    var got = path.split("/")
    if len(want) != len(got):
        return False
    args.clear()
    for i in range(len(want)):
        if want[i].startswith("{") and want[i].endswith("}"):
            args.append(String(got[i]))
        elif want[i] != got[i]:
            return False
    return True


def _int(s: String) raises -> Int:
    var b = s.as_bytes()
    var start = 1 if len(b) > 0 and Int(b[0]) == ord("-") else 0
    if len(b) == start:
        raise Error("not an integer")
    for i in range(start, len(b)):
        if Int(b[i]) < ord("0") or Int(b[i]) > ord("9"):
            raise Error("not an integer")
    return Int(s)


# ---------------------------------------------------------------------------
# Candidate 3b: typed heap box + pointer erasure (not the M0.5 design).
#
# The handler value of type F is moved into an `OwnedPointer[F]`, whose
# allocation is then held as an opaque pointer. Only the POINTER is erased;
# the function value's bytes are never reinterpreted, so nothing depends on
# how Mojo represents a function value, and size/alignment come from the
# allocation made for F. Ownership goes back to an `OwnedPointer[F]` through
# its documented `unsafe_from_opaque_pointer` constructor, whose contract is
# exactly this round trip ("must be initialize[d] with a single valid `T`
# initially allocated with this `OwnedPointer`'s backing allocator").
#
# The three thin functions stored beside the pointer are instantiated for the
# same F inside the one generic `__init__` that makes the box, so the pointer
# is only ever cast back to the type it was allocated as. Each `_Erased` owns
# its box: copy makes a new box (`_clone`), destruction rebuilds the
# `OwnedPointer[F]` and lets it deinitialize and free the value (`_drop`), and
# a move moves the pointer, not the box, so moving the route list or the App
# cannot leave a dangling box.
#
# Unsafe operations, all in this section: `OwnedPointer.unsafe_take_allocation`
# + `Allocation.unsafe_leak` (erase ownership), `Pointer.unsafe_bitcast` (F ->
# NoneType at erase, NoneType -> F at restore), and
# `OwnedPointer(unsafe_from_opaque_pointer=...)` (restore ownership). The
# invariant the compiler does not enforce: no code outside `_Erased.__init__`
# and its copy constructor writes `_box`, `_invoke`, `_clone` or `_drop`
# (Mojo 1.1.0 has no private fields).

comptime _Box = MutOpaquePointer[MutUntrackedOrigin]
comptime _Call[F: AnyType] = def(F, List[String]) raises thin -> Response


def _erase[F: Copyable & Deinitable](var owner: OwnedPointer[F]) -> _Box:
    return (
        owner^.unsafe_take_allocation().unsafe_leak().unsafe_bitcast[NoneType]()
    )


def _invoke_box[
    F: Copyable & Deinitable, //, call: _Call[F]
](box: _Box, args: List[String]) raises -> Response:
    return call(box.unsafe_bitcast[F]()[], args)


def _clone_box[F: Copyable & Deinitable](box: _Box) -> _Box:
    return _erase(OwnedPointer(copy_value=box.unsafe_bitcast[F]()[]))


def _drop_box[F: Copyable & Deinitable](box: _Box):
    _ = OwnedPointer[F](unsafe_from_opaque_pointer=box)


struct _Erased(Copyable, Movable):
    var _box: _Box
    var _invoke: def(_Box, List[String]) raises thin -> Response
    var _clone: def(_Box) thin -> _Box
    var _drop: def(_Box) thin

    def __init__[
        F: Copyable & Deinitable, //, call: _Call[F]
    ](out self, var value: F):
        self._box = _erase(OwnedPointer(value^))
        self._invoke = _invoke_box[call]
        self._clone = _clone_box[F]
        self._drop = _drop_box[F]

    def __init__(out self, *, copy: Self):
        self._box = copy._clone(copy._box)
        self._invoke = copy._invoke
        self._clone = copy._clone
        self._drop = copy._drop

    def __deinit__(deinit self):
        self._drop(self._box)

    def invoke(self, args: List[String]) raises -> Response:
        return self._invoke(self._box, args)


# Argument conversion is generic, so registration grows with arity, not with
# parameter types. Muntin types are selected by compile-time type equality:
# `Int` is `comptime Int = Scalar[DType.int]` on 1.1.0, so
# `__extension Int(...)` fails with "can't find a struct named 'Int'".
# Application-defined types (a request body such as `CreateUser`) conform to
# `FromArg` and are reached through `conforms_to` + `downcast`
# (std/builtin/rebind.mojo). An unsupported parameter type is a compile error
# at the registration call.


trait FromArg(Deinitable, Movable):
    """Conversion for application-defined parameter types (bodies)."""

    @staticmethod
    def from_arg(s: String) raises -> Self:
        ...


def _from_arg[A: Movable & Deinitable](s: String) raises -> A:
    comptime if A == Int:
        return rebind_var[A](_int(s))
    elif A == String:
        return rebind_var[A](s.copy())
    elif conforms_to(A, FromArg):
        return rebind_var[A](downcast[A, FromArg].from_arg(s))
    else:
        comptime assert False, "unsupported handler parameter type"


trait Reply(Deinitable):
    """Result conversion for application-defined return types (`User`)."""

    def reply(self) -> Response:
        ...


# Handler parameters are `raises` function types: a non-raising `def`
# converts to them implicitly, so raising handlers need no extra overloads.
# (Here any raise becomes 400; the application-error model is later M2 work.)
#
# `-> String` is its own return family with concrete adapters, so String
# needs no conformance; `__extension` is not in the 1.1.0 documentation and
# this spike does not use it. Registration grows with arity x return family,
# never with parameter types.


def _call0s(
    h: def() raises thin -> String, args: List[String]
) raises -> Response:
    return Response.text(h())


def _call0[
    R: Reply
](h: def() raises thin -> R, args: List[String]) raises -> Response:
    return h().reply()


def _call1s[
    A: Movable & Deinitable
](h: def(A) raises thin -> String, args: List[String]) raises -> Response:
    return Response.text(h(_from_arg[A](args[0])))


def _call1[
    A: Movable & Deinitable, R: Reply
](h: def(A) raises thin -> R, args: List[String]) raises -> Response:
    return h(_from_arg[A](args[0])).reply()


def _call2s[
    A: Movable & Deinitable, B: Movable & Deinitable
](h: def(A, B) raises thin -> String, args: List[String]) raises -> Response:
    return Response.text(h(_from_arg[A](args[0]), _from_arg[B](args[1])))


def _call2[
    A: Movable & Deinitable, B: Movable & Deinitable, R: Reply
](h: def(A, B) raises thin -> R, args: List[String]) raises -> Response:
    return h(_from_arg[A](args[0]), _from_arg[B](args[1])).reply()


@fieldwise_init
struct _BRoute(Copyable, Movable):
    var pattern: String
    var handler: _Erased


struct BoxApp(Movable):
    """Same registration syntax as production `App`:
    `app.get["/users/{id}"](get_user)` with the handler as a runtime value.
    """

    var _routes: List[_BRoute]

    def __init__(out self):
        self._routes = List[_BRoute]()

    def _add[
        F: Copyable & Deinitable, //, path: StaticString, call: _Call[F]
    ](mut self, var handler: F):
        self._routes.append(
            _BRoute(String(path), _Erased.__init__[call=call](handler^))
        )

    def get[path: StaticString](mut self, handler: def() raises thin -> String):
        comptime assert _count_params(path) == 0, "arity"
        self._add[path, _call0s](handler)

    def get[
        R: Reply, //, path: StaticString
    ](mut self, handler: def() raises thin -> R):
        comptime assert _count_params(path) == 0, "arity"
        self._add[path, _call0[R]](handler)

    def get[
        A: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def(A) raises thin -> String):
        comptime assert _count_params(path) == 1, "arity"
        self._add[path, _call1s[A]](handler)

    def get[
        A: Movable & Deinitable, R: Reply, //, path: StaticString
    ](mut self, handler: def(A) raises thin -> R):
        comptime assert _count_params(path) == 1, "arity"
        self._add[path, _call1[A, R]](handler)

    def get[
        A: Movable & Deinitable, B: Movable & Deinitable, //, path: StaticString
    ](mut self, handler: def(A, B) raises thin -> String):
        comptime assert _count_params(path) == 2, "arity"
        self._add[path, _call2s[A, B]](handler)

    def get[
        A: Movable & Deinitable,
        B: Movable & Deinitable,
        R: Reply,
        //,
        path: StaticString,
    ](mut self, handler: def(A, B) raises thin -> R):
        comptime assert _count_params(path) == 2, "arity"
        self._add[path, _call2[A, B, R]](handler)

    def handle(self, request: Request) -> Response:
        var args = List[String]()
        for route in self._routes:
            if request.method != "GET" or not _match(
                route.pattern, request.path, args
            ):
                continue
            try:
                return route.handler.invoke(args)
            except:
                return Response.text("Bad Request", status=400)
        return Response.text("Not Found", status=404)

    def route_handlers(self) -> List[_Erased]:
        """Copies of the stored handlers, for the ownership tests."""
        var out = List[_Erased]()
        for route in self._routes:
            out.append(route.handler.copy())
        return out^
