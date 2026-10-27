# Must not compile (M3-083): a top-level `Json[List[Float32]]` body, whose
# element is no JSON kind and no struct, is refused naming the whole type.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: Json[List[SIMD[DType.float32, 1]]] cannot be read
from muntin import App, Json


def h(body: Json[List[Float32]]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
