"""Verify parseXPointer fix + CFI for the two failing annotations."""
import re, zipfile

epub = r"d:/Code/ATzotero.koplugin/_tmp_orain.epub"
raw = zipfile.ZipFile(epub).read("OEBPS/couv.xhtml").decode("utf-8")

class Node:
    def __init__(self, tag=None, text=None, parent=None):
        self.tag, self.text, self.parent, self.children = tag, text, parent, []

VOID = {"br", "img", "hr", "meta", "link", "input", "area", "base", "col", "embed", "source", "wbr"}

def is_ws(s):
    return s is None or str(s).strip() == ""

def parse_lua_style(html):
    html = re.sub(r"<!--.*?-->", "", html, flags=re.S)
    html = re.sub(r"<!DOCTYPE[^>]*>", "", html, flags=re.I)
    root = Node("document")
    cur = root
    i, n = 0, len(html)
    while i < n:
        lt = html.find("<", i)
        if lt < 0:
            data = html[i:]
            if data and not is_ws(data):
                cur.children.append(Node(text=data, parent=cur))
            break
        if lt > i:
            data = html[i:lt]
            if data and not is_ws(data):
                cur.children.append(Node(text=data, parent=cur))
        gt = html.find(">", lt + 1)
        if gt < 0:
            break
        rawt = html[lt + 1 : gt]
        i = gt + 1
        if rawt.startswith("!") or rawt.startswith("?"):
            continue
        if rawt.startswith("/"):
            tag = re.match(r"^([\w:_\-]+)", rawt[1:])
            if tag:
                tag = tag.group(1).lower().split(":")[-1]
                walk = cur
                while walk and walk.tag != tag and walk.tag != "document":
                    walk = walk.parent
                if walk and walk.tag == tag:
                    cur = walk.parent or root
        else:
            tagm = re.match(r"^([\w:_\-]+)", rawt)
            if not tagm:
                continue
            plain = tagm.group(1).lower().split(":")[-1]
            self_closing = rawt.endswith("/") or plain in VOID
            node = Node(tag=plain, parent=cur)
            cur.children.append(node)
            if not self_closing:
                cur = node
    return root

def find_tag(n, tag):
    if n.tag == tag:
        return n
    for c in n.children:
        f = find_tag(c, tag)
        if f:
            return f

def cfi_children(parent):
    return [c for c in parent.children if c.tag is not None or (c.text is not None and not is_ws(c.text))]

def resolve_path(body, path):
    cur = body
    for seg in [s for s in path.split("/") if s]:
        m = re.match(r"^([\w\-]+)\[(\d+)\]$", seg)
        if m:
            tag, idx = m.group(1).lower(), int(m.group(2))
        else:
            tag, idx = seg.lower(), 1
        matches = [c for c in cur.children if c.tag == tag]
        if idx < 1 or idx > len(matches):
            print("  resolve FAIL", seg, "have", len(matches), tag)
            return None
        cur = matches[idx - 1]
    return cur

def parse_xp(xp):
    """Fixed KOReader text()[K].OFF parser."""
    m = re.match(r"^/body/DocFragment\[(\d+)\]/(.+)$", xp)
    if not m:
        return None
    frag, rest = int(m.group(1)), m.group(2)
    m2 = re.match(r"^(.*)/text\(\)\[(\d+)\]\.(\d+)$", rest)
    if m2:
        path = re.sub(r"^body/", "", m2.group(1))
        return {"fragment": frag, "path": path, "text_index": int(m2.group(2)), "offset": int(m2.group(3))}
    m3 = re.match(r"^(.*)/text\(\)\.(\d+)$", rest)
    if m3:
        path = re.sub(r"^body/", "", m3.group(1))
        return {"fragment": frag, "path": path, "text_index": None, "offset": int(m3.group(2))}
    return {"fragment": frag, "path": re.sub(r"^body/", "", rest), "text_index": None, "offset": None}

def find_text(el, text_index, offset):
    if text_index:
        direct = 0
        for c in el.children:
            if c.text is not None and c.tag is None:
                direct += 1
                if direct == text_index:
                    return c, offset or 0
        return None, offset
    rem = offset or 0
    def walk(n):
        nonlocal rem
        if n.text is not None and n.tag is None:
            ln = len(n.text)
            if rem <= ln:
                return n, rem
            rem -= ln
            return None
        for ch in n.children:
            r = walk(ch)
            if r and r[0]:
                return r
        return None
    return walk(el) or (None, offset)

def text_step(tn):
    for i, c in enumerate(cfi_children(tn.parent), 1):
        if c is tn:
            return i * 2 - 1
    return 1

def cfi_steps(node, html_node):
    steps = []
    cur = node
    while cur and cur is not html_node:
        parent = cur.parent
        if not parent:
            break
        siblings = cfi_children(parent)
        idx = next((i for i, c in enumerate(siblings, 1) if c is cur), None)
        if not idx:
            break
        steps.insert(0, idx * 2)
        cur = parent
    return steps

def build(pos0, pos1):
    p0, p1 = parse_xp(pos0), parse_xp(pos1)
    print("parsed0", p0)
    print("parsed1", p1)
    tree = parse_lua_style(raw)
    html_node = find_tag(tree, "html")
    body = find_tag(tree, "body")
    el0 = resolve_path(body, p0["path"])
    el1 = resolve_path(body, p1["path"]) if p1["path"] != p0["path"] else el0
    print("el0", el0.tag if el0 else None, "el1", el1.tag if el1 else None)
    t0, o0 = find_text(el0, p0["text_index"], p0["offset"] or 0)
    t1, o1 = find_text(el1, p1["text_index"], p1["offset"] or 0)
    print("t0", repr((t0.text[o0:o0+40] if t0 else None)))
    print("t1 end", repr((t1.text[max(0,o1-20):o1] if t1 else None)), "o1", o1)
    if not t0:
        return None
    if not t1:
        t1, o1 = t0, p1["offset"] or o0
    spine = p0["fragment"] * 2
    if t0.parent is t1.parent:
        steps = cfi_steps(t0.parent, html_node)
        ts0, ts1 = text_step(t0), text_step(t1)
        cfi = f"epubcfi(/6/{spine}!/{'/'.join(map(str,steps))},/{ts0}:{o0},/{ts1}:{o1})"
    else:
        s0 = cfi_steps(t0.parent, html_node)
        s1 = cfi_steps(t1.parent, html_node)
        common = []
        for a, b in zip(s0, s1):
            if a == b:
                common.append(a)
            else:
                break
        rel0 = s0[len(common):] + [text_step(t0)]
        rel1 = s1[len(common):] + [text_step(t1)]
        cfi = f"epubcfi(/6/{spine}!/{'/'.join(map(str,common))},/{'/'.join(map(str,rel0))}:{o0},/{'/'.join(map(str,rel1))}:{o1})"
    print("CFI", cfi)
    return cfi

cases = [
    ("économiste bio",
     "/body/DocFragment[4]/body/section/div[2]/p/text()[1].14",
     "/body/DocFragment[4]/body/section/div[2]/p/text()[1].134"),
    ("dévoile mixed",
     "/body/DocFragment[4]/body/section/div[1]/p[3]/text()[1].16",
     "/body/DocFragment[4]/body/section/div[1]/p[3]/text()[3].52"),
]
for name, a, b in cases:
    print("\n====", name, "====")
    build(a, b)
