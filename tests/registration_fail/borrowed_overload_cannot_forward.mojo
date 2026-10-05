# Must not compile: an overload that keeps today's borrowed signature
# (`def(Int) thin raises E -> String`) cannot pass its handler to an
# adapter generic over an owned slot (`def(var A)`). So the generic-slot
# adapters cannot sit behind production's unchanged `get`/`post`
# signatures: the engine and the signature change are one step
# (docs/ARCHITECTURE.md, "Registration structure decision (M3-014)",
# candidate C5). On a scratch copy that kept the signatures and named the
# engine's adapters through `_Erased`, the same step fails as `cannot pass
# 'def(Int) raises E thin -> String' value, expected 'def(var Int) raises E
# thin -> String'`.
# Expected diagnostic (checked by scripts/check.sh): function type conversions between closures not supported yet


def adapter[
    A: Movable & Deinitable, E: Deinitable, R: Movable & Deinitable
](handler: def(var A) thin raises E -> R):
    pass


def facade[E: Deinitable, //](handler: def(Int) thin raises E -> String):
    adapter[Int, E, String](handler)


def by_id(id: Int) -> String:
    return String(id)


def main():
    facade(by_id)
