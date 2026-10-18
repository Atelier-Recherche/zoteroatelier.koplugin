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

local function sourceBadge(ann)
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

local function annotationLabel(ann)
    local page = ann.pageno or ann.page or "?"
    local text = ann.note or ann.text or _("(no text)")
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

local function gotoAnnotation(ui, ann)
    if ui == nil or ann == nil then
        return
    end
    local page = tonumber(ann.pageno or ann.page)
    local ok = pcall(function()
        if page and ui.paging and ui.paging.onGotoPage then
            ui.paging:onGotoPage(page)
        elseif page and ui.link and ui.link.onGotoPage then
            ui.link:onGotoPage(page)
        elseif ann.pos0 and ann.pos0.xpointer and ui.link and ui.link.onGotoXPointer then
            ui.link:onGotoXPointer(ann.pos0.xpointer)
        elseif page and ui.document and ui.document.gotoPage then
            ui.document:gotoPage(page)
        end
    end)
    return ok
end

local function buildUnifiedList(ui, file_path)
    local list = collectLocalAnnotations(ui, file_path)
    local seen_keys = {}
    for _, ann in ipairs(list) do
        if ann.zoteroKey then
            seen_keys[ann.zoteroKey] = true
        end
    end

    local attachment_key = nil
    pcall(function()
        attachment_key = ZoteroAPI.findAttachmentKeyByFilePath(file_path)
    end)
    if attachment_key then
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
    end
    return list, attachment_key
end

local function ensureAttached(ui, file_path, attachment_key)
    if not attachment_key then
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
    local attachment_key = nil
    pcall(function()
        attachment_key = ZoteroAPI.findAttachmentKeyByFilePath(file_path)
    end)
    if attachment_key then
        ensureAttached(ui, file_path, attachment_key)
    end

    local filter = opts.filter or ""
    local annotations = buildUnifiedList(ui, file_path)
    local items = {}

    for i, ann in ipairs(annotations) do
        if matchesFilter(ann, filter) then
            table.insert(items, {
                text = annotationLabel(ann),
                ann = ann,
                index = ann._sidecarIndex or i,
            })
        end
    end

    if #items == 0 then
        local hint = ""
        if not attachment_key then
            hint = "\n\n"
                .. _(
                    "This file is not linked to a Zotero attachment."
                )
                .. "\n"
                .. _(
                    "Check Local files path mapping (avoid .stversions)."
                )
        end
        UIManager:show(InfoMessage:new({
            text = filter ~= "" and _("No matching annotations.")
                or (
                    _(
                        "No annotations in this document.\n\nTo create one: select text in the book, choose Highlight (or Add note), then use « Sync document annotations »."
                    ) .. hint
                ),
            timeout = 6,
        }))
        return
    end

    local use_side = ZoteroAPI.getLargeScreenAnnotationPanel() and ZoteroAPI.isLargeScreen()
    local panel_w = use_side and math.floor(Screen:getWidth() * 0.38) or nil
    local panel_h = use_side and Screen:getHeight() or nil

    local shell -- RightContainer when side panel; nil for popout
    local menu
    local function closePanel()
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
        title = _("Document annotations")
            .. " ("
            .. #items
            .. ")"
            .. (filter ~= "" and (" - " .. filter) or ""),
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
        onMenuChoice = function(_, item)
            closePanel()
            if item.ann and item.ann._fromDbOnly and attachment_key then
                ensureAttached(ui, file_path, attachment_key)
            end
            gotoAnnotation(ui, item.ann)
        end,
        onMenuHold = function(_, item)
            if item.ann and item.ann._fromDbOnly then
                UIManager:show(InfoMessage:new({
                    text = _(
                        "This annotation is in Zotero but not yet in the reader.\nUse « Sync document annotations » then reopen this list."
                    ),
                    timeout = 4,
                }))
                return true
            end
            local dialog
            dialog = ButtonDialog:new({
                title = _("Delete this annotation?"),
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(dialog)
                            end,
                        },
                        {
                            text = _("Delete"),
                            callback = function()
                                UIManager:close(dialog)
                                local idx = item.ann and item.ann._sidecarIndex or item.index
                                if ui.annotation and ui.annotation.annotations and idx then
                                    table.remove(ui.annotation.annotations, idx)
                                    if ui.doc_settings then
                                        ui.doc_settings:saveSetting(
                                            "annotations",
                                            ui.annotation.annotations
                                        )
                                        ui.doc_settings:flush()
                                    end
                                end
                                closePanel()
                                if opts.plugin and opts.plugin.syncOpenDocumentAnnotations then
                                    opts.plugin:syncOpenDocumentAnnotations(ui, { notify = false })
                                end
                                AnnotationPanel.show(ui, { filter = filter, plugin = opts.plugin })
                            end,
                        },
                    },
                },
            })
            UIManager:show(dialog)
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
end

return AnnotationPanel
