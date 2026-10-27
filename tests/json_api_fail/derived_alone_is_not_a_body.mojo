# Must not compile (M3-083): a `JsonFields` struct is not a body by itself;
# it is a body through `Json[T]`. `post`'s `FromBody` body rule rejects the
# bare type with its message, as for a `FromJson` type
# (from_json_alone_is_not_a_body.mojo).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's parameter is the request body; its type must conform to FromBody or FromBytes
from muntin import App, JsonFields


@fieldwise_init
struct CreateUser(JsonFields):
    var name: String


def create(body: CreateUser) -> String:
    return body.name


def main():
    var app = App()
    app.post["/users"](create)
