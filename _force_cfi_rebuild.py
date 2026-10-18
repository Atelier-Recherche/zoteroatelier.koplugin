"""Clear chapter-only CFI on R88T5VRI so next sync rebuilds a real range."""
import re
path = r"d:/Code/ATzotero.koplugin/_tmp_orain_meta.lua"
text = open(path, encoding="utf-8").read()
# Within R88T5VRI block, replace chapter-only cfi with empty so rebuild runs
key = "R88T5VRI"
idx = text.find(f'["zoteroKey"] = "{key}"')
if idx < 0:
    raise SystemExit("key not found")
start = text.rfind("\n        [", 0, idx)
brace = text.find("{", start)
depth = 0
end = None
for i in range(brace, len(text)):
    if text[i] == "{":
        depth += 1
    elif text[i] == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
block = text[start:end]
block2 = re.sub(
    r'\["zoteroCfi"\]\s*=\s*"epubcfi\(/6/\d+!/4\)"',
    '["zoteroCfi"] = "epubcfi(/6/8!/4/NEED_REBUILD)"',
    block,
    count=1,
)
# Also force version down so update compares as newer local intent
block2 = re.sub(r'\["zoteroVersion"\]\s*=\s*\d+', '["zoteroVersion"] = 1', block2, count=1)
text2 = text[:start] + block2 + text[end:]
text2 = re.sub(r'\["zoteroLibVersion"\]\s*=\s*\d+', '["zoteroLibVersion"] = 0', text2, count=1)
out = r"d:/Code/ATzotero.koplugin/_tmp_orain_meta_repaired.lua"
open(out, "w", encoding="utf-8", newline="\n").write(text2)
print("done", "NEED_REBUILD" in text2)
