# Must not compile: a result type that neither converts to String nor
# conforms to ToResponse. The generic overload binds its result type with a
# trait bound, so the compiler's note names the trait (M2-007).
# Expected diagnostic (checked by scripts/check.sh): argument type 'Int' does not conform to trait 'ToResponse'

from response_spike import ResponseApp


def count(id: Int) -> Int:
    return id


def main():
    var app = ResponseApp()
    app.get["/count/{id}"](count)
