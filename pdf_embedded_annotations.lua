-- Extract markup annotations embedded in a PDF file.
-- Uses KOReader/MuPDF getEmbeddedAnnotations when available, plus a fast scan of
-- vendor metadata (/onyxtag, etc.) and standard markup subtypes. Adapts drawer
-- and text extraction to the annotation type found. Non-UTF-8 quote bytes
-- (e.g. Windows-1252) are converted for KOReader display.

local JSON = require("json")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local PdfEmbedded = {}

-- Cache: path -> { mtime=number, size=number, list=table }
local _list_cache = {}
local CHUNK_OBJS = 280

-- MuPDF annot types: highlight=8, underline=9, squiggly=10, strikeout=11
local TYPE_TO_DRAWER = {
    [8] = "lighten",
    [9] = "underscore",
    [10] = "underscore",
    [11] = "strikeout",
    highlight = "lighten",
    underline = "underscore",
    squiggly = "underscore",
    strikeout = "strikeout",
    strike_out = "strikeout",
}

-- CP1252 C1 range (0x80-0x9F) → Unicode codepoints (nil = use Latin-1 / skip)
local CP1252_C1 = {
    [0x80] = 0x20AC, -- €
    [0x82] = 0x201A, -- ‚
    [0x83] = 0x0192, -- ƒ
    [0x84] = 0x201E, -- „
    [0x85] = 0x2026, -- …
    [0x86] = 0x2020, -- †
    [0x87] = 0x2021, -- ‡
    [0x88] = 0x02C6, -- ˆ
    [0x89] = 0x2030, -- ‰
    [0x8A] = 0x0160, -- Š
    [0x8B] = 0x2039, -- ‹
    [0x8C] = 0x0152, -- Œ
    [0x8E] = 0x017D, -- Ž
    [0x91] = 0x2018, -- ‘
    [0x92] = 0x2019, -- ’
    [0x93] = 0x201C, -- “
    [0x94] = 0x201D, -- ”
    [0x95] = 0x2022, -- •
    [0x96] = 0x2013, -- –
    [0x97] = 0x2014, -- —
    [0x98] = 0x02DC, -- ˜
    [0x99] = 0x2122, -- ™
    [0x9A] = 0x0161, -- š
    [0x9B] = 0x203A, -- ›
    [0x9C] = 0x0153, -- œ
    [0x9E] = 0x017E, -- ž
    [0x9F] = 0x0178, -- Ÿ
    -- Some writers store apostrophe as 0x90
    [0x90] = 0x2019,
}

local function unicodeToUtf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    end
    return "?"
end

local function isValidUtf8(s)
    if type(s) ~= "string" then
        return false
    end
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        if c < 0x80 then
            i = i + 1
        elseif c >= 0xC2 and c <= 0xDF and i + 1 <= n then
            local c2 = s:byte(i + 1)
            if c2 < 0x80 or c2 > 0xBF then
                return false
            end
            i = i + 2
        elseif c >= 0xE0 and c <= 0xEF and i + 2 <= n then
            local c2, c3 = s:byte(i + 1, i + 2)
            if c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF then
                return false
            end
            if c == 0xE0 and c2 < 0xA0 then
                return false
            end
            i = i + 3
        elseif c >= 0xF0 and c <= 0xF4 and i + 3 <= n then
            local c2, c3, c4 = s:byte(i + 1, i + 3)
            if c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF or c4 < 0x80 or c4 > 0xBF then
                return false
            end
            i = i + 4
        else
            return false
        end
    end
    return true
end

-- Convert Windows-1252 / Latin-1 bytes to UTF-8 (KOReader display charset).
local function cp1252ToUtf8(s)
    if not s or s == "" then
        return s
    end
    local parts = {}
    for i = 1, #s do
        local b = s:byte(i)
        if b < 0x80 then
            parts[#parts + 1] = string.char(b)
        else
            local cp = CP1252_C1[b]
            if not cp then
                cp = b -- Latin-1 for 0xA0-0xFF
            end
            parts[#parts + 1] = unicodeToUtf8(cp)
        end
    end
    return table.concat(parts)
end

local function ensureUtf8(s)
    if s == nil or s == "" then
        return s
    end
    s = tostring(s)
    if isValidUtf8(s) then
        return s
    end
    return cp1252ToUtf8(s)
end

local function subtypeToDrawer(subtype, onyx_type)
    if type(onyx_type) == "string" and string.lower(onyx_type) == "highlight" then
        return "lighten"
    end
    if type(subtype) == "number" then
        return TYPE_TO_DRAWER[subtype] or "lighten"
    end
    local s = string.lower(tostring(subtype or ""))
    return TYPE_TO_DRAWER[s] or "lighten"
end

local function boxesOverlap(a, b, tol)
    tol = tol or 3
    if not a or not b or #a == 0 or #b == 0 then
        return false
    end
    local function bounds(boxes)
        local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for _, box in ipairs(boxes) do
            local x = tonumber(box.x) or 0
            local y = tonumber(box.y) or 0
            local w = tonumber(box.w) or 0
            local h = tonumber(box.h) or 0
            if x < x0 then x0 = x end
            if y < y0 then y0 = y end
            if x + w > x1 then x1 = x + w end
            if y + h > y1 then y1 = y + h end
        end
        return x0, y0, x1, y1
    end
    local ax0, ay0, ax1, ay1 = bounds(a)
    local bx0, by0, bx1, by1 = bounds(b)
    return not (ax1 < bx0 - tol or bx1 < ax0 - tol or ay1 < by0 - tol or by1 < ay0 - tol)
end

local function quadPointsToPboxesSafe(nums)
    local pboxes = {}
    if not nums or #nums < 8 then
        return pboxes
    end
    for i = 1, #nums - 7, 8 do
        local xmin, xmax = nums[i], nums[i]
        local ymin, ymax = nums[i + 1], nums[i + 1]
        for j = 0, 7, 2 do
            local x = nums[i + j]
            local y = nums[i + j + 1]
            if x < xmin then xmin = x end
            if x > xmax then xmax = x end
            if y < ymin then ymin = y end
            if y > ymax then ymax = y end
        end
        table.insert(pboxes, {
            x = xmin,
            y = ymin,
            w = math.max(1, xmax - xmin),
            h = math.max(1, ymax - ymin),
        })
    end
    return pboxes
end

local function parseNumberList(s)
    local nums = {}
    if not s then
        return nums
    end
    for n in string.gmatch(s, "[%-%d%.]+") do
        local v = tonumber(n)
        if v then
            table.insert(nums, v)
        end
    end
    return nums
end

local function unescapePdfForJson(s)
    if not s then
        return ""
    end
    s = s:gsub("\\(%d%d%d)", function(oct)
        return string.char(tonumber(oct, 8) or 0)
    end)
    s = s:gsub("\\(%d%d)", function(oct)
        return string.char(tonumber(oct, 8) or 0)
    end)
    s = s:gsub("\\(%d)", function(oct)
        return string.char(tonumber(oct, 8) or 0)
    end)
    s = s:gsub("\\([()\\])", function(c)
        return c
    end)
    return s
end

local function decodeOnyxtag(raw)
    if not raw or raw == "" then
        return nil
    end
    local cleaned = unescapePdfForJson(raw)
    -- Vendor JSON is often Windows-1252. Convert BEFORE JSON.decode, otherwise
    -- invalid bytes become U+FFFD () and accents are lost forever.
    if not isValidUtf8(cleaned) then
        cleaned = cp1252ToUtf8(cleaned)
    end
    local ok, tag = pcall(JSON.decode, cleaned)
    if not ok or type(tag) ~= "table" then
        return nil
    end
    local extra = tag.extra_attr
    if type(extra) == "string" and extra ~= "" then
        if not isValidUtf8(extra) then
            extra = cp1252ToUtf8(extra)
        end
        local ok2, extra_t = pcall(JSON.decode, extra)
        if ok2 and type(extra_t) == "table" then
            tag._extra = extra_t
        end
    elseif type(extra) == "table" then
        tag._extra = extra
    end
    return tag
end

local function onyxtagQuote(tag)
    if not tag or not tag._extra then
        return nil
    end
    local q = tag._extra.quote
    if q and q ~= "" then
        return ensureUtf8(tostring(q):gsub("[\r\n]+", " "))
    end
    return nil
end

local function onyxtagUuid(tag)
    if not tag then
        return nil
    end
    if tag._extra and tag._extra.uuid then
        return tostring(tag._extra.uuid)
    end
    if tag.id then
        return tostring(tag.id)
    end
    return nil
end

local function extractBalancedParen(data, open_paren)
    local depth, i = 1, open_paren + 1
    local n = #data
    while i <= n and depth > 0 do
        local ch = data:sub(i, i)
        if ch == "\\" then
            i = i + 2
        elseif ch == "(" then
            depth = depth + 1
            i = i + 1
        elseif ch == ")" then
            depth = depth - 1
            i = i + 1
        else
            i = i + 1
        end
    end
    if depth ~= 0 then
        return nil
    end
    return data:sub(open_paren + 1, i - 2)
end

local function unescapePdfString(s)
    if not s then
        return ""
    end
    s = unescapePdfForJson(s)
    s = s:gsub("\\([nrtbf])", function(c)
        if c == "n" then
            return "\n"
        elseif c == "r" then
            return "\r"
        elseif c == "t" then
            return "\t"
        elseif c == "b" then
            return "\b"
        elseif c == "f" then
            return "\f"
        end
        return c
    end)
    return s
end

local function readFileBinary(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

local function fileMtime(path)
    local ok, attr = pcall(lfs.attributes, path, "modification")
    if ok then
        return attr
    end
    return nil
end

local function fileSize(path)
    local ok, attr = pcall(lfs.attributes, path, "size")
    if ok then
        return attr
    end
    return nil
end

local function cacheDir()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage then
        return nil
    end
    local base = DataStorage:getDataDir() .. "/zotero/pdf_annots_cache"
    pcall(lfs.mkdir, DataStorage:getDataDir() .. "/zotero")
    pcall(lfs.mkdir, base)
    return base
end

local function pathHash(path)
    local h = 5381
    for i = 1, #path do
        h = ((h * 33) + path:byte(i)) % 2147483647
    end
    return string.format("%08x", h)
end

local function diskCachePath(file_path)
    local dir = cacheDir()
    if not dir or not file_path then
        return nil
    end
    return dir .. "/" .. pathHash(file_path) .. ".json"
end

local function serializeListForCache(list)
    local out = {}
    for _, ann in ipairs(list or {}) do
        table.insert(out, {
            pageno = ann.pageno,
            page = ann.page or ann.pageno,
            pboxes = ann.pboxes,
            drawer = ann.drawer,
            text = ann.text,
            note = ann.note,
            uuid = ann.uuid,
            _fromPdfEmbedded = true,
            _pdfObjNum = ann._pdfObjNum,
            _pdfAnnotId = ann._pdfAnnotId,
            _pageUncertain = ann._pageUncertain,
            _pageFromScan = ann._pageFromScan,
            _pdfDeleteUnsafe = ann._pdfDeleteUnsafe,
        })
    end
    return out
end

local function writeDiskCache(file_path, mtime, size, list)
    local path = diskCachePath(file_path)
    if not path then
        return
    end
    local payload = {
        file = file_path,
        mtime = mtime,
        size = size,
        list = serializeListForCache(list),
    }
    local ok, encoded = pcall(JSON.encode, payload)
    if not ok or type(encoded) ~= "string" then
        return
    end
    local f = io.open(path, "wb")
    if not f then
        return
    end
    f:write(encoded)
    f:close()
end

local function readDiskCache(file_path, mtime, size)
    local path = diskCachePath(file_path)
    if not path then
        return nil
    end
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then
        return nil
    end
    local ok, payload = pcall(JSON.decode, raw)
    if not ok or type(payload) ~= "table" then
        return nil
    end
    if payload.file ~= file_path or payload.mtime ~= mtime or payload.size ~= size then
        return nil
    end
    if type(payload.list) ~= "table" then
        return nil
    end
    return payload.list
end

local function removeDiskCache(file_path)
    local path = diskCachePath(file_path)
    if path then
        pcall(os.remove, path)
    end
end

local function parseMarkupFromBody(obj_num, body)
    local subtype = body:match("/Subtype%s*/(%w+)")
    local sl = subtype and string.lower(subtype) or ""
    if not (sl == "highlight" or sl == "underline" or sl == "squiggly"
        or sl == "strikeout" or sl == "strike_out") then
        return nil
    end
    local qp_str = body:match("/QuadPoints%s*%[([^%]]*)%]")
    local rect_str = body:match("/Rect%s*%[([^%]]*)%]")
    local pboxes = quadPointsToPboxesSafe(parseNumberList(qp_str))
    if #pboxes == 0 and rect_str then
        local r = parseNumberList(rect_str)
        if #r >= 4 then
            local xmin, ymin = math.min(r[1], r[3]), math.min(r[2], r[4])
            local xmax, ymax = math.max(r[1], r[3]), math.max(r[2], r[4])
            pboxes = {{
                x = xmin,
                y = ymin,
                w = math.max(1, xmax - xmin),
                h = math.max(1, ymax - ymin),
            }}
        end
    end
    local contents = body:match("/Contents%s*%((.-)%)%s*/")
        or body:match("/Contents%s*%((.-)%)%s*>>")
        or body:match("/Contents%s*%((.-)%)")
    contents = unescapePdfString(contents or "")
    if contents == "" then
        contents = nil
    else
        contents = ensureUtf8(contents)
    end
    local onyx_raw = nil
    local ostart = body:find("/onyxtag%s*%(", 1)
    if ostart then
        local open_paren = body:find("%(", ostart)
        if open_paren then
            onyx_raw = extractBalancedParen(body, open_paren)
        end
    end
    local tag = decodeOnyxtag(onyx_raw)
    return {
        obj_num = obj_num,
        subtype = sl,
        pboxes = pboxes,
        contents = contents,
        quote = onyxtagQuote(tag) or contents,
        uuid = onyxtagUuid(tag),
        onyxtag = tag,
        drawer = subtypeToDrawer(sl, tag and tag.type),
    }
end

local function maybeIndexArrayObj(obj_num, body, array_objs)
    local trimmed = body:match("^%s*(%[)")
    if not trimmed then
        return
    end
    -- Indirect Annots arrays are bare [ N 0 R … ] objects.
    if body:find("/Type%s*/", 1) or body:find("/Subtype%s*/", 1) then
        return
    end
    local refs = {}
    for ref in body:gmatch("(%d+)%s+0%s+R") do
        table.insert(refs, tonumber(ref))
    end
    if #refs > 0 then
        array_objs[obj_num] = refs
    end
end

local function bodyWorthIndexing(body)
    if not body then
        return false
    end
    if body:match("^%s*%[") then
        return true
    end
    if body:find("/Type%s*/Catalog", 1)
        or body:find("/Type%s*/Pages", 1)
        or body:find("/Type%s*/Page[%s/>]", 1)
        or body:find("/Kids", 1, true)
        or body:find("/Annots", 1, true)
        or body:find("/Pages%s+", 1)
        or body:find("/Subtype%s*/", 1)
        or body:find("/onyxtag", 1, true)
    then
        return true
    end
    return false
end

-- Index one PDF object (last write wins for incremental updates).
local function ingestObject(obj_num, body, state)
    if bodyWorthIndexing(body) then
        state.obj_bodies[obj_num] = body
        maybeIndexArrayObj(obj_num, body, state.array_objs)
    end
    local ann = parseMarkupFromBody(obj_num, body)
    if ann then
        -- Replace prior definition of same obj_num if re-saved.
        local replaced = false
        for i, prev in ipairs(state.results) do
            if prev.obj_num == obj_num then
                state.results[i] = ann
                replaced = true
                break
            end
        end
        if not replaced then
            table.insert(state.results, ann)
        end
    end
    state.objs_seen = (state.objs_seen or 0) + 1
end

-- Walk up to CHUNK_OBJS objects from state.pos; returns true if more remain.
local function walkObjectChunk(state, limit)
    local data = state.data
    local n = 0
    limit = limit or CHUNK_OBJS
    while n < limit do
        local s, e, obj_num = data:find("(%d+)%s+0%s+obj", state.pos)
        if not s then
            state.pos = #data + 1
            return false
        end
        local end_s = data:find("endobj", e + 1, true)
        if not end_s then
            state.pos = #data + 1
            return false
        end
        local body = data:sub(e + 1, end_s - 1)
        state.pos = end_s + 6
        ingestObject(tonumber(obj_num), body, state)
        n = n + 1
    end
    return state.pos <= #data
end

local function findCatalogRoot(data, obj_bodies)
    local last_root = nil
    for root in data:gmatch("/Root%s+(%d+)%s+0%s+R") do
        last_root = tonumber(root)
    end
    if last_root and obj_bodies[last_root] then
        return last_root
    end
    for num, body in pairs(obj_bodies) do
        if body:find("/Type%s*/Catalog", 1) then
            return num
        end
    end
    return nil
end

local function kidsRefList(body, obj_bodies, array_objs)
    if not body then
        return nil
    end
    local kids = body:match("/Kids%s*%[([^%]]*)%]")
    if kids then
        return kids
    end
    local iref = body:match("/Kids%s+(%d+)%s+0%s+R")
    if not iref then
        return nil
    end
    local n = tonumber(iref)
    local arr = array_objs and array_objs[n]
    if arr then
        local parts = {}
        for _, r in ipairs(arr) do
            table.insert(parts, tostring(r) .. " 0 R")
        end
        return table.concat(parts, " ")
    end
    local ab = obj_bodies and obj_bodies[n]
    if ab then
        return ab:match("%[([^%]]*)%]") or ab
    end
    return nil
end

local function flattenPageTree(obj_bodies, obj_num, out, visited, array_objs)
    if not obj_num or visited[obj_num] then
        return
    end
    visited[obj_num] = true
    local body = obj_bodies[obj_num]
    if not body then
        return
    end
    local kids = kidsRefList(body, obj_bodies, array_objs)
    if kids then
        for ref in kids:gmatch("(%d+)%s+0%s+R") do
            flattenPageTree(obj_bodies, tonumber(ref), out, visited, array_objs)
        end
    else
        table.insert(out, obj_num)
    end
end

local function annotRefsFromPageBody(body, array_objs)
    local refs = {}
    local inline = body:match("/Annots%s*%[([^%]]*)%]")
    if inline then
        for ref in inline:gmatch("(%d+)%s+0%s+R") do
            table.insert(refs, tonumber(ref))
        end
        return refs
    end
    local iref = body:match("/Annots%s*(%d+)%s+0%s+R")
    if iref then
        local arr = array_objs[tonumber(iref)]
        if arr then
            for _, r in ipairs(arr) do
                table.insert(refs, r)
            end
        end
    end
    return refs
end

-- Map annot obj → 1-based page via /Root → /Pages → /Kids (ignores stale Page objs).
local function mapPagesFromTree(state)
    local obj_to_page = {}
    local root = findCatalogRoot(state.data, state.obj_bodies)
    if not root then
        return obj_to_page, 0
    end
    local cat = state.obj_bodies[root]
    local pages_ref = cat and cat:match("/Pages%s+(%d+)%s+0%s+R")
    if not pages_ref then
        return obj_to_page, 0
    end
    local page_objs = {}
    flattenPageTree(state.obj_bodies, tonumber(pages_ref), page_objs, {}, state.array_objs)
    for page_i, page_obj in ipairs(page_objs) do
        local body = state.obj_bodies[page_obj]
        if body then
            local refs = annotRefsFromPageBody(body, state.array_objs)
            for _, ref in ipairs(refs) do
                local nested = state.array_objs[ref]
                if nested then
                    for _, a in ipairs(nested) do
                        obj_to_page[a] = page_i
                    end
                else
                    obj_to_page[ref] = page_i
                end
            end
        end
    end
    return obj_to_page, #page_objs
end

local function applyPageMap(results, obj_to_page, doc_page_count)
    for _, ann in ipairs(results) do
        local page = obj_to_page[ann.obj_num]
        if page and doc_page_count and page > doc_page_count then
            ann.pageno = nil
            ann._pageUncertain = true
            ann._pageFromScan = false
        else
            ann.pageno = page
            ann._pageFromScan = page ~= nil
            ann._pageUncertain = page == nil
        end
    end
end

local function docPageCount(ui)
    if ui and ui.document and ui.document.info then
        return tonumber(ui.document.info.number_of_pages)
    end
    return nil
end

-- Walk PDF objects for markup annots, then map obj → page via page tree.
function PdfEmbedded.scanFile(file_path, ui)
    local data = readFileBinary(file_path)
    if not data or #data == 0 then
        return {}
    end
    local state = {
        data = data,
        pos = 1,
        obj_bodies = {},
        array_objs = {},
        results = {},
        objs_seen = 0,
    }
    while walkObjectChunk(state, 1000000) do
        -- sync: drain all chunks
    end
    local obj_to_page = mapPagesFromTree(state)
    applyPageMap(state.results, obj_to_page, docPageCount(ui))
    return state.results
end

local function listFromDocumentApi(document)
    if not document then
        return nil
    end
    -- Only the document-level API (one MuPDF pass). NEVER open every page
    -- individually — that freezes KOReader on large PDFs (200+ pages).
    if type(document.getEmbeddedAnnotations) == "function" then
        local ok, res = pcall(function()
            return document:getEmbeddedAnnotations()
        end)
        if ok and type(res) == "table" then
            return res
        end
    end
    return nil
end

local function normalizeApiAnnot(pageno, annot)
    local boxes = annot.boxes or annot.pboxes or {}
    local contents = annot.contents
    if contents == "" then
        contents = nil
    else
        contents = ensureUtf8(contents)
    end
    return {
        pageno = pageno,
        page = pageno,
        pboxes = boxes,
        drawer = subtypeToDrawer(annot.type),
        text = contents,
        note = contents,
        _fromPdfEmbedded = true,
        _pdfFromApi = true,
        _pdfApiType = annot.type,
    }
end

local function fingerprint(ann)
    if ann.uuid then
        return "u:" .. tostring(ann.uuid)
    end
    local page = tostring(ann.pageno or ann.page or "")
    local t = tostring(ann.text or ann.quote or ann.note or "")
    local box0 = ann.pboxes and ann.pboxes[1]
    local bx = box0 and string.format("%.1f:%.1f", box0.x or 0, box0.y or 0) or ""
    return "p:" .. page .. "|" .. bx .. "|" .. t:sub(1, 40)
end

local function enrichWithScan(api_list, scanned, has_api)
    if not scanned or #scanned == 0 then
        return api_list
    end
    local used_scan = {}
    for _, ann in ipairs(api_list) do
        local best, best_i
        for i, sc in ipairs(scanned) do
            if not used_scan[i] and boxesOverlap(ann.pboxes, sc.pboxes, 6) then
                if sc.pageno and ann.pageno and sc.pageno == ann.pageno then
                    best, best_i = sc, i
                    break
                elseif not best then
                    best, best_i = sc, i
                end
            end
        end
        if best then
            used_scan[best_i] = true
            local quote = best.quote and ensureUtf8(best.quote) or nil
            if quote and (not ann.text or ann.text == "" or ann.text == ann.note) then
                ann.text = quote
            end
            if best.contents and (not ann.note or ann.note == "") then
                ann.note = ensureUtf8(best.contents)
            end
            ann.uuid = best.uuid
            if best.onyxtag and best.onyxtag.type then
                ann.drawer = subtypeToDrawer(best.subtype, best.onyxtag.type)
            else
                ann.drawer = best.drawer or ann.drawer
            end
            if best.pageno and not ann.pageno then
                ann.pageno = best.pageno
                ann.page = best.pageno
            end
            ann._pdfObjNum = best.obj_num
            ann._pdfAnnotId = best.uuid or tostring(best.obj_num or "") or ann._pdfAnnotId
            ann._pageFromScan = best._pageFromScan
        end
    end
    if not has_api then
        for i, sc in ipairs(scanned) do
            -- Prefer hits with a resolved page (obj→/Annots map). Keep
            -- page-less ones only if they have text so the panel can still list them.
            if not used_scan[i] and sc.pboxes and #sc.pboxes > 0
                and (sc.pageno or sc.quote or sc.contents) then
                table.insert(api_list, {
                    pageno = sc.pageno,
                    page = sc.pageno,
                    pboxes = sc.pboxes,
                    drawer = sc.drawer or "lighten",
                    text = ensureUtf8(sc.quote or sc.contents),
                    note = ensureUtf8(sc.contents),
                    uuid = sc.uuid,
                    _fromPdfEmbedded = true,
                    _pdfObjNum = sc.obj_num,
                    _pdfAnnotId = sc.uuid or tostring(sc.obj_num or "") or fingerprint(sc),
                    _pageUncertain = sc.pageno == nil,
                    _pageFromScan = sc._pageFromScan,
                })
            end
        end
    end
    return api_list
end

-- Optional MuPDF text fill — ONLY with trustworthy page+boxes from the document API.
-- Scan-derived QuadPoints can differ from KOReader coords and crash native code.
local function fillTextFromDocument(ui, ann)
    if not ann or not ann._pdfFromApi then
        if ann and ann.text then
            ann.text = ensureUtf8(ann.text)
        end
        return
    end
    if ann.text and ann.text ~= "" then
        ann.text = ensureUtf8(ann.text)
        return
    end
    if not ui or not ui.document or type(ui.document.getTextFromPositions) ~= "function" then
        return
    end
    local pboxes = ann.pboxes
    local page = tonumber(ann.pageno or ann.page)
    if not page or not pboxes or #pboxes == 0 then
        return
    end
    local first, last = pboxes[1], pboxes[#pboxes]
    local pos0 = {
        page = page,
        x = (first.x or 0) + 1,
        y = (first.y or 0) + 1,
    }
    local pos1 = {
        page = page,
        x = (last.x or 0) + (last.w or 1) - 2,
        y = (last.y or 0) + (last.h or 1) - 2,
    }
    local ok, got = pcall(function()
        return ui.document:getTextFromPositions(pos0, pos1)
    end)
    if ok and got and type(got.text) == "string" and got.text ~= "" then
        ann.text = ensureUtf8(got.text:gsub("%s+", " "):match("^%s*(.-)%s*$") or got.text)
        ann.pos0 = pos0
        ann.pos1 = pos1
    end
end

function PdfEmbedded.isDuplicateOfLocal(embedded, local_ann)
    if not embedded or not local_ann then
        return false
    end
    local ep = tonumber(embedded.pageno or embedded.page)
    local lp = tonumber(local_ann.pageno or local_ann.page)
    if ep and lp and ep ~= lp then
        return false
    end
    if local_ann.pboxes and embedded.pboxes and boxesOverlap(embedded.pboxes, local_ann.pboxes, 4) then
        return true
    end
    local et = string.lower(tostring(embedded.text or ""))
    local lt = string.lower(tostring(local_ann.text or ""))
    if et ~= "" and lt ~= "" and (et == lt or lt:find(et:sub(1, 40), 1, true) or et:find(lt:sub(1, 40), 1, true)) then
        if ep and lp and ep == lp then
            return true
        end
    end
    return false
end

function PdfEmbedded.dedupeAgainstLocal(embedded_list, local_list)
    local out = {}
    for _, emb in ipairs(embedded_list or {}) do
        local dup = false
        for _, loc in ipairs(local_list or {}) do
            if PdfEmbedded.isDuplicateOfLocal(emb, loc) then
                dup = true
                break
            end
        end
        if not dup then
            table.insert(out, emb)
        end
    end
    return out
end

local function finalizeScannedList(ui, scanned)
    local list = enrichWithScan({}, scanned or {}, false)
    local page_count = docPageCount(ui)
    for _, ann in ipairs(list) do
        fillTextFromDocument(ui, ann)
        if ann.text then
            ann.text = ensureUtf8(ann.text)
        end
        if ann.note then
            ann.note = ensureUtf8(ann.note)
        end
        local page = tonumber(ann.pageno or ann.page)
        if page and page_count and page > page_count then
            ann.pageno = nil
            ann.page = nil
            ann._pageUncertain = true
        end
        ann._fromPdfEmbedded = true
        ann._pdfAnnotId = ann._pdfAnnotId or fingerprint(ann)
        if not ann._pdfFromApi then
            ann._pdfDeleteUnsafe = true
        end
    end
    local seen = {}
    local unique = {}
    for _, ann in ipairs(list) do
        local fp = fingerprint(ann)
        if not seen[fp] then
            seen[fp] = true
            table.insert(unique, ann)
        end
    end
    table.sort(unique, function(a, b)
        local pa = tonumber(a.pageno or a.page) or 0
        local pb = tonumber(b.pageno or b.page) or 0
        if pa ~= pb then
            return pa < pb
        end
        return tostring(a.text or "") < tostring(b.text or "")
    end)
    return unique
end

local function storeListCache(file_path, mtime, size, list)
    _list_cache[file_path] = { mtime = mtime, size = size, list = list }
    writeDiskCache(file_path, mtime, size, list)
end

local function tryLoadCachedList(file_path, mtime, size)
    local cached = _list_cache[file_path]
    if cached and cached.mtime == mtime and cached.size == size and type(cached.list) == "table" then
        return cached.list
    end
    local disk = readDiskCache(file_path, mtime, size)
    if disk then
        _list_cache[file_path] = { mtime = mtime, size = size, list = disk }
        return disk
    end
    return nil
end

--- List embedded PDF markup annotations for an open reader UI.
-- Fast path: binary scan only. getEmbeddedAnnotations walks every page and freezes
-- large PDFs on e-ink — use it only for small documents as optional enrichment.
function PdfEmbedded.list(ui)
    if not ui or not ui.document or not ui.document.is_pdf then
        return {}
    end
    local file_path = ui.document.file
    local mtime = fileMtime(file_path)
    local size = fileSize(file_path)
    local hit = tryLoadCachedList(file_path, mtime, size)
    if hit then
        return hit
    end

    local scanned = {}
    local ok_scan, scan_res = pcall(PdfEmbedded.scanFile, file_path, ui)
    if ok_scan and type(scan_res) == "table" then
        scanned = scan_res
    elseif not ok_scan then
        logger.warn("Zotero: PDF embedded scan failed: ", scan_res)
    end

    local unique = finalizeScannedList(ui, scanned)
    storeListCache(file_path, mtime, size, unique)
    return unique
end

--- Cooperative chunked scan. opts: on_progress(pct, annot_count), on_done(list), cancelled()
function PdfEmbedded.listAsync(ui, opts)
    opts = opts or {}
    local on_progress = opts.on_progress
    local on_done = opts.on_done
    local cancelled = opts.cancelled
    local function done(list)
        if on_done then
            on_done(list or {})
        end
    end
    if not ui or not ui.document or not ui.document.is_pdf then
        done({})
        return
    end
    local file_path = ui.document.file
    local mtime = fileMtime(file_path)
    local size = fileSize(file_path)
    local hit = tryLoadCachedList(file_path, mtime, size)
    if hit then
        if on_progress then
            on_progress(100, #hit)
        end
        done(hit)
        return
    end

    local UIManager = require("ui/uimanager")
    local data = readFileBinary(file_path)
    if not data or #data == 0 then
        done({})
        return
    end
    local state = {
        data = data,
        pos = 1,
        obj_bodies = {},
        array_objs = {},
        results = {},
        objs_seen = 0,
        file_path = file_path,
        mtime = mtime,
        size = size,
        data_len = #data,
    }

    local function tick()
        if cancelled and cancelled() then
            return
        end
        local more = walkObjectChunk(state, CHUNK_OBJS)
        local pct = math.min(99, math.floor((state.pos / math.max(1, state.data_len)) * 90))
        if on_progress then
            on_progress(pct, #state.results)
        end
        if more then
            UIManager:scheduleIn(0, tick)
            return
        end
        -- Resolve pages on tree (fast once objects are indexed).
        if on_progress then
            on_progress(95, #state.results)
        end
        local obj_to_page = mapPagesFromTree(state)
        applyPageMap(state.results, obj_to_page, docPageCount(ui))
        local unique = finalizeScannedList(ui, state.results)
        storeListCache(file_path, mtime, size, unique)
        if on_progress then
            on_progress(100, #unique)
        end
        done(unique)
    end

    UIManager:scheduleIn(0, tick)
end

function PdfEmbedded.clearCache(file_path)
    if file_path then
        _list_cache[file_path] = nil
        removeDiskCache(file_path)
    else
        _list_cache = {}
        local dir = cacheDir()
        if dir then
            for name in lfs.dir(dir) do
                if name ~= "." and name ~= ".." then
                    pcall(os.remove, dir .. "/" .. name)
                end
            end
        end
    end
end

function PdfEmbedded.deleteFromPdf(ui, ann)
    if not ui or not ui.document or not ann then
        return false, "missing ui/document/ann"
    end
    local page = tonumber(ann.pageno or ann.page)
    local pboxes = ann.pboxes
    if not page or not pboxes or #pboxes == 0 then
        return false, "missing page/pboxes"
    end
    local ok, err = pcall(function()
        if type(ui.document.deleteHighlight) == "function" then
            ui.document:deleteHighlight(page, { pboxes = pboxes, drawer = ann.drawer })
            if ui.document.is_edited and type(ui.document.writeDocument) == "function" then
                ui.document:writeDocument()
                ui.document.is_edited = false
            end
            return
        end
        if ui.highlight and ui.highlight.writePdfAnnotation then
            local prev = nil
            if ui.highlight.highlight_write_into_pdf == false then
                prev = false
                ui.highlight.highlight_write_into_pdf = true
            end
            ui.highlight:writePdfAnnotation("delete", {
                pageno = page,
                page = page,
                pboxes = pboxes,
                drawer = ann.drawer or "lighten",
            })
            if prev == false then
                ui.highlight.highlight_write_into_pdf = false
            end
            if ui.document.writeDocument then
                ui.document.is_edited = true
                ui.document:writeDocument()
                ui.document.is_edited = false
            end
        else
            error("no deleteHighlight / writePdfAnnotation")
        end
    end)
    if not ok then
        return false, err
    end
    if ui.document and ui.document.file then
        PdfEmbedded.clearCache(ui.document.file)
    end
    return true
end

function PdfEmbedded.toSidecarAnnotation(ui, emb)
    if not emb then
        return nil
    end
    local page = tonumber(emb.pageno or emb.page) or 1
    local pboxes = emb.pboxes or {}
    local text = ensureUtf8(emb.text or emb.quote or "")
    local note = emb.note and ensureUtf8(emb.note) or nil
    if note == text then
        note = nil
    end

    local pos0, pos1 = emb.pos0, emb.pos1
    if #pboxes > 0 and (not pos0 or not pos1) then
        local first = pboxes[1]
        local last = pboxes[#pboxes]
        pos0 = {
            page = page,
            x = (first.x or 0) + 1,
            y = (first.y or 0) + 1,
        }
        pos1 = {
            page = page,
            x = (last.x or 0) + (last.w or 1) - 2,
            y = (last.y or 0) + (last.h or 1) - 2,
        }
    end
    if (not text or text == "") and ui and ui.document and pos0 and pos1 then
        local ok, got = pcall(function()
            return ui.document:getTextFromPositions(pos0, pos1)
        end)
        if ok and got and got.text and got.text ~= "" then
            text = ensureUtf8(got.text)
        end
    end

    local Ann = nil
    pcall(function()
        Ann = require("annotations")
    end)

    return {
        drawer = emb.drawer or "lighten",
        color = "yellow",
        text = text,
        note = note,
        pageno = page,
        page = page,
        pboxes = pboxes,
        pos0 = pos0,
        pos1 = pos1,
        datetime = os.date("%Y-%m-%d %H:%M:%S"),
        zoteroDestination = Ann and Ann.DEST_ZOTERO or "zotero",
        _migratedFromPdf = true,
        _pdfAnnotId = emb._pdfAnnotId,
    }
end

return PdfEmbedded
