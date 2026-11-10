# Must not compile (M3-098 prototype): a Float64 default past the largest finite Float64.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the default '1e309' of field ratio of the JsonFields struct members_default_float_out_of_range.In does not read as SIMD[DType.float64, 1]: JSON number is out of range
from muntin import App, Json, JsonMember, JsonMembers


@fieldwise_init
struct In(JsonMembers):
    var ratio: Float64

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("ratio", default="1e309")]


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
