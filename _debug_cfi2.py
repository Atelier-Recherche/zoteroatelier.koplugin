import zipfile, re, html as htmlmod
from html.parser import HTMLParser

epub = r"d:/Code/ATzotero.koplugin/_tmp_orain.epub"
z = zipfile.ZipFile(epub)
opf = z.read("OEBPS/content.opf").decode("utf-8", "replace")
manifest = {}
for item in re.findall(r"<item\s+[^>]+>", opf):
    iid = re.search(r'id="([^"]+)"', item)
    href = re.search(r'href="([^"]+)"', item)
    if iid and href:
        manifest[iid.group(1)] = href.group(1)
spine = re.findall(r'<itemref[^>]+idref="([^"]+)"', opf)
print("spine:", [(i + 1, sid, manifest.get(sid)) for i, sid in enumerate(spine[:8])])
href = manifest[spine[3]]
entry = "OEBPS/" + href
print("entry", entry)
raw = z.read(entry).decode("utf-8", "replace")
open(r"d:/Code/ATzotero.koplugin/_tmp_frag4.xhtml", "w", encoding="utf-8").write(raw)
print("len", len(raw))

# Minimal tree like epub_cfi.lua: skip whitespace-only text
class Node:
    def __init__(self, tag=None, text=None, parent=None):
        self.tag = tag
        self.text = text
        self.children = []
        self.parent = parent

class P(HTMLParser):
    def __init__(self):
        super().__init__()
        self.root = Node("document")
        self.cur = self.root
        self.void = {"br", "img", "hr", "meta", "link", "input", "area", "base", "col", "embed", "source", "wbr"}

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        n = Node(tag=tag, parent=self.cur)
        self.cur.children.append(n)
        if tag not in self.void:
            self.cur = n

    def handle_endtag(self, tag):
        tag = tag.lower()
        # pop to matching
        c = self.cur
        while c and c.tag != tag and c.tag != "document":
            c = c.parent
        if c and c.parent:
            self.cur = c.parent

    def handle_data(self, data):
        if data is None:
            return
        # keep all text including whitespace for structure; cfi_children skips ws-only
        n = Node(text=data, parent=self.cur)
        self.cur.children.append(n)

p = P()
p.feed(raw)

def find_tag(n, tag):
    if n.tag == tag:
        return n
    for c in n.children:
        f = find_tag(c, tag)
        if f:
            return f
    return None

def is_ws(s):
    return s is None or str(s).strip() == ""

def cfi_children(parent):
    out = []
    for c in parent.children:
        if c.tag is not None:
            out.append(c)
        elif c.text is not None and not is_ws(c.text):
            out.append(c)
    return out

def resolve_path(body, path):
    path = path.replace("body/", "", 1) if path.startswith("body/") else path
    cur = body
    for seg in path.split("/"):
        if not seg:
            continue
        m = re.match(r"^([\w\-]+)\[(\d+)\]$", seg)
        if m:
            tag, idx = m.group(1).lower(), int(m.group(2))
        else:
            tag, idx = seg.lower(), 1
        matches = [c for c in cur.children if c.tag == tag]
        if idx < 1 or idx > len(matches):
            print("FAIL resolve", seg, "have", len(matches), "of", tag, "at", cur.tag)
            return None
        cur = matches[idx - 1]
    return cur

body = find_tag(p.root, "body")
print("body children tags:", [c.tag for c in body.children if c.tag])
section = resolve_path(body, "section/div[1]/p[3]")
print("resolved p[3]", section is not None, "tag", section.tag if section else None)
if section:
    print("p[3] children:")
    for i, c in enumerate(section.children):
        if c.tag:
            print(f"  [{i}] <{c.tag}>")
        else:
            t = repr(c.text[:80] if c.text else None)
            print(f"  [{i}] TEXT ws={is_ws(c.text)} {t}")
    print("cfi_children:")
    for i, c in enumerate(cfi_children(section)):
        if c.tag:
            print(f"  cfi[{i}] <{c.tag}>")
        else:
            print(f"  cfi[{i}] TEXT {repr(c.text[:60])}")

# Also list all p under section/div[1]
div = resolve_path(body, "section/div[1]")
print("\ndiv[1] p count", len([c for c in div.children if c.tag == "p"]) if div else None)
if div:
    for i, c in enumerate([c for c in div.children if c.tag == "p"]):
        texts = []
        for ch in c.children:
            if ch.text and not is_ws(ch.text):
                texts.append(ch.text[:40].replace("\n", " "))
            elif ch.tag:
                texts.append(f"<{ch.tag}>")
        print(f"  p[{i+1}]: {texts[:8]}")
