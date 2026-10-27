# Must not compile (M3-089): a Json[T] limit above 2^32 - 1, the
# longest body the parser's UInt32 offsets address, fails where the route
# instantiates the conversion.
# Expected diagnostic (checked by scripts/check.sh): Json's limit is over 4294967295 bytes, the longest body its parser addresses
from muntin import App, Json, JsonFields


@fieldwise_init
struct Item(JsonFields):
    var name: String


def create(body: Json[Item, limit=Int.MAX]) -> String:
    return body.value.name


def main():
    var app = App()
    app.post["/items"](create)
