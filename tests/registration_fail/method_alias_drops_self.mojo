# Must not compile: a method name defined once as a comptime member that binds
# the HTTP method of a shared registration method
# (`comptime get = Self.route["GET", ...]`) is not a method: `registry.get[path](h)`
# does not pass `registry` as `self`. It works only as an unbound call,
# `Registry.get[path](registry, h)`, which is not Muntin's spelling. So the
# per-method overload sets cannot be collapsed into one set behind aliases
# (docs/history/architecture-decisions.md, "Registration complexity budget
# decision (M3-052)"). If this compiles, re-measure that candidate.
# Expected diagnostic (checked by scripts/check.sh): invalid indirect call: missing required argument: 'handler'


struct Registry(Movable):
    var count: Int

    def __init__(out self):
        self.count = 0

    def route[
        A: Movable & Deinitable,
        R: Movable & Deinitable,
        //,
        method: StaticString,
        path: StaticString,
    ](mut self, handler: def(var A) thin -> R):
        self.count += 1

    comptime get = Self.route["GET", ...]


def one(id: Int) -> String:
    return String(id)


def main():
    var registry = Registry()
    registry.get["/users/{id}"](one)
