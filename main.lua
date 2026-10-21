local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher") -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local SpinWidget = require("ui/widget/spinwidget")
local DataStorage = require("datastorage")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LineWidget = require("ui/widget/linewidget")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local Menu = require("ui/widget/menu")
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
local ZoteroAPI = require("zoteroapi")
local itemInfoViewer = require("zoteroiteminfo")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local NetworkMgr = require("ui/network/manager")
local DocSettings = require("docsettings")
local Trapper = require("frontend/ui/trapper")

-- Load sibling plugin modules (require, then dofile from plugin folder).
local function loadPluginModule(plugin, name)
    local ok, mod = pcall(require, name)
    if ok and mod then
        return mod
    end
    local base = plugin and plugin.path
    if (not base or base == "") and debug and debug.getinfo then
        local src = debug.getinfo(1, "S").source
        if type(src) == "string" and src:sub(1, 1) == "@" then
            base = src:sub(2):match("^(.*)[/\\]") 
        end
    end
    if base and base ~= "" then
        local path = base .. "/" .. name .. ".lua"
        path = path:gsub("\\", "/")
        ok, mod = pcall(dofile, path)
        if ok and mod then
            return mod
        end
        logger.err("Zotero Atelier: dofile ", path, " failed: ", mod)
    else
        logger.err("Zotero Atelier: require ", name, " failed: ", mod)
    end
    return nil
end

local DEFAULT_LINES_PER_PAGE = 14

local init_done = false

local table_empty = function(table)
    -- see https://stackoverflow.com/a/1252776
    local next = next
    return (next(table) == nil)
end

local function truncatePath(p, max_len)
    max_len = max_len or 40
    if p == nil or p == "" then
        return _("(not set)")
    end
    if #p <= max_len then
        return p
    end
    return "…" .. p:sub(-max_len + 2)
end

local AnnotationsMod = nil
local function getAnnotationsMod()
    if AnnotationsMod == nil then
        local ok, mod = pcall(require, "annotations")
        if ok then
            AnnotationsMod = mod
        end
    end
    return AnnotationsMod
end

local function setHighlightWriteIntoPdf(file_path, enabled)
    if not file_path or not string.lower(file_path):match("%.pdf$") then
        return
    end
    local doc_settings = DocSettings:open(file_path)
    doc_settings:saveSetting("highlight_write_into_pdf", enabled and true or false)
    doc_settings:flush()
    -- Keep live reader setting in sync when open
end

-- EPUB rolling: page/pos must be DocFragment xpointers. Bare "1"/numeric pages crash CRE on open.
local function sanitizeEpubSidecarAnnotations(file_path)
    if not file_path or not string.lower(file_path):match("%.epub$") then
        return false
    end
    local changed = false
    pcall(function()
        local ds = DocSettings:open(file_path)
        local anns = ds:readSetting("annotations", {}) or {}
        local EpubCfi = nil
        pcall(function()
            EpubCfi = require("epub_cfi")
        end)
        local JSON = nil
        pcall(function()
            JSON = require("json")
        end)
        for _, ann in ipairs(anns) do
            -- Nested Zotero payload accidentally persisted — breaks KOReader highlight draw
            if ann._matchItem ~= nil then
                ann._matchItem = nil
                changed = true
            end
            local pg = ann.page
            local bad = type(pg) == "number"
                or (type(pg) == "string" and not pg:find("DocFragment", 1, true))
            if bad then
                local cfi = ann.zoteroCfi
                if JSON and type(ann.zoteroAnnotationPosition) == "string" then
                    local ok, pos = pcall(JSON.decode, ann.zoteroAnnotationPosition)
                    if ok and type(pos) == "table" then
                        cfi = cfi or pos.value
                    end
                end
                local xp0, xp1 = nil, nil
                if EpubCfi and cfi then
                    if EpubCfi.normalizeCfi then
                        cfi = EpubCfi.normalizeCfi(cfi) or cfi
                        ann.zoteroCfi = cfi
                    end
                    xp0, xp1 = EpubCfi.toKOReaderPositions(tostring(cfi), file_path)
                end
                if not xp0 then
                    local Ann = getAnnotationsMod()
                    local frag = Ann and Ann.docFragmentFromEpubCfi and Ann.docFragmentFromEpubCfi(cfi)
                    frag = frag
                        or (type(pg) == "number" and pg)
                        or (type(pg) == "string" and tonumber(pg))
                        or 1
                    xp0 = string.format("/body/DocFragment[%d]/body", frag)
                end
                ann.page = xp0
                ann.pos0 = xp0
                ann.pos1 = xp1 or xp0
                ann.pageno = tonumber(xp0:match("DocFragment%[(%d+)%]")) or ann.pageno or 1
                changed = true
            end
        end
        if changed then
            ds:saveSetting("annotations", anns)
            if ds.delSetting then
                ds:delSetting("annotations_paging")
                ds:delSetting("annotations_rolling")
            end
            ds:flush()
            logger.info("Zotero: sanitized EPUB sidecar annotations (non-xpointer page)")
        end
        pcall(function()
            ds:close()
        end)
    end)
    return changed
end

-- Apply default highlight color/style + PDF write-into-file from plugin settings.
local function configureZoteroDocumentSettings(file_path)
    if not file_path then
        return
    end
    sanitizeEpubSidecarAnnotations(file_path)
    local color = ZoteroAPI.getDefaultHighlightColor()
    local drawer = ZoteroAPI.getDefaultHighlightDrawer()
    pcall(function()
        local doc_settings = DocSettings:open(file_path)
        doc_settings:saveSetting("highlight_color", color)
        doc_settings:saveSetting("highlight_drawer", drawer)
        doc_settings:flush()
        doc_settings:close()
    end)

    local is_pdf = string.lower(file_path):match("%.pdf$") ~= nil
    if not is_pdf then
        return -- EPUB: sidecar only; color/drawer already applied
    end
    local key = nil
    pcall(function()
        key = ZoteroAPI.findAttachmentKeyByFilePath(file_path)
    end)
    local write = false
    if key then
        local Ann = getAnnotationsMod()
        local dest = ZoteroAPI.getEffectiveZoteroDestination()
        if Ann then
            write = Ann.shouldWriteIntoPdf({ zoteroDestination = dest })
        else
            write = dest == "local" or dest == "both"
        end
        if ZoteroAPI.getSettings():readSetting("auto_disable_pdf_writing", false) then
            write = false
        end
    else
        write = ZoteroAPI.getAnnotationDestinationNonZotero() == "local"
    end
    logger.info("Zotero: highlight_write_into_pdf=" .. tostring(write) .. " for " .. file_path)
    setHighlightWriteIntoPdf(file_path, write)
end

local function applyDefaultHighlightToOpenReader(ui)
    if not ui or not ui.document then
        return
    end
    local color = ZoteroAPI.getDefaultHighlightColor()
    local drawer = ZoteroAPI.getDefaultHighlightDrawer()
    logger.info("Zotero: apply default highlight style color=" .. color .. " drawer=" .. drawer)
    -- KOReader uses view.highlight.saved_* for NEW highlights
    if ui.view then
        ui.view.highlight = ui.view.highlight or {}
        ui.view.highlight.saved_color = color
        ui.view.highlight.saved_drawer = drawer
    end
    if ui.highlight then
        -- Older / alternate fields some builds still read
        pcall(function()
            ui.highlight.saved_color = color
            ui.highlight.saved_drawer = drawer
        end)
        if ui.highlight.setSelectionColor then
            pcall(function()
                ui.highlight:setSelectionColor()
            end)
        end
    end
    if ui.doc_settings then
        pcall(function()
            ui.doc_settings:saveSetting("highlight_color", color)
            ui.doc_settings:saveSetting("highlight_drawer", drawer)
            ui.doc_settings:flush()
        end)
    end
    -- Persist on disk sidecar too (live reader may otherwise flush yellow back)
    if ui.document.file then
        pcall(function()
            local ds = DocSettings:open(ui.document.file)
            ds:saveSetting("highlight_color", color)
            ds:saveSetting("highlight_drawer", drawer)
            ds:flush()
            pcall(function()
                ds:close()
            end)
        end)
    end
    -- Global defaults so new books / re-open also inherit
    pcall(function()
        G_reader_settings:saveSetting("highlight_color", color)
        G_reader_settings:saveSetting("highlight_drawing_style", drawer)
        G_reader_settings:flush()
    end)
end

local function enableWriteIntoPdf(file_path)
    setHighlightWriteIntoPdf(file_path, true)
end

local ZoteroBrowser = Menu:extend({
    no_title = false,
    is_borderless = true,
    is_popout = false,
    show_path = true,
    --    subtitle = "test path",
    title_bar_fm_style = true,
    parent = nil,
    title_bar_left_icon = "appbar.search",
    covers_full_screen = true,
    return_arrow_propagation = false,
    -- Slightly ugly using the option below, but better than truncated single line:
    multilines_show_more_text = true,
})

function ZoteroBrowser:init()
    Menu.init(self)
    self.paths = {}
    self.keys = {}
end

-- Show search input
function ZoteroBrowser:onLeftButtonTap()
    local search_query_dialog
    search_query_dialog = InputDialog:new({
        title = _("Search Zotero titles"),
        input = "",
        input_hint = "search query",
        description = _("This will search title and first author of all entries."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(search_query_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(search_query_dialog)
                        self:displaySearchResults(search_query_dialog:getInputText())
                    end,
                },
            },
        },
    })
    UIManager:show(search_query_dialog)
    search_query_dialog:onShowKeyboard()
end

function ZoteroBrowser:onReturn()
    table.remove(self.paths, #self.paths)
    local dir = table.remove(self.keys, #self.keys)
    if #self.keys == 0 then
        self:displayCollection(nil)
    else
        self:displayCollection(self.keys[#self.keys])
    end
    return true
end

function ZoteroBrowser:openResolvedFile(full_path)
    if self.download_dialog then
        UIManager:close(self.download_dialog)
        self.download_dialog = nil
    end
    configureZoteroDocumentSettings(full_path)
    local close_cb = self.close_callback
    UIManager:scheduleIn(0.05, function()
        if close_cb then
            close_cb()
        end
        require("apps/reader/readerui"):showReader(full_path)
    end)
end

function ZoteroBrowser:showOpenError(e)
    local err_text = ""
    if e ~= nil then
        err_text = " " .. tostring(e)
    end
    UIManager:show(InfoMessage:new({
        text = _("Could not open file.") .. err_text,
        timeout = 5,
        icon = "notice-warning",
    }))
end

function ZoteroBrowser:openAttachment(key)
    local local_path, local_err = ZoteroAPI.tryResolveLocalAttachment(key)
    if local_err ~= nil then
        self:showOpenError(local_err)
        return
    end
    if local_path then
        self:openResolvedFile(local_path)
        return
    end

    self.download_dialog = InfoMessage:new({
        text = _("Downloading file"),
        timeout = 5,
        icon = "notice-info",
    })
    UIManager:show(self.download_dialog)
    NetworkMgr:runWhenOnline(function()
        local full_path, e = ZoteroAPI.downloadAndGetPath(key)
        if e ~= nil or full_path == nil then
            UIManager:close(self.download_dialog)
            self:showOpenError(e)
        else
            self:openResolvedFile(full_path)
        end
    end)
end

function ZoteroBrowser:onMenuSelect(item)
    if item.type == "collection" then
        table.insert(self.paths, item.text)
        table.insert(self.keys, item.key)
        self:displayCollection(item.key)
    elseif item.type == "wildcard_collection" then
        table.insert(self.paths, "All items")
        table.insert(self.keys, "all")
        self:displaySearchResults("")
    elseif item.type == "item" then
        local attachments = ZoteroAPI.getItemAttachments(item.key)
        if attachments == nil or table_empty(attachments) then
            UIManager:show(InfoMessage:new({
                text = _("The selected entry does not have any attachments."),
                timeout = 5,
                icon = "notice-warning",
            }))
            return
        end
        local pdf_attachment = nil
        for _, attachment in ipairs(attachments) do
            if attachment.is_pdf then
                pdf_attachment = attachment
                break
            end
        end
        if pdf_attachment then
            self:openAttachment(pdf_attachment.key)
        else
            self:openAttachment(attachments[#attachments].key)
        end
    elseif item.type == "attachment" then
        self:openAttachment(item.key)
    elseif item.type == "label" then
        -- nop
    end
end

function ZoteroBrowser:onMenuHold(item)
    if item.type == "item" then
        --table.insert(self.paths, item.key)
        --table.insert(self.keys, item.key)
        --self:displayAttachments(item.key)
        local itemDetails = ZoteroAPI.getItemWithAttachments(item.key)
        local itemInfo = itemInfoViewer:new()
        itemInfo:show(itemDetails, function(key)
            self:openAttachment(key)
        end)
    elseif item.type == "collection" then
        local is_offline_enabled = ZoteroAPI.isOfflineCollection(item.key)
        local button_label = "▢  Download this collection during sync"
        if is_offline_enabled then
            button_label = "✓ Download this collection during sync"
        end
        local collection_dialog
        collection_dialog = ButtonDialog:new({
            title = item.text,
            buttons = {
                {
                    {
                        text = button_label,
                        callback = function()
                            if is_offline_enabled then
                                ZoteroAPI.removeOfflineCollection(item.key)
                            else
                                ZoteroAPI.addOfflineCollection(item.key)
                            end
                            UIManager:close(collection_dialog)
                        end,
                    },
                },
            },
        })
        UIManager:show(collection_dialog)
    end
end

function ZoteroBrowser:displaySearchResults(query)
    local items = ZoteroAPI.displaySearchResults(query)
    table.insert(self.paths, query)
    table.insert(self.keys, "search")
    items = self:addLabelIfEmpty(items, "No search results!")
    self:setItems(items)
end

function ZoteroBrowser:displayCollection(collection_id)
    local items = ZoteroAPI.displayCollection(collection_id)

    if collection_id == nil then
        if table_empty(items) then
            items = self:addLabelIfEmpty(items, "Library is empty! Synchronise first...")
        else
            table.insert(items, 1, {
                ["text"] = _("All Items"),
                ["type"] = "wildcard_collection",
            })
        end
    else
        items = self:addLabelIfEmpty(items)
    end
    self:setItems(items)
end

function ZoteroBrowser:addLabelIfEmpty(items, msg)
    if table_empty(items) then
        if msg == nil then
            msg = "No Items"
        end
        table.insert(items, 1, {
            ["text"] = _(msg),
            ["type"] = "label",
        })
    end

    return items
end

function ZoteroBrowser:displayAttachments(key)
    local attachments = ZoteroAPI.getItemAttachments(key) or {}
    attachments = self:addLabelIfEmpty(attachments)

    self:setItems(attachments)
end

function ZoteroBrowser:zPath()
    local path = "HOME"
    if #self.paths > 0 then
        if self.keys[#self.keys] == "search" then
            path = "Search results: '" .. self.paths[#self.paths] .. "'"
        else
            path = "/" .. table.concat(self.paths, "")
        end
    end
    return path
end

function ZoteroBrowser:setItems(items, subtitle)
    local subtitle = self:zPath()
    self:switchItemTable("Zotero Browser", items, nil, nil, subtitle)
end

-- Left column of the dual-pane browser (collections only).
local ZoteroLeftPane = Menu:extend({
    no_title = false,
    is_borderless = true,
    is_popout = false,
    show_path = true,
    title_bar_fm_style = true,
    title_bar_left_icon = "appbar.search",
    covers_full_screen = false,
    return_arrow_propagation = false,
    multilines_show_more_text = true,
})

function ZoteroLeftPane:init()
    Menu.init(self)
    self.paths = {}
    self.keys = {}
end

function ZoteroLeftPane:onLeftButtonTap()
    if self.host and self.host.onDualPaneSearch then
        self.host:onDualPaneSearch()
    end
end

function ZoteroLeftPane:onReturn()
    table.remove(self.paths, #self.paths)
    table.remove(self.keys, #self.keys)
    local parent = self.keys[#self.keys]
    self:displayCollections(parent)
    if self.host then
        self.host:dualLoadRight(parent)
    end
    return true
end

function ZoteroLeftPane:onMenuSelect(item)
    if item.type == "collection" then
        table.insert(self.paths, item.text)
        table.insert(self.keys, item.key)
        self:displayCollections(item.key)
        if self.host then
            self.host:dualLoadRight(item.key)
        end
    elseif item.type == "wildcard_collection" then
        if self.host then
            self.host:dualLoadRight("all")
        end
    end
end

function ZoteroLeftPane:onMenuHold(item)
    if item.type == "collection" and self.host and self.host.browser then
        self.host.browser:onMenuHold(item)
    end
end

function ZoteroLeftPane:displayCollections(collection_id)
    local raw = ZoteroAPI.displayCollection(collection_id)
    local items = {}
    if collection_id == nil then
        if table_empty(raw) then
            items = {
                {
                    text = _("Library is empty! Synchronise first..."),
                    type = "label",
                },
            }
        else
            table.insert(items, {
                text = _("All Items"),
                type = "wildcard_collection",
            })
            for _, it in ipairs(raw) do
                if it.type == "collection" then
                    table.insert(items, it)
                end
            end
        end
    else
        for _, it in ipairs(raw) do
            if it.type == "collection" then
                table.insert(items, it)
            end
        end
        if table_empty(items) then
            table.insert(items, {
                text = _("No subcollections"),
                type = "label",
            })
        end
    end
    local path = "HOME"
    if #self.paths > 0 then
        path = "/" .. table.concat(self.paths, "/")
    end
    self:switchItemTable(_("Collections"), items, nil, nil, path)
end

-- Right column of the dual-pane browser (items / attachments).
local ZoteroRightPane = Menu:extend({
    no_title = false,
    is_borderless = true,
    is_popout = false,
    show_path = true,
    title_bar_fm_style = true,
    covers_full_screen = false,
    return_arrow_propagation = false,
    multilines_show_more_text = true,
})

function ZoteroRightPane:init()
    Menu.init(self)
end

function ZoteroRightPane:onMenuSelect(item)
    if not self.host or not self.host.browser then
        return
    end
    if item.type == "collection" then
        -- Drill into subcollection via left pane navigation
        if self.host.dual_left then
            self.host.dual_left:onMenuSelect(item)
        end
    else
        self.host.browser:onMenuSelect(item)
    end
end

function ZoteroRightPane:onMenuHold(item)
    if self.host and self.host.browser then
        self.host.browser:onMenuHold(item)
    end
end

function ZoteroRightPane:displayItems(collection_id)
    local items
    local subtitle
    if collection_id == "all" then
        items = ZoteroAPI.displaySearchResults("")
        subtitle = _("All Items")
    elseif collection_id == "search" then
        items = self._search_items or {}
        subtitle = self._search_subtitle or _("Search")
    else
        local raw = ZoteroAPI.displayCollection(collection_id)
        items = {}
        for _, it in ipairs(raw) do
            -- At library root, collections live in the left pane only.
            if collection_id ~= nil or it.type ~= "collection" then
                table.insert(items, it)
            end
        end
        subtitle = collection_id == nil and _("Library") or _("Collection")
    end
    if table_empty(items) then
        table.insert(items, {
            text = _("No Items"),
            type = "label",
        })
    end
    self:switchItemTable(_("Items"), items, nil, nil, subtitle)
end

local Plugin = WidgetContainer:new({
    name = "zoteroatelier",
    is_doc_only = false,
})

function Plugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("zotero_browser_action", {
        category = "none",
        event = "ZoteroBrowserAction",
        title = _("Zotero Atelier Collection Browser"),
        general = true,
    })
    Dispatcher:registerAction("zotero_sync_action", {
        category = "none",
        event = "ZoteroSyncAction",
        title = _("Zotero Atelier Sync"),
        general = true,
    })
end

function Plugin:reloadReaderAnnotations(readerui, expected_file)
    -- Never reload after close: readerui.document is already nil → crash in readerui.lua:941
    if not readerui or not readerui.document then
        return
    end
    if expected_file and readerui.document.file and readerui.document.file ~= expected_file then
        return
    end
    UIManager:scheduleIn(0.1, function()
        if not readerui or not readerui.document then
            return
        end
        if expected_file and readerui.document.file ~= expected_file then
            return
        end
        local file = readerui.document.file
        -- Soft refresh from disk sidecar. Avoid reloadDocument (RefBase / native crash).
        local soft_ok, soft_did = pcall(function()
            if not readerui.annotation then
                return false
            end
            -- Repair bad EPUB pages first so a single bad ann cannot block Z→K adds
            sanitizeEpubSidecarAnnotations(file)
            local DocSettings = require("docsettings")
            local ds = DocSettings:open(file)
            local anns = ds:readSetting("annotations")
            if type(anns) ~= "table" then
                pcall(function()
                    ds:close()
                end)
                return false
            end
            -- EPUB rolling: drop individual non-xpointer entries (do NOT abort whole reload —
            -- aborting left live UI stale, then close-flush wiped newly pulled Zotero adds).
            if readerui.rolling then
                local cleaned = {}
                local dropped = 0
                for _, a in ipairs(anns) do
                    local pg = a.page
                    if type(pg) == "number"
                        or (type(pg) == "string" and not pg:find("DocFragment", 1, true))
                    then
                        dropped = dropped + 1
                        logger.warn("Zotero: soft-reload drop non-xpointer ann: ", tostring(pg))
                    else
                        table.insert(cleaned, a)
                    end
                end
                if dropped > 0 then
                    anns = cleaned
                    ds:saveSetting("annotations", anns)
                    ds:flush()
                end
            end
            pcall(function()
                ds:close()
            end)
            readerui.annotation.annotations = anns
            if readerui.doc_settings then
                pcall(function()
                    readerui.doc_settings:saveSetting("annotations", anns)
                    -- Drop stale mode copies so rolling stays on annotations
                    readerui.doc_settings:saveSetting("annotations_paging", nil)
                    readerui.doc_settings:saveSetting("annotations_rolling", nil)
                    readerui.doc_settings:flush()
                end)
            end
            -- Drop stale screen-box cache so new/updated Zotero highlights actually paint
            if readerui.view and readerui.view.highlight then
                readerui.view.highlight.page_boxes = {}
            end
            local refreshed = false
            if readerui.annotation.updateAnnotations then
                local uok = pcall(function()
                    readerui.annotation:updateAnnotations(true, true)
                end)
                refreshed = uok
            end
            if UIManager and UIManager.setDirty then
                UIManager:setDirty(readerui, "ui")
            end
            return refreshed or true
        end)
        if soft_ok and soft_did then
            logger.info("Zotero: refreshed annotations from sidecar (no full reload)")
            return
        end
        if not soft_ok then
            logger.warn("Zotero: soft annotation refresh failed: ", soft_did)
        end
        -- Do NOT call reloadDocument here — it has crashed native (RefBase) after bad sidecars.
        logger.info("Zotero: annotation UI not refreshed; reopen document to pick up sidecar")
    end)
end

local function networkIsOnline()
    local checked = false
    local online = false
    pcall(function()
        if NetworkMgr.isOnline then
            checked = true
            online = NetworkMgr:isOnline() and true or false
        elseif NetworkMgr.isWifiOn then
            checked = true
            online = NetworkMgr:isWifiOn() and true or false
        elseif NetworkMgr.isConnected then
            checked = true
            online = NetworkMgr:isConnected() and true or false
        end
    end)
    -- If NetworkMgr has no status API, do not permanently stall auto-sync.
    if not checked then
        return true
    end
    return online
end

-- Sync annotations for a file path (works even if reader is closing).
-- opts.reload: reload reader after sync (default true if reader still open)
-- opts.prompt_wifi: if true (manual sync), may ask to enable WiFi; auto syncs never prompt
function Plugin:syncOpenDocumentAnnotations(readerui, opts)
    opts = opts or {}
    if not init_done then
        return
    end
    local file_path = opts.file_path
    if (file_path == nil or file_path == "") and readerui and readerui.document then
        file_path = readerui.document.file
    end
    if file_path == nil or file_path == "" then
        return
    end
    local key = ZoteroAPI.findAttachmentKeyByFilePath(file_path)
    if not key then
        if opts.notify then
            UIManager:show(InfoMessage:new({
                text = _("This file is not linked to a Zotero attachment."),
                timeout = 3,
                icon = "notice-warning",
            }))
        end
        return
    end
    local item = ZoteroAPI.getItem(key)
    -- Flush live annotations to sidecar before upload (only if reader still has them).
    -- EPUB rolling: never flush numeric-page tables (paging format) — that hides highlights.
    if readerui and readerui.annotation and readerui.annotation.annotations and readerui.doc_settings then
        pcall(function()
            local live = readerui.annotation.annotations
            if readerui.rolling then
                for _, a in ipairs(live) do
                    if type(a.page) == "number" then
                        logger.warn("Zotero: skip pre-sync flush — live annotations use numeric page")
                        return
                    end
                end
            end
            readerui.doc_settings:saveSetting("annotations", live)
            readerui.doc_settings:flush()
        end)
    end
    local want_reload = opts.reload
    if want_reload == nil then
        want_reload = true
    end
    -- Invalidate late callbacks from a previous open/close cycle
    self._annot_sync_gen = (self._annot_sync_gen or 0) + 1
    local sync_gen = self._annot_sync_gen
    local closing = opts.reload == false
    local prompt_wifi = opts.prompt_wifi == true

    -- Auto syncs must not spam WiFi dialogs when offline; queue until later.
    if not networkIsOnline() and not prompt_wifi then
        self._annot_dirty = true
        ZoteroAPI.markAnnotSyncPending(file_path)
        logger.info("Zotero: defer annotation sync (offline, no WiFi prompt): ", file_path)
        return
    end

    local function run_sync()
        local push_u, push_d, push_up = 0, 0, 0
        local ok, err = pcall(function()
            if item then
                pcall(ZoteroAPI.setAttachmentVersionByKey, key, item.version or 1)
            end
            push_u, push_d, push_up = ZoteroAPI.syncAnnotationsForAttachment(key, file_path, {
                push_only = opts.push_only == true,
            })
            return true
        end)
        if not ok then
            logger.err("Zotero: document annotation sync failed: ", err)
            self._annot_dirty = true
            ZoteroAPI.markAnnotSyncPending(file_path)
            if opts.notify and not closing then
                UIManager:show(InfoMessage:new({
                    text = _("Annotation sync failed: ") .. tostring(err),
                    timeout = 5,
                    icon = "notice-warning",
                }))
            end
            return
        end
        -- Local creates/updates/deletes were pushed; clear dirty so close stays fast
        if (push_u or 0) + (push_d or 0) + (push_up or 0) == 0 then
            self._annot_dirty = false
            ZoteroAPI.clearAnnotSyncPending(file_path)
        else
            -- Partial failure: keep pending for a later retry
            self._annot_dirty = true
            ZoteroAPI.markAnnotSyncPending(file_path)
        end
        -- Only reload if this sync gen is still current and the same file is open
        local still_same = readerui
            and readerui.document
            and readerui.document.file == file_path
            and sync_gen == self._annot_sync_gen
        if want_reload and still_same then
            self:reloadReaderAnnotations(readerui, file_path)
            -- Extra dirty: ensure remote add/delete become visible without reopen
            if UIManager and UIManager.setDirty then
                UIManager:setDirty(readerui, "ui")
            end
        end
        if opts.notify and not closing then
            local u, d, up = push_u or 0, push_d or 0, push_up or 0
            local problems = u + d + up
            local text
            local icon
            if problems == 0 then
                text = _("Annotations synced both ways.")
                icon = "notice-info"
            else
                -- Keep msgid static for gettext; append counts outside _()
                text = _("Annotations synced with some errors.")
                    .. "\n"
                    .. _("Upload:")
                    .. " "
                    .. tostring(u)
                    .. "  "
                    .. _("Delete:")
                    .. " "
                    .. tostring(d)
                    .. "  "
                    .. _("Update:")
                    .. " "
                    .. tostring(up)
                icon = "notice-warning"
            end
            UIManager:show(InfoMessage:new({
                text = text,
                timeout = 5,
                icon = icon,
            }))
        end
    end

    if prompt_wifi then
        NetworkMgr:runWhenOnline(run_sync)
    else
        -- Already online (checked above): run without WiFi prompt machinery
        run_sync()
    end
end

function Plugin:applyDestinationToAnnotation(ui, ann, dest, opts)
    if ann == nil then
        return
    end
    opts = opts or {}
    local Ann = getAnnotationsMod()
    dest = Ann and Ann.normalizeDestination(dest) or dest
    ann.zoteroDestination = dest
    ZoteroAPI.setAnnotationDestinationLast(dest)
    -- Settings / sidecar flush deferred so the note dialog can open immediately
    local file_path = ui and ui.document and ui.document.file
    local flush_now = opts.flush_now == true
    local function persist()
        ZoteroAPI.saveSettingsToFile()
        if file_path and string.lower(file_path):match("%.pdf$") then
            local write = Ann and Ann.shouldWriteIntoPdf(ann) or (dest == "local" or dest == "both")
            if ZoteroAPI.getSettings():readSetting("auto_disable_pdf_writing", false) then
                write = false
            end
            setHighlightWriteIntoPdf(file_path, write)
            if ui.doc_settings then
                ui.doc_settings:saveSetting("highlight_write_into_pdf", write)
            end
        end
        if ui and ui.annotation and ui.annotation.annotations and ui.doc_settings then
            ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
            ui.doc_settings:flush()
        end
    end
    if flush_now then
        persist()
    else
        UIManager:scheduleIn(0.05, function()
            pcall(persist)
        end)
    end
end

function Plugin:promptAnnotationDestination(ui, ann)
    if self._destination_dialog_open then
        return
    end
    self._destination_dialog_open = true
    local last = ZoteroAPI.getAnnotationDestinationLast()
    local Ann = getAnnotationsMod()
    local labels = {
        local_ = _("Local only (PDF file / EPUB sidecar)"),
        zotero = _("Zotero only"),
        both = _("Both (local + Zotero)"),
    }
    local function mark(dest)
        if dest == last then
            return "✓ "
        end
        return ""
    end
    local dialog
    dialog = ButtonDialog:new({
        title = _("Where to save this annotation?"),
        buttons = {
            {
                {
                    text = mark(Ann and Ann.DEST_LOCAL or "local") .. labels.local_,
                    callback = function()
                        UIManager:close(dialog)
                        self._destination_dialog_open = false
                        self:applyDestinationToAnnotation(ui, ann, Ann and Ann.DEST_LOCAL or "local", { flush_now = true })
                    end,
                },
            },
            {
                {
                    text = mark(Ann and Ann.DEST_ZOTERO or "zotero") .. labels.zotero,
                    callback = function()
                        UIManager:close(dialog)
                        self._destination_dialog_open = false
                        self:applyDestinationToAnnotation(ui, ann, Ann and Ann.DEST_ZOTERO or "zotero", { flush_now = true })
                    end,
                },
            },
            {
                {
                    text = mark(Ann and Ann.DEST_BOTH or "both") .. labels.both,
                    callback = function()
                        UIManager:close(dialog)
                        self._destination_dialog_open = false
                        self:applyDestinationToAnnotation(ui, ann, Ann and Ann.DEST_BOTH or "both", { flush_now = true })
                    end,
                },
            },
            {
                {
                    text = _("Cancel (use last choice)"),
                    callback = function()
                        UIManager:close(dialog)
                        self._destination_dialog_open = false
                        self:applyDestinationToAnnotation(ui, ann, last, { flush_now = true })
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
end

-- Parse title / authors / date from a filename stem (no extension).
-- Patterns: "Author - Title", "Author – Title (2020)", "Title (2020)", underscores as spaces.
local function parseFilenameMetadata(file_path)
    local base = ZoteroAPI.basenameOfPath(file_path) or "Untitled"
    local stem = base:gsub("%.[^%.]+$", "")
    stem = stem:gsub("_+", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local title, authors, date = stem, "", ""

    local y = stem:match("%((%d%d%d%d)%)%s*$") or stem:match("%[(%d%d%d%d)%]%s*$")
    if y then
        date = y
        stem = stem
            :gsub("%s*%(%d%d%d%d%)%s*$", "")
            :gsub("%s*%[%d%d%d%d%]%s*$", "")
            :gsub("%s+$", "")
    end

    -- Author - Title / Author – Title / Author — Title
    local a, t = stem:match("^(.+)%s+[–—%-]+%s+(.+)$")
    if a and t and #a >= 2 and #t >= 2 then
        authors = a:gsub("%s+$", "")
        title = t:gsub("^%s+", "")
    else
        title = stem
    end
    if title == "" then
        title = base:gsub("%.[^%.]+$", "")
    end
    return title, authors, date
end

local function guessDocMetadata(file_path, ui)
    local title, authors, date = "", "", ""
    pcall(function()
        local ds = DocSettings:open(file_path)
        local props = ds:readSetting("doc_props") or {}
        local custom = ds:readSetting("custom_props") or {}
        local stats = ds:readSetting("stats") or {}
        title = tostring(custom.title or props.title or stats.title or "")
        authors = tostring(custom.authors or props.authors or stats.authors or "")
        date = tostring(custom.date or props.date or stats.date or custom.years or props.years or "")
        pcall(function()
            ds:close()
        end)
    end)
    if (title == "" or authors == "") and ui and ui.document then
        pcall(function()
            local props = ui.document.info or ui.document.props or {}
            if title == "" and props.title then
                title = tostring(props.title)
            end
            if authors == "" and (props.authors or props.author) then
                authors = tostring(props.authors or props.author)
            end
            if date == "" and props.date then
                date = tostring(props.date)
            end
        end)
    end
    if title == "" then
        local t, a, d = parseFilenameMetadata(file_path)
        title = t
        if authors == "" then
            authors = a
        end
        if date == "" then
            date = d
        end
    end
    return title, authors, date
end

local function setMultiInputFieldTexts(dialog, values)
    if not dialog or type(values) ~= "table" then
        return false
    end
    local inputs = dialog.input_fields or dialog._input_fields
    if type(inputs) ~= "table" then
        return false
    end
    for i, text in ipairs(values) do
        local field = inputs[i]
        if type(field) == "table" and field.setText then
            pcall(function()
                field:setText(tostring(text or ""))
            end)
        end
    end
    return true
end

function Plugin:applyDisplayRestyle(ui)
    local mod = loadPluginModule(self, "display_restyle")
    if not mod then
        return
    end
    mod.apply(ZoteroAPI.getDisplaySquigglyBlack())
    if ui then
        mod.refreshReader(ui)
    end
end

-- opts.on_success(attachment_key) optional callback after successful create
function Plugin:showAddLinkedBookDialog(file_path, ui, opts)
    opts = opts or {}
    ui = ui or self.ui
    file_path = file_path or (ui and ui.document and ui.document.file)
    if not file_path or file_path == "" then
        UIManager:show(InfoMessage:new({
            text = _("Open a document first."),
            timeout = 3,
            icon = "notice-warning",
        }))
        return
    end
    if not ZoteroAPI.isPathUnderLinkedBase(file_path) then
        UIManager:show(InfoMessage:new({
            text = _("This file is not in the linked files folder."),
            timeout = 4,
            icon = "notice-warning",
        }))
        return
    end
    local existing = ZoteroAPI.findAttachmentKeyByFilePath(file_path)
    if existing then
        UIManager:show(InfoMessage:new({
            text = _("This file is already linked to a Zotero attachment."),
            timeout = 3,
        }))
        return
    end

    local title0, authors0, date0 = guessDocMetadata(file_path, ui)
    if opts._force_title ~= nil then
        title0 = opts._force_title
    end
    if opts._force_authors ~= nil then
        authors0 = opts._force_authors
    end
    if opts._force_date ~= nil then
        date0 = opts._force_date
    end
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Add to Zotero (linked file)"),
        fields = {
            {
                text = title0,
                hint = _("Title"),
            },
            {
                text = authors0,
                hint = _("Author(s)"),
            },
            {
                text = date0,
                hint = _("Date"),
            },
        },
        buttons = {
            {
                {
                    text = _("From filename"),
                    callback = function()
                        local t, a, d = parseFilenameMetadata(file_path)
                        if not setMultiInputFieldTexts(dialog, { t, a, d }) then
                            -- Fallback if field widgets are not exposed: reopen dialog
                            dialog:onClose()
                            UIManager:close(dialog)
                            local reopen_opts = {}
                            for k, v in pairs(opts) do
                                reopen_opts[k] = v
                            end
                            reopen_opts._force_title = t
                            reopen_opts._force_authors = a
                            reopen_opts._force_date = d
                            self:showAddLinkedBookDialog(file_path, ui, reopen_opts)
                        end
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        dialog:onClose()
                        UIManager:close(dialog)
                        if opts.on_cancel then
                            opts.on_cancel()
                        end
                    end,
                },
                {
                    text = _("Create"),
                    callback = function()
                        local fields = dialog:getFields()
                        local title = (fields[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        local authors = (fields[2] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        local date = (fields[3] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        if title == "" then
                            UIManager:show(InfoMessage:new({
                                text = _("Title is required."),
                                timeout = 3,
                                icon = "notice-warning",
                            }))
                            return
                        end
                        dialog:onClose()
                        UIManager:close(dialog)
                        NetworkMgr:runWhenOnline(function()
                            Trapper:wrap(function()
                                Trapper:info(_("Creating Zotero item…"))
                                local key, err = ZoteroAPI.createLinkedBookItem({
                                    title = title,
                                    authors = authors,
                                    date = date,
                                    file_path = file_path,
                                })
                                if not key then
                                    Trapper:info(_("Could not add to Zotero: ") .. tostring(err or "?"))
                                    if opts.on_cancel then
                                        opts.on_cancel()
                                    end
                                    return
                                end
                                Trapper:info(_("Added to Zotero as a linked file."))
                                if opts.on_success then
                                    opts.on_success(key)
                                end
                            end)
                        end)
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Plugin:promptUnlinkedAnnotation(ui, file_path, ann)
    if self._unlinked_dialog_open then
        return
    end
    self._unlinked_dialog_open = true
    local Ann = getAnnotationsMod()
    local under_vault = ZoteroAPI.isPathUnderLinkedBase(file_path)
    local dialog
    local function applyLocalOnly()
        self._unlinked_dialog_open = false
        local mode = ZoteroAPI.getAnnotationDestinationNonZotero()
        ann.zoteroDestination = Ann and Ann.DEST_LOCAL or "local"
        if string.lower(file_path):match("%.pdf$") then
            setHighlightWriteIntoPdf(file_path, mode == "local")
        end
        if ui and ui.doc_settings and ui.annotation then
            pcall(function()
                ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
                ui.doc_settings:flush()
            end)
        end
    end
    local buttons = {}
    if under_vault then
        table.insert(buttons, {
            {
                text = _("Add to Zotero…"),
                callback = function()
                    UIManager:close(dialog)
                    self._unlinked_dialog_open = false
                    self:showAddLinkedBookDialog(file_path, ui, {
                        on_success = function()
                            -- Resume normal destination flow now that the file is linked
                            if ZoteroAPI.getAnnotationDestinationAsk() then
                                self:applyDestinationToAnnotation(
                                    ui,
                                    ann,
                                    ZoteroAPI.getAnnotationDestinationLast()
                                )
                                UIManager:scheduleIn(0.25, function()
                                    self:promptAnnotationDestination(ui, ann)
                                end)
                            else
                                self:applyDestinationToAnnotation(
                                    ui,
                                    ann,
                                    ZoteroAPI.getAnnotationDestinationDefault()
                                )
                            end
                            UIManager:scheduleIn(2.5, function()
                                self:syncOpenDocumentAnnotations(ui, {
                                    notify = false,
                                    reload = false,
                                    file_path = file_path,
                                })
                            end)
                        end,
                        on_cancel = applyLocalOnly,
                    })
                end,
            },
        })
        table.insert(buttons, {
            {
                text = _("Keep local only"),
                callback = function()
                    UIManager:close(dialog)
                    applyLocalOnly()
                end,
            },
        })
    else
        table.insert(buttons, {
            {
                text = _("OK"),
                callback = function()
                    UIManager:close(dialog)
                    applyLocalOnly()
                end,
            },
        })
    end
    dialog = ButtonDialog:new({
        title = under_vault
                and _("This document is not in Zotero yet.")
            or _("This document is not linked to Zotero. Annotation stays local."),
        buttons = buttons,
    })
    UIManager:show(dialog)
end

-- Called by KOReader when highlights/notes change.
-- Must return immediately: KOReader opens the note dialog only after this handler finishes.
-- Heavy work (attachment lookup, destination, Zotero upload) runs on the next UI ticks.
function Plugin:onAnnotationsModified(items)
    if not init_done or not self.ui or not self.ui.document or not self.ui.document.file then
        return
    end
    if items == nil then
        return
    end
    local added = (items.nb_highlights_added or 0) + (items.nb_notes_added or 0)
    local ui = self.ui
    local file_path = ui.document.file
    self._annot_dirty = true

    -- Local deletion: flush sidecar then record pending deletes + sync soon.
    -- items[1] is the removed annotation (still carries zoteroKey) — use it so we
    -- never mark the neighbour as deleted when the known/sidecar diff is noisy.
    if added < 0 then
        local deleted_ann = items[1]
        UIManager:scheduleIn(0.15, function()
            self:handleAnnotationDeletedDeferred(ui, file_path, deleted_ann)
        end)
        return
    end

    -- Existing Zotero-linked annotation edited (note added/changed, style, text…).
    -- KOReader fires this with added==0 (e.g. highlight→note: -1 highlight +1 note),
    -- or with just { item } for style edits — must NOT fall through to "new highlight".
    local edited = items[1]
    if edited and edited.zoteroKey then
        UIManager:scheduleIn(0.2, function()
            self:handleAnnotationUpdatedDeferred(ui, file_path, edited)
        end)
        return
    end

    if added == 0 and items.index_modified ~= nil and items[1] == nil then
        return
    end

    -- Capture snapshot; do not touch DocSettings / DB here (blocks note UI ~seconds).
    local items_snap = items
    UIManager:scheduleIn(0.01, function()
        self:handleAnnotationAddedDeferred(ui, file_path, items_snap, added)
    end)
end

-- Note / style / text change on an annotation that already has a zoteroKey.
function Plugin:handleAnnotationUpdatedDeferred(ui, file_path, edited_ann)
    if not file_path then
        return
    end
    if ui and ui.annotation and ui.annotation.annotations and ui.doc_settings then
        pcall(function()
            ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
            ui.doc_settings:flush()
        end)
    end
    local key = ZoteroAPI.findAttachmentKeyByFilePath(file_path)
    if not key then
        return
    end
    logger.info(
        "Zotero: local edit on "
            .. tostring(edited_ann and edited_ann.zoteroKey)
            .. " (note/style) → schedule sync"
    )
    UIManager:scheduleIn(0.6, function()
        self:syncOpenDocumentAnnotations(ui, {
            notify = false,
            reload = false,
            file_path = file_path,
        })
    end)
end

function Plugin:handleAnnotationDeletedDeferred(ui, file_path, deleted_ann)
    if not file_path then
        return
    end
    -- Flush live annotations (without deleted ones) to disk first
    if ui and ui.annotation and ui.annotation.annotations and ui.doc_settings then
        pcall(function()
            ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
            ui.doc_settings:flush()
        end)
    end
    local key = ZoteroAPI.findAttachmentKeyByFilePath(file_path)
    if not key then
        return
    end
    local keys_now = {}
    pcall(function()
        local ds = DocSettings:open(file_path)
        local anns = ds:readSetting("annotations", {}) or {}
        for _, ann in ipairs(anns) do
            if ann.zoteroKey then
                keys_now[ann.zoteroKey] = true
            end
        end
        pcall(function()
            ds:close()
        end)
    end)
    local deleted_key = deleted_ann and deleted_ann.zoteroKey or nil
    local pending
    if deleted_key then
        pending = ZoteroAPI.noteExplicitLocalAnnotationDeletion(key, deleted_key, keys_now)
        logger.info("Zotero: explicit local delete " .. tostring(deleted_key))
    else
        pending = ZoteroAPI.noteLocalAnnotationDeletions(key, keys_now)
    end
    local n = 0
    if type(pending) == "table" then
        for _ in pairs(pending) do
            n = n + 1
        end
    end
    logger.info("Zotero: recorded " .. tostring(n) .. " pending local delete(s) for " .. tostring(key))
    -- Sync soon (while still online / document may still be open)
    UIManager:scheduleIn(0.5, function()
        self:syncOpenDocumentAnnotations(ui, {
            notify = false,
            reload = false,
            file_path = file_path,
        })
    end)
end

function Plugin:handleAnnotationAddedDeferred(ui, file_path, items, added)
    if not ui or not ui.document or ui.document.file ~= file_path then
        return
    end
    local ann = items[1]
    if ann == nil and items.index_modified and ui.annotation and ui.annotation.annotations then
        ann = ui.annotation.annotations[items.index_modified]
    end
    if ann == nil and ui.annotation and ui.annotation.annotations then
        local list = ui.annotation.annotations
        for i = #list, 1, -1 do
            if list[i].drawer and list[i].zoteroDestination == nil and list[i].zoteroKey == nil then
                ann = list[i]
                break
            end
        end
    end
    if ann == nil then
        return
    end
    -- Already decided (pulled from Zotero or previous prompt)
    if ann.zoteroDestination ~= nil or ann.zoteroKey ~= nil then
        return
    end
    if added == 0 and (ann.drawer == nil) then
        return
    end

    -- Force plugin default style onto brand-new highlights.
    -- KOReader often still paints with stock yellow/lighten even when settings say otherwise.
    applyDefaultHighlightToOpenReader(ui)
    local def_color = ZoteroAPI.getDefaultHighlightColor()
    local def_drawer = ZoteroAPI.getDefaultHighlightDrawer()
    ann.color = def_color
    ann.drawer = def_drawer
    logger.info(
        "Zotero: new highlight forced style color="
            .. tostring(def_color)
            .. " drawer="
            .. tostring(def_drawer)
    )
    -- Redraw like ReaderHighlight:editHighlightStyle (setDirty — do NOT call
    -- updateAnnotations here, it can keep the old lighten paint until reopen).
    if ui.highlight and ui.paging and ui.highlight.writePdfAnnotation then
        pcall(function()
            ui.highlight:writePdfAnnotation("delete", ann)
            ui.highlight:writePdfAnnotation("save", ann)
        end)
    end
    if UIManager and UIManager.setDirty then
        UIManager:setDirty(ui, "ui")
    end
    -- Second tick: some CRE builds paint highlights one frame late
    UIManager:scheduleIn(0.05, function()
        if ann then
            ann.color = def_color
            ann.drawer = def_drawer
        end
        if UIManager and UIManager.setDirty and ui then
            UIManager:setDirty(ui, "ui")
        end
    end)
    if ui.annotation and ui.annotation.annotations and ui.doc_settings then
        pcall(function()
            ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
            ui.doc_settings:flush()
        end)
    end

    local key = ZoteroAPI.findAttachmentKeyByFilePath(file_path)
    if key then
        ZoteroAPI.rememberAttachmentKeyForPath(file_path, key)
    end
    if not key then
        UIManager:scheduleIn(0.2, function()
            if ui and ui.document and ui.document.file == file_path then
                self:promptUnlinkedAnnotation(ui, file_path, ann)
            end
        end)
        return
    end

    if ZoteroAPI.getAnnotationDestinationAsk() then
        self:applyDestinationToAnnotation(ui, ann, ZoteroAPI.getAnnotationDestinationLast())
        UIManager:scheduleIn(0.25, function()
            self:promptAnnotationDestination(ui, ann)
        end)
    else
        self:applyDestinationToAnnotation(ui, ann, ZoteroAPI.getAnnotationDestinationDefault())
    end

    -- Background upload after the user has time to type a note (Lua is single-threaded,
    -- but this no longer blocks the highlight → note dialog transition).
    self._annot_upload_gen = (self._annot_upload_gen or 0) + 1
    local upload_gen = self._annot_upload_gen
    UIManager:scheduleIn(2.5, function()
        if upload_gen ~= self._annot_upload_gen then
            return
        end
        if not ui or not ui.document or ui.document.file ~= file_path then
            return
        end
        -- Flush latest note text before upload
        if ui.annotation and ui.annotation.annotations and ui.doc_settings then
            pcall(function()
                if ui.rolling then
                    for _, a in ipairs(ui.annotation.annotations) do
                        if type(a.page) == "number" then
                            return
                        end
                    end
                end
                ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
                ui.doc_settings:flush()
            end)
        end
        self:syncOpenDocumentAnnotations(ui, {
            notify = false,
            reload = false,
            file_path = file_path,
        })
    end)
end

function Plugin:onReaderReady(readerui)
    if not init_done or not readerui or not readerui.document or not readerui.document.file then
        return
    end
    local file_path = readerui.document.file
    configureZoteroDocumentSettings(file_path)
    applyDefaultHighlightToOpenReader(readerui)
    self:applyDisplayRestyle(readerui)
    -- onReadSettings may run around the same time — re-apply so saved_* sticks
    UIManager:scheduleIn(0.4, function()
        if readerui and readerui.document and readerui.document.file == file_path then
            applyDefaultHighlightToOpenReader(readerui)
            self:applyDisplayRestyle(readerui)
        end
    end)

    -- Safe page jump requested by annotation search (after showReader)
    local search_mod = package.loaded["annotation_search"]
    if search_mod and search_mod.pending_goto and search_mod.pending_goto.path then
        local pending = search_mod.pending_goto
        search_mod.pending_goto = nil
        if pending.page and file_path == pending.path then
            UIManager:scheduleIn(0.3, function()
                pcall(function()
                    if readerui.paging and readerui.paging.onGotoPage then
                        readerui.paging:onGotoPage(pending.page)
                    elseif readerui.document and readerui.document.gotoPage then
                        readerui.document:gotoPage(pending.page)
                    end
                end)
            end)
        end
    end

    local key = ZoteroAPI.findAttachmentKeyByFilePath(file_path)
    if not key then
        return
    end
    ZoteroAPI.rememberAttachmentKeyForPath(file_path, key)
    -- Upgrade attachments: paths to absolute desktop paths (library style) when possible
    UIManager:scheduleIn(1.5, function()
        if not networkIsOnline() then
            return
        end
        pcall(function()
            ZoteroAPI.healLinkedAttachmentPath(file_path, key)
        end)
    end)
    local item = ZoteroAPI.getItem(key)
    if not item then
        return
    end
    local doc_settings = DocSettings:open(file_path)
    local sidecar_lib_version = doc_settings:readSetting("zoteroLibVersion", 0)
    local anns_now = doc_settings:readSetting("annotations", {}) or {}
    local keys_now = {}
    for _, ann in ipairs(anns_now) do
        if ann.zoteroKey then
            keys_now[ann.zoteroKey] = true
        end
    end
    doc_settings:close()
    -- Seed durable annot-state (outside sidecar) so local deletes are remembered
    pcall(function()
        ZoteroAPI.noteLocalAnnotationDeletions(key, keys_now)
    end)
    local _, pending_set = ZoteroAPI.annotationSyncStateSets(key)
    local db_zot = ZoteroAPI.countAttachmentAnnotations(key)
    local sidecar_zot = ZoteroAPI.countSidecarZoteroAnnotations(file_path)
    logger.info("Zotero: Matched open document to attachment " .. key)
    local needs_attach = sidecar_lib_version < ZoteroAPI.getUserLibraryVersion()
        or (db_zot > sidecar_zot)
    if needs_attach then
        local ok, err = pcall(function()
            -- Never re-inject annotations pending local delete
            local result = ZoteroAPI.attachItemAnnotations(
                item,
                nil,
                file_path,
                db_zot > sidecar_zot,
                pending_set
            )
            if result and type(result) == "string" and result:match("^Error") then
                logger.warn("Zotero: " .. tostring(result))
            else
                self:reloadReaderAnnotations(readerui)
            end
        end)
        if not ok then
            logger.err("Zotero: Failed to attach annotations on reader open: ", err)
        end
    end
    -- Keep dirty if a previous offline session queued this path
    self._annot_dirty = ZoteroAPI.isAnnotSyncPending(file_path)
    -- Upload local create/edit/delete shortly after open (sidecar may have pending changes).
    -- Offline: syncOpenDocumentAnnotations defers silently (no WiFi prompt).
    UIManager:scheduleIn(1.0, function()
        self:syncOpenDocumentAnnotations(readerui, { notify = false })
    end)
end

function Plugin:onCloseDocument()
    -- Invalidate any in-flight sync that might try reloadDocument after teardown
    self._annot_sync_gen = (self._annot_sync_gen or 0) + 1
    -- Capture path BEFORE the reader tears down document (async sync otherwise crashes)
    local file_path = nil
    if self.ui and self.ui.document then
        file_path = self.ui.document.file
        if self.ui.annotation and self.ui.annotation.annotations and self.ui.doc_settings then
            pcall(function()
                self.ui.doc_settings:saveSetting("annotations", self.ui.annotation.annotations)
                self.ui.doc_settings:flush()
            end)
        end
    end
    -- Close must stay snappy: do NOT run a full bidirectional sync here.
    -- Flush is enough for KOReader; push local creates/updates/deletes after teardown.
    -- (Edits already schedule a sync while the book is open.)
    if file_path and self._annot_dirty then
        local gen = self._annot_sync_gen
        UIManager:scheduleIn(0.9, function()
            -- Cancelled if another document opened or a newer close cycle started
            if gen ~= self._annot_sync_gen then
                return
            end
            if not self._annot_dirty then
                return
            end
            self:syncOpenDocumentAnnotations(nil, {
                notify = false,
                reload = false,
                file_path = file_path,
                push_only = true,
            })
        end)
    end
end

function Plugin:onCloseWidget()
    -- Do not sync again and do not bump _annot_sync_gen here:
    -- onCloseDocument may have scheduled a deferred push that must still run.
end

function Plugin:init()
    -- not sure when this is called, so I don't understand why some bits need to be
    -- re-initialised every time.
    -- But at least the ZoteroAPI only needs to be initialised once
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    else
        logger.err("Zotero Atelier: ui.menu unavailable; plugin menu will not appear")
    end
    if not init_done then
        xpcall(self.initAPI, self.initError, self)
        init_done = true
    end
    xpcall(self.initBrowser, self.initError, self)
    self.initialized = init_done

    local menu_tab = loadPluginModule(self, "menu_tab")
    if menu_tab and menu_tab.install then
        menu_tab.install(self)
    else
        logger.warn("Zotero Atelier: menu_tab.lua unavailable; dedicated tab not installed")
    end

    if self.initialized then
        pcall(function()
            self:applyDisplayRestyle(self.ui)
        end)
    end

    logger.info("Zotero Atelier: initialized (ok=" .. tostring(self.initialized) .. ")")

    -- Rewrite attachments: paths created earlier into absolute desktop paths (library style)
    if self.initialized then
        UIManager:scheduleIn(4.0, function()
            if not networkIsOnline() then
                return
            end
            pcall(function()
                ZoteroAPI.healAllAttachmentsPrefixedPaths()
            end)
        end)
    end

    -- One-shot ADB/debug: put absolute path in zotero/_debug_sync_path then restart KOReader
    if self.initialized then
        local debug_flag = DataStorage:getDataDir() .. "/zotero/_debug_sync_path"
        local f = io.open(debug_flag, "r")
        if f then
            local path = (f:read("*l") or ""):gsub("%s+$", "")
            f:close()
            pcall(os.remove, debug_flag)
            if path ~= "" then
                UIManager:scheduleIn(2.5, function()
                    logger.info("Zotero: DEBUG sync for ", path)
                    self:syncOpenDocumentAnnotations(self.ui, {
                        file_path = path,
                        notify = false,
                        reload = false,
                    })
                end)
            end
        end
    end
end

function Plugin:initError(e)
    logger.err("Zotero Atelier: Could not initialize: " .. tostring(e))
end

function Plugin:checkInitialized()
    if not self.initialized or self.browser == nil then
        UIManager:show(InfoMessage:new({
            text = _(
                "Zotero Atelier could not start.\n"
                    .. "Restart KOReader after installing the plugin.\n"
                    .. "If the problem persists, check crash.log for 'zoteroatelier' or 'zoteroapi' errors."
            ),
            timeout = 6,
            icon = "notice-warning",
        }))
    end

    return self.initialized
end

function Plugin:initAPI()
    self.zotero_dir_path = DataStorage:getDataDir() .. "/zotero"
    lfs.mkdir(self.zotero_dir_path)
    ZoteroAPI.init(self.zotero_dir_path)
end

function Plugin:initBrowser()
    self.small_font_face = Font:getFace("smallffont")
    local function closeBrowsers()
        if self.dual_dialog then
            UIManager:close(self.dual_dialog)
        end
        if self.zotero_dialog then
            UIManager:close(self.zotero_dialog)
        end
    end
    self.browser = ZoteroBrowser:new({
        refresh_callback = function()
            UIManager:setDirty(self.zotero_dialog)
            if self.ui and self.ui.onRefresh then
                self.ui:onRefresh()
            end
        end,
        close_callback = closeBrowsers,
        items_per_page = self:getItemsPerPage(),
    })
    self.zotero_dialog = FrameContainer:new({
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.browser,
    })
    self.browser.show_parent = self.zotero_dialog
    self:initDualPaneBrowser()
    logger.dbg("Zotero: Browser initialized")
end

function Plugin:initDualPaneBrowser()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local left_w = math.floor(screen_w * 0.4)
    local right_w = screen_w - left_w - Size.line.medium
    local per_page = self:getItemsPerPage()

    local function closeDual()
        if self.dual_dialog then
            UIManager:close(self.dual_dialog)
        end
    end

    self.dual_left = ZoteroLeftPane:new({
        width = left_w,
        height = screen_h,
        items_per_page = per_page,
        host = self,
        close_callback = closeDual,
    })
    self.dual_right = ZoteroRightPane:new({
        width = right_w,
        height = screen_h,
        items_per_page = per_page,
        host = self,
        close_callback = closeDual,
    })

    self.dual_dialog = FrameContainer:new({
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        covers_full_screen = true,
        HorizontalGroup:new({
            self.dual_left,
            LineWidget:new({
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new({
                    w = Size.line.medium,
                    h = screen_h,
                }),
            }),
            self.dual_right,
        }),
    })
    self.dual_left.show_parent = self.dual_dialog
    self.dual_right.show_parent = self.dual_dialog
    self._dual_geom = { w = screen_w, h = screen_h }
end

function Plugin:dualLoadRight(collection_id)
    if self.dual_right then
        self.dual_right:displayItems(collection_id)
    end
end

function Plugin:onDualPaneSearch()
    local search_query_dialog
    search_query_dialog = InputDialog:new({
        title = _("Search Zotero titles"),
        input = "",
        input_hint = "search query",
        description = _("This will search title and first author of all entries."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(search_query_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local q = search_query_dialog:getInputText()
                        UIManager:close(search_query_dialog)
                        local items = ZoteroAPI.displaySearchResults(q)
                        if self.dual_right then
                            self.dual_right._search_items = items
                            self.dual_right._search_subtitle = _("Search") .. ": " .. tostring(q)
                            self.dual_right:displayItems("search")
                        end
                    end,
                },
            },
        },
    })
    UIManager:show(search_query_dialog)
    search_query_dialog:onShowKeyboard()
end

function Plugin:showDualPaneBrowser()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    if
        not self.dual_dialog
        or not self._dual_geom
        or self._dual_geom.w ~= screen_w
        or self._dual_geom.h ~= screen_h
    then
        self:initDualPaneBrowser()
    end
    UIManager:show(
        self.dual_dialog,
        "full",
        Geom:new({
            w = screen_w,
            h = screen_h,
        })
    )
    self.dual_left.paths = {}
    self.dual_left.keys = {}
    self.dual_left:displayCollections(nil)
    self:dualLoadRight(nil)
end

function Plugin:getZoteroSubMenu()
    return {
            {
                text = _("Browse"),
                callback = function()
                    self:onZoteroBrowserAction()
                end,
            },
            {
                text = _("Synchronize"),
                callback = function()
                    self:onZoteroSyncAction()
                end,
            },
            {
                text = _("Document annotations"),
                enabled_func = function()
                    return self.ui ~= nil and self.ui.document ~= nil
                end,
                callback = function()
                    local panel = loadPluginModule(self, "annotation_panel")
                    if panel then
                        panel.show(self.ui, { plugin = self })
                    else
                        UIManager:show(InfoMessage:new({
                            text = _(
                                "annotation_panel.lua missing.\n"
                                    .. "Copy ALL plugin files (including annotation_panel.lua)."
                            ),
                            timeout = 5,
                            icon = "notice-warning",
                        }))
                    end
                end,
            },
            {
                text = _("Search annotations"),
                callback = function()
                    local search = loadPluginModule(self, "annotation_search")
                    if search then
                        search.show(self)
                    else
                        UIManager:show(InfoMessage:new({
                            text = _(
                                "annotation_search.lua missing.\n"
                                    .. "Copy ALL plugin files (including annotation_search.lua)."
                            ),
                            timeout = 5,
                            icon = "notice-warning",
                        }))
                    end
                end,
            },
            {
                text = _("Sync document annotations"),
                enabled_func = function()
                    return self.ui ~= nil and self.ui.document ~= nil
                end,
                callback = function()
                    self:syncOpenDocumentAnnotations(self.ui, {
                        notify = true,
                        prompt_wifi = true,
                    })
                end,
            },
            {
                text = _("Add to Zotero…"),
                enabled_func = function()
                    local fp = self.ui and self.ui.document and self.ui.document.file
                    -- Path-only check: avoid full attachment DB scan on menu open
                    return fp ~= nil and ZoteroAPI.isPathUnderLinkedBase(fp)
                end,
                callback = function()
                    local fp = self.ui and self.ui.document and self.ui.document.file
                    self:showAddLinkedBookDialog(fp, self.ui)
                end,
            },
            {
                text = _("How to annotate (help)"),
                callback = function()
                    UIManager:show(InfoMessage:new({
                        text = _(
                            "Create a Zotero annotation from KOReader:\n\n"
                                .. "1) Open a PDF/EPUB from Zotero Atelier → Browse\n"
                                .. "2) Select text → Highlight (and optional note)\n"
                                .. "3) Choose destination: Local / Zotero / Both\n"
                                .. "   (or set a default under Settings → Annotation destination)\n"
                                .. "4) Menu → Sync document annotations\n"
                                .. "   (sends TO Zotero and pulls FROM Zotero)\n\n"
                                .. "EPUB notes stay in the KOReader sidecar (not written into the file).\n"
                                .. "PDF can also write highlights into the file when Local or Both is chosen.\n\n"
                                .. "Or run full Synchronize later.\n"
                                .. "Search annotations opens a book; page jump happens after open."
                        ),
                        show_icon = false,
                    }))
                end,
            },
            {
                text = _("Maintenance"),
                callback = function()
                    return nil
                end,
                sub_item_table = {
                    {
                        text = _("Re-analyse local items"),
                        callback = function()
                            self:onZoteroReanalyzeAction()
                        end,
                    },
                    {
                        text = _("Re-scan storage for local items"),
                        callback = function()
                            self:onZoteroRescanAction()
                        end,
                    },
                    {
                        text = _("Resync entire collection"),
                        callback = function()
                            ZoteroAPI.resetSyncState()
                            self:onZoteroSyncAction()
                        end,
                    },
                },
            },
            {
                text = _("Settings"),
                callback = function()
                    return nil
                end,
                sub_item_table = {
                    {
                        text = _("Configure Zotero account"),
                        callback = function()
                            self:setAccount()
                        end,
                    },
                    {
                        text = _("Test Zotero API key"),
                        callback = function()
                            self:testZoteroAccount()
                        end,
                    },
                    {
                        text = _("Enable WebDAV storage"),
                        checked_func = function()
                            return ZoteroAPI.getWebDAVEnabled()
                        end,
                        callback = function()
                            ZoteroAPI.toggleWebDAVEnabled()
                        end,
                    },
                    {
                        text = _("Configure WebDAV account"),
                        callback = function()
                            self:setWebdavAccount()
                        end,
                    },
                    {
                        text = _("Check WebDAV connection"),
                        callback = function()
                            NetworkMgr:runWhenOnline(function()
                                local msg = nil
                                local result = ZoteroAPI.checkWebDAV()
                                if result == nil then
                                    msg = _("Success, WebDAV works!")
                                else
                                    msg = _("WebDAV could not connect: ") .. result
                                end
                                UIManager:show(InfoMessage:new({
                                    text = msg,
                                    timeout = 3,
                                    icon = "notice-info",
                                }))
                            end)
                        end,
                    },
                    {
                        text = _("Items per page"),
                        callback = function()
                            self:setItemsPerPage()
                        end,
                    },
                    {
                        text = _("Large screen"),
                        sub_item_table = {
                            {
                                text = _("Dual-pane library browser"),
                                checked_func = function()
                                    return ZoteroAPI.getLargeScreenDualPane()
                                end,
                                callback = function()
                                    ZoteroAPI.toggleLargeScreenDualPane()
                                    ZoteroAPI.saveSettingsToFile()
                                end,
                            },
                            {
                                text = _("Side annotation panel"),
                                checked_func = function()
                                    return ZoteroAPI.getLargeScreenAnnotationPanel()
                                end,
                                callback = function()
                                    ZoteroAPI.toggleLargeScreenAnnotationPanel()
                                    ZoteroAPI.saveSettingsToFile()
                                end,
                            },
                            {
                                text_func = function()
                                    return _("Min width (px): ")
                                        .. tostring(ZoteroAPI.getLargeScreenMinWidth())
                                end,
                                callback = function()
                                    self:setLargeScreenMinWidth()
                                end,
                            },
                        },
                    },
                    {
                        text = _("Default highlight style"),
                        sub_item_table = {
                            {
                                text_func = function()
                                    return _("Color: ")
                                        .. ZoteroAPI.labelDefaultHighlightColor()
                                end,
                                callback = function()
                                    ZoteroAPI.cycleDefaultHighlightColor()
                                    ZoteroAPI.saveSettingsToFile()
                                    if self.ui and self.ui.document and self.ui.document.file then
                                        configureZoteroDocumentSettings(self.ui.document.file)
                                        applyDefaultHighlightToOpenReader(self.ui)
                                    end
                                end,
                            },
                            {
                                text_func = function()
                                    return _("Style: ")
                                        .. ZoteroAPI.labelDefaultHighlightDrawer()
                                end,
                                callback = function()
                                    ZoteroAPI.cycleDefaultHighlightDrawer()
                                    ZoteroAPI.saveSettingsToFile()
                                    if self.ui and self.ui.document and self.ui.document.file then
                                        configureZoteroDocumentSettings(self.ui.document.file)
                                        applyDefaultHighlightToOpenReader(self.ui)
                                    end
                                end,
                            },
                            {
                                text = _("Show underlines as squiggly black"),
                                checked_func = function()
                                    return ZoteroAPI.getDisplaySquigglyBlack()
                                end,
                                callback = function()
                                    ZoteroAPI.toggleDisplaySquigglyBlack()
                                    ZoteroAPI.saveSettingsToFile()
                                    self:applyDisplayRestyle(self.ui)
                                end,
                            },
                        },
                    },
                    {
                        text = _("Annotation destination"),
                        sub_item_table = {
                            {
                                text = _("Ask where to save (each highlight)"),
                                checked_func = function()
                                    return ZoteroAPI.getAnnotationDestinationAsk()
                                end,
                                callback = function()
                                    ZoteroAPI.setAnnotationDestinationAsk(
                                        not ZoteroAPI.getAnnotationDestinationAsk()
                                    )
                                    ZoteroAPI.saveSettingsToFile()
                                    if self.ui and self.ui.document and self.ui.document.file then
                                        configureZoteroDocumentSettings(self.ui.document.file)
                                    end
                                end,
                            },
                            {
                                text_func = function()
                                    local d = ZoteroAPI.getAnnotationDestinationDefault()
                                    local label = d
                                    if d == "local" then
                                        label = _("Local only")
                                    elseif d == "zotero" then
                                        label = _("Zotero only")
                                    else
                                        label = _("Both")
                                    end
                                    return _("Default (Zotero docs): ") .. label
                                end,
                                callback = function()
                                    local Ann = getAnnotationsMod()
                                    local cur = ZoteroAPI.getAnnotationDestinationDefault()
                                    local order = { "local", "zotero", "both" }
                                    if Ann then
                                        order = { Ann.DEST_LOCAL, Ann.DEST_ZOTERO, Ann.DEST_BOTH }
                                    end
                                    local next_dest = order[1]
                                    for i, v in ipairs(order) do
                                        if v == cur then
                                            next_dest = order[(i % #order) + 1]
                                            break
                                        end
                                    end
                                    ZoteroAPI.setAnnotationDestinationDefault(next_dest)
                                    ZoteroAPI.saveSettingsToFile()
                                    if self.ui and self.ui.document and self.ui.document.file then
                                        configureZoteroDocumentSettings(self.ui.document.file)
                                    end
                                end,
                            },
                            {
                                text_func = function()
                                    local m = ZoteroAPI.getAnnotationDestinationNonZotero()
                                    local label = m == "sidecar" and _("Sidecar only")
                                        or _("Write into PDF")
                                    return _("Non-Zotero documents: ") .. label
                                end,
                                callback = function()
                                    local cur = ZoteroAPI.getAnnotationDestinationNonZotero()
                                    ZoteroAPI.setAnnotationDestinationNonZotero(
                                        cur == "local" and "sidecar" or "local"
                                    )
                                    ZoteroAPI.saveSettingsToFile()
                                    if self.ui and self.ui.document and self.ui.document.file then
                                        configureZoteroDocumentSettings(self.ui.document.file)
                                    end
                                end,
                            },
                            {
                                text = _("Never write highlights into PDF (legacy)"),
                                checked_func = function()
                                    return ZoteroAPI.getSettings():readSetting(
                                        "auto_disable_pdf_writing",
                                        false
                                    )
                                end,
                                callback = function()
                                    local cur = ZoteroAPI.getSettings():readSetting(
                                        "auto_disable_pdf_writing",
                                        false
                                    )
                                    ZoteroAPI.getSettings():saveSetting(
                                        "auto_disable_pdf_writing",
                                        not cur
                                    )
                                    ZoteroAPI.saveSettingsToFile()
                                    if self.ui and self.ui.document and self.ui.document.file then
                                        configureZoteroDocumentSettings(self.ui.document.file)
                                    end
                                end,
                            },
                        },
                    },
                    {
                        text = _("Local files"),
                        callback = function()
                            return nil
                        end,
                        sub_item_table = {
                            {
                                text = _("Enable linked files folder"),
                                checked_func = function()
                                    return ZoteroAPI.getLinkedFilesEnabled()
                                end,
                                callback = function()
                                    ZoteroAPI.toggleLinkedFilesEnabled()
                                    ZoteroAPI.saveSettingsToFile()
                                end,
                            },
                            {
                                text_func = function()
                                    return _("Linked files folder: ")
                                        .. truncatePath(ZoteroAPI.getLinkedFilesBase())
                                end,
                                callback = function()
                                    self:chooseDirectory(
                                        "linked_files_base",
                                        _("Choose folder on THIS device (Android path)"),
                                        function(path)
                                            ZoteroAPI.setLinkedFilesBase(path)
                                            ZoteroAPI.saveSettingsToFile()
                                            self:showLocalFilesHelp(path)
                                        end
                                    )
                                end,
                            },
                            {
                                text = _("Help: Windows path → Android"),
                                callback = function()
                                    self:showLocalFilesHelp()
                                end,
                            },
                            {
                                text = _("Enable external Zotero storage folder"),
                                checked_func = function()
                                    return ZoteroAPI.getExternalStorageEnabled()
                                end,
                                callback = function()
                                    ZoteroAPI.toggleExternalStorageEnabled()
                                    ZoteroAPI.saveSettingsToFile()
                                end,
                            },
                            {
                                text_func = function()
                                    return _("External storage folder: ")
                                        .. truncatePath(ZoteroAPI.getExternalStorageDir())
                                end,
                                callback = function()
                                    self:chooseDirectory(
                                        "external_storage_dir",
                                        _("Choose Zotero storage folder"),
                                        function(path)
                                            ZoteroAPI.setExternalStorageDir(path)
                                            ZoteroAPI.saveSettingsToFile()
                                        end
                                    )
                                end,
                            },
                            {
                                text = _("Prefer local files when available"),
                                checked_func = function()
                                    return ZoteroAPI.getSettings():readSetting("prefer_local_files", true)
                                end,
                                callback = function()
                                    ZoteroAPI.getSettings():toggle("prefer_local_files")
                                    ZoteroAPI.saveSettingsToFile()
                                end,
                            },
                            {
                                text = _("Allow opening outdated local files"),
                                checked_func = function()
                                    return ZoteroAPI.getAllowStaleLocal()
                                end,
                                callback = function()
                                    ZoteroAPI.toggleAllowStaleLocal()
                                    ZoteroAPI.saveSettingsToFile()
                                end,
                            },
                            {
                                text = _("Add search root folder"),
                                callback = function()
                                    self:chooseDirectory(
                                        "search_root_pick",
                                        _("Choose folder to search for files"),
                                        function(path)
                                            ZoteroAPI.addSearchRoot(path)
                                            ZoteroAPI.saveSettingsToFile()
                                        end
                                    )
                                end,
                            },
                            {
                                text = _("View search root folders"),
                                callback = function()
                                    self:showSearchRoots()
                                end,
                            },
                            {
                                text = _("Preview local path resolution"),
                                callback = function()
                                    self:showLocalPathPreview()
                                end,
                            },
                            {
                                text = _("Map a Zotero folder → this device"),
                                callback = function()
                                    self:mapZoteroPathWizard()
                                end,
                            },
                            {
                                text = _("Manual path mapping (advanced)"),
                                callback = function()
                                    self:suggestPathMapping()
                                end,
                            },
                            {
                                text = _("View path mappings"),
                                callback = function()
                                    self:showPathMappings()
                                end,
                            },
                            {
                                text = _("Clear all path mappings"),
                                callback = function()
                                    ZoteroAPI.clearPathMappings()
                                    ZoteroAPI.saveSettingsToFile()
                                    UIManager:show(InfoMessage:new({
                                        text = _("Path mappings cleared."),
                                        timeout = 3,
                                        icon = "notice-info",
                                    }))
                                end,
                            },
                        },
                    },
                },
            },
            {
                text = _("About/Info"),
                callback = function()
                    local version = ZoteroAPI.version
                    local stats = ZoteroAPI.getStats()
                    local dest_ask = ZoteroAPI.getAnnotationDestinationAsk() and _("Yes") or _("No")
                    local dest_def = ZoteroAPI.getAnnotationDestinationDefault()
                    local dest_nz = ZoteroAPI.getAnnotationDestinationNonZotero()
                    UIManager:show(InfoMessage:new({
                        text = _(
                            "Plugin version: \n"
                            .. version
                            .. "\n\nLibrary info:\n  Name:\t\t"
                            .. stats.name
                            .. "\n  Version:\t"
                            .. stats.libVersion
                            .. "\n  Last sync: "
                            .. stats.lastSync
                            .. "\n\nLibrary stats:\n\tCollections:\t\t"
                            .. stats.collections
                            .. "\n\tTotal items:\t\t"
                            .. stats.items
                            .. "\n\tAttachments:\t"
                            .. stats.attachments
                            .. "\n\tAnnotations:\t"
                            .. stats.annotations
                            .. "\n\nAnnotation destination:\n\tAsk each time:\t"
                            .. dest_ask
                            .. "\n\tDefault:\t"
                            .. dest_def
                            .. "\n\tNon-Zotero:\t"
                            .. dest_nz
                            .. "\n"
                        ),
                        show_icon = false,
                    }))

                    return nil
                end,
            },
    }
end

-- Convert TouchMenu-style entries (text_func / checked_func / sub_item_table)
-- into a flat Menu item_table that the classic Menu widget can display safely.
function Plugin:showTouchMenuItemsAsMenu(title, touch_items)
    local function resolveText(entry)
        if type(entry.text_func) == "function" then
            local ok, text = pcall(entry.text_func)
            if ok and text ~= nil then
                return tostring(text)
            end
        end
        return entry.text or ""
    end

    local function resolveEnabled(entry)
        if type(entry.enabled_func) == "function" then
            local ok, en = pcall(entry.enabled_func)
            if ok then
                return en and true or false
            end
        end
        if entry.enabled == false then
            return false
        end
        return true
    end

    local function resolveChecked(entry)
        if type(entry.checked_func) == "function" then
            local ok, checked = pcall(entry.checked_func)
            if ok and checked then
                return true
            end
        end
        return false
    end

    local function buildItemTable(entries)
        local out = {}
        for _, entry in ipairs(entries or {}) do
            if type(entry) == "table" and (entry.text or entry.text_func) then
                local text = resolveText(entry)
                if resolveChecked(entry) then
                    text = "✓ " .. text
                end
                local item = {
                    text = text,
                    enabled = resolveEnabled(entry),
                }
                if entry.sub_item_table then
                    item.callback = function()
                        self:showTouchMenuItemsAsMenu(resolveText(entry), entry.sub_item_table)
                    end
                elseif type(entry.callback) == "function" then
                    item.callback = entry.callback
                end
                table.insert(out, item)
            end
        end
        return out
    end

    local menu
    menu = Menu:new({
        title = title or _("Settings"),
        item_table = buildItemTable(touch_items),
        is_borderless = true,
        is_popout = true,
        multilines_show_more_text = true,
        onMenuChoice = function(_, item)
            UIManager:close(menu)
            if item.callback then
                item.callback()
            end
        end,
        close_callback = function()
            UIManager:close(menu)
        end,
    })
    UIManager:show(menu)
end

-- Flat full-screen hub (avoids digging through nested KOReader submenus).
function Plugin:showPluginHub()
    local items = {
        {
            text = _("Browse"),
            callback = function()
                self:onZoteroBrowserAction()
            end,
        },
        {
            text = _("Synchronize"),
            callback = function()
                self:onZoteroSyncAction()
            end,
        },
        {
            text = _("Document annotations"),
            enabled = self.ui ~= nil and self.ui.document ~= nil,
            callback = function()
                local panel = loadPluginModule(self, "annotation_panel")
                if panel then
                    panel.show(self.ui, { plugin = self })
                end
            end,
        },
        {
            text = _("Search annotations"),
            callback = function()
                local search = loadPluginModule(self, "annotation_search")
                if search then
                    search.show(self)
                end
            end,
        },
        {
            text = _("Sync document annotations"),
            enabled = self.ui ~= nil and self.ui.document ~= nil,
            callback = function()
                self:syncOpenDocumentAnnotations(self.ui, {
                    notify = true,
                    prompt_wifi = true,
                })
            end,
        },
        {
            text = _("Add to Zotero…"),
            enabled = (function()
                local fp = self.ui and self.ui.document and self.ui.document.file
                -- Path-only check: avoid full attachment DB scan on hub build
                return fp ~= nil and ZoteroAPI.isPathUnderLinkedBase(fp)
            end)(),
            callback = function()
                local fp = self.ui and self.ui.document and self.ui.document.file
                self:showAddLinkedBookDialog(fp, self.ui)
            end,
        },
        {
            text = _("Configure Zotero account"),
            callback = function()
                self:setAccount()
            end,
        },
        {
            text = _("Test Zotero API key"),
            callback = function()
                self:testZoteroAccount()
            end,
        },
        {
            text = _("Preview local path resolution"),
            callback = function()
                self:showLocalPathPreview()
            end,
        },
        {
            text = _("Linked files folder: ") .. truncatePath(ZoteroAPI.getLinkedFilesBase()),
            callback = function()
                self:chooseDirectory(
                    "linked_files_base",
                    _("Choose folder on THIS device (Android path)"),
                    function(path)
                        ZoteroAPI.setLinkedFilesBase(path)
                        ZoteroAPI.saveSettingsToFile()
                        self:showLocalFilesHelp(path)
                    end
                )
            end,
        },
        {
            text = _("Map a Zotero folder → this device"),
            callback = function()
                self:mapZoteroPathWizard()
            end,
        },
        {
            text = _("View path mappings"),
            callback = function()
                self:showPathMappings()
            end,
        },
        {
            text = _("Ask where to save (each highlight)"),
            callback = function()
                ZoteroAPI.setAnnotationDestinationAsk(not ZoteroAPI.getAnnotationDestinationAsk())
                ZoteroAPI.saveSettingsToFile()
                UIManager:show(InfoMessage:new({
                    text = ZoteroAPI.getAnnotationDestinationAsk() and _("Yes") or _("No"),
                    timeout = 1.5,
                }))
            end,
        },
        {
            text = _("Re-analyse local items"),
            callback = function()
                self:onZoteroReanalyzeAction()
            end,
        },
        {
            text = _("Re-scan storage for local items"),
            callback = function()
                self:onZoteroRescanAction()
            end,
        },
        {
            text = _("Resync entire collection"),
            callback = function()
                ZoteroAPI.resetSyncState()
                self:onZoteroSyncAction()
            end,
        },
        {
            text = _("How to annotate (help)"),
            callback = function()
                UIManager:show(InfoMessage:new({
                    text = _(
                        "Create a Zotero annotation from KOReader:\n\n"
                            .. "1) Open a PDF/EPUB from Zotero Atelier → Browse\n"
                            .. "2) Select text → Highlight (and optional note)\n"
                            .. "3) Choose destination: Local / Zotero / Both\n"
                            .. "   (or set a default under Settings → Annotation destination)\n"
                            .. "4) Menu → Sync document annotations\n"
                            .. "   (sends TO Zotero and pulls FROM Zotero)\n\n"
                            .. "EPUB notes stay in the KOReader sidecar (not written into the file).\n"
                            .. "PDF can also write highlights into the file when Local or Both is chosen.\n\n"
                            .. "Or run full Synchronize later.\n"
                            .. "Search annotations opens a book; page jump happens after open."
                    ),
                    show_icon = false,
                }))
            end,
        },
        {
            text = _("More settings…"),
            callback = function()
                -- Open nested settings from classic submenu builder.
                -- Must convert TouchMenu entries (text_func / nested tables)
                -- — feeding them raw to Menu:new crashes.
                local settings_item = nil
                for _, entry in ipairs(self:getZoteroSubMenu()) do
                    if entry.text == _("Settings") then
                        settings_item = entry
                        break
                    end
                end
                if settings_item and settings_item.sub_item_table then
                    self:showTouchMenuItemsAsMenu(_("Settings"), settings_item.sub_item_table)
                end
            end,
        },
        {
            text = _("About/Info"),
            callback = function()
                local version = ZoteroAPI.version
                local stats = ZoteroAPI.getStats()
                UIManager:show(InfoMessage:new({
                    text = string.format(
                        "%s\n%s\n\n%s\t%s\n%s\t%s\n%s %s\n\n%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s",
                        _("Plugin version:"),
                        version,
                        _("Name:"),
                        tostring(stats.name),
                        _("Version:"),
                        tostring(stats.libVersion),
                        _("Last sync:"),
                        tostring(stats.lastSync),
                        _("Collections:"),
                        tostring(stats.collections),
                        _("Items:"),
                        tostring(stats.items),
                        _("Attachments:"),
                        tostring(stats.attachments),
                        _("Annotations:"),
                        tostring(stats.annotations)
                    ),
                    show_icon = false,
                }))
            end,
        },
    }

    local menu_items = {}
    for _, entry in ipairs(items) do
        table.insert(menu_items, {
            text = entry.text,
            enabled = entry.enabled ~= false,
            callback = entry.callback,
        })
    end

    local hub
    hub = Menu:new({
        title = _("Zotero Atelier"),
        item_table = menu_items,
        is_borderless = true,
        is_popout = true,
        multilines_show_more_text = true,
        onMenuChoice = function(_, item)
            UIManager:close(hub)
            if item.callback then
                item.callback()
            end
        end,
        close_callback = function()
            UIManager:close(hub)
        end,
    })
    UIManager:show(hub)
end

function Plugin:addToMainMenu(menu_items)
    local sub_menu = self:getZoteroSubMenu()
    -- Search / Settings: classic submenu. Tools: flat hub (one tap → full list).
    menu_items.zoteroatelier = {
        text = _("Zotero Atelier"),
        sorting_hint = "search",
        callback = function()
            self:showPluginHub()
        end,
    }
    menu_items.zoteroatelier_tools = {
        text = _("Zotero Atelier"),
        sorting_hint = "tools",
        callback = function()
            self:showPluginHub()
        end,
    }
    menu_items.zoteroatelier_settings = {
        text = _("Zotero Atelier"),
        sorting_hint = "setting",
        sub_item_table = sub_menu,
    }
end

function Plugin:setAccount()
    self.account_dialog = MultiInputDialog:new({
        title = _("Edit User Info"),
        description = _(
            "On https://www.zotero.org/settings/keys : copy the numeric User ID and create an API key (library + notes + write if you sync annotations)."
        ),
        fields = {
            {
                text = ZoteroAPI.getUserID() or "",
                hint = _("User ID (digits only, not your username)"),
            },
            {
                text = ZoteroAPI.getAPIKey() or "",
                hint = _("API Key"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self.account_dialog:onClose()
                        UIManager:close(self.account_dialog)
                    end,
                },
                {
                    text = _("Save & test"),
                    callback = function()
                        local fields = self.account_dialog:getFields()
                        if not string.match(fields[1] or "", "^[0-9]+$") then
                            UIManager:show(InfoMessage:new({
                                text = _("The User ID must be an integer number (see zotero.org/settings/keys)."),
                                timeout = 4,
                                icon = "notice-warning",
                            }))
                            return
                        end

                        ZoteroAPI.setUserID(fields[1])
                        ZoteroAPI.setAPIKey(fields[2])
                        ZoteroAPI.saveSettingsToFile()
                        self.account_dialog:onClose()
                        UIManager:close(self.account_dialog)
                        self:testZoteroAccount()
                    end,
                },
            },
        },
    })
    UIManager:show(self.account_dialog)
    self.account_dialog:onShowKeyboard()
end

function Plugin:testZoteroAccount()
    if not self:checkInitialized() then
        return
    end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            Trapper:info(_("Testing Zotero API key…"))
            local ok_msg, err = ZoteroAPI.testCredentials()
            if err then
                Trapper:info(err)
            else
                Trapper:info(ok_msg or _("API key OK."))
            end
        end)
    end)
end

function Plugin:showLocalFilesHelp(chosen_path)
    local probe = ZoteroAPI.getFirstLocalPathPreview()
    local device_path = chosen_path or ZoteroAPI.getLinkedFilesBase() or ""
    if device_path ~= "" then
        device_path = ZoteroAPI.normalizeDevicePath(device_path)
    end
    local from_ex = (probe and probe.suggestedFrom) or ""
    local zpath = (probe and probe.zoteroPath) or ""
    local lines = {
        _("How linked files work:"),
        "",
        _("1) Synchronize so the plugin knows Zotero paths."),
        _("2) Linked files folder = where files are ON THIS DEVICE."),
        _("3) Path mapping = PC/Zotero prefix → device folder."),
        "",
    }
    if zpath ~= "" then
        table.insert(lines, _("Example from YOUR library:"))
        table.insert(lines, "  " .. zpath)
        if from_ex ~= "" then
            table.insert(lines, "")
            table.insert(lines, _("Suggested mapping From:"))
            table.insert(lines, "  " .. from_ex)
        end
        if device_path ~= "" then
            table.insert(lines, _("Suggested mapping To:"))
            table.insert(lines, "  " .. device_path)
        end
    else
        table.insert(lines, _("No linked attachment in the local DB yet — run Synchronize first,"))
        table.insert(lines, _("then open « Preview local path resolution »."))
    end
    table.insert(lines, "")
    table.insert(lines, _("Also enable « Enable linked files folder »."))
    UIManager:show(InfoMessage:new({
        text = table.concat(lines, "\n"),
        show_icon = false,
    }))
end

function Plugin:setWebdavAccount()
    self.webdav_account_dialog = MultiInputDialog:new({
        title = _("Edit WebDAV credentials"),
        fields = {
            {
                text = ZoteroAPI.getWebDAVUrl(),
                hint = _("URL"),
            },
            {
                text = ZoteroAPI.getWebDAVUser(),
                hint = _("Username"),
            },
            {
                text = ZoteroAPI.getWebDAVPassword(),
                hint = _("Password"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self.webdav_account_dialog:onClose()
                        UIManager:close(self.webdav_account_dialog)
                    end,
                },
                {
                    text = _("Update"),
                    callback = function()
                        local fields = self.webdav_account_dialog:getFields()

                        ZoteroAPI.setWebDAVUrl(fields[1])
                        ZoteroAPI.setWebDAVUser(fields[2])
                        ZoteroAPI.setWebDAVPassword(fields[3])
                        ZoteroAPI.saveSettingsToFile()
                        self.webdav_account_dialog:onClose()
                        UIManager:close(self.webdav_account_dialog)
                    end,
                },
            },
        },
    })
    UIManager:show(self.webdav_account_dialog)
    self.webdav_account_dialog:onShowKeyboard()
end

function Plugin:chooseDirectory(setting_key, title, on_path_chosen)
    local current = ZoteroAPI.getSettings():readSetting(setting_key, "") or ""
    local start_dir = current
    if start_dir == "" then
        start_dir = Device.home_dir or "/"
    end
    local ok, PathChooser = pcall(require, "ui/widget/pathchooser")
    if ok and PathChooser then
        local path_chooser = PathChooser:new({
            title = title,
            path = start_dir,
            select_directory = true,
            select_file = false,
            show_files = false,
            onConfirm = function(dir)
                on_path_chosen(dir)
                ZoteroAPI.saveSettingsToFile()
                self:showLocalPathPreview(dir)
            end,
        })
        UIManager:show(path_chooser)
        return
    end
    local input_dialog
    input_dialog = InputDialog:new({
        title = title,
        input = current,
        input_hint = _("Full path to folder"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("OK"),
                    is_enter_default = true,
                    callback = function()
                        local path = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if path and path ~= "" then
                            on_path_chosen(path)
                            ZoteroAPI.saveSettingsToFile()
                            self:showLocalPathPreview(path)
                        end
                    end,
                },
            },
        },
    })
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function Plugin:showLocalPathPreview(folder_hint)
    local probe = ZoteroAPI.getFirstLocalPathPreview()
    local text = ZoteroAPI.formatLocalPathPreview(probe)
    if folder_hint and folder_hint ~= "" then
        text = _("Folder set to:\n") .. folder_hint .. "\n\n" .. text
    end
    local preview_dialog
    preview_dialog = ButtonDialog:new({
        title = _("Local path preview") .. "\n\n" .. text,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(preview_dialog)
                    end,
                },
                {
                    text = _("Test again"),
                    callback = function()
                        UIManager:close(preview_dialog)
                        self:showLocalPathPreview()
                    end,
                },
            },
        },
    })
    UIManager:show(preview_dialog)
end

-- Guided mapping: pick a folder prefix from a Zotero PC path, then point to
-- the matching folder on this device (e.g. D:/Notes → /sdcard/Documents/Notes).
function Plugin:mapZoteroPathWizard()
    local probe = ZoteroAPI.getFirstLocalPathPreview()
    local zpath = probe and probe.zoteroPath or ""
    if zpath == "" then
        UIManager:show(InfoMessage:new({
            text = _(
                "No linked file path in the local library yet.\n"
                    .. "Run Synchronize first, then try again."
            ),
            timeout = 5,
            icon = "notice-warning",
        }))
        return
    end
    local prefixes = ZoteroAPI.listZoteroPathPrefixes(zpath)
    if #prefixes == 0 then
        UIManager:show(InfoMessage:new({
            text = _("Could not split this Zotero path into folders:\n") .. zpath,
            timeout = 4,
            icon = "notice-warning",
        }))
        return
    end

    local items = {}
    for _, choice in ipairs(prefixes) do
        -- Prefer mid-depth folders (e.g. Notes) as clearer defaults in the label
        local hint = ""
        if choice.label:match("[/\\]Notes$") or choice.label:match("^Notes$") then
            hint = "  ← "
        elseif choice.depth >= 2 then
            hint = ""
        end
        table.insert(items, {
            text = choice.label .. hint,
            from = choice.from,
        })
    end

    local pick_menu
    pick_menu = Menu:new({
        title = _("1/2 — Which Zotero folder to map?")
            .. "\n"
            .. truncatePath(zpath, 60),
        item_table = items,
        is_borderless = true,
        is_popout = true,
        multilines_show_more_text = true,
        onMenuChoice = function(_, item)
            UIManager:close(pick_menu)
            local from_prefix = item.from
            self:chooseDirectory(
                "path_map_to_pick",
                _("2/2 — Choose the SAME folder on THIS device"),
                function(to_dir)
                    to_dir = ZoteroAPI.normalizeDevicePath(to_dir or "")
                    if to_dir == "" then
                        return
                    end
                    ZoteroAPI.addPathMapping(from_prefix, to_dir)
                    -- Also enable linked files and set base to this folder if empty
                    if not ZoteroAPI.getLinkedFilesEnabled() then
                        ZoteroAPI.toggleLinkedFilesEnabled()
                    end
                    local base = ZoteroAPI.getLinkedFilesBase() or ""
                    if base == "" then
                        ZoteroAPI.setLinkedFilesBase(to_dir)
                    end
                    ZoteroAPI.saveSettingsToFile()
                    UIManager:show(InfoMessage:new({
                        text = _("Mapping added:\n")
                            .. from_prefix
                            .. "\n→\n"
                            .. to_dir
                            .. "\n\n"
                            .. _(
                                "Example: D:\\Notes\\Lectures\\book.pdf\n"
                                    .. "becomes <Android Notes>/Lectures/book.pdf"
                            ),
                        timeout = 6,
                        icon = "notice-info",
                    }))
                    self:showLocalPathPreview()
                end
            )
        end,
        close_callback = function()
            UIManager:close(pick_menu)
        end,
    })
    UIManager:show(pick_menu)
end

function Plugin:addPathMapping()
    -- Default to the guided wizard; keep manual entry as fallback button inside help
    self:mapZoteroPathWizard()
end

function Plugin:suggestPathMapping()
    local probe = ZoteroAPI.getFirstLocalPathPreview()
    local from_default = ""
    local to_default = ZoteroAPI.getLinkedFilesBase() or ""
    if probe then
        if probe.suggestedFrom and probe.suggestedFrom ~= "" then
            from_default = probe.suggestedFrom
        elseif probe.zoteroPath and probe.zoteroPath ~= "" then
            from_default = ZoteroAPI.pathPrefixOfFile(probe.zoteroPath)
        end
        if probe.suggestedTo and probe.suggestedTo ~= "" then
            to_default = probe.suggestedTo
        end
    end
    local desc
    if probe and probe.zoteroPath and probe.zoteroPath ~= "" then
        desc = _("From a linked file in your library:\n") .. probe.zoteroPath
    else
        desc = _(
            "No linked path in the local DB yet. Synchronize first, or paste the PC path prefix manually."
        )
    end
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Suggest path mapping"),
        description = desc,
        fields = {
            {
                text = from_default,
                hint = _("From: path prefix as stored by Zotero (PC)"),
            },
            {
                text = to_default,
                hint = _("To: same folder on THIS device"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Create mapping"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local from_path = ZoteroAPI.normalizePath(fields[1] or "")
                        local to_dir = ZoteroAPI.normalizePath(fields[2] or "")
                        if from_path == "" or to_dir == "" then
                            UIManager:show(InfoMessage:new({
                                text = _("Both paths are required."),
                                timeout = 3,
                                icon = "notice-warning",
                            }))
                            return
                        end
                        local basename = ZoteroAPI.basenameOfPath(from_path)
                        local from_prefix = from_path
                        if basename and #basename < #from_path then
                            from_prefix = from_path:sub(1, #from_path - #basename)
                            if from_prefix:sub(-1) == "/" then
                                from_prefix = from_prefix:sub(1, -2)
                            end
                        end
                        ZoteroAPI.addPathMapping(from_prefix, to_dir)
                        ZoteroAPI.saveSettingsToFile()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new({
                            text = _("Mapping added:\n") .. from_prefix .. "\n→\n" .. to_dir,
                            timeout = 4,
                            icon = "notice-info",
                        }))
                        self:showLocalPathPreview()
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Plugin:showSearchRoots()
    local roots = ZoteroAPI.getSearchRoots()
    if #roots == 0 then
        UIManager:show(InfoMessage:new({
            text = _("No extra search roots configured."),
            timeout = 3,
            icon = "notice-info",
        }))
        return
    end
    local items = {}
    for i, root in ipairs(roots) do
        table.insert(items, {
            text = truncatePath(root, 60),
            index = i,
            path = root,
        })
    end
    local menu
    menu = Menu:new({
        title = _("Search root folders"),
        item_table = items,
        is_borderless = true,
        is_popout = true,
        onMenuHold = function(_, item)
            ZoteroAPI.removeSearchRoot(item.index)
            ZoteroAPI.saveSettingsToFile()
            UIManager:close(menu)
            UIManager:show(InfoMessage:new({
                text = _("Search root removed."),
                timeout = 2,
            }))
            return true
        end,
        close_callback = function()
            UIManager:close(menu)
        end,
    })
    UIManager:show(menu)
end

function Plugin:showPathMappings()
    local mappings = ZoteroAPI.getPathMappings()
    if #mappings == 0 then
        UIManager:show(InfoMessage:new({
            text = _("No path mappings configured."),
            timeout = 3,
            icon = "notice-info",
        }))
        return
    end
    local lines = {}
    for i, m in ipairs(mappings) do
        table.insert(lines, i .. ". " .. m.from .. "\n   → " .. m.to)
    end
    local remove_dialog
    remove_dialog = ButtonDialog:new({
        title = _("Path mappings") .. "\n\n" .. table.concat(lines, "\n\n"),
        buttons = {
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(remove_dialog)
                    end,
                },
                {
                    text = _("Remove last"),
                    callback = function()
                        ZoteroAPI.removePathMapping(#mappings)
                        ZoteroAPI.saveSettingsToFile()
                        UIManager:close(remove_dialog)
                        self:showPathMappings()
                    end,
                },
            },
        },
    })
    UIManager:show(remove_dialog)
end

function Plugin:setItemsPerPage()
    assert(ZoteroAPI.getSettings ~= nil)
    self.items_per_page_dialog = SpinWidget:new({
        title_text = _("Set items per page"),
        value = self:getItemsPerPage(),
        value_min = 1,
        value_max = 1000,
        callback = function(d)
            ZoteroAPI.getSettings():saveSetting("items_per_page", d.value)
            ZoteroAPI.saveSettingsToFile()
            UIManager:show(InfoMessage:new({
                text = _("This change requires a restart of KOReader to take effect."),
                timeout = 3,
                icon = "notice",
            }))
        end,
    })
    UIManager:show(self.items_per_page_dialog)
end

function Plugin:setLargeScreenMinWidth()
    self.large_screen_width_dialog = SpinWidget:new({
        title_text = _("Large screen min width (px)"),
        value = ZoteroAPI.getLargeScreenMinWidth(),
        value_min = 400,
        value_max = 4000,
        value_step = 50,
        callback = function(d)
            ZoteroAPI.setLargeScreenMinWidth(d.value)
            ZoteroAPI.saveSettingsToFile()
        end,
    })
    UIManager:show(self.large_screen_width_dialog)
end

function Plugin:getItemsPerPage()
    return ZoteroAPI.getSettings():readSetting("items_per_page", DEFAULT_LINES_PER_PAGE)
end

function Plugin:onZoteroBrowserAction()
    if not self:checkInitialized() then
        return
    end

    if ZoteroAPI.getLargeScreenDualPane() and ZoteroAPI.isLargeScreen() then
        self:showDualPaneBrowser()
        return
    end

    self.browser:init()
    UIManager:show(
        self.zotero_dialog,
        "full",
        Geom:new({
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        })
    )
    self.browser:displayCollection(nil)
end

function Plugin:onZoteroSyncAction()
    if not self:checkInitialized() then
        return
    end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            Trapper:info(_("Synchronizing Zotero library…"))
            local ok, result = pcall(function()
                return ZoteroAPI.syncAllItems(function(msg)
                    Trapper:info(tostring(msg))
                end)
            end)

            if not ok then
                Trapper:info(_("Sync crashed: ") .. tostring(result))
                return
            end
            local e = result
            if e == nil or e == "" then
                local stats = ZoteroAPI.getStats()
                Trapper:info(
                    _("Sync finished.")
                        .. "\n"
                        .. _("Items: ")
                        .. tostring(stats.items)
                        .. "\n"
                        .. _("Attachments: ")
                        .. tostring(stats.attachments)
                        .. "\n"
                        .. _("Library version: ")
                        .. tostring(stats.libVersion)
                )
            else
                Trapper:info(tostring(e))
            end
        end)
    end)
end

function Plugin:onZoteroReanalyzeAction()
    if not self:checkInitialized() then
        return
    end
    Trapper:wrap(function()
        Trapper:info(_("Re-analysing local library…"))
        local e = ZoteroAPI.checkItemData(function(msg)
            Trapper:info(tostring(msg))
        end)

        if e == nil then
            Trapper:info(_("Success"))
        else
            Trapper:info(tostring(e))
        end
    end)
end

function Plugin:onZoteroRescanAction()
    if not self:checkInitialized() then
        return
    end
    Trapper:wrap(function()
        Trapper:info(_("Scanning local Zotero storage…"))
        local cnt = ZoteroAPI.scanStorage()

        Trapper:info(string.format(_("Found %d local attachments."), cnt or 0))
    end)
end

return Plugin
