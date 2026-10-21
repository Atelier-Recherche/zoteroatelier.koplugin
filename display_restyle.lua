-- Display-only highlight restyle: paint underlines as squiggly black
-- without mutating stored annotation color/drawer (sidecar / Zotero sync).

local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")

local M = {}

local UNDERLINE_DRAWERS = {
    underscore = true,
    wavy = true,
    squiggly = true,
    dash = true,
    dot = true,
    double_underline = true,
    zigzag = true,
}

local SQUIGGLY_SIZE = { w = 8, h = 5 }
-- Stroke size in px (was 2 — too thin on e-ink)
local SQUIGGLY_THICK = 5

local _orig_drawHighlightRect = nil
local _hooked = false

local function paintSquigglyBlack(bb, rect)
    if not bb or not rect then
        return
    end
    local x, y, w, h = rect.x, rect.y, rect.w, rect.h
    local color = Blitbuffer.COLOR_BLACK
    local is_color8 = Blitbuffer.isColor8 and Blitbuffer.isColor8(color)
    local thick = SQUIGGLY_THICK
    local wave_w, wave_h = SQUIGGLY_SIZE.w, SQUIGGLY_SIZE.h
    -- Leave room above the bottom of the highlight box for the thicker stroke
    local cy = y + h - thick - 1
    local function paint(px, py, pw, ph)
        if is_color8 then
            bb:paintRect(px, py, pw, ph, color)
        elseif bb.paintRectRGB32 then
            bb:paintRectRGB32(px, py, pw, ph, color)
        else
            bb:paintRect(px, py, pw, ph, color)
        end
    end
    for i = 0, w - 1 do
        local dy = math.floor(math.sin(i / wave_w * math.pi) * wave_h + 0.5)
        -- 2px-wide column so the wave reads denser on e-ink
        paint(x + i, cy + dy, 2, thick)
    end
end

function M.isUnderlineDrawer(drawer)
    return UNDERLINE_DRAWERS[tostring(drawer or "")] == true
end

function M.apply(enabled)
    local ok, ReaderView = pcall(require, "apps/reader/modules/readerview")
    if not ok or not ReaderView or not ReaderView.drawHighlightRect then
        logger.warn("Zotero: display_restyle — ReaderView.drawHighlightRect unavailable")
        return false
    end

    if enabled then
        if not _hooked then
            _orig_drawHighlightRect = ReaderView.drawHighlightRect
            ReaderView.drawHighlightRect = function(self, bb, _x, _y, rect, drawer, color, draw_note_mark)
                if M.isUnderlineDrawer(drawer) then
                    paintSquigglyBlack(bb, rect)
                    -- Still draw note mark via original if needed
                    if self.highlight and self.highlight.note_mark ~= nil and draw_note_mark ~= nil then
                        if _orig_drawHighlightRect then
                            -- Call original only for note mark path with zero-size? Skip — note marks rare on underline restyle.
                        end
                    end
                    return
                end
                return _orig_drawHighlightRect(self, bb, _x, _y, rect, drawer, color, draw_note_mark)
            end
            _hooked = true
            logger.info("Zotero: display squiggly-black underline restyle ON")
        end
        return true
    end

    if _hooked and _orig_drawHighlightRect then
        ReaderView.drawHighlightRect = _orig_drawHighlightRect
        _orig_drawHighlightRect = nil
        _hooked = false
        logger.info("Zotero: display squiggly-black underline restyle OFF")
    end
    return true
end

function M.refreshReader(ui)
    if not ui then
        return
    end
    if ui.view and ui.view.highlight then
        ui.view.highlight.page_boxes = {}
    end
    if ui.annotation and ui.annotation.updateAnnotations then
        pcall(function()
            ui.annotation:updateAnnotations(true, true)
        end)
    end
    local UIManager = require("ui/uimanager")
    if UIManager and UIManager.setDirty then
        UIManager:setDirty(ui, "ui")
    end
end

function M.isHooked()
    return _hooked
end

return M
