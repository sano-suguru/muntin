# Types and handlers for tests/test_app_route_values.mojo, in a module of
# their own: the application conforms its types to `FromRouteValue` where
# it declares them, and Muntin never names them. The `Param` handler is
# here too, because a module that discovers its tests crashes beside one
# (tests/named_values_api_fail/discover_tests_crash.mojo). `make_app` is
# docs/reference/route-values.md's example as written. Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)".

from std.os import abort

from muntin import (
    App,
    FromBody,
    FromBytes,
    FromRouteValue,
    Headers,
    Param,
    State,
)


struct UserId(FromRouteValue, Movable):
    var value: Int

    def __init__(out self, value: Int):
        self.value = value

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        if not value.startswith("u"):
            raise Error("a user id is u and a number")
        return Self(Int(value[byte=1:]))


struct Order(FromRouteValue, Movable):
    var newest_first: Bool

    def __init__(out self, newest_first: Bool):
        self.newest_first = newest_first

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        if value == "new":
            return Self(True)
        if value == "old":
            return Self(False)
        raise Error("order is new or old")


def get_user(id: UserId) -> String:
    return "user " + String(id.value)


def list_posts(id: UserId, order: Order) -> String:
    var by = "newest" if order.newest_first else "oldest"
    return "posts of user " + String(id.value) + ", " + by + " first"


def make_app() raises -> App:
    var app = App()
    app.get["/users/{id}"](get_user)
    app.get["/users/{id}/posts?{order}"](list_posts)
    return app^


struct Text(FromRouteValue, Movable):
    """Takes any text, the empty text included, so a 400 for an empty
    value shows `from_route_value` was not called."""

    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        return Self("[" + value + "]")


struct NoBytes(FromBytes, Movable):
    """A body of at most 0 bytes: a longer one is 413 if it is reached."""

    comptime max_bytes = 0

    def __init__(out self):
        pass

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self()


struct Prefix(Movable):
    var text: String

    def __init__(out self, text: String):
        self.text = text


def text_value(t: Text) -> String:
    return t.text


def named_user(id: Param["id", UserId]) -> String:
    return "named " + String(id.value.value)


def named_pair(id: Param["id", UserId], order: Param["order", Order]) -> String:
    return String(id.value.value) + (
        " new" if order.value.newest_first else " old"
    )


def name_then_user(name: String, id: UserId) -> String:
    return name + "/" + String(id.value)


def user_then_int(id: UserId, n: Int) -> String:
    return String(id.value) + "+" + String(n)


def user_and_body(id: UserId, b: NoBytes) -> String:
    return "body for " + String(id.value)


def touch(id: UserId) -> String:
    return "touched " + String(id.value)


def user_headers(id: UserId, h: Headers) raises -> String:
    return String(id.value) + " " + h.get("X-A").value()


def stateful_user(s: State[Prefix], id: UserId) -> String:
    return s[].text + String(id.value)


def owned_user(var id: UserId) -> String:
    var kept = id^
    return "owned " + String(kept.value)


struct Unreached(FromRouteValue, Movable):
    """A conversion that ends the process if it is called, so a test that
    survives a request through it shows that it was not called."""

    def __init__(out self):
        pass

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        abort("Unreached.from_route_value was called with: " + value)


struct UnreachedBody(FromBody, Movable):
    """A body whose conversion ends the process if it is called."""

    def __init__(out self):
        pass

    @staticmethod
    def from_body(body: String) raises -> Self:
        abort("UnreachedBody.from_body was called")


def unreached_value(u: Unreached) -> String:
    return "handler called"


def user_then_unreached(id: UserId, u: Unreached, b: UnreachedBody) -> String:
    return "handler called"


def two_values_and_body(id: UserId, order: Order, var b: Note) -> String:
    var by = "new" if order.newest_first else "old"
    return String(id.value) + " " + by + " " + b.text


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)
