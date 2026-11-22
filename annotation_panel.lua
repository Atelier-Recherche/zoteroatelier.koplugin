local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local DocSettings = require("docsettings")
local Device = require("device")
local Screen = Device.screen
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local _
do
    local ok, mod = pcall(require, "zotero_i18n")
    if ok and type(mod) == "function" then
        _ = mod
    else
        _ = require("gettext")
    end
end
local logger = require("logger")
local ZoteroAPI = require("zoteroapi")

local AnnotationPanel = {}

local function loadPdfEmbedded(plugin)
    local ok, mod = pcall(require, "pdf_embedded_annotations")
    if ok and mod then
        return mod
    end
    if plugin and plugin.path then
        local path = plugin.path .. "/pdf_embedded_annotations.lua"
        local ok2, mod2 = pcall(dofile, path)
        if ok2 and mod2 then
            return mod2
        end
    end
    return nil
end

local function sourceBadge(ann)
    if ann._fromPdfEmbedded then
        return "[PDF] "
    end
    if ann.zoteroKey and ann._fromDbOnly then
        return "[Z] "
    end
    if ann.zoteroKey then
        return "[Z+L] "
    end
    return "[L] "
end

local function truncate(s, max_len)
    s = s or ""
    max_len = max_len or 80
    if #s <= max_len then
        return s
    end
    return s:sub(1, max_len - 1) .. "..."
end

-- Keep only ASCII + valid UTF-8; replace anything else with '?' so FreeType
-- never crashes when painting Menu / dialogs.
local function safeText(s)
    if s == nil then
        return ""
    end
    s = tostring(s)
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        if c < 0x80 then
            if c >= 32 or c == 9 or c == 10 then
                out[#out + 1] = string.char(c)
            else
                out[#out + 1] = "?"
            end
            i = i + 1
        elseif c >= 0xC2 and c <= 0xDF and i + 1 <= n then
            local c2 = s:byte(i + 1)
            if c2 >= 0x80 and c2 <= 0xBF then
                out[#out + 1] = s:sub(i, i + 1)
                i = i + 2
            else
                out[#out + 1] = "?"
                i = i + 1
            end
        elseif c >= 0xE0 and c <= 0xEF and i + 2 <= n then
            local c2, c3 = s:byte(i + 1, i + 2)
            if c2 >= 0x80 and c2 <= 0xBF and c3 >= 0x80 and c3 <= 0xBF then
                out[#out + 1] = s:sub(i, i + 2)
                i = i + 3
            else
                out[#out + 1] = "?"
                i = i + 1
            end
        elseif c >= 0xF0 and c <= 0xF4 and i + 3 <= n then
            local c2, c3, c4 = s:byte(i + 1, i + 3)
            if c2 >= 0x80 and c2 <= 0xBF and c3 >= 0x80 and c3 <= 0xBF and c4 >= 0x80 and c4 <= 0xBF then
                out[#out + 1] = s:sub(i, i + 3)
                i = i + 4
            else
                out[#out + 1] = "?"
                i = i + 1
            end
        else
            out[#out + 1] = "?"
            i = i + 1
        end
    end
    return table.concat(out)
end

local function annotationLabel(ann)
    local page = ann.pageno or ann.page or "?"
    local text = safeText(ann.note or ann.text or _("(no text)"))
    return sourceBadge(ann) .. "p." .. tostring(page) .. " - " .. truncate(text, 70)
end

local function matchesFilter(ann, filter)
    if filter == nil or filter == "" then
        return true
    end
    filter = string.lower(filter)
    local hay = string.lower(
        tostring(ann.text or "")
            .. " "
            .. tostring(ann.note or "")
            .. " "
            .. tostring(ann.pageno or ann.page or "")
            .. " "
            .. tostring(ann.zoteroKey or "")
    )
    return hay:find(filter, 1, true) ~= nil
end

-- Collect annotations from every available local source (reader + sidecar file).
local function collectLocalAnnotations(ui, file_path)
    local by_fingerprint = {}
    local ordered = {}

    local function fingerprint(ann)
        if ann.zoteroKey then
            return "z:" .. tostring(ann.zoteroKey)
        end
        return "l:"
            .. tostring(ann.pageno or ann.page or "")
            .. "|"
            .. tostring(ann.text or "")
            .. "|"
            .. tostring(ann.note or "")
            .. "|"
            .. tostring(ann.datetime or "")
    end

    local function add_ann(ann, sidecar_index)
        if ann == nil or type(ann) ~= "table" then
            return
        end
        -- Skip bookmarks without highlight/note content when empty
        if ann.drawer == nil and ann.text == nil and ann.note == nil and ann.zoteroKey == nil then
            return
        end
        local fp = fingerprint(ann)
        if by_fingerprint[fp] then
            return
        end
        by_fingerprint[fp] = true
        local copy = {}
        for k, v in pairs(ann) do
            copy[k] = v
        end
        copy._sidecarIndex = sidecar_index
        table.insert(ordered, copy)
    end

    -- 1) Live reader table (array or map)
    local live = nil
    if ui and ui.annotation and ui.annotation.annotations then
        live = ui.annotation.annotations
    end
    if live then
        if #live > 0 then
            for i, ann in ipairs(live) do
                add_ann(ann, i)
            end
        else
            for k, ann in pairs(live) do
                if type(ann) == "table" then
                    add_ann(ann, tonumber(k))
                end
            end
        end
    end

    -- 2) Open doc_settings
    if ui and ui.doc_settings then
        local from_ds = ui.doc_settings:readSetting("annotations")
        if type(from_ds) == "table" then
            if #from_ds > 0 then
                for i, ann in ipairs(from_ds) do
                    add_ann(ann, i)
                end
            else
                for k, ann in pairs(from_ds) do
                    if type(ann) == "table" then
                        add_ann(ann, tonumber(k))
                    end
                end
            end
        end
    end

    -- 3) Sidecar file on disk (may differ from live memory)
    if file_path then
        pcall(function()
            local ds = DocSettings:open(file_path)
            local from_file = ds:readSetting("annotations")
            ds:close()
            if type(from_file) == "table" then
                if #from_file > 0 then
                    for i, ann in ipairs(from_file) do
                        add_ann(ann, i)
                    end
                else
                    for k, ann in pairs(from_file) do
                        if type(ann) == "table" then
                            add_ann(ann, tonumber(k))
                        end
                    end
                end
            end
        end)
    end

    return ordered
end

-- Menu may call onMenuChoice(item) OR self:onMenuChoice(item).
local function menuItemArg(a, b)
    if type(b) == "table" and (b.ann ~= nil or b.text ~= nil) then
        return b
    end
    if type(a) == "table" and (a.ann ~= nil or a.text ~= nil) then
        return a
    end
    return b or a
end

local function documentPageCount(ui)
    if ui and ui.document and ui.document.info then
        return tonumber(ui.document.info.number_of_pages)
    end
    return nil
end

-- Trust scan/sidecar pageno only; never findText (slow + wrong on OCR PDFs).
local function resolveAnnotationPage(ui, ann)
    if ann == nil then
        return nil
    end
    local page = tonumber(ann.pageno or ann.page)
    if not page or page < 1 then
        return nil
    end
    local max_page = documentPageCount(ui)
    if max_page and page > max_page then
        return nil
    end
    return page
end

local function gotoAnnotation(ui, ann)
    if ui == nil or ann == nil then
        return false
    end
    if ann.pos0 and ann.pos0.xpointer and ui.link and ui.link.onGotoXPointer then
        local ok = pcall(function()
            ui.link:onGotoXPointer(ann.pos0.xpointer)
        end)
        if ok then
            return true
        end
    end
    local page = resolveAnnotationPage(ui, ann)
    if not page then
        UIManager:show(InfoMessage:new({
            text = _("Could not find this annotation’s page in the document."),
            timeout = 3,
        }))
        return false
    end
    local ok = pcall(function()
        if ui.paging and ui.paging.onGotoPage then
            ui.paging:onGotoPage(page)
        elseif ui.link and ui.link.onGotoPage then
            ui.link:onGotoPage(page)
        elseif ui.document and ui.document.gotoPage then
            ui.document:gotoPage(page)
        else
            error("no goto page API")
        end
    end)
    return ok
end

-- Sidecar / live reader only — must stay instant (no DB, no PDF I/O).
local function buildLocalOnlyList(ui, file_path)
    return collectLocalAnnotations(ui, file_path)
end

local function appendZoteroDbAnnotations(list, attachment_key)
    if not attachment_key then
        return list
    end
    local seen_keys = {}
    for _, ann in ipairs(list) do
        if ann.zoteroKey then
            seen_keys[ann.zoteroKey] = true
        end
    end
    local ok, db_rows = pcall(ZoteroAPI.listAttachmentAnnotations, attachment_key)
    if ok and db_rows then
        for _, row in ipairs(db_rows) do
            if row.key and not seen_keys[row.key] then
                table.insert(list, {
                    zoteroKey = row.key,
                    text = row.text,
                    note = row.comment ~= "" and row.comment or nil,
                    page = row.page ~= "" and tonumber(row.page) or row.page,
                    pageno = row.page ~= "" and tonumber(row.page) or nil,
                    color = row.color,
                    zoteroVersion = row.version,
                    _fromDbOnly = true,
                    drawer = "lighten",
                })
                seen_keys[row.key] = true
            end
        end
    end
    return list
end

local function appendPdfEmbedded(list, plugin, ui, embedded)
    if type(embedded) ~= "table" then
        return list
    end
    local PdfEmb = loadPdfEmbedded(plugin)
    if PdfEmb and PdfEmb.dedupeAgainstLocal then
        embedded = PdfEmb.dedupeAgainstLocal(embedded, list)
    end
    for _, emb in ipairs(embedded) do
        table.insert(list, emb)
    end
    return list
end

local function annotationsToItems(annotations, filter)
    local items = {}
    local pdf_embedded_count = 0
    for i, ann in ipairs(annotations) do
        if matchesFilter(ann, filter) then
            if ann._fromPdfEmbedded then
                pdf_embedded_count = pdf_embedded_count + 1
            end
            table.insert(items, {
                text = annotationLabel(ann),
                ann = ann,
                index = ann._sidecarIndex or i,
            })
        end
    end
    return items, pdf_embedded_count
end

local function panelTitle(count, filter, status_suffix)
    local title = _("Document annotations") .. " (" .. tostring(count) .. ")"
    if filter ~= nil and filter ~= "" then
        title = title .. " - " .. filter
    end
    if status_suffix and status_suffix ~= "" then
        title = title .. " · " .. status_suffix
    end
    return title
end

local function refreshMenu(menu, items, filter, status_suffix)
    if not menu then
        return
    end
    local title = panelTitle(#items, filter, status_suffix)
    if menu.switchItemTable then
        pcall(function()
            menu:switchItemTable(title, items)
        end)
    end
end

local function ensureAttached(ui, file_path, attachment_key)
    if not attachment_key then
        return
    end
    -- Avoid re-attaching on every panel open (freezes on large libraries).
    if ui and ui._zotero_panel_attached_key == attachment_key then
        return
    end
    local item = ZoteroAPI.getItem(attachment_key)
    if not item then
        return
    end
    local ok, err = pcall(function()
        ZoteroAPI.attachItemAnnotations(item, nil, file_path, true)
    end)
    if not ok then
        logger.err("Zotero: panel attach failed: ", err)
        return
    end
    if ui then
        ui._zotero_panel_attached_key = attachment_key
    end
    if ui and ui.doc_settings and file_path then
        local ds = DocSettings:open(file_path)
        local anns = ds:readSetting("annotations", {}) or {}
        ds:close()
        if ui.annotation then
            ui.annotation.annotations = anns
        end
        ui.doc_settings:saveSetting("annotations", anns)
    end
end

function AnnotationPanel.show(ui, opts)
    opts = opts or {}
    if ui == nil or ui.document == nil then
        UIManager:show(InfoMessage:new({
            text = _("Open a document first."),
            timeout = 2,
        }))
        return
    end

    local file_path = ui.document.file
    local filter = opts.filter or ""
    local is_pdf = ui.document.is_pdf and true or false

    -- INSTANT: sidecar/live only. Never touch Zotero DB or PDF here
    -- (findAttachmentKeyByFilePath can take tens of seconds on large libraries).
    local annotations = buildLocalOnlyList(ui, file_path)
    local items = annotationsToItems(annotations, filter)
    local attachment_key = nil
    local pdf_embedded_count = 0

    table.insert(items, 1, {
        text = "… " .. _("Loading…"),
        ann = { _scanningPlaceholder = true },
        index = 0,
    })

    local use_side = ZoteroAPI.getLargeScreenAnnotationPanel() and ZoteroAPI.isLargeScreen()
    local panel_w = use_side and math.floor(Screen:getWidth() * 0.38) or nil
    local panel_h = use_side and Screen:getHeight() or nil

    local shell
    local menu
    local closed = false
    local function closePanel()
        closed = true
        if shell then
            UIManager:close(shell)
        elseif menu then
            UIManager:close(menu)
        end
    end

    local function reopen(new_filter)
        closePanel()
        AnnotationPanel.show(ui, { filter = new_filter or filter, plugin = opts.plugin })
    end

    menu = Menu:new({
        title = panelTitle(#items, filter, _("Loading…")),
        item_table = items,
        is_borderless = not use_side,
        is_popout = not use_side,
        width = panel_w,
        height = panel_h,
        covers_full_screen = false,
        multilines_show_more_text = true,
        title_bar_left_icon = "appbar.search",
        onLeftButtonTap = function()
            local dialog
            dialog = InputDialog:new({
                title = _("Filter annotations"),
                input = filter,
                input_hint = _("text, note, page…"),
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(dialog)
                            end,
                        },
                        {
                            text = _("Clear"),
                            callback = function()
                                UIManager:close(dialog)
                                reopen("")
                            end,
                        },
                        {
                            text = _("Filter"),
                            is_enter_default = true,
                            callback = function()
                                local q = dialog:getInputText()
                                UIManager:close(dialog)
                                reopen(q)
                            end,
                        },
                    },
                },
            })
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end,
        onMenuChoice = function(a, b)
            local item = menuItemArg(a, b)
            if not item or not item.ann or item.ann._scanningPlaceholder then
                return
            end
            closePanel()
            -- Defer navigation so Menu can finish closing cleanly.
            local ann_ref = item.ann
            UIManager:scheduleIn(0.05, function()
                gotoAnnotation(ui, ann_ref)
            end)
        end,
        onMenuHold = function(a, b)
            -- MUST return immediately and defer UI: showing a dialog inside the
            -- hold gesture handler re-enters input/paint and native-crashes KOReader.
            local item = menuItemArg(a, b)
            if not item or not item.ann or item.ann._scanningPlaceholder then
                return true
            end
            -- Snapshot plain fields only (no live table mutation during gesture).
            local ann_ref = item.ann
            local page_n = tonumber(ann_ref.pageno or ann_ref.page)
            local from_pdf = ann_ref._fromPdfEmbedded and true or false
            local from_db = ann_ref._fromDbOnly and true or false
            local sidecar_index = ann_ref._sidecarIndex or item.index
            local can_convert = from_pdf
                and attachment_key
                and opts.plugin
                and opts.plugin.migratePdfEmbeddedToZotero

            UIManager:scheduleIn(0.15, function()
                if closed then
                    return
                end
                local ok_ui, err_ui = pcall(function()
                    if from_db then
                        UIManager:show(InfoMessage:new({
                            text = _(
                                "This annotation is in Zotero but not yet in the reader.\nUse « Sync document annotations » then reopen this list."
                            ),
                            timeout = 4,
                        }))
                        return
                    end

                    local dialog
                    local rows = {}
                    -- Always offer go-to: page may be resolved on demand from text.
                    table.insert(rows, {
                        {
                            text = _("Go to page"),
                            callback = function()
                                UIManager:close(dialog)
                                closePanel()
                                UIManager:scheduleIn(0.05, function()
                                    gotoAnnotation(ui, ann_ref)
                                end)
                            end,
                        },
                    })
                    if can_convert then
                        table.insert(rows, {
                            {
                                text = _("Convert to Zotero"),
                                callback = function()
                                    UIManager:close(dialog)
                                    closePanel()
                                    opts.plugin:migratePdfEmbeddedToZotero(ui, { ann_ref }, {
                                        notify = true,
                                        on_done = function()
                                            AnnotationPanel.show(ui, {
                                                filter = filter,
                                                plugin = opts.plugin,
                                            })
                                        end,
                                    })
                                end,
                            },
                        })
                    end
                    if not from_pdf and not from_db then
                        table.insert(rows, {
                            {
                                text = _("Delete"),
                                callback = function()
                                    UIManager:close(dialog)
                                    if ui.annotation and ui.annotation.annotations and sidecar_index then
                                        pcall(function()
                                            table.remove(ui.annotation.annotations, sidecar_index)
                                            if ui.doc_settings then
                                                ui.doc_settings:saveSetting(
                                                    "annotations",
                                                    ui.annotation.annotations
                                                )
                                                ui.doc_settings:flush()
                                            end
                                        end)
                                    end
                                    closePanel()
                                    AnnotationPanel.show(ui, {
                                        filter = filter,
                                        plugin = opts.plugin,
                                    })
                                end,
                            },
                        })
                    end
                    table.insert(rows, {
                        {
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(dialog)
                            end,
                        },
                    })
                    -- Fixed translated title only — never annotation body text.
                    dialog = ButtonDialog:new({
                        title = _("Annotation"),
                        buttons = rows,
                    })
                    UIManager:show(dialog)
                end)
                if not ok_ui then
                    logger.err("Zotero: deferred hold UI failed: ", err_ui)
                end
            end)
            return true
        end,
        close_callback = function()
            closePanel()
        end,
    })

    if use_side then
        local screen_w = Screen:getWidth()
        local screen_h = Screen:getHeight()
        local scrim_w = screen_w - panel_w
        local framed = FrameContainer:new({
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            padding = 0,
            margin = 0,
            width = panel_w,
            height = panel_h,
            menu,
        })
        local scrim = InputContainer:new({
            dimen = Geom:new({
                w = scrim_w,
                h = screen_h,
            }),
        })
        scrim.ges_events = {
            TapCloseSidePanel = {
                GestureRange:new({
                    ges = "tap",
                    range = function()
                        return scrim.dimen
                    end,
                }),
            },
        }
        function scrim:onTapCloseSidePanel()
            UIManager:close(shell)
            return true
        end
        shell = HorizontalGroup:new({
            dimen = Geom:new({
                w = screen_w,
                h = screen_h,
            }),
            scrim,
            framed,
        })
        menu.show_parent = shell
        UIManager:show(shell)
    else
        UIManager:show(menu)
    end

    -- Force a paint so the user sees the panel before heavy work.
    pcall(function()
        if UIManager.forceRePaint then
            UIManager:forceRePaint()
        elseif UIManager.repaintEntireScreen then
            UIManager:repaintEntireScreen()
        end
    end)

    -- Parallel background: Zotero lookup + chunked PDF scan (each refreshes when ready).
    local zotero_done = false
    local pdf_done = not is_pdf
    local embedded = {}
    local pdf_pct = 0

    local function paintSoon()
        pcall(function()
            if UIManager.forceRePaint then
                UIManager:forceRePaint()
            end
        end)
    end

    local function rebuildMerged(status_suffix, show_placeholder)
        if closed or not ui or not ui.document or ui.document.file ~= file_path then
            return
        end
        local list = buildLocalOnlyList(ui, file_path)
        if attachment_key then
            list = appendZoteroDbAnnotations(list, attachment_key)
        end
        if pdf_done then
            list = appendPdfEmbedded(list, opts.plugin, ui, embedded)
        end
        items, pdf_embedded_count = annotationsToItems(list, filter)
        if show_placeholder then
            table.insert(items, 1, {
                text = "… " .. (status_suffix or _("Loading…")),
                ann = { _scanningPlaceholder = true },
                index = 0,
            })
        elseif #items == 0 then
            items = {
                {
                    text = _("No annotations in this document."),
                    ann = { _scanningPlaceholder = true },
                    index = 0,
                },
            }
        end
        local suffix = status_suffix
        if not show_placeholder and pdf_embedded_count > 0 then
            suffix = "PDF " .. tostring(pdf_embedded_count)
        end
        refreshMenu(menu, items, filter, suffix)
        paintSoon()
    end

    UIManager:scheduleIn(0.05, function()
        if closed or not ui or not ui.document or ui.document.file ~= file_path then
            return
        end
        refreshMenu(menu, items, filter, _("Looking up Zotero…"))
        paintSoon()

        local ok_key, key_or_err = pcall(ZoteroAPI.findAttachmentKeyByFilePath, file_path)
        if ok_key then
            attachment_key = key_or_err
        end
        zotero_done = true
        if closed then
            return
        end
        if attachment_key then
            UIManager:scheduleIn(0.2, function()
                if not closed and ui and ui.document and ui.document.file == file_path then
                    pcall(ensureAttached, ui, file_path, attachment_key)
                end
            end)
        end
        local status = nil
        if not pdf_done then
            status = string.format(_("Scanning PDF… %d%%"), pdf_pct)
        end
        rebuildMerged(status, not zotero_done or not pdf_done)
    end)

    if is_pdf then
        UIManager:scheduleIn(0.05, function()
            if closed or not ui or not ui.document or ui.document.file ~= file_path then
                return
            end
            local PdfEmb = loadPdfEmbedded(opts.plugin)
            if not PdfEmb or type(PdfEmb.listAsync) ~= "function" then
                if PdfEmb then
                    local ok_e, res = pcall(PdfEmb.list, ui)
                    if ok_e and type(res) == "table" then
                        embedded = res
                    end
                end
                pdf_done = true
                rebuildMerged(nil, not zotero_done)
                return
            end
            local last_paint_pct = -10
            PdfEmb.listAsync(ui, {
                cancelled = function()
                    return closed
                        or not ui
                        or not ui.document
                        or ui.document.file ~= file_path
                end,
                on_progress = function(pct, annot_count)
                    if closed then
                        return
                    end
                    pdf_pct = pct or 0
                    -- Throttle e-ink repaints (every ~8%).
                    if pdf_pct - last_paint_pct < 8 and pdf_pct < 100 then
                        return
                    end
                    last_paint_pct = pdf_pct
                    local label = string.format(
                        _("Scanning PDF… %d%% (%d)"),
                        pdf_pct,
                        annot_count or 0
                    )
                    refreshMenu(menu, items, filter, label)
                    paintSoon()
                end,
                on_done = function(list)
                    if closed then
                        return
                    end
                    embedded = type(list) == "table" and list or {}
                    pdf_done = true
                    rebuildMerged(nil, not zotero_done)
                end,
            })
        end)
    end
end

return AnnotationPanel
