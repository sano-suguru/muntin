# Must not compile (M3-082 prototype): a Dict field in a body.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field by_name of the JsonFields struct derived_body_dict.Counts has type std.collections.dict.Dict
from muntin import App, Json, JsonFields


@fieldwise_init
struct Counts(JsonFields):
    var total: Int
    var by_name: Dict[String, Int]


def h(body: Json[Counts]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
