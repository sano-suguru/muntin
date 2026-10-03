# Must not compile, and pins A2's diagnostics: a failing M2 call on the
# app lists only M2 candidates, so Mojo's ten-note cap keeps the trailing
# detail note that A1's extra candidates push out (M3-001; the A1 copy of
# this call omits it). Same handler as body_fail/post_two_bodies.mojo.
# Expected diagnostic (checked by scripts/check.sh): result type of the first type is 'String' but the second type is 'Response'
from muntin import FromBody, Request, Response
from scoped_state_spike import ScopedApp
from state_spike import State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


@fieldwise_init
struct CreateUser(FromBody, Movable):
    var name: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(a: CreateUser, b: CreateUser) -> String:
    return a.name + b.name


def main():
    var app = ScopedApp()
    app.post["/x"](h)
