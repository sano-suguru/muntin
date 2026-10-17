#!/usr/bin/env python3
"""Checks the documents' size budgets and that their references resolve.

1. Each document read routinely stays within its size budget (BUDGETS). A
   budget is a prompt to place each fact by its reader, never a reason to
   drop a constraint, exception or safety condition: docs/DEVELOPMENT.md
   section 7 says which document owns what, and why. When a fact does belong
   where it grew, raise that budget in the same pull request and say why.
2. Every relative link in a Markdown file names a file that exists, and its
   #anchor a heading or an id="..." in that file. External links are not
   fetched.
3. Every repository path in backticks in the current documents (not
   docs/history/, which may cite removed files), and every docs/....md path
   named in a code, script or CI file, exists; a checker's own test
   (scripts/test_check_*.py) is skipped, since its fixtures name documents
   of a scratch repository.

Standard library only: python3 -I scripts/check_docs.py [ROOT], where ROOT
(the repository by default) is for scripts/test_check_docs.py.
"""

import os
import pathlib
import re
import sys

ROOT = (
    pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1
    else pathlib.Path(__file__).resolve().parent.parent
)
KB = 1024

# Size budgets in bytes; the first pattern a file matches applies. A
# document already over the target its reader needs has a ceiling near its
# size when this check landed, so it does not grow unnoticed; the target is
# in its comment.
BUDGETS = [
    ("README.md", 10 * KB),
    ("AGENTS.md", 6 * KB),
    ("docs/GUIDE.md", 20 * KB),
    ("docs/reference/*.md", 28 * KB),  # past this, split the topic
    ("docs/ARCHITECTURE.md", 50 * KB),  # target 20 KB
    ("docs/DEVELOPMENT.md", 20 * KB),  # target 10 KB
    ("docs/SPEC.md", 14 * KB),  # target 10 KB
    ("docs/REFERENCES.md", 3 * KB),
    # A record is 1-3 KB (docs/DEVELOPMENT.md section 2); the rest is room
    # for its opening lines, which grow as later records change it.
    ("docs/history/decisions/*.md", 4 * KB),
]

# The records written before this check, which stay as they are
# (docs/DEVELOPMENT.md section 2). Nothing is added here.
EXEMPT_RECORDS = set("""
local-flare-run-decision
m0-implemented-layout
m1-002-flare-adapter
m1-003-real-localhost-round-trip
m2-001-routing-and-handler-storage
m2-002-request-target-boundary-and-query-extraction
m2-004-production-implementation
m2-005-argument-extraction-decision
m2-006-body-only-post
m2-007-typed-response-decision
m2-008-typed-results-in-production
m2-009-route-value-then-body-in-production
m2-010-application-error-decision
m2-011-raising-handlers-in-production
m2-012-error-response-decision
m2-013-application-defined-error-responses-in-production
m2-014-raw-request-decision
m2-015-raw-request-handlers-in-production
m2-016-m2-closure
m2-handler-storage-decision
m3-001-application-state-decision
m3-002-headers-decision
m3-004-state-storage-decision
m3-005-headers-in-production
m3-006-stateful-post-in-production
m3-007-stateful-raw-handlers-in-production
m3-008-json-codec-decision
m3-009-json-in-production
m3-010-testclient-request-headers-decision
m3-011-testclient-request-headers-in-production
m3-012-typed-header-access-decision
m3-013-typed-header-access-in-production
m3-014-registration-structure-decision
m3-015-registration-on-generic-arity-slots-in-production
m3-015-registration-structure-amendment-generic-forwarding
m3-016-typed-get-header-access-decision
m3-018-route-value-decoding-and-string-route-values-decision
m3-020-http-methods-decision
m3-022-several-route-values-decision
m3-024-optional-query-values-decision
m3-026-head-decision
m3-028-json-response-status-decision
m3-030-method-not-allowed-decision
m3-032-serving-entrypoint-decision
m3-034-middleware-decision
m3-036-testclient-head-decision
m3-038-request-body-bytes-decision
m3-039-request-target-and-method-bytes-decision
m3-040-binary-request-and-response-bodies-decision
m3-041-typed-binary-request-bodies-decision
m3-042-typed-binary-request-bodies-with-header-fields-decision
m3-043-typed-binary-request-body-size-limits-decision
m3-044-server-receive-body-limit-decision
m3-045-graceful-shutdown-decision
m3-046-head-of-line-blocking-decision
m3-047-server-idle-timeout-decision
m3-048-bodyless-typed-post-put-and-patch-handlers-decision
m3-049-multi-worker-serving-decision
m3-050-named-route-values-decision
m3-051-server-tls-decision
m3-052-registration-complexity-budget-decision
m3-053-route-conflict-decision
m3-054-application-route-value-types-decision
m3-056-streaming-responses-and-cancellation-decision
m3-058-dropped-error-report-decision
m3-059-dropped-error-report-amendment
m3-060-tls-with-workers-decision
m3-061-route-value-records-decision
m3-063-request-context-decision
m3-065-request-context-storage-decision
m3-066-request-header-conversion-decision
m3-068-worker-connection-spread-decision
m3-070-backend-coupling-decision
m3-071-handler-execution-model-decision
m3-073-request-host-decision
m3-074-state-borrowing-decision
production-verification-policy-decision
""".split())

CURRENT_DOCS = ["README.md", "AGENTS.md", "docs/*.md", "docs/reference/*.md"]
CODE_SUFFIXES = {".mojo", ".py", ".sh", ".yml", ".yaml", ".toml"}

FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^#{1,6}\s+(.*?)(?:\s+#+)?\s*$")
LINK = re.compile(r"\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
CODE_SPAN = re.compile(r"(`+)(.+?)\1")
ID_ATTR = re.compile(r"""\bid=["']([^"']+)["']""")
PATH_SPAN = re.compile(
    r"^(?:src|tests|scripts|adapters|bench|examples|compat|docs|\.github)/[\w./-]*$"
)
DOCS_PATH = re.compile(r"\bdocs/[\w./-]*\w\.md\b")


def files(suffixes):
    """The repository's files with these suffixes, outside build/ and
    hidden directories other than .github/."""
    for top, dirs, names in os.walk(ROOT):
        dirs[:] = sorted(d for d in dirs if d == ".github"
                         or d != "build" and not d.startswith("."))
        for name in sorted(names):
            if pathlib.Path(name).suffix in suffixes:
                yield pathlib.Path(top) / name


def prose(text):
    """Yields (line number, line) for the lines outside fenced code."""
    fenced = False
    for n, line in enumerate(text.split("\n"), 1):
        if FENCE.match(line):
            fenced = not fenced
        elif not fenced:
            yield n, line


def slug(heading):
    """GitHub's anchor for a heading's text."""
    text = CODE_SPAN.sub(lambda m: m.group(2), heading)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    return re.sub(r"[^\w\- ]", "", text.lower()).replace(" ", "-")


ANCHORS = {}


def anchors(path):
    if path not in ANCHORS:
        found, seen = set(), {}
        for _, line in prose(path.read_text()):
            found.update(ID_ATTR.findall(line))
            m = HEADING.match(line)
            if m:
                s = slug(m.group(1))
                n = seen.get(s, 0)
                seen[s] = n + 1
                found.add(s if n == 0 else f"{s}-{n}")
        ANCHORS[path] = found
    return ANCHORS[path]


def check_budgets(errors):
    over = False
    done = set()
    for pattern, budget in BUDGETS:
        for p in sorted(ROOT.glob(pattern)):
            if p in done:
                continue
            done.add(p)
            rel = p.relative_to(ROOT)
            if rel.parent.name == "decisions" and rel.stem in EXEMPT_RECORDS:
                continue
            size = p.stat().st_size
            if size > budget:
                over = True
                errors.append(f"{rel}: {size} bytes, over its budget of {budget}")
    if over:
        errors.append(
            "a document grew past its budget. Check each new fact against "
            "docs/DEVELOPMENT.md section 7, which names each document's "
            "reader and what goes there (AGENTS.md, \"Before writing\", sums "
            "it up), and move what belongs elsewhere. Never cut a "
            "constraint, exception or safety condition to fit: if the facts "
            "belong here, raise the budget in scripts/check_docs.py in this "
            "pull request and say why there."
        )


def check_links(errors):
    for path in files({".md"}):
        rel = path.relative_to(ROOT)
        for n, line in prose(path.read_text()):
            for m in LINK.finditer(CODE_SPAN.sub("", line)):
                target = m.group(1)
                if re.match(r"[a-z][a-z0-9+.-]*:", target):
                    continue  # https:, mailto:, ...
                file, _, anchor = target.partition("#")
                dest = (path.parent / file).resolve() if file else path
                if not dest.exists():
                    errors.append(f"{rel}:{n}: {target}: no such file")
                elif anchor and dest.suffix == ".md" and anchor not in anchors(dest):
                    errors.append(f"{rel}:{n}: {target}: no heading or id "
                                  f"\"{anchor}\" in {dest.relative_to(ROOT)}")


def check_paths(errors):
    current = sorted({p for g in CURRENT_DOCS for p in ROOT.glob(g)})
    for path in current:
        rel = path.relative_to(ROOT)
        for n, line in prose(path.read_text()):
            for m in CODE_SPAN.finditer(line):
                span = m.group(2).strip()
                if PATH_SPAN.match(span) and not (ROOT / span).exists():
                    errors.append(f"{rel}:{n}: `{span}`: no such file")
    for path in files(CODE_SUFFIXES):
        rel = path.relative_to(ROOT)
        if rel.name.startswith("test_check_"):
            continue  # its fixtures name documents of a scratch repository
        for n, line in enumerate(path.read_text().split("\n"), 1):
            for m in DOCS_PATH.finditer(line):
                if not (ROOT / m.group(0)).exists():
                    errors.append(f"{rel}:{n}: {m.group(0)}: no such file")


def main():
    errors = []
    check_budgets(errors)
    check_links(errors)
    check_paths(errors)
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    if errors:
        sys.exit(1)
    print("ok")


main()
