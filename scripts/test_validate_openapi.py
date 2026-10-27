#!/usr/bin/env python3
"""Tests scripts/validate_openapi.py's choice of operation and its check of
an answer against the document, so that a change that lets the
differential check agree with a wrong document fails here. Needs what the
validator needs (jsonschema, openapi-spec-validator); run it beside the
validator:

    python3 -I scripts/test_validate_openapi.py
"""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import validate_openapi as v  # noqa: E402

TEXT = {"description": "t", "content": {"*/*": {"schema": {"type": "string"}}}}


def exchange(status, response="", content_type="", target="/a/1"):
    return {
        "method": "GET",
        "target": target,
        "body": "",
        "json": False,
        "member": False,
        "status": status,
        "response": response,
        "content_type": content_type,
    }


def op(responses):
    return {"parameters": [], "responses": responses}


class Operation(unittest.TestCase):
    def test_a_plain_path_is_chosen_before_the_method(self):
        doc = {"paths": {"/a/{x}": {"get": op({})}, "/a/b": {"post": op({})}}}
        self.assertEqual(v.operation(doc, "GET", "/a/b"), (None, "no GET in /a/b"))
        found, values = v.operation(doc, "GET", "/a/c")
        self.assertIs(found, doc["paths"]["/a/{x}"]["get"])
        self.assertEqual(values, {"x": "c"})

    def test_two_templated_paths_are_no_choice(self):
        doc = {"paths": {"/a/b/{z}": {"get": op({})}, "/a/{x}/{z}": {"get": op({})}}}
        self.assertEqual(
            v.operation(doc, "GET", "/a/b/1"), (None, "paths /a/b/{z} and /a/{x}/{z}")
        )

    def test_a_placeholder_name_that_needs_escaping(self):
        doc = {"paths": {"/n/{note-id}": {"get": op({})}}}
        self.assertEqual(v.operation(doc, "GET", "/n/7")[1], {"note-id": "7"})


class Check(unittest.TestCase):
    def check(self, responses, ex):
        return v.check({"paths": {}}, ex, op(responses), {})

    def test_an_undescribed_success_status(self):
        responses = {"400": {"description": "bad"}}
        self.assertEqual(
            self.check(responses, exchange(200, "x")), "status 200 not described"
        )

    def test_a_described_success_status(self):
        self.assertIsNone(self.check({"200": TEXT}, exchange(200, "x")))

    def test_an_undescribed_media_type(self):
        responses = {"200": {"description": "t", "content": {"text/plain": {}}}}
        self.assertEqual(
            self.check(responses, exchange(200, "{}", "application/json")),
            "media type application/json",
        )
        self.assertIsNone(
            self.check(responses, exchange(200, "x", "text/plain; charset=utf-8"))
        )

    def test_a_text_schema(self):
        schema = {"type": "string", "minLength": 2}
        responses = {
            "200": {"description": "t", "content": {"text/*": {"schema": schema}}}
        }
        self.assertEqual(
            self.check(responses, exchange(200, "x", "text/plain")), "response schema"
        )
        self.assertIsNone(self.check(responses, exchange(200, "xy", "text/plain")))

    def test_a_json_schema(self):
        schema = {"type": "integer"}
        responses = {
            "2XX": {
                "description": "j",
                "content": {"application/json": {"schema": schema}},
            }
        }
        self.assertEqual(
            self.check(responses, exchange(201, '"a"', "application/json")),
            "response schema",
        )
        self.assertEqual(
            self.check(responses, exchange(201, "x", "application/json")),
            "response not JSON",
        )
        self.assertIsNone(self.check(responses, exchange(201, "1", "application/json")))

    def test_a_body_without_described_content(self):
        responses = {"200": {"description": "none"}}
        self.assertEqual(
            self.check(responses, exchange(200, "x")),
            "a body the document does not describe",
        )
        # The derived `default` of a `Response` result says it is not described.
        self.assertIsNone(
            self.check({"default": {"description": "n"}}, exchange(200, "x"))
        )

    def test_muntin_s_own_answers_are_not_described(self):
        self.assertIsNone(self.check({"200": TEXT}, exchange(404, "Not Found")))


class Request(unittest.TestCase):
    def check(self, content, body, status=200, json=False):
        ex = exchange(status, "ok")
        ex["body"], ex["json"] = body, json
        body_op = op({"200": TEXT})
        body_op["requestBody"] = {"required": False, "content": content}
        return v.check({"paths": {}}, ex, body_op, {})

    def test_a_text_body_schema(self):
        content = {"*/*": {"schema": {"type": "string", "minLength": 2}}}
        self.assertEqual(
            self.check(content, "x"), "refused by the document (body schema), admitted"
        )
        self.assertIsNone(self.check(content, "xy"))

    def test_a_body_media_type(self):
        content = {"application/json": {"schema": {"type": "integer"}}}
        self.assertEqual(
            self.check(content, "1"), "refused by the document (media type), admitted"
        )
        self.assertIsNone(self.check(content, "1", status=415))
        self.assertIsNone(self.check(content, "1", json=True))


class Denial(unittest.TestCase):
    DOC = {
        "paths": {},
        "security": [{"member": []}],
        "components": {
            "securitySchemes": {
                "member": {"type": "apiKey", "in": "header", "name": "X-Member"}
            }
        },
    }

    def check(self, responses, member=False, status=401):
        ex = exchange(status, "Unauthorized")
        ex["member"] = member
        return v.check(self.DOC, ex, op(responses), {})

    def test_a_denial_meets_its_described_response(self):
        def denied(schema):
            return {"401": {"description": "d", "content": {"*/*": {"schema": schema}}}}

        self.assertEqual(self.check(denied({"const": "wrong"})), "response schema")
        self.assertIsNone(self.check(denied({"const": "Unauthorized"})))
        self.assertEqual(
            self.check({"401": {"description": "d"}}),
            "a body the document does not describe",
        )
        self.assertIsNone(self.check({"200": TEXT}))

    def test_credentials_decide_the_denial(self):
        self.assertEqual(self.check({}, member=True), "denied with credentials")
        self.assertEqual(
            self.check({"200": TEXT}, status=200), "admitted without credentials"
        )


if __name__ == "__main__":
    unittest.main()
