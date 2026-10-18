"""Simulate Lua CFI build for Hhhhhh xpointers against couv.xhtml."""
import re
from html.parser import HTMLParser

raw = open(r"d:/Code/ATzotero.koplugin/_tmp_frag4.xhtml", encoding="utf-8").read()

class Node:
    def __init__(self, tag=None, text=None, parent=None):
        self.tag, self.text, self.parent, self.children = tag, text, parent, []

VOID = {"br", "img", "hr", "meta", "link", "input", "area", "base", "col", "embed", "source", "wbr"}

def is_ws(s):
    return s is None or str(s).strip() == ""

# Lua-like parser: drop whitespace-only text
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
                root_child = Node(text=data, parent=cur)
                cur.children.append(root_child)
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
            return None
        cur = matches[idx - 1]
    return cur

def find_text_target_BUGGY(el, text_index, offset):
    if text_index:
        direct = cumulative = 0
        for c in el.children:
            if c.text is not None and c.tag is None:
                direct += 1
                if direct == text_index:
                    return c, cumulative + (offset or 0)  # BUG
                cumulative += len(c.text)
        return None, offset
    return None, offset

def find_text_target_FIXED(el, text_index, offset):
    if text_index:
        direct = 0
        for c in el.children:
            if c.text is not None and c.tag is None:
                direct += 1
                if direct == text_index:
                    return c, offset or 0
        return None, offset
    return None, offset

def text_step(text_node):
    siblings = cfi_children(text_node.parent)
    for i, c in enumerate(siblings, 1):
        if c is text_node:
            return i * 2 - 1
    return 1

def cfi_steps_to_html(node, html_node):
    steps = []
    cur = node
    while cur and cur is not html_node:
        parent = cur.parent
        if not parent:
            break
        siblings = cfi_children(parent)
        idx = None
        for i, c in enumerate(siblings, 1):
            if c is cur:
                idx = i
                break
        if not idx:
            break
        steps.insert(0, idx * 2)
        cur = parent
    return steps

tree = parse_lua_style(raw)
html_node = find_tag(tree, "html") or tree
body = find_tag(tree, "body")
path = "section/div[1]/p[3]"
el = resolve_path(body, path)
print("el", el.tag if el else None)
print("direct texts:")
ti = 0
for c in el.children:
    if c.text is not None and c.tag is None:
        ti += 1
        print(f"  text()[{ti}] len={len(c.text)} {repr(c.text[:50])}")

for label, fn in [("BUGGY", find_text_target_BUGGY), ("FIXED", find_text_target_FIXED)]:
    t0, o0 = fn(el, 3, 1)
    t1, o1 = fn(el, 3, 39)
    print(label, "t0", repr(t0.text[:40]) if t0 else None, "o0", o0, "o1", o1)
    if t0:
        steps = cfi_steps_to_html(t0.parent, html_node)
        ts = text_step(t0)
        cfi = f"epubcfi(/6/8!/{'/'.join(map(str,steps))},/{ts}:{o0},/{ts}:{o1})"
        print(" ", cfi)
