# Must not compile: one registration method over a generic handler type `H`
# cannot hand the handler to a shared overload set that spells the function
# types (`def() thin -> R`, `def(var A) thin -> R`): Mojo 1.1.0 does not
# convert a generic `H` to a function type whose parameters it must infer. So
# each method name declares its own function-typed overloads, and a method
# cannot be one forwarding overload over shared ones
# (docs/history/architecture-decisions.md, "Registration complexity budget
# decision (M3-052)"). If this compiles, re-measure that candidate.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'H' to 'def(var A) thin -> R', it depends on an unresolved parameter 'A'


struct Registry(Movable):
    var count: Int

    def __init__(out self):
        self.count = 0

    def _route[
        R: Movable & Deinitable, //, method: StaticString, path: StaticString
    ](mut self, handler: def() thin -> R):
        self.count += 1

    def _route[
        A: Movable & Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](mut self, handler: def(var A) thin -> R):
        self.count += 1

    def get[
        H: ImplicitlyCopyable, //, path: StaticString
    ](mut self, handler: H):
        self._route["GET", path](handler)


def one(id: Int) -> String:
    return String(id)


def main():
    var registry = Registry()
    registry.get["/users/{id}"](one)
