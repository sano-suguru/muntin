# Must not compile (M3-089 prototype): a negative Json[T] limit inside
# WithHeaders[B] is rejected at registration, as a bare one.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the request body's max_bytes is negative; a body type's max_bytes is a byte count, 0 or more
from muntin import App, Json, JsonFields, WithHeaders


@fieldwise_init
struct Item(JsonFields):
    var name: String


def create(id: Int, input: WithHeaders[Json[Item, limit=-1]]) -> String:
    return input.body.value.name


def main():
    var app = App()
    app.post["/items/{id}"](create)
