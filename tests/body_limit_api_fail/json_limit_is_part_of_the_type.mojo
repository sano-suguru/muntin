# Must not compile (M3-089): `limit` is part of `Json`'s type, so a handler
# that returns its `Json[T, limit=n]` body as a `Json[T]` does not build;
# it returns `Json[T, limit=n]`. The compiler's check, not Muntin's.
# Expected diagnostic (checked by scripts/check.sh): cannot implicitly convert 'Json[Item, limit=Int(4096)]' value to 'Json[Item]'
from muntin import App, Json, JsonFields


@fieldwise_init
struct Item(JsonFields):
    var name: String


def echo(var body: Json[Item, limit=4096]) -> Json[Item]:
    return body^


def main():
    var app = App()
    app.post["/items"](echo)
