# Must not build (M3-035): `Next.run` consumes the `Next` (`deinit self`), so
# a middleware cannot run the rest twice; the second use is the error, at its
# own line. Built against production `muntin`.
# Expected diagnostic (checked by scripts/check.sh): next_called_twice.mojo:10:16: error: use of uninitialized value 'next'
from muntin import Next, Request, Response


def twice(var request: Request, var next: Next) raises -> Response:
    _ = next^.run(request.copy())
    return next^.run(request^)


def main():
    pass
