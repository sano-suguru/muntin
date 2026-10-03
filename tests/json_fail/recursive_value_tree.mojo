# Must not compile (M3-008): Mojo 1.1.0 rejects a struct holding a list of
# itself, so a parsed document is a flat tape (`JsonValue` is a position in
# it), not a tree of values.
# Expected diagnostic (checked by scripts/check.sh): field 'items' has non-'Deinitable' type 'List[Node]'
struct Node(Copyable, Movable):
    var items: List[Node]

    def __init__(out self):
        self.items = List[Node]()


def main():
    _ = Node()
