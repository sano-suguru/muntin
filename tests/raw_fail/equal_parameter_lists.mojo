# Must not compile: the selection rule the raw overloads rested on until
# M3-015. A raw handler also satisfied the generic body overload
# (B = Request). Mojo 1.1.0 documents "shorter parameter list" as the
# deciding resolution rule; with equal lists (here [E, path] and [B, path])
# the call is ambiguous, so the raw overloads stayed strictly shorter than
# every viable body overload (M2-014). Since M3-015 `Request` is a slot kind
# and no two overloads of a method accept the same handler, so production
# no longer relies on the rule; this stays as M2-014's toolchain pin.
# Expected diagnostic (checked by scripts/check.sh): ambiguous call to 'f'

from muntin import Request, Response


struct P:
    def __init__(out self):
        pass

    def f[
        E: Deinitable, //, path: StaticString
    ](self, h: def(var Request) thin raises E -> Response):
        pass

    def f[
        B: Movable & Deinitable, //, path: StaticString
    ](self, h: def(var B) thin -> Response):
        pass


def h(req: Request) -> Response:
    return Response.text("")


def main():
    P().f["/hooks"](h)
