# Must not compile (M3-098 prototype): a defaulted member of a struct that is not JsonDefault, nested in a body.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field limit of the JsonFields struct members_default_without_json_default.Page is defaulted, but members_default_without_json_default.Page is not JsonDefault
from muntin import (
    App,
    Json,
    JsonCamelCase,
    JsonDefault,
    JsonFields,
    JsonMember,
    JsonMembers,
)


@fieldwise_init
struct Page(JsonMembers):
    var limit: Int

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("limit", default=True)]


@fieldwise_init
struct In(JsonFields):
    var pages: List[Page]


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
