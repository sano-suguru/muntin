# Must not compile (M3-083): a `JsonFields` struct holding a `List` of itself.
# Mojo 1.1.0 rejects the struct before any codec sees it, so the derived
# codec's kind checks, which recurse into each field's type with no cycle
# guard, never meet a cycle. If this starts to build, give them one first.
# Expected diagnostic (checked by scripts/check.sh): field 'kids' has non-'Deinitable' type 'List[Tree]'
from muntin import App, Json, JsonFields


@fieldwise_init
struct Tree(Copyable, JsonFields):
    var name: String
    var kids: List[Tree]


def h(body: Json[Tree]) -> String:
    return body.value.name


def main():
    var app = App()
    app.post["/t"](h)
