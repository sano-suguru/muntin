# Must not compile (M3-083): a Dict field in a result.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field by_name of the JsonFields struct derived_result_dict.Counts has type std.collections.dict.Dict
from muntin import App, Json, JsonFields


@fieldwise_init
struct Counts(JsonFields):
    var total: Int
    var by_name: Dict[String, Int]


def h() -> Json[Counts]:
    return Json(Counts(1, {}))


def main():
    var app = App()
    app.get["/c"](h)
