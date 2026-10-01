# Must not compile: two capturing closures with the same signature have
# different types, so one List cannot hold both.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def(x: Int) -> String' to 'def(x: Int) -> String'


def wrap(h: def() thin -> String) -> String:
    def first(x: Int) {var h} -> String:
        return h()

    def second(x: Int) {var h} -> String:
        return h() + "!"

    var l = List[type_of(first)]()
    l.append(first)
    l.append(second)
    return l[0](1)


def hello() -> String:
    return "hello"


def main():
    print(wrap(hello))
