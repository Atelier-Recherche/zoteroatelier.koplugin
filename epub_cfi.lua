-- Convert KOReader CREngine XPointers to EPUB CFI (for Zotero FragmentSelector).
-- Example:
--   /body/DocFragment[3]/body/section/p[2]/text().0
--   /body/DocFragment[3]/body/section/p[2]/text().18
-- → epubcfi(/6/6!/4/2/4,/1:0,/1:18)
--
-- Important: Zotero's reader ignores whitespace-only text nodes between elements
-- when resolving CFI steps (same as most browser EPUB CFI impls). Counting those
-- newlines shifts highlights to the next paragraph.

local EpubCfi = {}
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local VOID = {
    area = true,
    base = true,
    br = true,
    col = true,
    embed = true,
    hr = true,
    img = true,
    input = true,
    link = true,
    meta = true,
    source = true,
    wbr = true,
}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_whitespace_text(s)
    return tostring(s or ""):match("^%s*$") ~= nil
end

-- Child list as Zotero/CFI resolvers see it: skip whitespace-only text nodes.
local function cfi_children(parent)
    local out = {}
    if not parent or not parent.children then
        return out
    end
    for _, c in ipairs(parent.children) do
        if c.tag ~= nil then
            table.insert(out, c)
        elseif c.text ~= nil and not is_whitespace_text(c.text) then
            table.insert(out, c)
        end
    end
    return out
end

--- Normalize KOReader pos0/pos1 (string or {xpointer=...}).
function EpubCfi.getXPointer(pos)
    if type(pos) == "string" and pos ~= "" then
        return pos
    end
    if type(pos) == "table" and pos.xpointer and tostring(pos.xpointer) ~= "" then
        return tostring(pos.xpointer)
    end
    return nil
end

--- Parse /body/DocFragment[N]/.../text().OFF or .../text()[K].OFF
--- KOReader/CRE format is literally:  .../text()[3].14  (NOT text([3]).14).
function EpubCfi.parseXPointer(xp)
    xp = tostring(xp or "")
    local frag, rest = xp:match("^/body/DocFragment%[(%d+)%]/(.+)$")
    if not frag then
        frag, rest = xp:match("^/body/DocFragment/(.+)$")
        if rest then
            frag = "1"
        end
    end
    if not frag or not rest then
        return nil
    end

    local path, text_index, offset
    -- text()[K].OFF  — indexed text node (most common for mixed <span>/<sup> paragraphs)
    path, text_index, offset = rest:match("^(.*)/text%(%)%[(%d+)%]%.(%d+)$")
    if path then
        -- CRE often prefixes path with body/; resolve_path expects relative-to-body
        path = path:gsub("^body/", "")
        return {
            fragment = tonumber(frag),
            path = path,
            text_index = tonumber(text_index),
            offset = tonumber(offset),
        }
    end
    -- text().OFF — single / first text node
    path, offset = rest:match("^(.*)/text%(%)%.(%d+)$")
    if path then
        path = path:gsub("^body/", "")
        return {
            fragment = tonumber(frag),
            path = path,
            text_index = nil,
            offset = tonumber(offset),
        }
    end
    rest = rest:gsub("^body/", "")
    return {
        fragment = tonumber(frag),
        path = rest,
        text_index = nil,
        offset = nil,
    }
end

local function new_node(tag, text, parent)
    return { tag = tag, text = text, children = {}, parent = parent }
end

--- Minimal HTML tree (good enough for CFI sibling indices).
function EpubCfi.parseHtml(html)
    html = tostring(html or "")
    -- Drop comments / doctype / scripts / styles content noise
    html = html:gsub("<!%-%-.-%-%->", "")
    html = html:gsub("<!DOCTYPE[^>]*>", "")
    local root = new_node("document", nil, nil)
    local cur = root
    local i = 1
    local n = #html
    while i <= n do
        local lt = html:find("<", i, true)
        if not lt then
            local data = html:sub(i)
            -- Keep non-whitespace text only (Zotero ignores inter-element newlines)
            if data ~= "" and not is_whitespace_text(data) then
                table.insert(cur.children, new_node(nil, data, cur))
            end
            break
        end
        if lt > i then
            local data = html:sub(i, lt - 1)
            if data ~= "" and not is_whitespace_text(data) then
                table.insert(cur.children, new_node(nil, data, cur))
            end
        end
        local gt = html:find(">", lt + 1, true)
        if not gt then
            break
        end
        local raw = html:sub(lt + 1, gt - 1)
        i = gt + 1
        if raw:sub(1, 1) == "!" or raw:sub(1, 1) == "?" then
            -- skip
        elseif raw:sub(1, 1) == "/" then
            local tag = raw:sub(2):match("^([%w:_%-]+)")
            if tag then
                tag = tag:lower()
                -- pop until matching tag
                local walk = cur
                while walk and walk.tag ~= tag and walk.tag ~= "document" do
                    walk = walk.parent
                end
                if walk and walk.tag == tag then
                    cur = walk.parent or root
                end
            end
        else
            local tag = raw:match("^([%w:_%-]+)")
            if tag then
                tag = tag:lower()
                -- strip namespace prefix for matching (epub:type attrs stay on tag name only)
                local plain = tag:match("([^:]+)$") or tag
                local self_closing = raw:match("/$") ~= nil or VOID[plain]
                local node = new_node(plain, nil, cur)
                table.insert(cur.children, node)
                if not self_closing then
                    cur = node
                end
            end
        end
    end
    return root
end

local function find_tag(node, tag)
    if node.tag == tag then
        return node
    end
    for _, c in ipairs(node.children) do
        local f = find_tag(c, tag)
        if f then
            return f
        end
    end
    return nil
end

local function resolve_path(body, path)
    -- path like "body/section/p[2]" or "body/section/p[2]" after DocFragment
    path = path:gsub("^body/", "")
    local cur = body
    for seg in path:gmatch("[^/]+") do
        if seg ~= "" then
            local tag, idx_s = seg:match("^([%w_%-]+)%[(%d+)%]$")
            if not tag then
                tag = seg:match("^([%w_%-]+)$")
                idx_s = "1"
            end
            if not tag then
                return nil
            end
            tag = tag:lower()
            local idx = tonumber(idx_s) or 1
            local matches = {}
            for _, c in ipairs(cur.children) do
                if c.tag == tag then
                    table.insert(matches, c)
                end
            end
            if idx < 1 or idx > #matches then
                return nil
            end
            cur = matches[idx]
        end
    end
    return cur
end

local function cfi_steps_to_html(node, html_node)
    local steps = {}
    local cur = node
    while cur and cur ~= html_node do
        local parent = cur.parent
        if not parent then
            break
        end
        local siblings = cfi_children(parent)
        local idx = nil
        for i, c in ipairs(siblings) do
            if c == cur then
                idx = i
                break
            end
        end
        if not idx then
            break
        end
        -- EPUB CFI: childNodes index (among significant nodes) → (i+1)*2
        table.insert(steps, 1, idx * 2)
        cur = parent
    end
    return steps
end

local function join_steps(steps)
    local t = {}
    for _, s in ipairs(steps) do
        table.insert(t, tostring(s))
    end
    return table.concat(t, "/")
end

local function find_text_target(el, text_index, offset)
    -- text_index: 1-based direct text()[K] among element children (CRE xpointer).
    -- offset is WITHIN that text node — never add lengths of previous siblings
    -- (that produced /13:140 on a 153-char node → Zotero drops the underline).
    if text_index then
        local direct = 0
        for _, c in ipairs(el.children) do
            if c.text ~= nil and c.tag == nil then
                direct = direct + 1
                if direct == text_index then
                    return c, offset or 0
                end
            end
        end
        return nil, offset
    end
    -- cumulative offset across all descendant text (no text()[K] in xpointer)
    local remaining = offset or 0
    local function walk(n)
        if n.text ~= nil and n.tag == nil then
            local len = #tostring(n.text)
            if remaining <= len then
                return n, remaining
            end
            remaining = remaining - len
            return nil
        end
        for _, ch in ipairs(n.children) do
            local node, off = walk(ch)
            if node then
                return node, off
            end
        end
        return nil
    end
    return walk(el)
end

local function text_step_among_siblings(text_node)
    local parent = text_node.parent
    if not parent then
        return 1
    end
    local siblings = cfi_children(parent)
    for i, c in ipairs(siblings) do
        if c == text_node then
            -- Text nodes use odd CFI indices: 1, 3, 5...
            return i * 2 - 1
        end
    end
    return 1
end

local function path_relative_to_body(path)
    path = tostring(path or "")
    path = path:gsub("^body/", "")
    return path
end

--- Build range CFI from two parsed positions + HTML string of the spine item.
function EpubCfi.cfiFromParsed(html, start_p, end_p)
    local tree = EpubCfi.parseHtml(html)
    local html_node = find_tag(tree, "html") or tree
    local body = find_tag(tree, "body")
    if not body then
        return nil, "no body"
    end
    local el0 = resolve_path(body, path_relative_to_body(start_p.path))
    if not el0 then
        return nil, "cannot resolve start path " .. tostring(start_p.path)
    end
    local el1 = el0
    if end_p and end_p.path and end_p.path ~= start_p.path then
        el1 = resolve_path(body, path_relative_to_body(end_p.path)) or el0
    end

    local function resolve_text(el, text_index, offset)
        local t, off = find_text_target(el, text_index, offset or 0)
        if t then
            return t, off
        end
        -- text()[K] may point at a deeper descendant (spans); walk in document order
        if text_index then
            local n = 0
            local function walk(node)
                if node.text ~= nil and node.tag == nil then
                    n = n + 1
                    if n == text_index then
                        return node
                    end
                end
                for _, ch in ipairs(node.children or {}) do
                    local found = walk(ch)
                    if found then
                        return found
                    end
                end
                return nil
            end
            local deep = walk(el)
            if deep then
                return deep, offset or 0
            end
            -- CRE text()[N] often does not match our HTML splits — use offset on 1st text
            t, off = find_text_target(el, 1, offset or 0)
            if t then
                return t, off
            end
        end
        -- last resort: cumulative offset across descendants
        return find_text_target(el, nil, offset or 0)
    end

    local end_off = (end_p and end_p.offset)
    if end_off == nil then
        end_off = start_p.offset or 0
    end
    local t0, off0 = resolve_text(el0, start_p.text_index, start_p.offset or 0)
    local t1, off1 = resolve_text(
        el1,
        end_p and end_p.text_index or start_p.text_index,
        end_off
    )
    local spine = (start_p.fragment or 1) * 2
    if not t0 then
        -- Still emit a character range on the resolved element so Zotero paints something
        local steps = cfi_steps_to_html(el0, html_node)
        local a = start_p.offset or 0
        local b = end_off
        if b < a then
            b = a
        end
        if b == a and (end_p and end_p.path and end_p.path ~= start_p.path) then
            b = a + 1
        end
        return string.format(
            "epubcfi(/6/%d!/%s,/1:%d,/1:%d)",
            spine,
            join_steps(steps),
            a,
            b
        )
    end
    if not t1 then
        -- NEVER collapse to identical offsets when the local range has a different end
        t1 = t0
        off1 = end_off
        if el1 and el1 ~= el0 then
            local alt, alt_off = resolve_text(el1, end_p and end_p.text_index, end_off)
            if alt then
                t1, off1 = alt, alt_off
            end
        end
    end
    if t0 == t1 and (off0 or 0) == (off1 or 0) and end_off ~= (off0 or 0) then
        off1 = end_off
    end

    -- Same parent element (common highlight in one paragraph)
    if t0.parent == t1.parent then
        local steps = cfi_steps_to_html(t0.parent or el0, html_node)
        local ts0 = text_step_among_siblings(t0)
        local ts1 = text_step_among_siblings(t1)
        if t0 == t1 then
            return string.format(
                "epubcfi(/6/%d!/%s,/%d:%d,/%d:%d)",
                spine,
                join_steps(steps),
                ts0,
                off0 or 0,
                ts0,
                off1 or off0 or 0
            )
        end
        return string.format(
            "epubcfi(/6/%d!/%s,/%d:%d,/%d:%d)",
            spine,
            join_steps(steps),
            ts0,
            off0 or 0,
            ts1,
            off1 or 0
        )
    end

    local s0 = cfi_steps_to_html(t0.parent or el0, html_node)
    local s1 = cfi_steps_to_html(t1.parent or el1, html_node)
    local ts0 = text_step_among_siblings(t0)
    local ts1 = text_step_among_siblings(t1)
    local common = {}
    local n = math.min(#s0, #s1)
    for i = 1, n do
        if s0[i] == s1[i] then
            table.insert(common, s0[i])
        else
            break
        end
    end
    local rel0, rel1 = {}, {}
    for i = #common + 1, #s0 do
        table.insert(rel0, s0[i])
    end
    table.insert(rel0, ts0)
    for i = #common + 1, #s1 do
        table.insert(rel1, s1[i])
    end
    table.insert(rel1, ts1)
    return string.format(
        "epubcfi(/6/%d!/%s,/%s:%d,/%s:%d)",
        spine,
        join_steps(common),
        join_steps(rel0),
        off0 or 0,
        join_steps(rel1),
        off1 or 0
    )
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function unzip_entry(epub_path, entry_path, dest_path)
    -- Prefer io.popen (redirect-to-file often fails on Android with Unicode paths)
    local cmd = "unzip -p " .. sh_quote(epub_path) .. " " .. sh_quote(entry_path) .. " 2>/dev/null"
    local pipe = io.popen(cmd, "r")
    if pipe then
        local data = pipe:read("*a")
        pipe:close()
        if data and #data > 0 then
            pcall(function()
                local out = io.open(dest_path, "wb")
                if out then
                    out:write(data)
                    out:close()
                end
            end)
            return data
        end
    end
    -- Fallback: shell redirect to file
    os.execute(
        "unzip -p "
            .. sh_quote(epub_path)
            .. " "
            .. sh_quote(entry_path)
            .. " > "
            .. sh_quote(dest_path)
            .. " 2>/dev/null"
    )
    local data = read_file(dest_path)
    if data and #data > 0 then
        return data
    end
    local tmpdir = dest_path .. "_dir"
    lfs.mkdir(tmpdir)
    os.execute(
        "unzip -qq -o "
            .. sh_quote(epub_path)
            .. " "
            .. sh_quote(entry_path)
            .. " -d "
            .. sh_quote(tmpdir)
            .. " 2>/dev/null"
    )
    return read_file(tmpdir .. "/" .. entry_path)
end

local function parse_opf_spine(opf_xml)
    local manifest = {}
    for id, href in opf_xml:gmatch('<item[^>]+id="([^"]+)"[^>]+href="([^"]+)"') do
        manifest[id] = href
    end
    for id, href in opf_xml:gmatch('<item[^>]+href="([^"]+)"[^>]+id="([^"]+)"') do
        -- alternate attr order
        manifest[href] = manifest[href] -- no-op keep
        if not manifest[id] then
            -- swapped capture when href comes first: fix by second pass below
        end
    end
    -- More robust: any order
    manifest = {}
    for item in opf_xml:gmatch("<item%s+[^>]+>") do
        local id = item:match('id="([^"]+)"')
        local href = item:match('href="([^"]+)"')
        if id and href then
            manifest[id] = href
        end
    end
    local spine = {}
    for idref in opf_xml:gmatch('<itemref[^>]+idref="([^"]+)"') do
        if manifest[idref] then
            table.insert(spine, manifest[idref])
        end
    end
    return spine
end

local function opf_dir(opf_path)
    return opf_path:match("^(.*)/[^/]+$") or ""
end

-- Cache: epub_path → { mtime, spine_hrefs, html_by_fragment }
local _epub_cache = {}

local function epub_mtime(path)
    local attr = lfs.attributes(path)
    return attr and attr.modification or 0
end

function EpubCfi.clearCache(epub_path)
    if epub_path then
        _epub_cache[epub_path] = nil
    else
        _epub_cache = {}
    end
end

--- Read spine item HTML (1-based DocFragment index) from EPUB.
--- Cached per file+mtime so sync/create does not unzip 3× per annotation.
function EpubCfi.readSpineHtml(epub_path, fragment_index)
    fragment_index = tonumber(fragment_index) or 1
    local mtime = epub_mtime(epub_path)
    local cached = _epub_cache[epub_path]
    if cached and cached.mtime == mtime then
        if cached.html[fragment_index] then
            return cached.html[fragment_index], cached.entry[fragment_index]
        end
    else
        cached = { mtime = mtime, spine = nil, opf_dir = nil, html = {}, entry = {} }
        _epub_cache[epub_path] = cached
    end

    local base_tmp = "/storage/emulated/0/koreader/cache"
    pcall(function()
        local DataStorage = require("datastorage")
        base_tmp = DataStorage:getDataDir() .. "/cache"
    end)
    -- Stable temp dir per epub (reuse extracted OPF across fragments)
    local safe = tostring(epub_path):gsub("[^%w]+", "_"):sub(-40)
    local tmp = base_tmp .. "/zotero_epub_cfi_" .. safe
    lfs.mkdir(base_tmp)
    lfs.mkdir(tmp)

    if not cached.spine then
        local container = unzip_entry(epub_path, "META-INF/container.xml", tmp .. "/container.xml")
        if not container then
            return nil, "no container.xml"
        end
        local opf_path = container:match('full%-path="([^"]+)"')
        if not opf_path then
            return nil, "no opf path"
        end
        local opf = unzip_entry(epub_path, opf_path, tmp .. "/content.opf")
        if not opf then
            return nil, "no opf"
        end
        cached.spine = parse_opf_spine(opf)
        cached.opf_dir = opf_dir(opf_path)
    end

    local href = cached.spine[fragment_index]
    if not href then
        return nil, "spine index out of range: " .. tostring(fragment_index)
    end
    local entry = href
    if cached.opf_dir ~= "" and not href:match("^/") then
        entry = cached.opf_dir .. "/" .. href
        entry = entry:gsub("//", "/")
    end
    local html = unzip_entry(epub_path, entry, tmp .. "/spine_" .. tostring(fragment_index) .. ".xhtml")
    if not html then
        return nil, "cannot read spine item " .. entry
    end
    cached.html[fragment_index] = html
    cached.entry[fragment_index] = entry
    return html, entry
end

--- Main entry: KOReader pos0/pos1 (+ optional epub path) → epubcfi(...)
function EpubCfi.fromKOReaderPositions(pos0, pos1, epub_path)
    local xp0 = EpubCfi.getXPointer(pos0)
    local xp1 = EpubCfi.getXPointer(pos1) or xp0
    if not xp0 then
        return nil, "missing pos0"
    end
    local p0 = EpubCfi.parseXPointer(xp0)
    local p1 = EpubCfi.parseXPointer(xp1)
    if not p0 then
        return nil, "bad pos0"
    end
    p1 = p1 or p0
    if not epub_path or epub_path == "" then
        return nil, "missing epub path"
    end
    local html, err = EpubCfi.readSpineHtml(epub_path, p0.fragment)
    if not html then
        return nil, err or "html"
    end
    local cfi, cerr = EpubCfi.cfiFromParsed(html, p0, p1)
    if not cfi then
        return nil, cerr
    end
    return cfi, p0
end

local function follow_cfi_steps(start_node, steps_str)
    local cur = start_node
    for step_s in tostring(steps_str or ""):gmatch("%d+") do
        local step = tonumber(step_s)
        if not step then
            return nil
        end
        local kids = cfi_children(cur)
        local idx = math.ceil(step / 2)
        cur = kids[idx]
        if not cur then
            return nil
        end
    end
    return cur
end

local function element_path_from_body(el)
    local parts = {}
    local cur = el
    while cur and cur.tag and cur.tag ~= "body" and cur.tag ~= "html" and cur.tag ~= "document" do
        local parent = cur.parent
        if not parent then
            break
        end
        local idx = 0
        for _, c in ipairs(parent.children) do
            if c.tag == cur.tag then
                idx = idx + 1
                if c == cur then
                    break
                end
            end
        end
        table.insert(parts, 1, string.format("%s[%d]", cur.tag, idx > 0 and idx or 1))
        cur = parent
    end
    return table.concat(parts, "/")
end

local function text_node_to_xpointer(fragment, text_node, offset)
    if not text_node or not text_node.parent then
        return nil
    end
    local parent = text_node.parent
    local path = element_path_from_body(parent)
    if path == "" then
        path = parent.tag or "body"
    end
    local tcount = 0
    local tidx = 1
    for _, c in ipairs(parent.children) do
        if c.text ~= nil and c.tag == nil then
            tcount = tcount + 1
            if c == text_node then
                tidx = tcount
            end
        end
    end
    local off = tonumber(offset) or 0
    if tcount > 1 then
        return string.format(
            "/body/DocFragment[%d]/body/%s/text()[%d].%d",
            fragment,
            path,
            tidx,
            off
        )
    end
    return string.format("/body/DocFragment[%d]/body/%s/text().%d", fragment, path, off)
end

--- Normalize Zotero/EPUB CFI into `epubcfi(/6/N!/...)`.
--- Handles bare paths (`/6/8!/...`), missing `epubcfi()` wrapper, and ID assertions (`[couv]`).
function EpubCfi.normalizeCfi(cfi)
    cfi = trim(tostring(cfi or ""))
    if cfi == "" then
        return nil
    end
    -- Strip XML/HTML ID assertions: /6/8[couv]! → /6/8!
    cfi = cfi:gsub("%b[]", "")
    local inner = cfi:match("^epubcfi%((.+)%)$")
    if inner then
        cfi = trim(inner)
    end
    if not cfi:match("^/6/%d+!") then
        return nil
    end
    return "epubcfi(" .. cfi .. ")"
end

--- Reverse: epubcfi(...) → KOReader xpointer strings (pos0, pos1).
--- Needed so annotations created in Zotero become visible highlights in EPUB rolling mode.
function EpubCfi.toKOReaderPositions(cfi, epub_path)
    cfi = EpubCfi.normalizeCfi(cfi) or tostring(cfi or "")
    local spine_s, after = cfi:match("epubcfi%(/6/(%d+)!(.+)%)$")
    if not spine_s or not after then
        return nil, nil, "bad cfi"
    end
    local fragment = math.floor(tonumber(spine_s) / 2)
    if fragment < 1 then
        fragment = 1
    end
    if not epub_path or epub_path == "" then
        return nil, nil, "missing epub path"
    end
    local html, err = EpubCfi.readSpineHtml(epub_path, fragment)
    if not html then
        return nil, nil, err or "html"
    end
    local tree = EpubCfi.parseHtml(html)
    local html_node = find_tag(tree, "html") or tree
    local body = find_tag(tree, "body")
    if not body then
        return nil, nil, "no body"
    end

    -- Range form: /4/2/4,/1:0,/1:18  or non-range /4/2/4/1:0
    local common, s_steps, s_off, e_steps, e_off =
        after:match("^([^,]+),/([^:]+):(%d+),/([^:]+):(%d+)$")
    if not common then
        local path_only, off_only = after:match("^(.+)/(%d+)$")
        if path_only and off_only then
            -- Odd terminal text step folded into path: /4/2/1:18 style is rare; try whole path
            common = after
            s_steps, s_off, e_steps, e_off = "", 0, "", 0
        else
            common = after
            s_steps, s_off, e_steps, e_off = "", 0, "", 0
        end
    end

    local parent = follow_cfi_steps(html_node, common)
    if not parent then
        return nil, nil, "cannot walk cfi parent"
    end
    local start_node = parent
    if s_steps and s_steps ~= "" then
        start_node = follow_cfi_steps(parent, s_steps) or parent
    end
    local end_node = parent
    if e_steps and e_steps ~= "" then
        end_node = follow_cfi_steps(parent, e_steps) or start_node
    end

    -- Ensure we land on text nodes
    local function ensure_text(node, offset)
        if node and node.text ~= nil and node.tag == nil then
            return node, offset
        end
        if node then
            local t, off = find_text_target(node, nil, offset or 0)
            if t then
                return t, off
            end
        end
        return node, offset
    end

    local t0, o0 = ensure_text(start_node, tonumber(s_off) or 0)
    local t1, o1 = ensure_text(end_node, tonumber(e_off) or tonumber(s_off) or 0)
    if not t0 or t0.tag ~= nil then
        -- parent was element; first text child
        t0, o0 = find_text_target(parent, nil, tonumber(s_off) or 0)
    end
    if not t1 or t1.tag ~= nil then
        t1, o1 = t0, o0
    end
    if not t0 then
        return nil, nil, "no text node"
    end

    local xp0 = text_node_to_xpointer(fragment, t0, o0)
    local xp1 = text_node_to_xpointer(fragment, t1 or t0, o1 or o0)
    if not xp0 then
        return nil, nil, "xpointer build failed"
    end
    logger.info("Zotero: CFI→xpointer ", cfi, " → ", xp0, " .. ", xp1)
    return xp0, xp1 or xp0, nil
end

return EpubCfi
