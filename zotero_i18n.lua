-- Plugin-local gettext wrapper with FR / DE / ES overlays.
-- Falls back to KOReader's gettext, then to the English msgid.
-- IMPORTANT: must always return a callable function (never crash on load).

local raw_gettext
do
    local ok, mod = pcall(require, "gettext")
    if ok then
        raw_gettext = mod
    else
        raw_gettext = function(s)
            return s
        end
    end
end

local function pluginDir()
    if debug and debug.getinfo then
        local src = debug.getinfo(1, "S").source
        if type(src) == "string" and src:sub(1, 1) == "@" then
            local base = src:sub(2):match("^(.*)[/\\]")
            if base then
                return base:gsub("\\", "/")
            end
        end
    end
    return nil
end

local function loadLangTable(name)
    -- Prefer dofile from plugin folder (reliable even if package.path is incomplete)
    local base = pluginDir()
    if base then
        local path = base .. "/" .. name .. ".lua"
        local ok, mod = pcall(dofile, path)
        if ok and type(mod) == "table" then
            return mod
        end
    end
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then
        return mod
    end
    return {}
end

local translations = {
    fr = loadLangTable("i18n_fr"),
    de = loadLangTable("i18n_de"),
    es = loadLangTable("i18n_es"),
}

local function normalizeLang(lang)
    if lang == nil or lang == "" or lang == "C" then
        return "en"
    end
    lang = tostring(lang):lower():gsub("-", "_")
    local short = lang:match("^([a-z][a-z])")
    return short or lang
end

local function currentLang()
    local lang = nil
    pcall(function()
        if G_reader_settings then
            lang = G_reader_settings:readSetting("language")
        end
    end)
    if (lang == nil or lang == "") and type(raw_gettext) == "table" then
        pcall(function()
            -- Some KOReader builds expose the active locale here
            if raw_gettext.current_lang then
                lang = raw_gettext.current_lang
            elseif raw_gettext.getCurrent then
                lang = raw_gettext.getCurrent()
            elseif raw_gettext.language then
                lang = raw_gettext.language
            end
        end)
    end
    return normalizeLang(lang)
end

local function _(msgid)
    if msgid == nil then
        return ""
    end
    local lang = currentLang()
    local table_ = translations[lang]
    if table_ and table_[msgid] then
        return table_[msgid]
    end
    if type(raw_gettext) == "function" then
        return raw_gettext(msgid)
    elseif type(raw_gettext) == "table" and type(raw_gettext.gettext) == "function" then
        return raw_gettext.gettext(msgid)
    end
    return msgid
end

return _
