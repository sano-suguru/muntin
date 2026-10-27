# Must not compile (M3-098 prototype): a default that its field does not read, nested in a body.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the default '"20"' of field limit of the JsonFields struct members_default_does_not_read.Page does not read as SIMD[DType.int, 1]: JSON value is not a number
from muntin import App, Json, JsonFields, JsonMember, JsonMembers


@fieldwise_init
struct Page(JsonMembers):
    var limit: Int

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("limit", default='"20"')]


@fieldwise_init
struct In(JsonFields):
    var pages: List[Page]


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
