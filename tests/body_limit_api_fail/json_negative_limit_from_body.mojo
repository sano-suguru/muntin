# Must not compile (M3-089): a raw handler's call of a Json[T] body's
# from_body, which no route registration checks, rejects a negative limit too.
# Expected diagnostic (checked by scripts/check.sh): Json's limit is negative; a limit is a byte count, 0 or more
from muntin import Json, JsonFields


@fieldwise_init
struct Item(JsonFields):
    var name: String


def main() raises:
    var item = Json[Item, limit=-1].from_body('{"name":"a"}')
    print(item.value.name)
