describe("Zotero path resolution", function()
    local ZoteroAPI
    local orig_path = package.path
    local plugin_dir = "plugins/zoteroatelier.koplugin"

    local function mock_module(name, impl)
        package.loaded[name] = nil
        package.preload[name] = function()
            return impl
        end
    end

    setup(function()
        package.path = plugin_dir .. "/?.lua;" .. orig_path

        mock_module("gettext", function()
            return function(s)
                return s
            end
        end)

        mock_module("logger", function()
            return {
                info = function() end,
                dbg = function() end,
                warn = function() end,
                err = function() end,
            }
        end)

        mock_module("ffi/util", function()
            return {
                joinPath = function(...)
                    local parts = { ... }
                    local path = table.concat(parts, "/")
                    return path:gsub("/+", "/")
                end,
            }
        end)

        mock_module("luasettings", function()
            local settings = {}
            return {
                open = function()
                    return {
                        readSetting = function(_, key, default)
                            if settings[key] == nil then
                                return default
                            end
                            return settings[key]
                        end,
                        saveSetting = function(_, key, value)
                            settings[key] = value
                        end,
                        isTrue = function(_, key)
                            return settings[key] == true
                        end,
                        toggle = function(_, key)
                            settings[key] = not settings[key]
                        end,
                        flush = function()
                            return true
                        end,
                    }
                end,
            }
        end)

        mock_module("ssl.https", function()
            return { request = function() end }
        end)
        mock_module("ltn12", function()
            return {}
        end)
        mock_module("json", function()
            return { encode = function() return "" end, decode = function() return {} end }
        end)
        mock_module("libs/libkoreader-lfs", function()
            return {
                attributes = function() end,
                mkdir = function() end,
                dir = function()
                    return function()
                        return nil
                    end
                end,
            }
        end)
        mock_module("ffi/sha2", function()
            return { bin_to_base64 = function() return "" end }
        end)
        mock_module("lua-ljsqlite3/init", function()
            return {
                open = function()
                    return {
                        exec = function() return { { { 0 } } }, 1 end,
                        prepare = function()
                            return {
                                reset = function() return { bind1 = function() return { resultset = function() return {}, 0 end } end } end,
                                bind1 = function() return { resultset = function() return {}, 0 end } end,
                                close = function() end,
                            }
                        end,
                        rowexec = function()
                            return 0, 0, 0, 0
                        end,
                        close = function() end,
                    }
                end,
            }
        end)
        mock_module("docsettings", function()
            return {
                open = function()
                    return {
                        readSetting = function(_, _, d)
                            return d
                        end,
                        close = function() end,
                    }
                end,
                openSettingsFile = function()
                    return {}
                end,
            }
        end)
        mock_module("annotations", function()
            return {
                supportedZoteroTypes = function()
                    return {}
                end,
            }
        end)

        package.loaded["zoteroapi"] = nil
        ZoteroAPI = require("zoteroapi")
        ZoteroAPI.init("/tmp/zotero_path_test")
    end)

    teardown(function()
        package.path = orig_path
        package.loaded["zoteroapi"] = nil
    end)

    it("normalizes path separators and trailing slashes", function()
        assert.are.equal("/foo/bar", ZoteroAPI.normalizePath("foo\\bar\\"))
        assert.are.equal("D:/docs/file.pdf", ZoteroAPI.normalizePath("D:\\docs\\file.pdf"))
    end)

    it("detects absolute paths", function()
        assert.is_true(ZoteroAPI.isAbsolutePath("/storage/foo"))
        assert.is_true(ZoteroAPI.isAbsolutePath("D:\\Zotero\\file.pdf"))
        assert.is_false(ZoteroAPI.isAbsolutePath("relative/file.pdf"))
    end)

    it("applies longest prefix mapping first", function()
        local mappings = {
            { from = "D:/Zotero", to = "/sync/Zotero" },
            { from = "D:/Zotero/linked", to = "/sync/Zotero/linked" },
        }
        local result = ZoteroAPI.applyPathMappings("D:/Zotero/linked/paper.pdf", mappings)
        assert.are.equal("/sync/Zotero/linked/paper.pdf", result)
    end)

    it("maps Windows path to device path", function()
        local mappings = {
            { from = "D:/Documents/Zotero", to = "/storage/emulated/0/Sync/Zotero" },
        }
        local result = ZoteroAPI.applyPathMappings(
            "D:/Documents/Zotero/linked/paper.pdf",
            mappings
        )
        assert.are.equal("/storage/emulated/0/Sync/Zotero/linked/paper.pdf", result)
    end)

    it("resolves attachments: prefix under linked base", function()
        local result = ZoteroAPI.resolveLinkedPath(
            "attachments:paper.pdf",
            "/books/zotero-linked",
            {}
        )
        assert.are.equal("/books/zotero-linked/paper.pdf", result)
    end)

    it("resolves relative path under linked base", function()
        local result = ZoteroAPI.resolveLinkedPath(
            "subdir/paper.pdf",
            "/books/zotero-linked",
            {}
        )
        assert.are.equal("/books/zotero-linked/subdir/paper.pdf", result)
    end)

    it("resolves absolute path using mappings", function()
        local result = ZoteroAPI.resolveLinkedPath(
            "D:/Zotero/linked/paper.pdf",
            "/books/zotero-linked",
            { { from = "D:/Zotero", to = "/storage/sync/Zotero" } }
        )
        assert.are.equal("/storage/sync/Zotero/linked/paper.pdf", result)
    end)

    it("applies mappings to attachments: relative paths", function()
        local result = ZoteroAPI.resolveLinkedPath(
            "attachments:sub/paper.pdf",
            "/books/linked",
            { { from = "sub", to = "mapped" } }
        )
        -- Without an existing file, falls back to mapped relative under base
        assert.are.equal("/books/linked/mapped/paper.pdf", result)
    end)

    it("extracts basename from path", function()
        assert.are.equal("paper.pdf", ZoteroAPI.basenameOfPath("D:/Zotero/linked/paper.pdf"))
        assert.are.equal("paper.pdf", ZoteroAPI.basenameOfPath("/storage/sync/paper.pdf"))
    end)

    it("can execute placeholder test", function()
        assert.is_true(true)
    end)
end)
