# M2-005 argument-extraction decision spike, application side. Not
# production code, and not a supported Muntin API: production App still
# accepts exactly def() -> String and def(Int) -> String.
#
# `CreateUser` is defined here, as an application's request body would be; the
# conversion machinery lives in tests/extraction_spike.mojo, which does not
# import this module. Decision: docs/history/architecture-decisions.md,
# "Argument extraction decision".

from std.testing import assert_equal, TestSuite

from extraction_spike import (
    Body,
    ExtractApp,
    FromBody,
    box_with_decoder,
    call_wrapped,
)
from muntin import Request, Response


# ---------------------------------------------------------------------------
# Application code.


struct CreateUser(FromBody):
    """A move-only request body: no `Copyable`, so the spike must move it."""

    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        # The application owns the body format; this one is `name=<text>`.
        # Not JSON: the extraction contract does not choose a codec.
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


struct RenameTeam(FromBody):
    """A second body type with its own format, so a library that special-cased
    one application type would fail here."""

    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body.byte_length() == 0:
            raise Error("empty team name")
        return Self(body.upper())


def rename_team(id: Int, body: RenameTeam) -> String:
    return "team " + String(id) + " is " + body.name


def create_user(body: CreateUser) -> String:
    return "created " + body.name


def store_user(var payload: CreateUser) -> String:
    # Owned and moved on: proves the extracted value is not copied. The
    # parameter is not named `body`; binding never looks at names.
    var users = List[CreateUser]()
    users.append(payload^)
    return "stored " + users[0].name


def update_user(id: Int, body: CreateUser) -> String:
    return String(id) + ":" + body.name


def get_item(id: Int) -> String:
    return "item " + String(id)


def reject_user(body: CreateUser) raises -> String:
    raise Error("application failure for " + body.name)


def _post(app: ExtractApp, target: String, body: String) -> Response:
    return app.handle(Request("POST", target, body))


# ---------------------------------------------------------------------------
# Chosen direction: route values by position, then one body slot.


def test_body_slot_builds_app_type_without_library_naming_it() raises:
    var app = ExtractApp()
    app.post["/users"](create_user)
    var ok = _post(app, "/users", "name=Ada")
    assert_equal(ok.status, 200)
    assert_equal(ok.text(), "created Ada")
    # Conversion failure: 400, and the handler (which returns 200) never ran.
    for bad in ["", "Ada", "name="]:
        var r = _post(app, "/users", bad)
        assert_equal(r.status, 400)
        assert_equal(r.text(), "Bad Request")
    assert_equal(app.handle(Request("GET", "/users", "name=Ada")).status, 404)


def test_owned_parameter_receives_moved_body() raises:
    var app = ExtractApp()
    app.post["/users"](store_user)
    assert_equal(_post(app, "/users", "name=Grace").text(), "stored Grace")


def test_route_value_and_body_compose_by_position() raises:
    var app = ExtractApp()
    app.post["/users/{id}"](update_user)
    app.post["/teams?{id}"](update_user)  # same adapter, other source
    assert_equal(_post(app, "/users/7", "name=Bob").text(), "7:Bob")
    assert_equal(_post(app, "/teams?id=8", "name=Eve").text(), "8:Eve")
    assert_equal(_post(app, "/users/x", "name=Bob").status, 400)
    assert_equal(_post(app, "/users/7", "Bob").status, 400)
    assert_equal(_post(app, "/teams", "name=Eve").status, 400)
    assert_equal(_post(app, "/teams?id=1&id=2", "name=Eve").status, 400)
    app.post["/rename/{id}"](rename_team)
    assert_equal(_post(app, "/rename/4", "core").text(), "team 4 is CORE")
    assert_equal(_post(app, "/rename/4", "").status, 400)


def test_route_value_without_body_is_unaffected() raises:
    var app = ExtractApp()
    app.post["/items/{id}"](get_item)
    app.post["/users"](create_user)
    assert_equal(_post(app, "/items/5", "name=ignored").text(), "item 5")
    assert_equal(_post(app, "/items/x", "").status, 400)
    assert_equal(_post(app, "/users", "name=Lin").text(), "created Lin")


def test_handler_failure_is_not_an_extraction_failure() raises:
    var app = ExtractApp()
    app.post["/users"](reject_user)
    # Valid body, handler raises: not 400 (500 is the spike's placeholder
    # for the future application-error model).
    var r = _post(app, "/users", "name=Ada")
    assert_equal(r.status, 500)
    # Invalid body: 400 before the handler runs.
    assert_equal(_post(app, "/users", "Ada").status, 400)


def test_request_body_is_borrowed_not_consumed() raises:
    var app = ExtractApp()
    app.post["/users"](create_user)
    var request = Request("POST", "/users", "name=Ada")
    _ = app.handle(request)
    assert_equal(request.text(), "name=Ada")
    assert_equal(app.handle(request).text(), "created Ada")


def test_app_moves_with_body_routes() raises:
    var app = ExtractApp()
    app.post["/users"](create_user)
    app.post["/users/{id}"](update_user)
    var moved = app^
    assert_equal(_post(moved, "/users", "name=Ada").text(), "created Ada")
    assert_equal(_post(moved, "/users/3", "name=Ada").text(), "3:Ada")


# ---------------------------------------------------------------------------
# Rejected alternatives that compile: rejection is about DX, not feasibility.


def create_wrapped(body: Body[CreateUser]) -> String:
    return "created " + body.value.name  # extraction plumbing in the handler


def decode_user(raw: String) raises -> CreateUser:
    return CreateUser("decoded " + raw)


def test_wrapper_alternative_compiles() raises:
    assert_equal(call_wrapped(create_wrapped, "name=Ada"), "created Ada")


def test_decoder_alternative_fits_the_unchanged_box() raises:
    var boxed = box_with_decoder(create_user, decode_user)
    var raw: List[String] = ["Ada"]
    assert_equal(boxed.invoke(raw, List[UInt8]()).text(), "created decoded Ada")
    assert_equal(boxed.invoke(raw, List[UInt8]()).status, 200)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
