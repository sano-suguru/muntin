# Must not compile: one generic first handler parameter `I` standing for either
# `State[S]` or a per-request context built from it (the "generic injected slot"
# and "relaxed get slot" candidates). `comptime if I == State[S]` does not
# refine `I` on Mojo 1.1.0, so passing the route's handle (or a context) where
# the handler expects `I` needs `rebind`, the M3-008 4b rejection class
# (docs/history/architecture-decisions.md, "Typed header access decision
# (M3-012)"). The else branch uses `rebind` only so that the one error left is
# the if branch's: if `comptime if` starts refining `I`, this compiles;
# re-measure those candidates then.
# Expected diagnostic (checked by scripts/check.sh): value cannot be converted from 'State[S]' to 'I'

from muntin import Headers, State


struct Ctx[S: Movable & Deinitable](Movable):
    var state: State[Self.S]
    var headers: Headers

    def __init__(out self, state: State[Self.S], var headers: Headers):
        self.state = state.copy()
        self.headers = headers^


struct Users(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def call_slot[
    I: Movable, S: Movable & Deinitable, //
](
    handler: def(I, Int) thin -> String,
    state: State[S],
    var headers: Headers,
) -> String:
    comptime if I == State[S]:
        return handler(state, 1)
    else:
        return handler(rebind[I](Ctx[S](state, headers^)), 1)


def with_state(u: State[Users], id: Int) -> String:
    return String(u[].n + id)


def main():
    var u = State(Users(41))
    print(call_slot(with_state, u, Headers()))
