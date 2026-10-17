# Handlers for tests/test_named_values.mojo, kept in their own module: Mojo
# 1.1.0 crashes when a module that discovers its tests
# (`TestSuite.discover_tests[__functions_in_module()]`) also defines a
# function with a `Param` parameter
# (tests/named_values_api_fail/discover_tests_crash.mojo). Importing them
# does not crash, so the test module discovers its tests as every other one
# does. Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".

from muntin import App, FromBody, Headers, Param, State


struct Prefix(Movable):
    var text: String

    def __init__(out self, text: String):
        self.text = text


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


# docs/reference/route-values.md, "Named route values": the text between the
# `# example:` lines is what the page shows (scripts/check_doc_examples.py).


# fmt: off
# example: route-values-named
from muntin import App, Param


def post_of(uid: Int, pid: Int) -> String:              # bare: bound by position, not checked
    return String("post ", pid, " of user ", uid)


def checked_post_of(uid: Param["uid", Int], pid: Param["pid", Int]) -> String:
    return String("post ", pid.value, " of user ", uid.value)


def make_app() -> App:
    var app = App()
    app.get["/users/{uid}/posts/{pid}"](post_of)
    app.get["/checked/{uid}/posts/{pid}"](checked_post_of)
    return app^
# GET /users/1/posts/2, /checked/1/posts/2 -> 200 "post 2 of user 1"
# GET /checked/1/posts/x                   -> 400 "Bad Request"
# example: end
# fmt: on


def with_body(
    uid: Param["uid", Int], pid: Param["pid", Int], body: Note
) -> String:
    return String(uid.value, ",", pid.value, "=", body.text)


def query_pair(q: Param["q", String], limit: Param["limit", Int]) -> String:
    return String(limit.value, " results for ", q.value)


def bodyless(a: Param["a", String], b: Param["b", String]) -> String:
    return String(a.value, ",", b.value)


def with_headers(
    uid: Param["uid", Int], pid: Param["pid", Int], headers: Headers
) -> String:
    return String(uid.value, ",", pid.value, " ", len(headers))


def stateful(
    p: State[Prefix], uid: Param["uid", Int], tag: Param["tag", String]
) -> String:
    return String(p[].text, uid.value, ",", tag.value)


def named_one(id: Param["id", Int]) -> String:
    return String("named ", id.value)


def named_optional(limit: Param["limit", Optional[Int]]) -> String:
    return String("limit ", limit.value.or_else(20))


def same_names(first: Param["a", Int], second: Param["a", Int]) -> String:
    return String(first.value, ",", second.value)


def misled(pid: Param["uid", Int], uid: Param["pid", Int]) -> String:
    # Each variable is named after the other placeholder; only the `Param`
    # names are compared, so this registers on /users/{uid}/posts/{pid}.
    return String("post ", pid.value, " of user ", uid.value)
