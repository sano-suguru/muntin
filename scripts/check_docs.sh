#!/usr/bin/env bash
# The documents' checks: examples (scripts/check_doc_examples.py), size
# budgets and references (scripts/check_docs.py).
# Python standard library only, with no pixi or Mojo, so that CI can run them
# on every pull request, those that change only documents included.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -I scripts/test_check_doc_examples.py
python3 -I scripts/check_doc_examples.py
python3 -I scripts/test_check_docs.py
python3 -I scripts/check_docs.py
