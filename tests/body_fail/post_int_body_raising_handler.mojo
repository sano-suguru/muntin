# Must not compile: a raising (Int, B) handler; handlers do not raise until
# the application-error model exists.
# Expected text is the compiler's note for App.post's String (Int, B)
# overload, def(Int, var B) thin -> String (M2-009); the other three post
# overloads add their own notes ('no matching method').
# Expected diagnostic (checked by scripts/check.sh): value passed to 'handler' cannot be converted from 'def h(id: Int, body: UpdateUser) raises thin -> String' to 'def(Int, var B) thin -> String'

from muntin import App, FromBody


struct UpdateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(id: Int, body: UpdateUser) raises -> String:
    return body.name


def main():
    var app = App()
    app.post["/users/{id}"](h)
