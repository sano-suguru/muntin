# Expected diagnostic (checked by scripts/check.sh): the handler's parameter is the request body; its type must conform to FromBody or FromBytes
from muntin import App, JsonFields, FromBody, Response, ToResponse, Json


def create(body: List[String]) -> String:
    return body[0]


def main():
    var app = App()
    app.post["/x"](create)
