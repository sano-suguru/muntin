# Must not compile (M3-098 prototype): two fields that camelCase makes one member, in a result.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: fields created_at and createdAt of the JsonFields struct members_same_name.Out are both member createdAt
from muntin import App, Json, JsonCamelCase


@fieldwise_init
struct Out(JsonCamelCase):
    var created_at: Int
    var createdAt: Int


def h() -> Json[Out]:
    return Json(Out(1, 2))


def main():
    var app = App()
    app.post["/c"](h)
