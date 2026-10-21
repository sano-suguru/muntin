# Must not compile (M3-082 prototype): a top-level Dict.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: Json[std.collections.dict.Dict[String, SIMD[DType.int, 1]
from muntin import App, Json


def h() -> Json[Dict[String, Int]]:
    return Json(Dict[String, Int]())


def main():
    var app = App()
    app.get["/c"](h)
