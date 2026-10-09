# Must not compile (M3-034): `Next` has no non-consuming call, so the rest of
# the chain runs only through `next^.run(request^)`. This is the only fixture
# that catches a borrowing `__call__` added to `Next`: with one,
# `next_called_twice.mojo` and `next_called_in_loop.mojo` still fail (they use
# `run`), and this one builds.
# Expected diagnostic (checked by scripts/check.sh): does not implement the '__call__' method
from muntin import Request, Response
from middleware_spike import Next


def plain(var request: Request, var next: Next) raises -> Response:
    return next(request^)


def main():
    pass
