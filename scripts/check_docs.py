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
4. Every section cited by name or number exists: a Markdown file's path or
   a link to it, then a quoted heading or "section N" in the same block
   (CITATION), in every Markdown file but the older decision records in
   UNCHECKED_CITATIONS and in every code, script or CI file. A block is a
   paragraph, heading or table row of a document, its inline Markdown read
   as CommonMark reads it; in Python and Mojo, a run of comments in one
   column, or a string read as the value Python makes of it (adjacent
   literals joined, escapes decoded); elsewhere, a run of comment lines or
   a line (blocks). A quote right after a path is read as a heading, so
   quote other text elsewhere in the sentence.

Standard library only: python3 -I scripts/check_docs.py [ROOT], where ROOT
(the repository by default) is for scripts/test_check_docs.py.
"""

import ast
import io
import os
import pathlib
import re
import string
import sys
import tokenize
import warnings

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
    # M3-081 added the guarded groups' structure, transport and box when the
    # page was 0.2 KB under 50 KB, M3-088 its JSON sentence and revisit row
    # 90 bytes under 52 KB, and M3-092 the OpenAPI module, invariant and
    # revisit row 154 bytes under 53 KB, after M3-090; trim the page before
    # raising this again.
    ("docs/ARCHITECTURE.md", 54 * KB),  # target 20 KB
    # #169 added the load benchmark and its client's check when the page was
    # 7 bytes under 20 KB, and #176 the JSON float oracle and benchmark; trim
    # the page before raising this again.
    ("docs/DEVELOPMENT.md", 21 * KB),  # target 10 KB
    # M3-096 named its slice in the remaining candidates 45 bytes past
    # 14 KB, after M3-094 had filled it; trim the page before raising this
    # again.
    ("docs/SPEC.md", 15 * KB),  # target 10 KB
    ("docs/REFERENCES.md", 3 * KB),
    # M3-082's body was 4,082 bytes when it merged (#187), leaving no room
    # for the opening lines of the records that change it, M3-084 first.
    ("docs/history/decisions/m3-082-derived-json-codecs-decision.md", 5 * KB),
    # M3-091 was 4,087 bytes when it merged (#202), leaving no room
    # for the opening lines of its slice's amendment, M3-092.
    ("docs/history/decisions/m3-091-openapi-output-decision.md", 5 * KB),
    # M3-084 was 4,083 bytes when it merged (#190), leaving no room for the
    # opening line that names where its behavior is now described (M3-085).
    ("docs/history/decisions/m3-084-request-rejection-report-decision.md", 5 * KB),
    # M3-094 is 4,339 bytes (#207): the owner's review asked it to state its
    # rule for a declared type's parameters and the subtype's length limit,
    # both part of the slice's contract.
    ("docs/history/decisions/m3-094-json-media-types-decision.md", 5 * KB),
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
REFERENCE = re.compile(r" {0,3}\[(?!\^)((?:[^\]\\]|\\.)+)\]:[ \t]*(?:<([^>]*)>|(\S+))?")


def label_key(label):
    """A link label as CommonMark matches it: case and spacing ignored."""
    return " ".join(label.split()).casefold()


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
    its text lines again, grouped by the block (paragraph, heading or table
    row) each belongs to; the destination of each definition's label;
    and the line of a fence that never closes, or None."""

    def __init__(self, text):
        self.prose, self.html, self.headings, self.references = [], [], [], []
        self.blocks, self.labels = [], {}
        self.unclosed = None
        stack = []  # open containers: ">" or a list item's content indent
        fence = None  # the open fence's text, and its line
        leaf = None  # the open leaf block: "paragraph", "table" or "html"
        paragraph = []
        definition = None  # a "[label]:" line's label, waiting for its destination
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
                    self.blocks[-1].append((n, rest))
                    continue
                del stack[matched:]
                leaf, definition = None, None
            if leaf == "html" and (html_end or rest.strip()):
                # Like code, an HTML block holds text, not Markdown: nothing
                # in it opens a block quote or list item before its end.
                self.html.append((n, rest))
                if html_end and html_end.search(rest):
                    leaf = None
                continue
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
            if not rest.strip():
                leaf, definition = None, None
                continue
            if definition:
                destination = rest.split()[0].strip("<>")
                self.references.append((n, destination))
                self.labels.setdefault(definition, destination)
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
                self.blocks.append([(n, rest)])
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
                label, destination = label_key(m.group(1)), m.group(2) or m.group(3)
                if destination:
                    self.references.append((n, destination))
                    self.labels.setdefault(label, destination)
                else:
                    definition = label
                leaf = None
                continue
            if leaf is None:
                leaf = "table" if rest.lstrip().startswith("|") else "paragraph"
                paragraph = []
            if leaf == "table" or not paragraph:
                self.blocks.append([])  # a new paragraph, or a table's row
            paragraph.append(rest.strip())
            self.prose.append((n, rest))
            self.blocks[-1].append((n, rest))
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
            "reader and what goes there (AGENTS.md, \"Where to look\", sums "
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


# A section citation: a Markdown file, named by its path (in backticks or
# not) or by a link to it, followed by a quoted heading (`, "Heading"`,
# ` ("Heading"` or ` "Heading"`, starting on that line or the next and over
# at most two lines) or by `section 7` (`sections 6 and 7`), all in one
# block (blocks). It is read in plain text (plain), the same for a document,
# a comment and a string.
SEP = r"[ \t]*\n?[ \t]*"  # spaces, and at most one line break
CITATION = re.compile(
    r"(?<![\w./-])([\w./-]+\.md)(?:#[\w-]*)?(?=[,\s(])"
    rf",?{SEP}(?:\(?\"([^\"\s][^\"\n]*(?:\n[^\"\n]*)?)\""
    rf"|sections?{SEP}(\d+(?:(?:,|,?{SEP}(?:and|or)){SEP}\d+)*))"
)
# A URL, with a scheme or scheme-relative ("//host/path").
URL = re.compile(r"\b[A-Za-z][\w+.-]*://[^\s<>\"'`]*|(?<![\w./:-])//[^\s<>\"'`]*")
PUNCTUATION = set(string.punctuation)  # what a backslash escapes
NUMBERED = re.compile(r"(\d+)\.\s+(.*)")
# Records written before this check whose citations name headings their
# documents had then, which docs/history/architecture-decisions.md maps to
# today's, or quote text that is not a heading right after a path. Their
# bodies are not rewritten (docs/DEVELOPMENT.md section 2), so they are not
# read for citations. Nothing is added here: a new record is checked.
UNCHECKED_CITATIONS = set("""
m3-001-application-state-decision
m3-004-state-storage-decision
m3-016-typed-get-header-access-decision
m3-018-route-value-decoding-and-string-route-values-decision
m3-020-http-methods-decision
m3-026-head-decision
m3-028-json-response-status-decision
m3-030-method-not-allowed-decision
m3-032-serving-entrypoint-decision
m3-036-testclient-head-decision
m3-038-request-body-bytes-decision
m3-039-request-target-and-method-bytes-decision
m3-044-server-receive-body-limit-decision
m3-045-graceful-shutdown-decision
m3-046-head-of-line-blocking-decision
m3-047-server-idle-timeout-decision
m3-048-bodyless-typed-post-put-and-patch-handlers-decision
m3-049-multi-worker-serving-decision
m3-051-server-tls-decision
m3-056-streaming-responses-and-cancellation-decision
m3-058-dropped-error-report-decision
m3-059-dropped-error-report-amendment
m3-060-tls-with-workers-decision
m3-063-request-context-decision
m3-066-request-header-conversion-decision
m3-068-worker-connection-spread-decision
m3-070-backend-coupling-decision
m3-071-handler-execution-model-decision
m3-073-request-host-decision
m3-074-state-borrowing-decision
""".split())

SECTIONS = {}


def code_span(line, i):
    """Where the code span opening at line[i] ends, and its content; or the
    end of the unmatched backtick run, and None."""
    run = len(line) - i - len(line[i:].lstrip("`"))
    j = i + run
    while True:
        j = line.find("`" * run, j)
        if j < 0:
            return i + run, None
        end = len(line) - len(line[j:].lstrip("`"))
        if end - j == run:
            return end, line[i + run:j]
        j = end


def link_text_end(line, i):
    """Where the bracket opening at line[i] closes (brackets nested to any
    depth, escapes and code spans skipped), or None."""
    depth, j = 0, i
    while j < len(line):
        c = line[j]
        if c == "\\" and line[j + 1:j + 2] in PUNCTUATION:
            j += 2
            continue
        if c == "`":
            j = code_span(line, j)[0]
            continue
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return None


# After a link's text: "(dest)", "(<dest>)", either with a title in "", ''
# or (); and "[label]" or "[]".
INLINE = re.compile(
    r"\(\s*(?:<([^<>\n]*)>|((?:[^\s()\\]|\\.|\((?:[^\s()\\]|\\.)*\))+))?"
    r"(?:\s+(?:\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|\((?:[^()\\]|\\.)*\)))?\s*\)")
LABEL = re.compile(r"\[((?:[^\[\]\\]|\\.)*)\]")


def link(line, i, labels):
    """The destination and end of the link whose text opens at line[i], as
    CommonMark reads it: inline ("[text](dest "title")"), full or collapsed
    reference ("[text][label]", "[text][]") or shortcut ("[label]"); or
    None, also when its text holds a link, since no link holds another."""
    close = link_text_end(line, i)
    if close is None:
        return None
    text = label_key(line[i + 1:close])
    m = INLINE.match(line, close + 1)
    if m:
        found = m.group(1) or m.group(2) or "", m.end()
    elif (m := LABEL.match(line, close + 1)) and (label_key(m.group(1)) or text) in labels:
        found = labels[label_key(m.group(1)) or text], m.end()
    elif text in labels:
        found = labels[text], close + 1
    else:
        return None
    return None if holds_link(line[i + 1:close], labels) else found


def holds_link(text, labels):
    """Whether text holds a link; an image ("![alt](src)", "![alt][label]")
    is none."""
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\" and text[i + 1:i + 2] in PUNCTUATION:
            i += 2
        elif c == "`":
            i = code_span(text, i)[0]
        elif c == "!" and text[i + 1:i + 2] == "[":
            image = link(text, i + 1, labels)  # its label is no link
            i = image[1] if image else i + 1
        elif c == "[" and link(text, i, labels):
            return True
        else:
            i += 1
    return False


def plain(line, labels):
    """A line as CITATION reads it, its inline Markdown read left to right as
    CommonMark does: an escaped character (\\[) is that character and no
    syntax; a code span is its content, backticks dropped; a link is its
    destination (a reference's looked up in labels), its text and title
    dropped; and each URL is a word that is no path. So a path, a path in
    backticks and a link name a file alike, and a URL never names one. Each
    line is read alone: a link or code span broken across lines is text."""
    out, i = [], 0
    while i < len(line):
        c = line[i]
        if c == "\\" and line[i + 1:i + 2] in PUNCTUATION:
            out.append(line[i + 1])
            i += 2
        elif c == "`":
            i, content = code_span(line, i)
            out.append(content or "")
        elif c == "[" and (found := link(line, i, labels)):
            out.append(found[0])
            i = found[1]
        else:
            out.append(c)
            i += 1
    return URL.sub("URL", "".join(out))


def line_blocks(text):
    """The blocks of a file read line by line: each run of comment lines
    ("#" first) up to an empty or blank one, and each other line."""
    found, comment = [], False
    for n, line in enumerate(text.split("\n"), 1):
        line = line.strip()
        now = line.startswith("#")
        line = plain(line.lstrip("#").replace('\\"', '"').strip(), {})
        if not line:
            comment = False
            continue
        if not (now and comment):
            found.append([])
        found[-1].append((n, line))
        comment = now
    return found


FSTRING_START, FSTRING_END = (getattr(tokenize, name, None)
                              for name in ("FSTRING_START", "FSTRING_END"))


def string_value(source):
    """The string Python makes of source, one or more adjacent literals:
    joined, escapes decoded, and an f-string's fields each "{}"; or, if
    Python cannot read it (as a Mojo literal it does not know), the
    source."""
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")  # an invalid escape is no error here
            node = ast.parse("(" + source + "\n)", mode="eval").body
    except SyntaxError:
        node = None
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.Constant) and isinstance(node.value, bytes):
        return node.value.decode("latin-1")
    if isinstance(node, ast.JoinedStr):
        return "".join(part.value if isinstance(part, ast.Constant) else "{}"
                       for part in node.values)
    return source


def token_blocks(text):
    """The blocks of a Python or Mojo file read by tokenize: each run of
    comments on consecutive lines in one column (so in one scope), up to an
    empty one; and each string, as the value Python makes of it (adjacent
    literals joined, as "a" "b" is "ab": string_value), up to a blank line,
    each line numbered from the string's first. Code is not read."""
    offsets = [0]
    for line in text.splitlines(keepends=True):
        offsets.append(offsets[-1] + len(line))
    found = []
    comment = None  # the run a comment may continue: (row, column, block)
    string = None  # where the adjacent literals start and end, as (row, column)
    depth = 0  # how many f-strings the token is in

    def read(string):
        (row, column), (end_row, end_column) = string
        value = string_value(text[offsets[row - 1] + column:offsets[end_row - 1] + end_column])
        found.append([])
        for k, line in enumerate(value.split("\n")):
            line = plain(line.strip(), {})
            if line:
                found[-1].append((row + k, line))
            else:
                found.append([])

    for token in tokenize.generate_tokens(io.StringIO(text).readline):
        kind, (row, column), literal = token.type, token.start, None
        if kind == FSTRING_START:
            depth += 1
            begin = token.start if depth == 1 else begin
        elif kind == FSTRING_END:
            depth -= 1
            literal = None if depth else (begin, token.end)
        elif depth:
            pass
        elif kind == tokenize.STRING:
            literal = token.start, token.end
        elif kind == tokenize.COMMENT:
            line = plain(token.string.lstrip("#").replace('\\"', '"').strip(), {})
            if line and comment and comment[:2] == (row - 1, column):
                comment[2].append((row, line))
                comment = row, column, comment[2]
            elif line:
                found.append([(row, line)])
                comment = row, column, found[-1]
        elif kind != tokenize.NL and string:  # ENDMARKER ends the last
            read(string)  # only line breaks and comments may stand between
            string = None
        if literal:
            string = (string[0] if string else literal[0]), literal[1]
    return [block for block in found if block]


def blocks(path):
    """The blocks a citation may not cross, each a list of (number, text):
    in a Markdown file, each paragraph, heading or table row (Scan); in a
    Python or Mojo file, its comments and strings (token_blocks), or line by
    line if it does not tokenize; in any other code file, line by line
    (line_blocks); with \\" read as " in code."""
    text = path.read_text()
    if path.suffix == ".md":
        scan = Scan(text)
        return [[(n, plain(line, scan.labels).strip()) for n, line in block]
                for block in scan.blocks]
    if path.suffix in (".py", ".mojo"):
        try:
            return token_blocks(text)
        except (tokenize.TokenError, SyntaxError):
            pass
    return line_blocks(text)


def sections(path):
    """What a citation may name in a Markdown file: the anchor of each
    heading or id, as a link's #anchor may, also the anchor of a numbered
    heading's name ("Where information lives" for "7. Where information
    lives"); and the numbers of its numbered headings."""
    if path not in SECTIONS:
        names, numbers = set(anchors(path)), set()
        for heading in Scan(path.read_text()).headings:
            m = NUMBERED.fullmatch(heading.strip())
            if m:
                numbers.add(m.group(1))
                names.add(slug(m.group(2)))
        SECTIONS[path] = names, numbers
    return SECTIONS[path]


def check_citations(errors):
    """Each section citation names a heading or section number its file has,
    in every Markdown file but the records in UNCHECKED_CITATIONS and in
    every code, script or CI file."""
    sources = [p for p in files({".md"})
               if not (p.parent == ROOT / "docs/history/decisions"
                       and p.stem in UNCHECKED_CITATIONS)]
    sources += [p for p in files(CODE_SUFFIXES)
                # a checker's own test: its fixtures name a scratch repository
                if not p.name.startswith("test_check_")]
    for path in sources:
        rel = path.relative_to(ROOT)
        for block in blocks(path):
            text = "\n".join(line for _, line in block)
            for m in CITATION.finditer(text):
                n = block[text.count("\n", 0, m.start())][0]
                check_citation(errors, path, f"{rel}:{n}", *m.groups())


def check_citation(errors, path, where, file, heading, numbers):
    dest = path.parent / file
    if not dest.exists():
        dest = ROOT / file
    dest = dest.resolve()
    if ROOT not in dest.parents:
        errors.append(f"{where}: {file}: outside the repository")
        return
    if not dest.is_file():
        errors.append(f"{where}: {file}: no such file")
        return
    names, numbered = sections(dest)
    rel = dest.relative_to(ROOT)
    if heading is not None:
        heading = " ".join(heading.split())
        if slug(heading) not in names:
            errors.append(f"{where}: \"{heading}\": no such heading in {rel}")
    for number in re.findall(r"\d+", numbers or ""):
        if number not in numbered:
            errors.append(f"{where}: section {number}: no such numbered "
                          f"heading in {rel}")


def main():
    errors = []
    check_budgets(errors)
    check_links(errors)
    check_paths(errors)
    check_citations(errors)
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    if errors:
        sys.exit(1)
    print("ok")


main()
