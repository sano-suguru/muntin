# Must not compile: a borrowed-parameter handler converts both to `def(B)` and
# to `def(var B)`, so offering both overloads is ambiguous on Mojo 1.1.0.
# Registration therefore offers only `def(var B)`, which also accepts
# borrowed handlers and lets the adapter move a move-only body in.
# Expected diagnostic (checked by scripts/check.sh): ambiguous call to 'register'


trait FromBody(Deinitable, Movable):
    @staticmethod
    def from_body(body: String) raises -> Self:
        ...


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def create_user(body: CreateUser) -> String:
    return body.name


def register[B: FromBody](handler: def(B) raises thin -> String):
    pass


def register[B: FromBody](handler: def(var B) raises thin -> String):
    pass


def main():
    register(create_user)
