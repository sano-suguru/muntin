# Must not compile: application code outside Muntin making two routes share
# one handler box. The handle is a move-only `ThinAllocation`.
# Expected diagnostic (checked by scripts/check.sh): value of type 'ThinAllocation[_Header]' cannot be implicitly copied, it does not conform to 'ImplicitlyCopyable'

from muntin import App


def hello() -> String:
    return "hello"


def main():
    var a = App()
    var b = App()
    a.get["/hello"](hello)
    b.get["/hello"](hello)
    a._routes[0].handler._header = b._routes[0].handler._header
