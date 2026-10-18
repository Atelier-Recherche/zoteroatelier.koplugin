"""Strip leaked _matchItem and normalize section → section[1] in Orain sidecar."""
import re

path = r"d:/Code/ATzotero.koplugin/_tmp_orain_meta.lua"
text = open(path, encoding="utf-8").read()

# Remove entire _matchItem = { ... }, blocks (nested braces)
def strip_match_item(s):
    out = []
    i = 0
    while i < len(s):
        m = re.search(r'\n\s*\["_matchItem"\]\s*=\s*\{', s[i:])
        if not m:
            out.append(s[i:])
            break
        start = i + m.start()
        out.append(s[i:start])
        brace = i + m.end() - 1  # position of '{'
        depth = 0
        j = brace
        while j < len(s):
            if s[j] == "{":
                depth += 1
            elif s[j] == "}":
                depth -= 1
                if depth == 0:
                    j += 1
                    # optional trailing comma
                    if j < len(s) and s[j] == ",":
                        j += 1
                    break
            j += 1
        i = j
    return "".join(out)

text2 = strip_match_item(text)
# Normalize unindexed section/ to section[1]/
text2 = re.sub(
    r'(/body/DocFragment\[\d+\]/body/)section/',
    r'\1section[1]/',
    text2,
)
# Force re-attach on next open
text2 = re.sub(r'\["zoteroLibVersion"\]\s*=\s*\d+', '["zoteroLibVersion"] = 0', text2, count=1)

out = r"d:/Code/ATzotero.koplugin/_tmp_orain_meta_repaired.lua"
open(out, "w", encoding="utf-8", newline="\n").write(text2)
print("wrote", out)
print("matchItem left", text2.count("_matchItem"))
print("pages", re.findall(r'\["page"\]\s*=\s*"([^"]+)"', text2))
