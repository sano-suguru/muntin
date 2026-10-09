# Must not build (M3-035): a `Next` run inside a loop would run the rest once
# per iteration; the compiler rejects the second iteration's use. Built
# against production `muntin`.
# Expected diagnostic (checked by scripts/check.sh): next_called_in_loop.mojo:11:24: error: use of uninitialized value 'next'
from muntin import Next, Request, Response


def retry(var request: Request, var next: Next) raises -> Response:
    var response = Response.text("unused")
    for _ in range(2):
        response = next^.run(request.copy())
    return response^


def main():
    pass
