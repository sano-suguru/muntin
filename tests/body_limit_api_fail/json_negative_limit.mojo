# Must not compile (M3-089): a Json[T] body whose limit is
# negative is rejected at registration, as any body type's max_bytes.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the request body's max_bytes (a Json[T]'s limit) is negative; a body type's max_bytes is a byte count, 0 or more
from muntin import App, Json, JsonFields


@fieldwise_init
struct Item(JsonFields):
    var name: String


def create(body: Json[Item, limit=-1]) -> String:
    return body.value.name


def main():
    var app = App()
    app.post["/items"](create)
