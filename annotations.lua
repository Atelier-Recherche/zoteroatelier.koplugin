local Annotations = {}
local DocSettings = require("docsettings")
local JSON = require("json")
local logger = require("logger")

local Z2K_COLORS = {
    ["#ffd400"] = "yellow",
    ["#ff6666"] = "red",
    ["#5fb236"] = "green",
    ["#2ea8e5"] = "blue",
    ["#a28ae5"] = "purple",
    ["#e56eee"] = "red", -- this would be magenta, but that is not in KOreaders palette
    ["#f19837"] = "orange",
    ["#aaaaaa"] = "gray",
    -- Near-black from Zotero / desktop clients → KOReader gray (darkest e-ink underline)
    ["#000000"] = "gray",
    ["#000"] = "gray",
    ["#111111"] = "gray",
    ["#222222"] = "gray",
    ["#333333"] = "gray",
    ["black"] = "gray",
}

-- Zotero only accepts its fixed annotation palette (others → API reject).
-- No pure black in Zotero palette: map black → gray (#aaaaaa).
local K2Z_COLORS = {
    ["red"] = "#ff6666",
    ["orange"] = "#f19837",
    ["yellow"] = "#ffd400",
    ["green"] = "#5fb236",
    ["olive"] = "#5fb236",
    ["cyan"] = "#2ea8e5",
    ["blue"] = "#2ea8e5",
    ["purple"] = "#a28ae5",
    -- Zotero accepts #000000 for underlines (darker on e-ink than palette gray #aaaaaa)
    ["gray"] = "#000000",
    ["grey"] = "#000000",
    ["black"] = "#000000",
    ["magenta"] = "#e56eee",
}

local function mapZoteroColorToKOReader(z_color, fallback)
    local z = string.lower(tostring(z_color or ""))
    if z == "" then
        return fallback
    end
    if Z2K_COLORS[z] then
        return Z2K_COLORS[z]
    end
    -- Hex without leading # or unknown dark → gray (never yellow: that caused e-ink sync flips)
    local hex = z:match("^#?(%x%x%x%x%x%x)$") or z:match("^#?(%x%x%x)$")
    if hex then
        if #hex == 3 then
            hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
        end
        local mapped = Z2K_COLORS["#" .. hex]
        if mapped then
            return mapped
        end
        local r = tonumber(hex:sub(1, 2), 16) or 255
        local g = tonumber(hex:sub(3, 4), 16) or 255
        local b = tonumber(hex:sub(5, 6), 16) or 255
        if (r + g + b) < 120 then
            return "gray"
        end
    end
    return fallback
end

local function mapKOReaderColorToZotero(k_color, fallback_hex)
    local k = string.lower(tostring(k_color or ""))
    if K2Z_COLORS[k] then
        return K2Z_COLORS[k]
    end
    return fallback_hex or K2Z_COLORS["gray"]
end

local K2Z_STYLE = {
    ["underscore"] = "underline",
    ["lighten"] = "highlight",
    ["strikeout"] = "highlight",
    ["invert"] = "highlight",
}

local Z2K_STYLE = {
    ["underline"] = "underscore",
    ["highlight"] = "lighten",
    ["note"] = "lighten",
}

-- Destinations: local (sidecar / PDF write only), zotero (sync only), both
Annotations.DEST_LOCAL = "local"
Annotations.DEST_ZOTERO = "zotero"
Annotations.DEST_BOTH = "both"

function Annotations.normalizeDestination(dest)
    if dest == Annotations.DEST_LOCAL or dest == Annotations.DEST_ZOTERO or dest == Annotations.DEST_BOTH then
        return dest
    end
    return Annotations.DEST_BOTH
end

-- Whether this annotation should be uploaded / updated on Zotero.
-- Missing destination defaults to both (legacy sidecars).
function Annotations.shouldSyncToZotero(annotation)
    if annotation == nil then
        return false
    end
    local dest = Annotations.normalizeDestination(annotation.zoteroDestination)
    return dest == Annotations.DEST_ZOTERO or dest == Annotations.DEST_BOTH
end

function Annotations.shouldWriteIntoPdf(annotation)
    if annotation == nil then
        return false
    end
    local dest = Annotations.normalizeDestination(annotation.zoteroDestination)
    return dest == Annotations.DEST_LOCAL or dest == Annotations.DEST_BOTH
end

local function normalizeMatchText(s)
    if s == nil then
        return ""
    end
    s = string.lower(tostring(s))
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Find a local annotation without zoteroKey that matches page + text (+ note).
-- Returns index in koreaderAnnotations or nil.
function Annotations.findMatchingLocalAnnotation(koreaderAnnotations, zotero_item)
    if koreaderAnnotations == nil or zotero_item == nil or zotero_item.data == nil then
        return nil
    end
    local data = zotero_item.data
    local z_text = normalizeMatchText(data.annotationText)
    local z_note = normalizeMatchText(data.annotationComment)
    local z_page = nil
    if data.annotationPageLabel then
        z_page = tonumber(data.annotationPageLabel)
    end
    if z_page == nil and data.annotationPosition then
        local ok, pos = pcall(JSON.decode, data.annotationPosition)
        if ok and pos and pos.pageIndex ~= nil then
            z_page = tonumber(pos.pageIndex) + 1
        end
    end
    z_page = z_page or 1

    for idx, ann in ipairs(koreaderAnnotations) do
        if ann.zoteroKey == nil then
            local a_page = Annotations.getAnnotationPage(ann)
            local a_text = normalizeMatchText(ann.text)
            local a_note = normalizeMatchText(ann.note)
            if a_page == z_page and a_text == z_text and (z_note == "" or a_note == z_note or a_note == "") then
                return idx
            end
            -- EPUB: also try xpointer match when available
            if data.annotationPosition then
                local ok, pos = pcall(JSON.decode, data.annotationPosition)
                if ok and pos and pos.koreaderPos0 and ann.pos0 and ann.pos0.xpointer
                    and tostring(pos.koreaderPos0) == tostring(ann.pos0.xpointer)
                    and a_text == z_text
                then
                    return idx
                end
            end
        end
    end
    return nil
end

function Annotations.fallbackPageBbox()
    return {
        width = 595,
        height = 842,
        bbox_width = 595,
        bbox_height = 842,
        bbox_x0 = 0,
        bbox_y0 = 0,
        bbox_x1 = 595,
        bbox_y1 = 842,
    }
end

local defaultKColor = "yellow"
local defaultZColor = K2Z_COLORS["gray"]

local function limitDigits(x, num_places)
    local fac = 10 ^ num_places
    return math.floor(x * fac) / fac
end

function Annotations.setDefaultColor(ZColor)
    local hex = mapKOReaderColorToZotero(ZColor, nil)
    if hex then
        defaultZColor = hex
    end
end

-- Get BBOX dimensions for specified pages
-- Returns a table with page numbers as keys, containing:
--   width, height (full page dimensions)
--   bbox_x0, bbox_y0, bbox_x1, bbox_y1 (usedBBox coordinates)
--   bbox_width, bbox_height (calculated from bbox)
-- TODO: Simplify this function and remove extensive logging after testing for a while
function Annotations.getPageDimensions(file, pages)
    if pages == nil or type(pages) ~= "table" then
        logger.warn("Annotations.getPageDimensions: pages parameter is nil or invalid")
        return {}
    end

    logger.info("Annotations.getPageDimensions: Getting BBOX data for file: " .. file)
    logger.info("Annotations.getPageDimensions: Pages requested: " .. JSON.encode(pages))

    local result = {}

    -- Use DocumentRegistry to get usedBBox which is the actual content area
    local DocumentRegistry = require("document/documentregistry")
    local doc = DocumentRegistry:openDocument(file)

    if doc == nil then
        logger.err("Annotations.getPageDimensions: Could not open document: " .. file)
        return nil
    end

    for pageno, _ in pairs(pages) do
        logger.info("Annotations.getPageDimensions: Processing page " .. pageno)

        -- Get native page dimensions
        local page_dims = doc:getNativePageDimensions(pageno)
        if page_dims == nil then
            logger.err("Annotations.getPageDimensions: Could not get dimensions for page " .. pageno)
            doc:close()
            return nil
        end

        -- Get usedBBox for this specific page
        local bbox = doc:getUsedBBox(pageno)
        if bbox == nil then
            logger.warn("Annotations.getPageDimensions: Could not get usedBBox for page " ..
                pageno .. ", using full page")
            bbox = { x0 = 0, y0 = 0, x1 = page_dims.w, y1 = page_dims.h }
        end

        -- TODO: To remove after testing
        local bbox_width = bbox.x1 - bbox.x0
        local bbox_height = bbox.y1 - bbox.y0

        result[pageno] = {
            width = page_dims.w,
            height = page_dims.h,
            -- TODO: To remove after testing
            bbox_x0 = bbox.x0,
            bbox_y0 = bbox.y0,
            bbox_x1 = bbox.x1,
            bbox_y1 = bbox.y1,
            bbox_width = bbox_width,
            bbox_height = bbox_height,
        }

        logger.info(string.format(
            "Annotations.getPageDimensions: Page %d - Full: %.2fx%.2f, BBox: [%.2f,%.2f,%.2f,%.2f], BBox Size: %.2fx%.2f",
            pageno, page_dims.w, page_dims.h,
            bbox.x0, bbox.y0, bbox.x1, bbox.y1,
            bbox_width, bbox_height
        ))
    end

    doc:close()
    logger.info("Annotations.getPageDimensions: Completed, returning data for " .. table.getn(result) .. " pages")

    return result
end

-- Output the timezone-agnostic timestamp, since KOReader uses timestamps with
-- local time.
function Annotations.utcFromLocal(timestamp)
    timestamp = tostring(timestamp or "")
    local year, month, day, hour, minute, second =
        string.match(timestamp, "(%d%d%d%d)%-(%d%d)%-(%d%d)[ T](%d%d):(%d%d):(%d%d)")
    if not year then
        return os.date("!%Y-%m-%dT%H:%M:%SZ")
    end
    local time = {
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(minute),
        sec = tonumber(second),
    }
    local ok, ts = pcall(os.time, time)
    if not ok or not ts then
        return os.date("!%Y-%m-%dT%H:%M:%SZ")
    end
    return os.date("!%Y-%m-%dT%H:%M:%SZ", ts)
end

function Annotations.localFromUtc(utc_timestamp)
    local year, month, day, hour, minute, second =
        string.match(utc_timestamp, "(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)Z")
    local time = {
        ["year"] = year,
        ["month"] = month,
        ["day"] = day,
        ["hour"] = hour,
        ["min"] = minute,
        ["sec"] = second,
    }

    return os.date("%Y-%m-%d %H:%M:%S", os.time(time))
end

function Annotations.supportedZoteroTypes()
    local types = {}
    for key, _ in pairs(Z2K_STYLE) do
        table.insert(types, key)
    end
    return types
end

function Annotations.annotationTypeKOReaderToZotero(type)
    return K2Z_STYLE[string.lower(type)]
end

-- Resolve 1-based page number from a KOReader annotation (fields vary by version/format).
function Annotations.getAnnotationPage(annotation)
    if annotation == nil then
        return 1
    end
    local page = tonumber(annotation.pageno) or tonumber(annotation.page)
    if page == nil and annotation.pos0 then
        page = tonumber(annotation.pos0.page) or tonumber(annotation.pos0.pageno)
    end
    if page == nil and annotation.pos1 then
        page = tonumber(annotation.pos1.page) or tonumber(annotation.pos1.pageno)
    end
    if page == nil or page < 1 then
        return 1
    end
    return math.floor(page)
end

-- PDF annotationSortIndex: PPPPP|OOOOOO|TTTTT (page index, text offset, top Y)
function Annotations.makeSortIndex(page, offset, miny)
    page = tonumber(page) or 1
    if page < 1 then
        page = 1
    end
    offset = tonumber(offset) or 0
    miny = tonumber(miny) or 0
    local zoteroSortIndex = string.format("%05d|%06d|%05d", page - 1, offset, math.max(0, math.floor(miny)))
    return zoteroSortIndex
end

-- EPUB annotationSortIndex: SSSSS|OOOOOOOO (section index, char offset in section)
-- Zotero rejects the PDF 3-part form with: Invalid sortIndex for EPUB annotation
function Annotations.makeEpubSortIndex(section_or_page, char_offset)
    local section = tonumber(section_or_page) or 1
    -- KOReader page is 1-based; Zotero section index is 0-based
    if section >= 1 then
        section = section - 1
    end
    if section < 0 then
        section = 0
    end
    char_offset = math.max(0, math.floor(tonumber(char_offset) or 0))
    return string.format("%05d|%08d", section, char_offset)
end

-- Convert KOReader annotation to Zotero format
-- page_bbox: table with bbox info for this specific page (from getPageDimensions)
function Annotations.convertKOReaderToZotero(annotation, page_bbox, parent_key)
    local page_no = Annotations.getAnnotationPage(annotation)
    local pboxes = annotation.pboxes or {}
    logger.info("=== SENDING ANNOTATION TO ZOTERO ===")
    logger.info("Local KOReader annotation data:")
    logger.info("  Page number: " .. tostring(page_no))
    logger.info("  Drawer type: " .. (annotation.drawer or "nil"))
    logger.info("  Color: " .. (annotation.color or "nil"))
    logger.info("  Text: " .. (annotation.text or ""))
    logger.info("  Note: " .. (annotation.note or ""))
    logger.info("  DateTime: " .. (annotation.datetime or "nil"))
    logger.info("  Number of pboxes: " .. tostring(#pboxes))

    local date = Annotations.utcFromLocal(annotation.datetime or os.date("%Y-%m-%d %H:%M:%S"))
    local color = defaultZColor
    if annotation.color ~= nil then
        color = mapKOReaderColorToZotero(annotation.color, K2Z_COLORS["gray"])
    end
    local type = Annotations.annotationTypeKOReaderToZotero(annotation.drawer) or "highlight"

    -- Extract BBOX dimensions for coordinate conversion
    page_bbox = page_bbox or {}
    local page_height = page_bbox.height or page_bbox.bbox_height or 842

    logger.info("")
    logger.info("Conversion parameters:")
    logger.info("  Using Page height for conversion: " .. tostring(page_height))
    logger.info("  Parent key: " .. tostring(parent_key))

    local rects = {}

    -- Coordinate systems of KOReader and Zotero are flipped. On KOReader, the
    -- y-axis extends towards the bottom whereas on Zotero the y-axis extends
    -- towards the top.
    -- Therefore, we need to transform coordinates before uploading them to Zotero
    local digits = 2
    local miny = page_height

    for idx, pbox in ipairs(pboxes) do
        local x1 = pbox.x or 0
        local x2 = (pbox.x or 0) + (pbox.w or 0)
        local y1 = page_height - (pbox.y or 0) - (pbox.h or 0)
        local y2 = y1 + (pbox.h or 0)

        table.insert(
            rects,
            { limitDigits(x1, digits), limitDigits(y1, digits), limitDigits(x2, digits), limitDigits(y2, digits) }
        )
        if (pbox.y or 0) < miny then
            miny = pbox.y or 0
        end
    end

    -- If no pboxes, still create a minimal annotation (text/note only)
    if #rects == 0 then
        table.insert(rects, { 0, 0, 10, 10 })
        miny = 0
    end

    local zoteroSortIndex = Annotations.makeSortIndex(page_no, 0, miny)

    local ZAnnotation = {
        ["itemType"] = "annotation",
        ["parentItem"] = parent_key,
        ["annotationType"] = type,
        ["annotationColor"] = color,
        ["annotationPageLabel"] = tostring(annotation.page or page_no),
        ["annotationSortIndex"] = zoteroSortIndex,
        ["annotationPosition"] = JSON.encode({
            ["pageIndex"] = page_no - 1,
            ["rects"] = rects,
        }),
        ["dateModified"] = date,
    }

    if annotation.note then
        ZAnnotation["annotationComment"] = annotation.note
    end
    if annotation.text then
        ZAnnotation["annotationText"] = annotation.text
    end

    logger.info("")
    logger.info("Final Zotero annotation package:")
    logger.info(JSON.encode(ZAnnotation))
    logger.info("=== END CREATING ANNOTATION FOR ZOTERO ===")
    logger.info("")

    return ZAnnotation
end

-- Convert a Zotero annotation item to a KOReader annotation
-- NOTE: currently only works with text highlights and annotations.
-- page_bbox: table with bbox info for this specific page (from getPageDimensions)
function Annotations.convertZoteroToKOReader(annotation, page_bbox)
    logger.info("=== CONVERTING ANNOTATION FROM ZOTERO ===")
    logger.info("Raw Zotero annotation data:")
    logger.info("  Key: " .. (annotation.key or "nil"))
    logger.info("  Version: " .. (annotation.version or "nil"))
    logger.info("  Annotation Type: " .. (annotation.data.annotationType or "nil"))
    logger.info("  Annotation Color: " .. (annotation.data.annotationColor or "nil"))
    logger.info("  Annotation Text: " .. (annotation.data.annotationText or "nil"))
    logger.info("  Annotation Comment: " .. (annotation.data.annotationComment or ""))
    logger.info("  Date Modified: " .. (annotation.data.dateModified or "nil"))
    logger.info("  Sort Index: " .. (annotation.data.annotationSortIndex or "nil"))
    logger.info("  Annotation Position JSON: " .. (annotation.data.annotationPosition or "nil"))

    page_bbox = page_bbox or Annotations.fallbackPageBbox()
    local pos = {}
    if annotation.data.annotationPosition then
        local ok_pos, decoded = pcall(JSON.decode, annotation.data.annotationPosition)
        if ok_pos and type(decoded) == "table" then
            pos = decoded
        end
    end
    local page = (pos.pageIndex ~= nil and (tonumber(pos.pageIndex) + 1)) or 1
    if annotation.data.annotationPageLabel then
        page = tonumber(annotation.data.annotationPageLabel) or page
    end

    local page_height = page_bbox.height or page_bbox.bbox_height or 842
    local z_rects = pos.rects or {}
    local rects = {}

    for _, bbox in ipairs(z_rects) do
        local x1 = bbox[1] or 0
        local y1_zotero = bbox[2] or 0
        local x2 = bbox[3] or 10
        local y2_zotero = bbox[4] or 10
        local h_koreader = y2_zotero - y1_zotero
        local y_koreader = page_height - y1_zotero - h_koreader
        table.insert(rects, {
            ["x"] = x1,
            ["y"] = y_koreader,
            ["w"] = x2 - x1,
            ["h"] = h_koreader,
        })
    end
    -- Notes / annotations without geometry: keep a minimal box so KOReader can display them
    if #rects == 0 then
        table.insert(rects, { x = 0, y = 0, w = 10, h = 10 })
    end

    local shift = 1
    local pos0 = {
        ["page"] = page,
        ["rotation"] = 0,
        ["x"] = rects[1].x + shift,
        ["y"] = rects[1].y + shift,
    }
    local pos1 = {
        ["page"] = page,
        ["rotation"] = 0,
        ["x"] = rects[#rects].x + rects[#rects].w - shift,
        ["y"] = rects[#rects].y + rects[#rects].h - shift,
    }

    local color_mapped = mapZoteroColorToKOReader(annotation.data.annotationColor, defaultKColor)
    local drawer_mapped = Z2K_STYLE[annotation.data.annotationType] or "lighten"
    local date_mod = annotation.data.dateModified or ""
    local datetime_converted = string.sub(string.gsub(date_mod, "T", " "), 1, -2)
    if datetime_converted == "" then
        datetime_converted = os.date("%Y-%m-%d %H:%M:%S")
    end

    local koAnnotation = {
        ["color"] = color_mapped,
        ["datetime"] = datetime_converted,
        ["drawer"] = drawer_mapped,
        ["page"] = page,
        ["pageno"] = page,
        ["pboxes"] = rects,
        ["pos0"] = pos0,
        ["pos1"] = pos1,
        ["text"] = annotation.data.annotationText,
        ["zoteroKey"] = annotation.key,
        ["zoteroSortIndex"] = annotation.data.annotationSortIndex,
        ["zoteroVersion"] = annotation.version,
        ["zoteroDestination"] = Annotations.DEST_BOTH,
    }
    if annotation.data.annotationComment and annotation.data.annotationComment ~= "" then
        koAnnotation["note"] = annotation.data.annotationComment
    end

    logger.info("Final KOReader annotation: " .. JSON.encode(koAnnotation))
    logger.info("=== END RECEIVING ANNOTATION ===")
    return koAnnotation
end

-- Detect whether a local KOReader annotation differs from the Zotero item data.
-- file_path: optional EPUB path — when set, compares freshly built CFI to remote.
function Annotations.annotationNeedsUpdate(local_ann, zotero_item, file_path)
    if local_ann == nil or zotero_item == nil or zotero_item.data == nil then
        return false
    end
    local data = zotero_item.data
    local local_type = Annotations.annotationTypeKOReaderToZotero(local_ann.drawer)
    if local_type and data.annotationType and local_type ~= data.annotationType then
        return true
    end
    local local_k = string.lower(tostring(local_ann.color or ""))
    if local_k == "black" or local_k == "grey" then
        local_k = "gray"
    end
    local remote_k = mapZoteroColorToKOReader(data.annotationColor, nil)
    if remote_k then
        if local_k ~= "" and local_k ~= remote_k then
            return true
        end
    elseif data.annotationColor then
        local local_hex = mapKOReaderColorToZotero(local_ann.color, defaultZColor)
        if string.lower(tostring(local_hex)) ~= string.lower(tostring(data.annotationColor)) then
            return true
        end
    end
    local local_text = local_ann.text or ""
    local remote_text = data.annotationText or ""
    if local_text ~= remote_text then
        return true
    end
    local local_note = local_ann.note or ""
    local remote_note = data.annotationComment or ""
    if local_note ~= remote_note then
        return true
    end
    -- EPUB CFI: avoid unzipping the EPUB on every sync. Prefer cached local CFI;
    -- rebuild only when remote or local CFI lacks a text range (no underline in Zotero).
    local xp = local_ann.pos0
    local has_xp = (type(xp) == "string" and xp:find("DocFragment", 1, true))
        or (type(xp) == "table" and xp.xpointer and tostring(xp.xpointer):find("DocFragment", 1, true))
    if has_xp then
        local remote_pos = data.annotationPosition or ""
        local remote_cfi = nil
        if type(remote_pos) == "string" and remote_pos ~= "" then
            local ok, parsed = pcall(JSON.decode, remote_pos)
            if ok and type(parsed) == "table" then
                remote_cfi = parsed.value
            end
        end
        local remote_ok = remote_cfi and tostring(remote_cfi):find(",", 1, true)
        local local_cfi = local_ann.zoteroCfi
        local local_ok = local_cfi and tostring(local_cfi):find(",", 1, true)
        if not remote_ok then
            return true
        end
        if local_ok then
            return local_cfi ~= remote_cfi
        end
        -- No good local cache: rebuild once to decide (and cache for next sync)
        if file_path and Annotations.isEpubPath and Annotations.isEpubPath(file_path) then
            local full = Annotations.buildEpubAnnotationPosition(local_ann, file_path)
            if full and full.value then
                local_ann.zoteroCfi = full.value
                return full.value ~= remote_cfi
            end
        end
        return true
    end
    return false
end

-- Build a Zotero update payload (includes key + version) from a KOReader annotation.
function Annotations.buildUpdatePayload(annotation, page_bbox, parent_key)
    local payload = Annotations.convertKOReaderToZotero(annotation, page_bbox, parent_key)
    payload.key = annotation.zoteroKey
    payload.version = annotation.zoteroVersion
    return payload
end

-- Build a Zotero-accepted EPUB annotationPosition (FragmentSelector + epubcfi).
-- KOReader xpointers are kept alongside for round-trip; Zotero requires CFI shape.
local EPUB_CFI_CONFORMS = "http://www.idpf.org/epub/linking/cfi/epub-cfi.html"

-- API payload must be a clean FragmentSelector only (extra keys can make Zotero
-- return an empty successful/failed map or reject the item).
function Annotations.epubPositionForApi(cfi_value)
    return {
        type = "FragmentSelector",
        conformsTo = EPUB_CFI_CONFORMS,
        value = tostring(cfi_value or "epubcfi(/6/2!/4)"),
    }
end

local function loadEpubCfi()
    local ok, mod = pcall(require, "epub_cfi")
    if ok and mod then
        return mod
    end
    return nil
end

-- Full local position: API fields + KOReader xpointers + pageIndex for round-trip.
-- epub_path: optional absolute path to the .epub (needed to resolve real range CFIs).
function Annotations.buildEpubAnnotationPosition(annotation, epub_path)
    local page = Annotations.getAnnotationPage(annotation)
    local page_index = math.max(0, (tonumber(page) or 1) - 1)
    local EpubCfi = loadEpubCfi()
    local pos0 = EpubCfi and EpubCfi.getXPointer(annotation.pos0) or nil
    local pos1 = EpubCfi and EpubCfi.getXPointer(annotation.pos1) or nil
    if not pos0 and type(annotation.pos0) == "string" then
        pos0 = annotation.pos0
    end
    if not pos1 and type(annotation.pos1) == "string" then
        pos1 = annotation.pos1
    end
    if not pos0 and annotation.pos0 and annotation.pos0.xpointer then
        pos0 = annotation.pos0.xpointer
    end
    if not pos1 and annotation.pos1 and annotation.pos1.xpointer then
        pos1 = annotation.pos1.xpointer
    end
    local cfi = nil
    local char_offset = 0

    if annotation.zoteroCfi and tostring(annotation.zoteroCfi):match("^epubcfi") then
        cfi = annotation.zoteroCfi
    elseif annotation.zoteroAnnotationPosition then
        local ok, parsed = pcall(JSON.decode, annotation.zoteroAnnotationPosition)
        if ok and type(parsed) == "table" then
            if parsed.type == "FragmentSelector" and parsed.value then
                cfi = parsed.value
                pos0 = pos0 or parsed.koreaderPos0
                pos1 = pos1 or parsed.koreaderPos1
                if parsed.pageIndex ~= nil then
                    page_index = tonumber(parsed.pageIndex) or page_index
                end
            elseif parsed.value and tostring(parsed.value):match("^epubcfi") then
                cfi = parsed.value
            end
        end
    end

    -- Always rebuild from xpointers when possible (cached CFI may be chapter-only
    -- or offset by whitespace nodes that Zotero ignores).
    local function cfi_has_range(v)
        return type(v) == "string" and v:find(",", 1, true) ~= nil
    end
    -- Drop cached chapter-only / zero-width CFI before rebuild
    if cfi and not cfi_has_range(cfi) then
        logger.warn("Zotero: discarding chapter-only CFI before rebuild: ", cfi)
        cfi = nil
    end
    if EpubCfi and epub_path and pos0 then
        local real, perr = EpubCfi.fromKOReaderPositions(pos0, pos1 or pos0, epub_path)
        if real and cfi_has_range(real) then
            if cfi and cfi ~= real then
                logger.info("Zotero: EPUB CFI corrected: ", cfi, " → ", real)
            else
                logger.info("Zotero: built EPUB CFI from xpointers: ", real)
            end
            cfi = real
            local parsed = EpubCfi.parseXPointer(pos0)
            if parsed then
                if parsed.fragment then
                    page_index = math.max(0, parsed.fragment - 1)
                end
                char_offset = parsed.offset or 0
            end
        else
            logger.warn(
                "Zotero: EPUB CFI from xpointers failed: ",
                perr or real,
                " pos0=",
                tostring(pos0)
            )
        end
    elseif EpubCfi and pos0 then
        local parsed = EpubCfi.parseXPointer(pos0)
        if parsed and parsed.offset then
            char_offset = parsed.offset
        end
    end

    if not cfi or not cfi_has_range(cfi) then
        -- Last resort: paragraph + char offsets (better than chapter-only — Zotero paints)
        local parsed0 = EpubCfi and EpubCfi.parseXPointer(pos0)
        local parsed1 = EpubCfi and EpubCfi.parseXPointer(pos1 or pos0)
        if parsed0 then
            local spine = math.max(2, (parsed0.fragment or (page_index + 1)) * 2)
            local p_idx = 1
            if parsed0.path then
                p_idx = tonumber(parsed0.path:match("p%[(%d+)%]")) or 1
            end
            local tstep = 1
            if parsed0.text_index then
                -- Approximate: odd CFI index for K-th text among siblings (no mixed elems)
                tstep = parsed0.text_index * 2 - 1
            end
            local a = parsed0.offset or 0
            local b = (parsed1 and parsed1.offset) or a
            if b <= a then
                b = a + math.max(1, #(tostring(annotation.text or "x")))
            end
            cfi = string.format(
                "epubcfi(/6/%d!/4/2/2/%d,/%d:%d,/%d:%d)",
                spine,
                p_idx * 2,
                tstep,
                a,
                tstep,
                b
            )
            logger.warn("Zotero: EPUB CFI heuristic range: ", cfi)
        else
            local spine = math.max(2, (page_index + 1) * 2)
            cfi = string.format("epubcfi(/6/%d!/4)", spine)
            logger.warn("Zotero: EPUB CFI fallback without range (Zotero will not underline)")
        end
    end

    local api = Annotations.epubPositionForApi(cfi)
    return {
        type = api.type,
        conformsTo = api.conformsTo,
        value = api.value,
        koreaderPos0 = pos0,
        koreaderPos1 = pos1,
        pageIndex = page_index,
        charOffset = char_offset,
    }
end

-- EPUB / non-PDF: build a Zotero annotation from KOReader sidecar fields.
-- Must use FragmentSelector position (PDF pageIndex/rects are rejected for EPUB).
-- file_path: absolute EPUB path (enables real CFI for visible highlights in Zotero).
function Annotations.convertKOReaderToZoteroEpub(annotation, parent_key, file_path)
    local date = Annotations.utcFromLocal(annotation.datetime or os.date("%Y-%m-%d %H:%M:%S"))
    local color = defaultZColor
    if annotation.color ~= nil then
        color = mapKOReaderColorToZotero(annotation.color, K2Z_COLORS["gray"])
    end
    -- Force lowercase hex; Zotero rejects unknown / non-hex colors.
    color = string.lower(tostring(color))
    local ann_type = Annotations.annotationTypeKOReaderToZotero(annotation.drawer) or "highlight"
    -- EPUB: Zotero reader supports highlight + underline reliably
    if ann_type ~= "highlight" and ann_type ~= "underline" then
        ann_type = "highlight"
    end
    local page = Annotations.getAnnotationPage(annotation)
    local full_pos = Annotations.buildEpubAnnotationPosition(annotation, file_path)
    local api_pos = Annotations.epubPositionForApi(full_pos.value)
    -- Prefer section from DocFragment / pageIndex; include char offset for sort
    local section_page = (full_pos.pageIndex ~= nil and (tonumber(full_pos.pageIndex) + 1)) or page
    local zoteroSortIndex = Annotations.makeEpubSortIndex(section_page, full_pos.charOffset or 0)
    local ZAnnotation = {
        ["itemType"] = "annotation",
        ["parentItem"] = parent_key,
        ["annotationType"] = ann_type,
        ["annotationColor"] = color,
        ["annotationPageLabel"] = tostring(page),
        ["annotationSortIndex"] = zoteroSortIndex,
        ["annotationPosition"] = JSON.encode(api_pos),
        ["dateModified"] = date,
        -- Local-only (stripped before POST if present; kept for sidecar after create)
        ["_epubFullPosition"] = full_pos,
    }
    if annotation.note and annotation.note ~= "" then
        ZAnnotation["annotationComment"] = annotation.note
    end
    if annotation.text and annotation.text ~= "" then
        ZAnnotation["annotationText"] = annotation.text
    end
    return ZAnnotation
end

-- EPUB rolling annotations require page/pos0/pos1 as XPointer *strings*.
-- A numeric page makes KOReader move them to annotations_paging → invisible in EPUB.
local function epubXpString(v)
    if type(v) == "string" and v:find("DocFragment", 1, true) then
        return v
    end
    if type(v) == "table" and type(v.xpointer) == "string" and v.xpointer ~= "" then
        return v.xpointer
    end
    return nil
end

function Annotations.docFragmentFromEpubCfi(cfi)
    -- Accept /6/8!, /6/8[couv]!, epubcfi(/6/8!/...), bare paths
    local cleaned = tostring(cfi or ""):gsub("%b[]", "")
    local spine = cleaned:match("/6/(%d+)!")
    if not spine then
        return nil
    end
    local frag = math.floor(tonumber(spine) / 2)
    if frag < 1 then
        frag = 1
    end
    return frag
end

local function normalizeEpubCfiValue(cfi_val)
    local EpubCfi = loadEpubCfi()
    if EpubCfi and EpubCfi.normalizeCfi then
        return EpubCfi.normalizeCfi(cfi_val)
    end
    local s = tostring(cfi_val or ""):gsub("%b[]", "")
    if s:match("^epubcfi%(") then
        return s
    end
    if s:match("^/6/%d+!") then
        return "epubcfi(" .. s .. ")"
    end
    return nil
end

local function epubXpIsPrecise(xp)
    return type(xp) == "string" and xp:find("text()", 1, true) ~= nil
end

-- Convert Zotero EPUB (or non-PDF) annotation to KOReader sidecar fields.
-- epub_path: optional absolute .epub path — used to reverse CFI into real xpointers
-- so highlights created in Zotero become visible in rolling mode.
function Annotations.convertZoteroToKOReaderEpub(annotation, epub_path)
    local pos = {}
    if annotation.data.annotationPosition then
        local ok, parsed = pcall(JSON.decode, annotation.data.annotationPosition)
        if ok and type(parsed) == "table" then
            pos = parsed
        end
    end
    local z_color = string.lower(tostring(annotation.data.annotationColor or ""))
    -- Underline without a known color → gray (readable on e-ink), never yellow fallback
    local color_fallback = defaultKColor
    if z_color == "" and string.lower(tostring(annotation.data.annotationType or "")) == "underline" then
        color_fallback = "gray"
    end
    local color_mapped = mapZoteroColorToKOReader(z_color, color_fallback)
    local z_type = string.lower(tostring(annotation.data.annotationType or ""))
    local drawer_mapped = Z2K_STYLE[z_type] or "lighten"
    local datetime_converted = string.sub(string.gsub(annotation.data.dateModified or "", "T", " "), 1, -2)
    if datetime_converted == "" then
        datetime_converted = os.date("%Y-%m-%d %H:%M:%S")
    end

    local xp0 = epubXpString(pos.koreaderPos0)
    local xp1 = epubXpString(pos.koreaderPos1) or xp0
    local cfi_raw = pos.value and tostring(pos.value) or nil
    local cfi_val = normalizeEpubCfiValue(cfi_raw)
    if cfi_val and (not epubXpIsPrecise(xp0)) then
        local EpubCfi = loadEpubCfi()
        if EpubCfi and epub_path then
            local r0, r1, rerr = EpubCfi.toKOReaderPositions(cfi_val, epub_path)
            if r0 then
                xp0, xp1 = r0, r1 or r0
                logger.info("Zotero: reversed CFI for visible EPUB highlight: ", r0)
            else
                logger.warn("Zotero: CFI reverse failed: ", rerr, " cfi=", cfi_val)
            end
        end
    end
    -- Never leave EPUB annotations with numeric/page-label page — CRE crashes / blanks.
    if not epubXpIsPrecise(xp0) then
        local frag = Annotations.docFragmentFromEpubCfi(cfi_val or cfi_raw)
            or (pos.pageIndex ~= nil and (tonumber(pos.pageIndex) + 1))
            or 1
        xp0 = xp0 or string.format("/body/DocFragment[%d]/body", frag)
        xp1 = xp1 or xp0
    end

    local page_num = (pos.pageIndex ~= nil and (tonumber(pos.pageIndex) + 1)) or 1
    if epubXpIsPrecise(xp0) then
        local EpubCfiMod = loadEpubCfi()
        local parsed = EpubCfiMod and EpubCfiMod.parseXPointer(xp0)
        if parsed and parsed.fragment then
            page_num = parsed.fragment
        end
    elseif type(xp0) == "string" then
        local frag = xp0:match("DocFragment%[(%d+)%]")
        if frag then
            page_num = tonumber(frag) or page_num
        end
    end
    local koAnnotation = {
        ["color"] = color_mapped,
        ["datetime"] = datetime_converted,
        ["drawer"] = drawer_mapped,
        -- Rolling (EPUB): page MUST be XPointer string with DocFragment
        ["page"] = xp0,
        ["pageno"] = page_num,
        ["pos0"] = xp0,
        ["pos1"] = xp1 or xp0,
        ["text"] = annotation.data.annotationText,
        ["zoteroKey"] = annotation.key,
        ["zoteroSortIndex"] = annotation.data.annotationSortIndex,
        ["zoteroVersion"] = annotation.version,
        ["zoteroAnnotationPosition"] = annotation.data.annotationPosition,
        ["zoteroDestination"] = Annotations.DEST_BOTH,
    }
    if cfi_val then
        koAnnotation.zoteroCfi = cfi_val
    elseif cfi_raw then
        koAnnotation.zoteroCfi = cfi_raw
    end
    if annotation.data.annotationComment and annotation.data.annotationComment ~= "" then
        koAnnotation["note"] = annotation.data.annotationComment
    end
    return koAnnotation
end

function Annotations.isPdfPath(file_path)
    return file_path ~= nil and string.lower(file_path):match("%.pdf$") ~= nil
end

function Annotations.isEpubPath(file_path)
    return file_path ~= nil and string.lower(file_path):match("%.epub$") ~= nil
end

-- Create annotations for a single document using creation_callback.
-- returns number of items it FAILED to sync (and error if applicable)
function Annotations.createAnnotations(file_path, key, creation_callback)
    logger.info("Annotations.createAnnotations: Starting for file: " .. file_path)
    local doc_settings = DocSettings:open(file_path)
    if
        doc_settings.data == nil
        or doc_settings.data["annotations"] == nil
        or #doc_settings.data["annotations"] == 0
    then
        logger.info("Annotations.createAnnotations: No annotations to create")
        return 0, nil
    end

    local k_annotations = doc_settings.data["annotations"]
    local z_annotations = {}
    local pages = {}
    local is_pdf = Annotations.isPdfPath(file_path)

    -- the following associative array maps from indices of k_annotations to z_annotations.
    -- This is necessary because not all annotations necessitate a creation event, since some might
    -- have been created in a prevous sync.
    local index_map = {}

    local page_dimensions = {}
    if is_pdf then
        -- gather page numbers beforehand so that we may determine page sizes in a
        -- single go
        for i = 1, #k_annotations do
            local pageno = Annotations.getAnnotationPage(k_annotations[i])
            pages[pageno] = true
        end

        logger.info("Annotations.createAnnotations: Getting BBOX dimensions for pages: " .. JSON.encode(pages))
        page_dimensions = Annotations.getPageDimensions(file_path, pages) or {}

        if next(page_dimensions) == nil then
            logger.warn(
                ("Zotero: page dimensions unavailable for '%s' — uploading with fallback page size"):format(file_path)
            )
        end
    end

    logger.info("Annotations.createAnnotations: Processing " .. #k_annotations .. " annotations")
    for i = 1, #k_annotations do
        local kann = k_annotations[i]
        if
            (kann.zoteroKey == nil)
            and (kann.drawer ~= nil)
            and Annotations.shouldSyncToZotero(kann)
        then
            local pageno = Annotations.getAnnotationPage(kann)
            if is_pdf then
                local page_bbox = page_dimensions[pageno] or Annotations.fallbackPageBbox()
                if page_dimensions[pageno] == nil then
                    logger.warn(
                        "Annotations.createAnnotations: No BBOX for page "
                            .. tostring(pageno)
                            .. ", using fallback"
                    )
                end
                local ok_c, a = pcall(Annotations.convertKOReaderToZotero, kann, page_bbox, key)
                if ok_c and a then
                    table.insert(z_annotations, a)
                    index_map[#z_annotations] = i
                else
                    logger.err("Annotations.createAnnotations: convert failed: ", a)
                end
            else
                local ok_c, a = pcall(Annotations.convertKOReaderToZoteroEpub, kann, key, file_path)
                if ok_c and a then
                    table.insert(z_annotations, a)
                    index_map[#z_annotations] = i
                else
                    logger.err("Annotations.createAnnotations: epub convert failed: ", a)
                end
            end
        end
    end

    if #z_annotations == 0 then
        logger.info("Annotations.createAnnotations: No new annotations to create")
        return 0, nil
    end

    -- Strip local-only fields; keep a side map for sidecar round-trip after create
    local local_extras = {}
    local payload = {}
    for i, za in ipairs(z_annotations) do
        local_extras[i] = za._epubFullPosition
        za._epubFullPosition = nil
        table.insert(payload, za)
    end

    logger.info(("Zotero: creating %d annotation(s) for %s"):format(#payload, file_path))
    logger.dbg(("Zotero: create payload:\n%s"):format(JSON.encode(payload)))
    local created_items, e = creation_callback(payload)

    if created_items == nil then
        logger.err("Annotations.createAnnotations: Failed to create annotations: " .. tostring(e))
        return #payload, e
    end

    local cnt = 0
    for k, v in pairs(created_items) do
        if type(v) == "table" and v.key ~= nil then
            local idx = tonumber(k) or k
            local k_index = index_map[idx]
            if k_index == nil then
                logger.err(
                    "Annotations.createAnnotations: no index_map for created item index "
                        .. tostring(k)
                        .. " key="
                        .. tostring(v.key)
                )
            else
                k_annotations[k_index].zoteroKey = v.key
                k_annotations[k_index].zoteroVersion = v.version
                if k_annotations[k_index].zoteroDestination == nil then
                    k_annotations[k_index].zoteroDestination = Annotations.DEST_BOTH
                end
                local full_pos = local_extras[idx]
                if type(full_pos) == "table" and full_pos.value then
                    k_annotations[k_index].zoteroCfi = full_pos.value
                    k_annotations[k_index].zoteroAnnotationPosition = JSON.encode(full_pos)
                end
                cnt = cnt + 1
                logger.info("Zotero: New Zotero annotation created: ", JSON.encode(v))
            end
        end
    end

    if cnt > 0 then
        doc_settings:flush()
        logger.info("Annotations.createAnnotations: Successfully created " .. cnt .. " annotations")
    end

    local fail_msg = nil
    if type(e) == "table" and #e > 0 then
        fail_msg = JSON.encode(e)
        logger.err("Annotations.createAnnotations: Zotero rejected items: ", fail_msg)
    elseif type(e) == "string" and e ~= "" then
        fail_msg = e
    elseif cnt < #payload then
        fail_msg = ("Zotero created %d/%d items (no failed[] detail — see createItems logs)"):format(
            cnt,
            #payload
        )
        logger.err("Annotations.createAnnotations: ", fail_msg)
    end
    return #payload - cnt, fail_msg
end

-- Update existing annotations that differ from Zotero.
-- get_item_callback(key) -> zotero item; update_callback(payloads) -> updated items
-- returns number of items it FAILED to sync (and error if applicable)
function Annotations.updateAnnotations(file_path, key, update_callback, get_item_callback)
    local doc_settings = DocSettings:open(file_path)
    if
        doc_settings.data == nil
        or doc_settings.data["annotations"] == nil
        or #doc_settings.data["annotations"] == 0
    then
        return 0, nil
    end

    local k_annotations = doc_settings.data["annotations"]
    local z_updates = {}
    local index_map = {}
    local pages = {}
    local is_pdf = Annotations.isPdfPath(file_path)

    for i = 1, #k_annotations do
        local ann = k_annotations[i]
        if ann.zoteroKey ~= nil and ann.drawer ~= nil and Annotations.shouldSyncToZotero(ann) then
            local remote = nil
            if get_item_callback then
                remote = get_item_callback(ann.zoteroKey)
            end
            if remote and Annotations.annotationNeedsUpdate(ann, remote, file_path) then
                local pageno = Annotations.getAnnotationPage(ann)
                if is_pdf then
                    pages[pageno] = true
                end
                table.insert(z_updates, { index = i, ann = ann, remote = remote })
            end
        end
    end

    if #z_updates == 0 then
        return 0, nil
    end

    local page_dimensions = {}
    if is_pdf then
        page_dimensions = Annotations.getPageDimensions(file_path, pages) or {}
    end

    local payloads = {}
    for _, entry in ipairs(z_updates) do
        local ann = entry.ann
        local payload
        if is_pdf then
            local pageno = Annotations.getAnnotationPage(ann)
            local page_bbox = page_dimensions[pageno]
                or { width = 595, height = 842, bbox_width = 595, bbox_height = 842,
                    bbox_x0 = 0, bbox_y0 = 0, bbox_x1 = 595, bbox_y1 = 842 }
            local ok_c, built = pcall(Annotations.buildUpdatePayload, ann, page_bbox, key)
            if ok_c then
                payload = built
            else
                logger.err("Annotations.updateAnnotations: build failed: ", built)
            end
        else
            local ok_c, built = pcall(Annotations.convertKOReaderToZoteroEpub, ann, key, file_path)
            if ok_c and built then
                payload = built
                local full_pos = payload._epubFullPosition
                payload._epubFullPosition = nil
                payload.key = ann.zoteroKey
                payload.version = ann.zoteroVersion or (entry.remote and entry.remote.version)
                payload._saveFullPos = full_pos
            end
        end
        if payload then
            table.insert(payloads, payload)
            index_map[#payloads] = entry.index
        end
    end

    if #payloads == 0 then
        return 0, nil
    end

    -- Strip local-only fields before POST
    local save_pos = {}
    for i, p in ipairs(payloads) do
        save_pos[i] = p._saveFullPos
        p._saveFullPos = nil
    end

    local updated_items, e = update_callback(payloads)
    if updated_items == nil then
        return #payloads, e
    end

    local cnt = 0
    local function apply_updated(v, payload_index)
        if not v then
            return
        end
        local k_index = payload_index and index_map[payload_index] or nil
        if not k_index and v.key then
            for pi, p in ipairs(payloads) do
                if p.key == v.key then
                    k_index = index_map[pi]
                    payload_index = pi
                    break
                end
            end
        end
        if not k_index then
            return
        end
        if v.version then
            k_annotations[k_index].zoteroVersion = v.version
        end
        local full_pos = payload_index and save_pos[payload_index]
        if type(full_pos) == "table" and full_pos.value then
            k_annotations[k_index].zoteroCfi = full_pos.value
            k_annotations[k_index].zoteroAnnotationPosition = JSON.encode(full_pos)
        end
        cnt = cnt + 1
    end

    for k, v in pairs(updated_items) do
        if type(v) == "table" and (v.key ~= nil or v.version ~= nil) then
            apply_updated(v, tonumber(k) or k)
        end
    end

    if cnt > 0 then
        doc_settings:flush()
    end

    return math.max(0, #payloads - cnt), nil
end

return Annotations
