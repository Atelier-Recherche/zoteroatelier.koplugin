-- Extract markup annotations embedded in a PDF file (Acrobat, KOReader, BOOX/Onyx, …).
-- Uses KOReader/MuPDF getEmbeddedAnnotations when available, plus a binary scan for
-- /onyxtag (BOOX) so citations are recovered when /Contents is empty.

local JSON = require("json")
local logger = require("logger")

local PdfEmbedded = {}

-- MuPDF annot types: highlight=8, underline=9, squiggly=10, strikeout=11
local TYPE_TO_DRAWER = {
    [8] = "lighten",
    [9] = "underscore",
    [10] = "underscore", -- squiggly → underline for KOReader/Zotero
    [11] = "strikeout",
    highlight = "lighten",
    underline = "underscore",
    squiggly = "underscore",
    strikeout = "strikeout",
    strike_out = "strikeout",
}

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
        -- PDF QuadPoints often UL UR LL LR; MuPDF boxes use top-left origin like KOReader pboxes.
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

-- PDF literal escapes that are safe before JSON.parse of an embedded blob:
-- keep \n \r \t as two-char sequences for JSON; only resolve octals and \( \) \\.
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

local function unescapePdfString(s)
    if not s then
        return ""
    end
    s = unescapePdfForJson(s)
    s = s:gsub("\\([nrtbf])", function(c)
        if c == "n" then return "\n"
        elseif c == "r" then return "\r"
        elseif c == "t" then return "\t"
        elseif c == "b" then return "\b"
        elseif c == "f" then return "\f"
        else return c
        end
    end)
    return s
end

local function decodeOnyxtag(raw)
    if not raw or raw == "" then
        return nil
    end
    local cleaned = unescapePdfForJson(raw)
    local ok, tag = pcall(JSON.decode, cleaned)
    if not ok or type(tag) ~= "table" then
        return nil
    end
    local extra = tag.extra_attr
    if type(extra) == "string" and extra ~= "" then
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
    if not tag then
        return nil
    end
    if tag._extra and tag._extra.quote and tag._extra.quote ~= "" then
        return tostring(tag._extra.quote):gsub("[\r\n]+", " ")
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

local function readFileBinary(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

-- Scan PDF bytes for markup Annot dictionaries (and BOOX /onyxtag).
-- Returns list of { subtype, pboxes, contents, onyxtag, uuid, quote, obj_num }
function PdfEmbedded.scanFile(file_path)
    local data = readFileBinary(file_path)
    if not data or #data == 0 then
        return {}
    end
    local results = {}
    -- Iterate object headers; keep a window until endobj
    local pos = 1
    while true do
        local s, e, obj_num = data:find("(%d+)%s+0%s+obj", pos)
        if not s then
            break
        end
        local end_s = data:find("endobj", e + 1, true)
        if not end_s then
            break
        end
        local body = data:sub(e + 1, end_s - 1)
        pos = end_s + 6

        local subtype = body:match("/Subtype%s*/(%w+)")
        local sl = subtype and string.lower(subtype) or ""
        if sl == "highlight" or sl == "underline" or sl == "squiggly"
            or sl == "strikeout" or sl == "strike_out" then
            local qp_str = body:match("/QuadPoints%s*%[([^%]]*)%]")
            local rect_str = body:match("/Rect%s*%[([^%]]*)%]")
            local nums = parseNumberList(qp_str)
            local pboxes = quadPointsToPboxesSafe(nums)
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
            end

            -- Balanced-paren extract: JSON may contain ')' inside quote strings.
            local onyx_raw = nil
            local ostart = body:find("/onyxtag%s*%(", 1)
            if ostart then
                local open_paren = body:find("%(", ostart)
                if open_paren then
                    local depth, i = 1, open_paren + 1
                    while i <= #body and depth > 0 do
                        local ch = body:sub(i, i)
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
                    if depth == 0 then
                        onyx_raw = body:sub(open_paren + 1, i - 2)
                    end
                end
            end
            local tag = decodeOnyxtag(onyx_raw)
            local quote = onyxtagQuote(tag)
            local uuid = onyxtagUuid(tag)

            table.insert(results, {
                obj_num = tonumber(obj_num),
                subtype = sl,
                pboxes = pboxes,
                contents = contents,
                quote = quote,
                uuid = uuid,
                onyxtag = tag,
                drawer = subtypeToDrawer(sl, tag and tag.type),
            })
        end
    end

    -- Indirect Annots arrays: N 0 obj [ M 0 R … ] endobj (common after BOOX incremental save)
    local array_objs = {}
    for a_num, a_body in data:gmatch("(%d+)%s+0%s+obj%s*%[([^%]]*)%]%s*endobj") do
        local refs = {}
        for ref in a_body:gmatch("(%d+)%s+0%s+R") do
            table.insert(refs, tonumber(ref))
        end
        if #refs > 0 then
            array_objs[tonumber(a_num)] = refs
        end
    end

    -- Best-effort page map. Incremental PDFs may contain stale Page objects; prefer
    -- MuPDF getEmbeddedAnnotations for page numbers. Last write wins per annot obj.
    local page_no = 0
    pos = 1
    local obj_to_page = {}
    while true do
        local s, e = data:find("%d+%s+0%s+obj", pos)
        if not s then
            break
        end
        local end_s = data:find("endobj", e + 1, true)
        if not end_s then
            break
        end
        local body = data:sub(e + 1, end_s - 1)
        pos = end_s + 6
        if body:find("/Type%s*/Page[%s/>]", 1)
            and not body:find("/Type%s*/Pages", 1)
            and body:find("/MediaBox", 1, true)
        then
            page_no = page_no + 1
            local refs = {}
            local inline = body:match("/Annots%s*%[([^%]]*)%]")
            if inline then
                for ref in inline:gmatch("(%d+)%s+0%s+R") do
                    table.insert(refs, tonumber(ref))
                end
            else
                local iref = body:match("/Annots%s*(%d+)%s+0%s+R")
                if iref then
                    local arr = array_objs[tonumber(iref)]
                    if arr then
                        for _, r in ipairs(arr) do
                            table.insert(refs, r)
                        end
                    end
                end
            end
            for _, ref in ipairs(refs) do
                local nested = array_objs[ref]
                if nested then
                    for _, a in ipairs(nested) do
                        obj_to_page[a] = page_no
                    end
                else
                    obj_to_page[ref] = page_no
                end
            end
        end
    end
    for _, ann in ipairs(results) do
        ann.pageno = obj_to_page[ann.obj_num]
        ann._pageFromScan = ann.pageno ~= nil
    end
    return results
end

local function listFromDocumentApi(document)
    if not document then
        return nil
    end
    local by_page = nil
    if type(document.getEmbeddedAnnotations) == "function" then
        local ok, res = pcall(function()
            return document:getEmbeddedAnnotations()
        end)
        if ok and type(res) == "table" then
            by_page = res
        end
    end
    -- Fallback: iterate pages if page-level API exists
    if not by_page and document._document and document.info and document.info.number_of_pages then
        local ok_loop, collected = pcall(function()
            local out = {}
            for pageno = 1, document.info.number_of_pages do
                local page = document._document:openPage(pageno)
                if page and type(page.getEmbeddedAnnotations) == "function" then
                    local page_annots = page:getEmbeddedAnnotations()
                    if page_annots then
                        out[pageno] = page_annots
                    end
                end
                if page and page.close then
                    page:close()
                end
            end
            return next(out) and out or nil
        end)
        if ok_loop then
            by_page = collected
        end
    end
    return by_page
end

local function normalizeApiAnnot(pageno, annot)
    local boxes = annot.boxes or annot.pboxes or {}
    local annot_type = annot.type
    local contents = annot.contents
    if contents == "" then
        contents = nil
    end
    return {
        pageno = pageno,
        page = pageno,
        pboxes = boxes,
        drawer = subtypeToDrawer(annot_type),
        text = contents,
        note = contents,
        _fromPdfEmbedded = true,
        _pdfApiType = annot_type,
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
                -- Prefer same page when both known; still allow match if scan page is wrong
                -- (incremental PDFs often mis-number stale Page objects).
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
            if (not ann.text or ann.text == "") and best.quote then
                ann.text = best.quote
            end
            if (not ann.note or ann.note == "") and best.contents then
                ann.note = best.contents
            end
            if best.quote and (not ann.text or ann.text == "") then
                ann.text = best.quote
            elseif best.quote and ann.text == ann.note then
                ann.text = best.quote
            end
            ann.uuid = best.uuid
            -- BOOX stores type=highlight on Squiggly subtype
            if best.onyxtag and best.onyxtag.type then
                ann.drawer = subtypeToDrawer(best.subtype, best.onyxtag.type)
            else
                ann.drawer = best.drawer or ann.drawer
            end
            ann._pdfObjNum = best.obj_num
            ann._pdfAnnotId = best.uuid or tostring(best.obj_num or "")
        end
    end
    -- Without MuPDF API, expose scan hits that have a page guess.
    if not has_api then
        for i, sc in ipairs(scanned) do
            if not used_scan[i] and sc.pageno then
                table.insert(api_list, {
                    pageno = sc.pageno,
                    page = sc.pageno,
                    pboxes = sc.pboxes,
                    drawer = sc.drawer or "lighten",
                    text = sc.quote or sc.contents,
                    note = sc.contents,
                    uuid = sc.uuid,
                    _fromPdfEmbedded = true,
                    _pdfObjNum = sc.obj_num,
                    _pdfAnnotId = sc.uuid or tostring(sc.obj_num or ""),
                    _pageUncertain = true,
                })
            end
        end
    end
    return api_list
end

-- True if sidecar annotation already covers this embedded one.
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

--- List embedded PDF markup annotations for an open reader UI.
-- @return array of annotation-like tables with _fromPdfEmbedded=true
function PdfEmbedded.list(ui)
    if not ui or not ui.document or not ui.document.is_pdf then
        return {}
    end
    local file_path = ui.document.file
    local list = {}

    local by_page = listFromDocumentApi(ui.document)
    local has_api = by_page ~= nil
    if by_page then
        for pageno, page_annots in pairs(by_page) do
            if type(page_annots) == "table" then
                for _, annot in ipairs(page_annots) do
                    table.insert(list, normalizeApiAnnot(tonumber(pageno) or pageno, annot))
                end
            end
        end
    end

    local scanned = {}
    local ok_scan, scan_res = pcall(PdfEmbedded.scanFile, file_path)
    if ok_scan and type(scan_res) == "table" then
        scanned = scan_res
    elseif not ok_scan then
        logger.warn("Zotero: PDF embedded scan failed: ", scan_res)
    end

    list = enrichWithScan(list, scanned, has_api)

    -- Stable unique by fingerprint
    local seen = {}
    local unique = {}
    for _, ann in ipairs(list) do
        local fp = fingerprint(ann)
        if not seen[fp] then
            seen[fp] = true
            ann._pdfAnnotId = ann._pdfAnnotId or fp
            ann._fromPdfEmbedded = true
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

--- Delete an embedded markup annotation from the open PDF (by pboxes).
-- Does not sync to Zotero. Returns true on success.
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
        -- Prefer direct document API (works even if highlight_write_into_pdf is off)
        if type(ui.document.deleteHighlight) == "function" then
            ui.document:deleteHighlight(page, { pboxes = pboxes, drawer = ann.drawer })
            if ui.document.is_edited then
                -- ensure write on close; try immediate write if available
                if type(ui.document.writeDocument) == "function" then
                    ui.document:writeDocument()
                    ui.document.is_edited = false
                end
            end
            return
        end
        if ui.highlight and ui.highlight.writePdfAnnotation then
            local prev = nil
            -- Temporarily force write path if needed
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
    return true
end

--- Build a KOReader sidecar annotation from an embedded PDF annot (for migration).
function PdfEmbedded.toSidecarAnnotation(ui, emb)
    if not emb then
        return nil
    end
    local page = tonumber(emb.pageno or emb.page) or 1
    local pboxes = emb.pboxes or {}
    local text = emb.text or emb.quote or ""
    local note = emb.note
    if note == text then
        note = nil
    end

    local pos0, pos1
    if #pboxes > 0 then
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
        -- Prefer live text extraction when Contents/quote missing
        if (text == nil or text == "") and ui and ui.document and ui.document.getTextFromPositions then
            local ok, got = pcall(function()
                return ui.document:getTextFromPositions(pos0, pos1)
            end)
            if ok and got and got.text and got.text ~= "" then
                text = got.text
            end
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
