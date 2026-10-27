# Must not compile (M3-089): Json's limit is keyword-only, so a
# later keyword parameter (#193's media-type rule, if per route) never
# depends on its position. The compiler's check, not Muntin's.
# Expected diagnostic (checked by scripts/check.sh): unexpected parameter
from muntin import App, Json, JsonFields


@fieldwise_init
struct Item(JsonFields):
    var name: String


def create(body: Json[Item, 4096]) -> String:
    return body.value.name


def main():
    var app = App()
    app.post["/items"](create)
