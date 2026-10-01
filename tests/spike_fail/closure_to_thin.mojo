# Must not compile: a capturing closure (which could wrap any handler in one
# signature) cannot become a storable thin function value.
# Expected diagnostic (checked by scripts/check.sh): cannot implicitly convert 'def(x: Int) -> String' value to 'def(Int) thin -> String'


def wrap(h: def() thin -> String) -> def(Int) thin -> String:
    def call(x: Int) {var h} -> String:
        return h()

    return call


def hello() -> String:
    return "hello"


def main():
    print(wrap(hello)(1))
