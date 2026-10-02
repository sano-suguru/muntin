# Must not compile: candidate 1 (M2-010), the handler function type widened
# to a bare `raises`. Non-raising and `raises` handlers convert to it
# (tests/test_spike_error.mojo), but a handler that raises an
# application-defined error type does not: a bare `raises` means error type
# `Error`, and Mojo 1.1.0 does not convert another error type to it.
# Expected diagnostic (checked by scripts/check.sh): error type of the first type is 'NotFound' but the second type is 'Error'

from error_spike import ErrorApp


@fieldwise_init
struct NotFound(Movable):
    var id: Int


def find_user(id: Int) raises NotFound -> String:
    raise NotFound(id)


def main():
    var app = ErrorApp()
    app.get_widened["/users/{id}"](find_user)
