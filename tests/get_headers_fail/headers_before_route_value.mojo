# Must not compile: on the M3-016 spike, a `Headers` slot is the last
# parameter, after the route value, never before it (positional binding:
# its raw index is its position, since only route values precede it). The
# inverse, `def(id: Int, headers: Headers)`, registers
# (tests/test_spike_get_headers.mojo). Decision: docs/ARCHITECTURE.md,
# "Typed get header access decision (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes one Headers, as its last parameter
from muntin import App, Headers

from get_headers_spike import get


def h(headers: Headers, id: Int) -> String:
    return "x"


def main():
    var app = App()
    get["/x/{id}"](app, h)
