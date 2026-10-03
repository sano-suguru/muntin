# Must not compile: candidate A through today's one-argument registration.
# A handler declaring only `State[S]` also satisfies production's generic
# body overload (B = State[S]); both lists have length 3 and Mojo 1.1.0
# ranks by list length only (M2-014), so the call is ambiguous. A concrete
# wrapper does not outrank a generic parameter (M3-001).
# Expected diagnostic (checked by scripts/check.sh): ambiguous call to 'post'


struct State[S: Movable & Deinitable](Movable):
    var value: Self.S

    def __init__(out self, var value: Self.S):
        self.value = value^


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


struct P:
    def __init__(out self):
        pass

    def post[
        B: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](self, h: def(var B) thin raises E -> String):
        pass

    def post[
        S: Movable & Deinitable, E: Deinitable, //, path: StaticString
    ](self, h: def(State[S]) thin raises E -> String):
        pass


def h(s: State[Db]) -> String:
    return "x"


def main():
    var p = P()
    p.post["/x"](h)
