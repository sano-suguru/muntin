# Must not compile (M3-083): an Optional of an Optional (null would not round-trip).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field x of the JsonFields struct derived_optional_optional.S has type std.collections.optional.Optional[std.collections.optional.Optional[
from muntin import App, Json, JsonFields


@fieldwise_init
struct S(JsonFields):
    var x: Optional[Optional[Int]]


def h() -> Json[S]:
    return Json(S(None))


def main():
    var app = App()
    app.get["/c"](h)
