# Must build, never run (M3-008, candidate B rejected): a trait refining
# `FromBody` that supplies the parent's `from_body` as a default compiles on
# Mojo 1.1.0, and would give DX section 4's exact `def create_user(body:
# CreateUser)`. The manual documents defaults for a trait's own methods and
# refinement inheriting requirements, not a refining trait implementing its
# parent's requirement, so B is evidence, not a basis. If this stops
# building, B is gone; if the manual documents it, re-measure B against A
# (docs/history/architecture-decisions.md, "JSON codec decision (M3-008)").
from muntin import App, FromBody
from muntin.testing import TestClient


trait BodyByDefault(FromBody):
    @staticmethod
    def from_text(text: String) raises -> Self:
        ...

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self.from_text(body)


@fieldwise_init
struct CreateUser(BodyByDefault):
    var name: String

    @staticmethod
    def from_text(text: String) raises -> Self:
        return Self(text)


def create_user(body: CreateUser) -> String:
    return body.name


def main():
    var app = App()
    app.post["/users"](create_user)
    _ = TestClient(app).post("/users", "Ada")
