# Must not compile (M3-083): a carried top-level `Json[List[Float32]]` body
# is refused at the registration with the bare body's text, with state
# and a route value.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: Json[List[SIMD[DType.float32, 1]]] cannot be read
from muntin import App, Json, State, WithHeaders


def h(
    s: State[String], id: Int, input: WithHeaders[Json[List[Float32]]]
) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c/{id}"](h, State(String("s")))
