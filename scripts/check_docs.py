#!/usr/bin/env python3
"""Checks the documents' size budgets and that their references resolve.

1. Each document read routinely stays within its size budget (BUDGETS). A
   budget is a prompt to place each fact by its reader, never a reason to
   drop a constraint, exception or safety condition: docs/DEVELOPMENT.md
   section 7 says which document owns what, and why. When a fact does belong
   where it grew, raise that budget in the same pull request and say why.
2. Every relative link in a Markdown file, inline or a reference
   definition, names a file that exists, and its #anchor a heading (ATX or
   setext) or an id="..." in that file. Lines are read through the block
   quotes and list items they belong to (Scan); code, fenced or indented,
   and HTML blocks are skipped, and a fence that never closes is an error.
   External links are not fetched.
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
    # #163 restored the stop's constraints and exceptions the reduction had
    # dropped; split the page before raising this again.
    ("docs/reference/serving.md", 35 * KB),
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


# The block structure CommonMark gives a Markdown file, as far as this check
# needs it: which lines are text and which are code, the headings, and the
# link reference definitions. Each line is read through the block quotes and
# list items still open above it, so a marker inside code, or one across a
# quote's edge, is not taken for structure.
QUOTE = re.compile(r" {0,3}> ?")
ITEM = re.compile(r"( {0,3})([-*+]|\d{1,9}[.)])( *)(.*)$")
FENCE = re.compile(r" {0,3}(`{3,}(?=[^`]*$)|~{3,})")
ATX = re.compile(r" {0,3}#{1,6}(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$")
SETEXT = re.compile(r" {0,3}(?:=+|-+)[ \t]*$")
BREAK = re.compile(r" {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$")
# CommonMark's kinds of HTML block, in order: how each starts, the text that
# ends it (None: a blank line), and whether it may interrupt a paragraph. An
# autolink such as <https://example.com>, or a tag with text after it on its
# line, starts none of them and stays text.
BLOCK_TAGS = (
    "address|article|aside|base|basefont|blockquote|body|caption|center|col|"
    "colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|"
    "footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|"
    "link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|"
    "section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul"
)
ATTRIBUTE = r"""\s+[A-Za-z_:][\w.:-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?"""
HTML_BLOCKS = [
    (r"<(?:pre|script|style|textarea)(?:[ \t>]|$)", r"</(?:pre|script|style|textarea)>", True),
    (r"<!--", r"-->", True),
    (r"<\?", r"\?>", True),
    (r"<![A-Za-z]", r">", True),
    (r"<!\[CDATA\[", r"\]\]>", True),
    (r"</?(?:%s)(?:[ \t>]|/>|$)" % BLOCK_TAGS, None, True),
    (r"(?:<[A-Za-z][A-Za-z0-9-]*(?:%s)*\s*/?>|</[A-Za-z][A-Za-z0-9-]*\s*>)[ \t]*$"
     % ATTRIBUTE, None, False),
]
HTML_BLOCKS = [(re.compile(r" {0,3}" + start, re.I), end and re.compile(end, re.I), interrupts)
               for start, end, interrupts in HTML_BLOCKS]


def html_block(rest, in_paragraph):
    """The end pattern of the HTML block that rest starts (None: a blank
    line ends it), or False when rest starts none."""
    for start, end, interrupts in HTML_BLOCKS:
        if start.match(rest) and (interrupts or not in_paragraph):
            return end
    return False


# "[label]: destination", the destination on this line or the next; a
# "[^1]:" is a footnote, not a link.
REFERENCE = re.compile(r" {0,3}\[(?!\^)(?:[^\]\\]|\\.)+\]:[ \t]*(?:<([^>]*)>|(\S+))?")


def item_width(rest):
    """The content indent of the list item that rest starts, or 0."""
    m = ITEM.match(rest)
    if not m or BREAK.match(rest):
        return 0
    spaces = len(m.group(3))
    if not m.group(4):
        spaces = 1
    elif spaces == 0:
        return 0
    elif spaces > 4:
        spaces = 1  # the item starts with indented code
    return len(m.group(1)) + len(m.group(2)) + spaces


def starts_block(rest):
    return bool(QUOTE.match(rest) or item_width(rest) or FENCE.match(rest)
                or ATX.match(rest) or BREAK.match(rest)
                or html_block(rest, True) is not False)


class Scan:
    """A Markdown file's text lines (number, text without its quote and list
    markers), outside code and HTML blocks; its HTML block lines; its
    headings in order; its link reference definitions (number, destination);
    and the line of a fence that never closes, or None."""

    def __init__(self, text):
        self.prose, self.html, self.headings, self.references = [], [], [], []
        self.unclosed = None
        stack = []  # open containers: ">" or a list item's content indent
        fence = None  # the open fence's text, and its line
        leaf = None  # the open leaf block: "paragraph", "table" or "html"
        paragraph = []
        definition = None  # a "[label]:" line still waiting for its destination
        html_end = None  # what ends the open HTML block; None: a blank line
        for n, raw in enumerate(text.split("\n"), 1):
            rest, matched = raw.expandtabs(4), 0
            for c in stack:
                if c == ">":
                    m = QUOTE.match(rest)
                    if not m:
                        break
                    rest = rest[m.end():]
                elif not rest.strip():
                    rest = ""
                elif len(rest) - len(rest.lstrip(" ")) >= c:
                    rest = rest[c:]
                else:
                    break
                matched += 1
            if fence:
                if matched == len(stack):
                    close = r" {0,3}%s{%d,}[ \t]*$" % (re.escape(fence[0]), len(fence))
                    if re.match(close, rest):
                        fence = None
                    continue
                fence = None  # its container ended, and the code with it
            if matched < len(stack):
                if leaf == "paragraph" and rest.strip() and not starts_block(rest):
                    paragraph.append(rest.strip())  # a lazy continuation line
                    self.prose.append((n, rest))
                    continue
                del stack[matched:]
                leaf, definition = None, None
            opened = False
            while not BREAK.match(rest):
                m = QUOTE.match(rest)
                if m:
                    stack.append(">")
                    rest = rest[m.end():]
                elif item_width(rest):
                    width = item_width(rest)
                    stack.append(width)
                    rest = rest[width:]
                else:
                    break
                opened = True
            if opened:
                leaf, definition = None, None
            if leaf == "html" and (html_end or rest.strip()):
                self.html.append((n, rest))
                if html_end and html_end.search(rest):
                    leaf = None
                continue
            if not rest.strip():
                leaf, definition = None, None
                continue
            if definition:
                self.references.append((n, rest.split()[0].strip("<>")))
                definition = None
                continue
            if leaf != "paragraph" and rest.startswith("    "):
                continue  # indented code
            m = FENCE.match(rest)
            if m:
                fence, self.unclosed, leaf = m.group(1), n, None
                continue
            m = ATX.match(rest)
            if m:
                self.headings.append(m.group(1) or "")
                self.prose.append((n, rest))
                leaf = None
                continue
            if leaf == "paragraph" and SETEXT.match(rest):
                self.headings.append(" ".join(paragraph))
                leaf = None
                continue
            if BREAK.match(rest):
                leaf = None
                continue
            end = html_block(rest, leaf is not None)
            if end is not False:
                # Its own first line may already hold its end.
                html_end, leaf = end, None if end and end.search(rest) else "html"
                self.html.append((n, rest))
                continue
            m = REFERENCE.match(rest)
            if m and leaf != "table":
                # Checked even where CommonMark would read it as the text of
                # the paragraph above: a broken one is never a sound link.
                destination = m.group(1) or m.group(2)
                if destination:
                    self.references.append((n, destination))
                else:
                    definition = n
                leaf = None
                continue
            if leaf is None:
                leaf = "table" if rest.lstrip().startswith("|") else "paragraph"
                paragraph = []
            paragraph.append(rest.strip())
            self.prose.append((n, rest))
        if not fence:
            self.unclosed = None


def slug(heading):
    """GitHub's anchor for a heading's text."""
    text = CODE_SPAN.sub(lambda m: m.group(2), heading)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    return re.sub(r"[^\w\- ]", "", text.lower()).replace(" ", "-")


ANCHORS = {}


def anchors(path):
    if path not in ANCHORS:
        scan = Scan(path.read_text())
        found, seen = set(), {}
        for _, line in scan.prose + scan.html:
            found.update(ID_ATTR.findall(line))
        for heading in scan.headings:
            s = slug(heading)
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


def check_target(errors, path, where, target):
    if re.match(r"[a-z][a-z0-9+.-]*:", target):
        return  # https:, mailto:, ...
    file, _, anchor = target.partition("#")
    dest = (path.parent / file).resolve() if file else path
    if not dest.exists():
        errors.append(f"{where}: {target}: no such file")
    elif anchor and dest.suffix == ".md" and anchor not in anchors(dest):
        errors.append(f"{where}: {target}: no heading or id \"{anchor}\" "
                      f"in {dest.relative_to(ROOT)}")


def check_links(errors):
    for path in files({".md"}):
        rel = path.relative_to(ROOT)
        scan = Scan(path.read_text())
        if scan.unclosed:
            errors.append(f"{rel}:{scan.unclosed}: this fence has no closing "
                          f"fence, so nothing after it is checked")
        for n, target in scan.references:
            check_target(errors, path, f"{rel}:{n}", target)
        for n, line in scan.prose:
            for m in LINK.finditer(CODE_SPAN.sub("", line)):
                check_target(errors, path, f"{rel}:{n}", m.group(1))


def check_paths(errors):
    current = sorted({p for g in CURRENT_DOCS for p in ROOT.glob(g)})
    for path in current:
        rel = path.relative_to(ROOT)
        for n, line in Scan(path.read_text()).prose:
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
