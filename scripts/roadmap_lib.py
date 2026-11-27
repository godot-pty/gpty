"""The roadmap ledger's shared vocabulary.

The ledger is the index row on a release chain page (`v*.md`, plus `future.md`)
joined by ID to the detail section on `details/<area>.md`. Four tools read it -
`scripts/roadmap`, `scripts/docs-check`, `scripts/check-capabilities` and
`scripts/render-capabilities` - so the row shape, the ID rule, the detail link,
the page-name rule, the area list, the front matter, the `Commits:` rule and
the line-length cap live here, once.

Functions that read the tree take its root (the ledger tree, `ROADMAP_ROOT` for
`scripts/roadmap`) as their first argument; nothing here holds module state.
"""

import collections
import os
import re
import textwrap

STATUS = {'⬜': 'open', '✅': 'done', '🚫': 'dropped', '❌': 'wontfix'}
ROW_RE = re.compile(
    r'^\| (✅|⬜|🚫|❌) \| \[([A-Z]+-\d+)\]\(details/([a-z]+)\.md#([a-z]+-\d+)\) '
    r'\| \*\*(.+?)\*\* \|$')
ROW_SHAPE = '| ✅/⬜/🚫/❌ | [AREA-N](details/area.md#area-n) | **Title** |'
ROW = collections.namedtuple('Row', 'status rid area_file anchor title')
SECTION_RE = re.compile(r'(?m)^## ([A-Z]+-\d+)$')
COMMIT_LINE = re.compile(r'^Commits: (.*)$')
COMMIT_RE = re.compile(r'^Commits: (unrecorded|[0-9a-f]{7,40}(?:, [0-9a-f]{7,40})*)$')
MAX_LINE = 768
WRAP = 100
PAGE_RE = re.compile(r'^(v.*|future)\.md$')
AREA_RE = re.compile(r'ID prefix names[^(]*\(([A-Z, ]+)\)')
FRONT_RE = re.compile(r'---\n(.*?)\n---\n', re.S)


def parse_row(line):
    """The index row as a `Row`, or None when the line is not one."""
    m = ROW_RE.match(line)
    return ROW(*m.groups()) if m else None


def detail_link(rid):
    """The index row's link target for a row ID: `details/build.md#build-128`."""
    return f'details/{rid.split("-", 1)[0].lower()}.md#{rid.lower()}'


def roadmap_dir(root):
    return os.path.join(root, 'docs/content/docs/roadmap')


def page_names(root):
    """The release chain pages, by filename (`v0.9.md`, `future.md`), sorted."""
    d = roadmap_dir(root)
    if not os.path.isdir(d):
        return []
    return [n for n in sorted(os.listdir(d)) if PAGE_RE.match(n)]


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def areas(root):
    """The ID-prefix vocabulary, read from ROADMAP.md's opening text."""
    path = os.path.join(root, 'ROADMAP.md')
    if not os.path.exists(path):
        return []
    m = AREA_RE.search(read(path))
    return [a.strip() for a in m.group(1).split(',') if a.strip()] if m else []


def rows(root):
    """Every index row keyed by ID; a malformed line is skipped, not fatal."""
    found = {}
    for name in page_names(root):
        for line in read(os.path.join(roadmap_dir(root), name)).split('\n'):
            row = parse_row(line)
            if row:
                found.setdefault(row.rid, row)
    return found


def front_matter(text):
    """A page's front matter as a dict of stripped values, or None."""
    m = FRONT_RE.match(text)
    if not m:
        return None
    return dict(
        (k.strip(), v.strip().strip('"'))
        for k, _, v in (line.partition(':') for line in m.group(1).split('\n'))
        if k.strip())


def long_lines(text, limit=MAX_LINE):
    """`(line number, UTF-8 size)` for every line over the cap, 1-based."""
    out = []
    for n, line in enumerate(text.split('\n'), 1):
        size = len(line.encode('utf-8'))
        if size > limit:
            out.append((n, size))
    return out


def wrap(text, width=WRAP):
    """Reflow prose paragraphs to `width`; leave structure alone.

    A fenced block, a heading, a table row, an indented line and a bullet are
    copied unchanged and end the paragraph in progress. A title paragraph
    (`**Title** - text`) is filled with the bold span as its indent, so the
    span is never split - a split title would put a newline inside the index
    row. Words longer than the width stay whole; `MAX_LINE` is the backstop.
    """
    out, block, in_fence = [], [], False
    fill = dict(break_long_words=False, break_on_hyphens=False)

    def flush():
        if not block:
            return
        para = ' '.join(block)
        block.clear()
        m = re.match(r'\*\*(.+?)\*\* - (.*)', para, re.S)
        if m:
            head = f'**{m.group(1)}** - '
            body = ' '.join(m.group(2).split())
            if not body:
                out.append(head.rstrip())
                return
            out.extend(textwrap.fill(body, width=width, initial_indent=head,
                                     subsequent_indent='', **fill).split('\n'))
            return
        out.extend(textwrap.fill(para, width=width, **fill).split('\n'))

    for line in text.split('\n'):
        if line.startswith('```'):
            flush()
            in_fence = not in_fence
            out.append(line)
        elif (in_fence or not line.strip() or line.startswith(('#', '|', '    ', '- ', '* '))
                or re.match(r'^\d+\. ', line)):
            flush()
            out.append(line)
        else:
            block.append(line.strip())
    flush()
    return '\n'.join(x.rstrip() for x in out)
