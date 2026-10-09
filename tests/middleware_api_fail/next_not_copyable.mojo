# Must not build (M3-035): `Next` is not `Copyable`, so a middleware cannot
# make a second `Next` to run the rest again.
# Expected diagnostic (checked by scripts/check.sh): 'Next[next.o]' value has no attribute 'copy'
from muntin import Next, Request, Response


def keep(var request: Request, var next: Next) raises -> Response:
    var copy = next.copy()
    _ = next^.run(request.copy())
    return copy^.run(request^)


def main():
    pass
