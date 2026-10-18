-- Inject a dedicated Zotero Atelier top-level tab into Reader / FileManager menus.
-- Pattern adapted from SimpleUI's menu hooks (prepare after setUpdateItemTable).
-- Placement: after document/FM settings tab, before the gear (setting).
--
-- Important: TouchMenu uses the tab table itself as item_table
-- (see touchmenu.lua: self.item_table = self.tab_item_table[tab_num]).
-- Items must be at array indices of the tab, NOT in a nested sub_item_table.

local logger = require("logger")
local _
do
    local ok, mod = pcall(require, "zotero_i18n")
    if ok and type(mod) == "function" then
        _ = mod
    else
        _ = require("gettext")
    end
end

local MenuTab = {}

local TAB_ID = "zoteroatelier_tab"
local TAB_ICON = "book.opened"

local TARGET = {
    READER = "reader",
    FM = "fm",
}

local MENU_MODULES = {
    [TARGET.READER] = "apps/reader/modules/readermenu",
    [TARGET.FM] = "apps/filemanager/filemanagermenu",
}

local ORIG_FIELD = "_zoteroatelier_menu_tab_orig"

local _plugin = nil
local _installed = false

local function tabIndexById(menu, id)
    if type(menu.tab_item_table) ~= "table" then
        return nil
    end
    for i, tab in ipairs(menu.tab_item_table) do
        if tab and tab.id == id then
            return i
        end
    end
    return nil
end

--- Insert after typeset (reader) / filemanager_settings (FM); fallback before setting.
local function insertIndex(menu)
    local after = tabIndexById(menu, "typeset") or tabIndexById(menu, "filemanager_settings")
    if after then
        return after + 1
    end
    local before = tabIndexById(menu, "setting")
    if before then
        return before
    end
    return #menu.tab_item_table + 1
end

--- Build a TouchMenu top-level tab: icon/id + array items (not sub_item_table).
local function buildTab()
    local items = {}
    if _plugin and _plugin.getZoteroSubMenu then
        local ok, result = pcall(function()
            return _plugin:getZoteroSubMenu()
        end)
        if ok and type(result) == "table" then
            items = result
        else
            logger.warn("Zotero Atelier: getZoteroSubMenu failed:", result)
        end
    end
    local tab = {
        id = TAB_ID,
        icon = TAB_ICON,
    }
    for i, item in ipairs(items) do
        tab[i] = item
    end
    return tab
end

local function clearArrayPart(t)
    for i = #t, 1, -1 do
        t[i] = nil
    end
end

local function injectTab(menu)
    if not _plugin or type(menu.tab_item_table) ~= "table" then
        return
    end
    local tab = buildTab()
    local existing = tabIndexById(menu, TAB_ID)
    if existing then
        local old = menu.tab_item_table[existing]
        clearArrayPart(old)
        for i, item in ipairs(tab) do
            old[i] = item
        end
        old.icon = TAB_ICON
        old.id = TAB_ID
        old.sub_item_table = nil
        return
    end
    table.insert(menu.tab_item_table, insertIndex(menu), tab)
end

local function loadMenuClass(target)
    local path = MENU_MODULES[target]
    local Menu = package.loaded[path]
    if Menu then
        return Menu
    end
    local ok, mod = pcall(require, path)
    return ok and mod or nil
end

local function hook(target)
    local Menu = loadMenuClass(target)
    if not Menu or rawget(Menu, ORIG_FIELD) then
        return
    end

    local orig = {
        setUpdateItemTable = Menu.setUpdateItemTable,
        onShowMenu = Menu.onShowMenu,
    }
    Menu[ORIG_FIELD] = orig

    function Menu:setUpdateItemTable(...)
        local ret = orig.setUpdateItemTable(self, ...)
        local ok, err = pcall(injectTab, self)
        if not ok then
            logger.warn("Zotero Atelier: menu tab inject failed:", err)
        end
        return ret
    end

    function Menu:onShowMenu(tab_index, do_not_show)
        if self.tab_item_table == nil then
            self:setUpdateItemTable()
        else
            local ok, err = pcall(injectTab, self)
            if not ok then
                logger.warn("Zotero Atelier: menu tab refresh failed:", err)
            end
        end
        return orig.onShowMenu(self, tab_index, do_not_show)
    end
end

local function unhook(target)
    local Menu = package.loaded[MENU_MODULES[target]]
    local orig = Menu and rawget(Menu, ORIG_FIELD)
    if not orig then
        return
    end
    Menu.setUpdateItemTable = orig.setUpdateItemTable
    Menu.onShowMenu = orig.onShowMenu
    Menu[ORIG_FIELD] = nil
end

function MenuTab.install(plugin)
    _plugin = plugin
    if _installed then
        -- Plugin widget is re-created when switching FM ↔ Reader; keep ref fresh.
        return
    end
    for _, target in pairs(TARGET) do
        hook(target)
    end
    _installed = true
    logger.info("Zotero Atelier: dedicated menu tab installed")
end

function MenuTab.uninstall()
    if not _installed then
        return
    end
    for _, target in pairs(TARGET) do
        unhook(target)
    end
    _plugin = nil
    _installed = false
end

return MenuTab
