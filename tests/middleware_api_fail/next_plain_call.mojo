# Must not build (M3-035): `Next` has no non-consuming call, so the rest runs
# only through `next^.run(request^)`. The only fixture that catches a
# borrowing `__call__` added to `Next`: with one, `next_called_twice.mojo` and
# `next_called_in_loop.mojo` still fail (they use `run`), and this one builds.
# Expected diagnostic (checked by scripts/check.sh): 'Next[next.o]' does not implement the '__call__' method
from muntin import Next, Request, Response


def plain(var request: Request, var next: Next) raises -> Response:
    return next(request^)


def main():
    pass
