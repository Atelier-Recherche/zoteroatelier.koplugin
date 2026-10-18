local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
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

local AnnotationSearch = {}

-- Set by openAnnotation; consumed safely in Plugin:onReaderReady
AnnotationSearch.pending_goto = nil

local function truncate(s, max_len)
    s = s or ""
    max_len = max_len or 90
    if #s <= max_len then
        return s
    end
    return s:sub(1, max_len - 1) .. "..."
end

local function resultLabel(row)
    local page = row.page ~= "" and ("p." .. row.page .. " - ") or ""
    local body = row.comment ~= "" and row.comment or row.text
    if body == nil or body == "" then
        body = _("(empty)")
    end
    local title = row.parentTitle ~= "" and row.parentTitle or (row.attachmentKey or "?")
    return truncate(title, 40) .. "\n" .. page .. truncate(body, 80)
end

function AnnotationSearch.show(plugin, initial_query)
    local dialog
    dialog = InputDialog:new({
        title = _("Search annotations"),
        input = initial_query or "",
        input_hint = _("text, comment, title..."),
        description = _("Search highlights and notes across the synchronized Zotero library."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local q = dialog:getInputText()
                        UIManager:close(dialog)
                        AnnotationSearch.showResults(plugin, q)
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AnnotationSearch.showResults(plugin, query)
    local ok, results = pcall(ZoteroAPI.searchAnnotations, query)
    if not ok then
        logger.err("Zotero: searchAnnotations failed: ", results)
        UIManager:show(InfoMessage:new({
            text = _("Annotation search failed."),
            timeout = 3,
            icon = "notice-warning",
        }))
        return
    end
    if results == nil or #results == 0 then
        UIManager:show(InfoMessage:new({
            text = _("No annotations found."),
            timeout = 2,
        }))
        return
    end

    local items = {}
    for _, row in ipairs(results) do
        table.insert(items, {
            text = resultLabel(row),
            row = row,
        })
    end

    local menu
    menu = Menu:new({
        title = _("Annotation results") .. " (" .. #items .. ")",
        item_table = items,
        is_borderless = true,
        is_popout = true,
        multilines_show_more_text = true,
        onMenuChoice = function(_, item)
            local row = item.row
            if row == nil or row.attachmentKey == nil then
                return
            end
            UIManager:close(menu)
            AnnotationSearch.openAnnotation(plugin, row)
        end,
        close_callback = function()
            UIManager:close(menu)
        end,
    })
    UIManager:show(menu)
end

function AnnotationSearch.openAnnotation(plugin, row)
    local item = ZoteroAPI.getItem(row.attachmentKey)
    if item == nil then
        UIManager:show(InfoMessage:new({
            text = _("Attachment not found in local library."),
            timeout = 3,
            icon = "notice-warning",
        }))
        return
    end

    local function open_path(path)
        if path == nil or path == "" then
            return
        end
        -- Defer page jump to onReaderReady (avoids crash after switchDocument)
        AnnotationSearch.pending_goto = {
            path = path,
            page = tonumber(row.page),
        }
        UIManager:scheduleIn(0.05, function()
            local ok, err = pcall(function()
                require("apps/reader/readerui"):showReader(path)
            end)
            if not ok then
                AnnotationSearch.pending_goto = nil
                logger.err("Zotero: showReader failed: ", err)
                UIManager:show(InfoMessage:new({
                    text = _("Could not open file."),
                    timeout = 3,
                    icon = "notice-warning",
                }))
            end
        end)
    end

    local local_path = ZoteroAPI.resolveAttachmentPath(item)
    if local_path then
        open_path(local_path)
        return
    end

    NetworkMgr:runWhenOnline(function()
        local path, err = ZoteroAPI.downloadAndGetPath(item.key)
        if path then
            open_path(path)
        else
            UIManager:show(InfoMessage:new({
                text = _("Could not open attachment: ") .. tostring(err or _("unknown error")),
                timeout = 4,
                icon = "notice-warning",
            }))
        end
    end)
end

return AnnotationSearch
