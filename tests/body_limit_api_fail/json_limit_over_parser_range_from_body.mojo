# Must not compile (M3-089): a raw handler's call of a Json[T] body's
# from_body, which no route registration checks, rejects a limit past the
# parser's range too.
# Expected diagnostic (checked by scripts/check.sh): Json's limit is over 4294967295 bytes, the longest body its parser addresses
from muntin import Json, JsonFields


@fieldwise_init
struct Item(JsonFields):
    var name: String


def main() raises:
    var item = Json[Item, limit=4_294_967_296].from_body('{"name":"a"}')
    print(item.value.name)
