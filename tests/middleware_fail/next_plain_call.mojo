# Must not compile (M3-034): `Next` has no non-consuming call, so the rest of
# the chain runs only through `next^.run(request)`. If `Next` gains a
# `__call__` (or `run` stops consuming), `next_called_twice.mojo` is the
# fixture that would then build; this one pins the spelling.
# Expected diagnostic (checked by scripts/check.sh): does not implement the '__call__' method
from muntin import Request, Response
from middleware_spike import Next


def plain(var request: Request, var next: Next) raises -> Response:
    return next(request^)


def main():
    pass
