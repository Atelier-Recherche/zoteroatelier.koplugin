local BaseUtil = require("ffi/util")
local LuaSettings = require("luasettings")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local sha2 = require("ffi/sha2")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")
local Annotations = require("annotations")
local _
do
    local ok, mod = pcall(require, "zotero_i18n")
    if ok and type(mod) == "function" then
        _ = mod
    else
        _ = require("gettext")
    end
end
-- For my annotation routines:
local DocSettings = require("docsettings")

-- Functions expect config parameter, a lua table with the following keys:
-- zotero_dir: Path to a directory where cache files will be stored
-- api_key: self-explanatory
--
-- Directory layout of zoteroapi
-- /zotero.db: SQLite3 database that contains JSON items & collections
-- /storage/<KEY>/filename.pdf: Actual PDF files
-- /storage/<KEY>/version: Version number of downloaded attachment
-- /meta.lua: Metadata containing library version, items etc.

local API = { ["version"] = "Zotero Atelier 2.1.6" }

-- Zotero object keys: /[23456789ABCDEFGHIJKLMNPQRSTUVWXYZ]{8}/ (no 0/1/O, no lowercase)
local ZOTERO_KEY_ALPHABET = "23456789ABCDEFGHIJKLMNPQRSTUVWXYZ"
local _zotero_key_seeded = false
local function newZoteroTempKey()
    if not _zotero_key_seeded then
        pcall(function()
            math.randomseed(os.time() % 100000 + (os.clock() * 1000000) % 100000)
        end)
        _zotero_key_seeded = true
    end
    local out = {}
    local n = #ZOTERO_KEY_ALPHABET
    for i = 1, 8 do
        local idx = math.random(1, n)
        out[i] = ZOTERO_KEY_ALPHABET:sub(idx, idx)
    end
    return table.concat(out)
end

local SUPPORTED_MEDIA_TYPES = {
    [1] = "application/pdf",
    [2] = "application/epub+zip",
    [3] = "text/html",
}

local ZOTERO_BASE_URL = "https://api.zotero.org"
-- Avoid infinite "Synchronizing…" on slow/broken networks (seconds).
local HTTP_TIMEOUT = 45
pcall(function()
    https.TIMEOUT = HTTP_TIMEOUT
end)

-- Update whenever the database scheme is updated/changed
local db_version = 1

local ZOTERO_DB_SCHEMA = [[
CREATE TABLE IF NOT EXISTS itemData (
	itemID INTEGER PRIMARY KEY,
    value BLOB,
    FOREIGN KEY (itemID) REFERENCES items(itemID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS items (
	itemID INTEGER PRIMARY KEY,
	itemTypeID INT NOT NULL,
	libraryID INT NOT NULL,
	key TEXT NOT NULL,
	version INT NOT NULL DEFAULT 0,
	synced INT NOT NULL DEFAULT 0,
	UNIQUE (libraryID, key),
	FOREIGN KEY (libraryID) REFERENCES libraries(libraryID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS libraries (
	libraryID INTEGER PRIMARY KEY,
	type TEXT NOT NULL,
	editable INT NOT NULL,
	name TEXT NOT NUll,
	userID INT NOT NULL DEFAULT 0,
	version INT NOT NULL DEFAULT 0,
	storageVersion INT NOT NULL DEFAULT 0,
	lastSync INT NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS collections (
	collectionID INTEGER PRIMARY KEY,
	collectionName TEXT NOT NULL,
	parentCollectionID INT DEFAULT NULL,
	libraryID INT NOT NULL,
	key TEXT NOT NULL,
	version INT NOT NULL DEFAULT 0,
	synced INT NOT NULL DEFAULT 0,
	UNIQUE (libraryID, key),
	FOREIGN KEY (libraryID) REFERENCES libraries(libraryID) ON DELETE CASCADE,
	FOREIGN KEY (parentCollectionID) REFERENCES collections(collectionID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS collectionItems (
	collectionID INT NOT NULL,
	itemID INT NOT NULL,
	PRIMARY KEY(collectionID, itemID),
	FOREIGN KEY (collectionID) REFERENCES collections(collectionID) ON DELETE CASCADE,
	FOREIGN KEY (itemID) REFERENCES items(itemID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS itemTypes (
	itemTypeID INTEGER PRIMARY KEY,
	typeName TEXT,
	display INT DEFAULT 1
);
CREATE TABLE IF NOT EXISTS itemAttachments (
	itemID INTEGER PRIMARY KEY,
	parentItemID INT,
	syncedVersion INT NOT NULL DEFAULT 0,
	lastSync INT NOT NULL DEFAULT 0,
	FOREIGN KEY (itemID) REFERENCES items(itemID) ON DELETE CASCADE,
	FOREIGN KEY (parentItemID) REFERENCES items(itemID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS itemAnnotations (
	itemID INTEGER PRIMARY KEY,
	parentItemID INT,
	syncedVersion INT NOT NULL DEFAULT 0,
	FOREIGN KEY (itemID) REFERENCES items(itemID) ON DELETE CASCADE,
	FOREIGN KEY (parentItemID) REFERENCES items(itemID) ON DELETE CASCADE
);
]]

-- SQLite: string literals MUST use single quotes. Double quotes are identifiers.
local ZOTERO_DB_INIT_ITEMTYPES = [[
INSERT OR IGNORE INTO itemTypes(itemTypeID,typeName)
VALUES
(1,'annotation'),
(2,'artwork'),
(3,'attachment'),
(4,'audioRecording'),
(5,'bill'),
(6,'blogPost'),
(7,'book'),
(8,'bookSection'),
(9,'case'),
(10,'computerProgram'),
(11,'conferencePaper'),
(12,'dictionaryEntry'),
(13,'document'),
(14,'email'),
(15,'encyclopediaArticle'),
(16,'film'),
(17,'forumPost'),
(18,'hearing'),
(19,'instantMessage'),
(20,'interview'),
(21,'journalArticle'),
(22,'letter'),
(23,'magazineArticle'),
(24,'manuscript'),
(25,'map'),
(26,'newspaperArticle'),
(27,'note'),
(28,'patent'),
(29,'podcast'),
(30,'preprint'),
(31,'presentation'),
(32,'radioBroadcast'),
(33,'report'),
(34,'statute'),
(35,'thesis'),
(36,'tvBroadcast'),
(37,'videoRecording'),
(38,'webpage'),
(39,'dataset'),
(40,'standard');
]]

-- TODO: Check if this makes sense to remove
--local ZOTERO_CREATE_VIEWS = [[
--CREATE TEMPORARY TABLE IF NOT EXISTS supported_media_types (mime TEXT);
--INSERT INTO supported_media_types(mime) VALUES ('application/pdf'), ('application/epub+zip'), ('text/html') ON CONFLICT DO NOTHING;

--CREATE TEMPORARY TABLE IF NOT EXISTS supported_link_types (type TEXT);
--INSERT INTO supported_link_types(type) VALUES ('imported_file'), ('imported_url') ON CONFLICT DO NOTHING;

---- create view that holds metadata of the parent item. if it does not exist, it is equal to the item itself
--CREATE TEMPORARY VIEW IF NOT EXISTS attachment_data AS
--SELECT items.key AS key, items.value AS value, parents.key AS parent_key, coalesce(parents.value, items.value) AS parent_value
--FROM items
--LEFT JOIN items AS parents ON jsonb_extract(items.value, '$.data.parentItem') = parents.key
--WHERE
--(jsonb_extract(items.value, '$.data.itemType')  = 'attachment');

--CREATE TEMPORARY VIEW IF NOT EXISTS item_download_queue AS
---- A collection is a offline collection if it is in the respective table or any of its parent collections are
---- in the respective table
--WITH RECURSIVE collection_hierarchy(key) AS
--(SELECT key FROM offline_collections -- starting values are all collections inside the offline_collections table
--UNION
--SELECT collections.key              -- select all other keys of collections
--FROM collections, collection_hierarchy
--WHERE jsonb_extract(collections.value, '$.data.parentCollection') = collection_hierarchy.key) -- whose parentCollection is the collection we just inserted
--SELECT attachment_data.key FROM attachment_data
--LEFT JOIN attachment_versions ON attachment_data.key = attachment_versions.key
--WHERE
---- must be an attachment with supported media type
--(jsonb_extract(value, '$.data.itemType') = 'attachment') AND
--(jsonb_extract(value, '$.data.linkMode') IN (SELECT type FROM supported_link_types)) AND
--(jsonb_extract(value, '$.data.contentType') IN (SELECT mime FROM supported_media_types)) AND
---- the item may not be deleted
--(jsonb_extract(value, '$.data.deleted') IS NOT 1)
---- and must belong to a collection in the offline collection hierarchy
--AND EXISTS (SELECT collection_hierarchy.key FROM collection_hierarchy INTERSECT SELECT value FROM json_each(jsonb_extract(attachment_data.parent_value, '$.data.collections')))
---- and local version must be lower than remote version (otherwise its considered up-to-date)
--AND coalesce((SELECT version FROM attachment_versions WHERE attachment_versions.key = attachment_data.key), 0) < jsonb_extract(attachment_data.value, '$.version');
--[[
-- NOTE: This VIEW is currently unused and kept for reference
-- select all pdf attachments present locally (would need JSON parsing in Lua if used)
local ZOTERO_CREATE_VIEWS = [[
CREATE TEMPORARY TABLE IF NOT EXISTS supported_link_types (type TEXT);
INSERT INTO supported_link_types(type) VALUES ('imported_file'), ('imported_url') ON CONFLICT DO NOTHING;

CREATE TEMPORARY VIEW IF NOT EXISTS local_pdf_items AS
SELECT
    items.key AS key,
    value
FROM attachment_versions
LEFT JOIN items ON attachment_versions.key = items.key;
]]
--]]

-- Make sure there is at least one item in libraries table: ony insert if table is empty:
local ZOTERO_DB_INIT_LIBS = [[
INSERT INTO libraries(type, editable, name) SELECT 'user',1,'' WHERE NOT EXISTS(SELECT libraryID FROM libraries);
]]

local ZOTERO_DB_INIT_COLLECTIONS = [[
-- only insert item if table is empty:
-- 'Fake collection' for items in root
INSERT INTO collections(collectionName, libraryID, key) SELECT '',1,'/' WHERE NOT EXISTS(SELECT collectionID FROM collections);
]]

local ZOTERO_CREATE_ITEMKEY_INDEX = [[
CREATE INDEX IF NOT EXISTS idx_itemkey ON items(key);
]]

local ZOTERO_DB_UPDATE_ITEM = [[
INSERT INTO items(itemTypeID, libraryID, key, version) SELECT itemTypeID, ?1, ?3, ?4 FROM itemTypes WHERE typeName IS ?2
ON CONFLICT DO UPDATE SET itemTypeID = excluded.itemTypeID, version = excluded.version;
]]
local ZOTERO_DB_DELETE_ITEM = [[
DELETE FROM items WHERE key IS ?1
]]

local ZOTERO_DB_UPDATE_ITEMDATA = [[
INSERT INTO itemData(itemID, value) SELECT itemID,?2 FROM items WHERE key IS ?1
ON CONFLICT DO UPDATE SET value = excluded.value;
]]

local ZOTERO_DB_UPDATE_COLLECTION = [[
-- hardcoded libraryID = 1 for now
INSERT INTO collections(collectionName, parentCollectionID, libraryID , key, version) SELECT ?1, collectionID, 1, ?3, ?4 FROM collections WHERE key=?2
ON CONFLICT DO UPDATE SET collectionName = excluded.collectionName, version = excluded.version, parentCollectionID = excluded.parentCollectionID;
]]
local ZOTERO_DB_DELETE_COLLECTION = [[
DELETE FROM collections WHERE key IS ?1
]]
local ZOTERO_DB_UPDATE_PARENTCOLLECTION = [[
-- assume libraryID = 1 for now
UPDATE collections SET parentCollectionID = (SELECT collectionID FROM collections WHERE key = ?2) WHERE key=?1;
]]
local ZOTERO_DB_UPDATE_COLLECTION_ITEMS = [[
INSERT INTO collectionItems(collectionID, itemID) SELECT collections.collectionID, items.itemID FROM collections, items WHERE collections.key = ?1 AND items.key=?2
ON CONFLICT DO NOTHING;
]]
local ZOTERO_GET_COLLECTION_VERSION = [[ SELECT version, collectionID FROM collections WHERE key = ?; ]]

local ZOTERO_GET_DB_VERSION = [[ PRAGMA user_version; ]]

local ZOTERO_GET_ITEM = [[ SELECT value 	FROM
		itemData INNER JOIN items ON itemData.itemID = items.itemID WHERE items.key = ?; ]]

local ZOTERO_GET_OFFLINE_COLLECTION = [[
SELECT key FROM collections WHERE (synced > 0) AND (key = ?);
]]

local ZOTERO_ADD_OFFLINE_COLLECTION = [[
UPDATE collections
SET synced = 1
WHERE key=?;
]]

local ZOTERO_REMOVE_OFFLINE_COLLECTION = [[
UPDATE collections
SET synced = 0
WHERE key=?;
]]

local ZOTERO_QUERY_ITEMS = [[
WITH cid AS (SELECT collectionID AS ID FROM collections WHERE key = ?1)
SELECT
	key,
	colname,
	'collection'
FROM (
	SELECT
		key,
		collectionName || '/' AS colname
	FROM collections, cid
	WHERE parentCollectionID = cid.ID
	ORDER By colname)
UNION ALL
SELECT
	items.key,
	value,
	iif(items.itemTypeID = 3, 'attachment', 'item') AS type
FROM
	itemData INNER JOIN items ON itemData.itemID = items.itemID, cid
WHERE
	itemData.itemID IN (
		SELECT itemID FROM collectionItems,cid WHERE collectionID = cid.ID
	)
;
]]

local ZOTERO_GET_COLLECTION_ITEMS = [[
WITH cid AS (SELECT collectionID AS ID FROM collections WHERE key = ?1)
SELECT
   items.key,
	value,
	iif(items.itemTypeID = 3, 'attachment', 'item') AS type
FROM
	itemData INNER JOIN items ON itemData.itemID = items.itemID, cid
WHERE
	itemData.itemID IN (
		SELECT itemID FROM collectionItems,cid WHERE collectionID = cid.ID
	)
;
]]

local ZOTERO_GET_COLLECTION_FOR_ITEM = [[
SELECT
	collectionID
FROM
	collectionItems INNER JOIN items USING (itemID)
WHERE
	key = ?
;
]]

local ZOTERO_GET_OFFLINE_COLLECTION_ATTACHMENTS = [[
SELECT
   items.key,
	value,
	iif(items.itemTypeID = 3, 'attachment', 'item') AS type
FROM
	itemData INNER JOIN items ON itemData.itemID = items.itemID
WHERE
	itemData.itemID IN (
		SELECT ItemID
		FROM itemAttachments
		WHERE
			parentItemID IN (
				SELECT itemID
				FROM collectionItems INNER JOIN collections ON collections.collectionID = collectionItems.collectionID
				WHERE synced = 1)
	);
]]

local ZOTERO_SEARCH_ITEMS = [[
SELECT
    key,
    value,
	iif(itemTypeID = 3, 'attachment', 'item') AS type
FROM itemData INNER JOIN items ON itemData.itemID = items.itemID
WHERE
	itemData.itemID IN (SELECT parentItemID FROM itemAttachments)
;
]]

local ZOTERO_GET_ITEM_ATTACHMENTS = [[
SELECT
	key,
	value
FROM (itemAttachments INNER JOIN itemData ON itemData.itemID = itemAttachments.itemID) INNER JOIN items ON itemData.itemID = items.itemID
WHERE
	itemAttachments.parentItemID IN (SELECT itemID FROM items WHERE key = ?1);
]]

local ZOTERO_GET_ITEM_ANNOTATIONS_INFO = [[
SELECT
	key,
	version,
	syncedVersion
FROM
	itemAnnotations INNER JOIN items ON itemAnnotations.itemID = items.itemID
WHERE
	itemAnnotations.parentItemID IN (SELECT itemID FROM items WHERE key = ?1);
]]

local ZOTERO_UPSERT_ITEM_ATTACHMENTS = [[
INSERT INTO itemAttachments(itemID, parentItemID) SELECT i.itemID, p.itemID AS pID FROM items i, items p WHERE i.key = ?1 AND p.key=?2
ON CONFLICT DO UPDATE SET parentItemID = excluded.parentItemID;
]]

local ZOTERO_DELETE_ITEM_ATTACHMENT = [[
DELETE FROM itemAttachments WHERE itemID IN (SELECT itemID FROM items WHERE key IS ?);
]]

local ZOTERO_UPSERT_ITEM_ANNOTATIONS = [[
INSERT INTO itemAnnotations(itemID, parentItemID) SELECT i.itemID, p.itemID FROM items i, items p WHERE i.key = ?1 AND p.key=?2
ON CONFLICT DO UPDATE SET parentItemID = excluded.parentItemID;
]]

local ZOTERO_GET_ITEM_VERSION = [[ SELECT version, itemID FROM items WHERE key = ?; ]]

-- Return synced version according to database for item identified by its key. Also return lastest version and itemID
local ZOTERO_GET_ATTACHMENT_VERSION = [[
SELECT syncedVersion, lastSync, version, items.itemID
FROM itemAttachments INNER JOIN items ON itemAttachments.itemID = items.itemID
WHERE key = ?;
]]

-- set synced version using the itemID (not key!) as the 1st parameter, and version number as the 2nd
local ZOTERO_SET_ATTACHMENT_SYNCEDVERSION = [[
UPDATE itemAttachments SET syncedVersion = ?2, lastSync = unixepoch('now') WHERE itemID = ?1;
]]

-- set synced version using not key as the 1st parameter, and version number as the 2nd
local ZOTERO_SET_ATTACHMENT_SYNCEDVERSION_KEY = [[
UPDATE itemAttachments SET syncedVersion = ?2 WHERE itemID IN (SELECT itemID FROM items WHERE key = ?1);
]]

-- set lastSync to now for attachment with key specified by parameter
local ZOTERO_SET_ATTACHMENT_LASTSYNC = [[
UPDATE itemAttachments SET lastSync = unixepoch('now') WHERE itemID IN (SELECT itemID FROM items WHERE key = ?);
]]

-- Return key, value (JSON) and lastSync for all locally synced attachments.
local ZOTERO_GET_LOCAL_ATTACHMENT = [[
SELECT
	key,
	value,
	lastSync
FROM (itemAttachments INNER JOIN itemData ON itemData.itemID = itemAttachments.itemID) INNER JOIN items ON itemData.itemID = items.itemID
WHERE itemAttachments.syncedVersion > 0;
]]

local ZOTERO_GET_VERSION = [[ SELECT version FROM attachment_versions WHERE key = ?; ]]
local ZOTERO_SET_VERSION = [[
INSERT INTO attachment_versions(key,version)
       VALUES(?,?)
       ON CONFLICT DO UPDATE SET version = excluded.version;
]]

-- get user library version and last sync
local ZOTERO_GET_USERLIB_VERSION = [[
SELECT version, lastSync FROM libraries WHERE libraryID = 1;
]]

-- set library version and last sync for user library (which always should have libraryID = 1)
local ZOTERO_SET_USERLIB_VERSION = [[
UPDATE libraries SET version = ?, lastSync = unixepoch('now') WHERE libraryID = 1;
]]

-- to check whether changes where made
local ZOTERO_DB_CHANGES = [[ SELECT changes() ]]

-- Return some basic stats about database
local ZOTERO_DB_STATS = [[
SELECT
	colls,
	allItems,
	attachments,
	annotations
FROM
	((
	SELECT
		COUNT(collectionID) AS colls
	FROM
		collections
	),(
	SELECT
		COUNT(itemID) AS allItems
	FROM
		items
	),(
	SELECT
		COUNT(itemID) AS attachments
	FROM
		itemAttachments
	),(
	SELECT
		COUNT(itemID) AS annotations
	FROM
		itemAnnotations
	));
]]

local function file_exists(path)
    if path == nil then
        return nil
    end
    return lfs.attributes(path) ~= nil
end

local function table_contains(t, search_value)
    for k, v in pairs(t) do
        if v == search_value then
            return true
        end
    end

    return false
end

-- TODO: Commenting to see if it used or needed for removal
-- local function file_slurp(path)
-- 	if not file_exists(path) then
-- 		return nil
-- 	end
-- 	local f = io.open(path, "r")

-- 	if f == nil then
-- 		return nil
-- 	end

-- 	local content = f:read("*all")
-- 	f:close()
-- 	return content
-- end

-- Open the sqlite database. When opening it for the first time also get the current database version.
-- If sqlite library is empty make sure the required tables are set up
function API.openDB()
    if API.db ~= nil then
        return API.db
    else
        API.db = SQ3.open(API.db_path)
        --API.db:exec(ZOTERO_CREATE_VIEWS)
        API.db:exec("PRAGMA foreign_keys=ON")
        --logger.info("Zotero: db opened with foreign keys enabled: ", tonumber(unpack(API.db:exec("PRAGMA foreign_keys")[1])))
        if API.getDatabaseVersion() == 0 then
            logger.info("Zotero: db version is 0. Set up tables.")
            API.db:exec(ZOTERO_DB_SCHEMA)
            logger.info("Zotero: Set up user library.")
            API.db:rowexec(ZOTERO_DB_INIT_LIBS)
            local cnt = API.db:rowexec(ZOTERO_DB_CHANGES)
            if cnt ~= nil then
                logger.info("Zotero: Changes in libraries table: ", tonumber(cnt))
            end
            local cnt = API.db:rowexec("SELECT COUNT(*) FROM itemTypes")
            if cnt == 0 then
                logger.info("Zotero: Set up user itemTypes.")
                API.db:exec(ZOTERO_DB_INIT_ITEMTYPES)
                local cnt = API.db:rowexec(ZOTERO_DB_CHANGES)
                if cnt ~= nil then
                    logger.info("Zotero: Changes in itemTypes table: ", tonumber(cnt))
                end
            end
            logger.info("Zotero: Set up root collection.")
            API.db:exec(ZOTERO_DB_INIT_COLLECTIONS)
            -- Create index for item keys
            API.db:exec(ZOTERO_CREATE_ITEMKEY_INDEX)
            API.setDatabaseVersion(db_version)
        else
            API.getUserLibraryVersion()
            logger.info("Zotero: Local db version: " .. API.libVersion)
            -- Repair: itemTypes must exist or every item INSERT silently inserts 0 rows
            local it_cnt = tonumber(API.db:rowexec("SELECT COUNT(*) FROM itemTypes")) or 0
            if it_cnt == 0 then
                logger.warn("Zotero: itemTypes empty — re-initializing")
                API.db:exec(ZOTERO_DB_INIT_ITEMTYPES)
            end
        end
        return API.db
    end
end

-- TODO: call this at appropriate time
function API.closeDB()
    if API.db ~= nil then
        API.db:close()
    end
    API.db = nil
    API.libVersion = nil
end

-- Initialise plugin by setting correct path and opening the sqlite database
function API.init(zotero_dir)
    API.zotero_dir = zotero_dir
    local settings_path = BaseUtil.joinPath(API.zotero_dir, "meta.lua")
    API.settings = LuaSettings:open(settings_path)

    API.storage_dir = BaseUtil.joinPath(API.zotero_dir, "storage")
    if not file_exists(API.storage_dir) then
        lfs.mkdir(API.storage_dir)
    end
    -- Per-attachment sync state (known keys / pending deletes). MUST live outside the
    -- document sidecar — KOReader rewrites metadata.*.lua and would wipe our keys.
    API.annot_state_dir = BaseUtil.joinPath(API.zotero_dir, "annot_state")
    if not file_exists(API.annot_state_dir) then
        lfs.mkdir(API.annot_state_dir)
    end

    logger.dbg("Zotero: storage dir" .. API.storage_dir)

    API.db_path = BaseUtil.joinPath(API.zotero_dir, "zotero.db")
    logger.info("Zotero: opening db path ", API.db_path)
    local db = API.openDB()
    local stats = {}

    -- get file modification time (to provide some indication of 'version')
    local path = debug.getinfo(1, "S").source:sub(2)
    local ts = lfs.attributes(path, "modification")
    API.version = API.version .. " (" .. os.date("%Y-%m-%d %X", ts) .. ")"
    logger.info("Zotero plugin version: " .. API.version)

    --API.scanStorage()
    --API.getItemWithAttachments("H26YYGWN")
end

local function annotStatePath(attachment_key)
    return BaseUtil.joinPath(API.annot_state_dir or API.zotero_dir, "annot_" .. tostring(attachment_key) .. ".lua")
end

-- Persistent sync state for one attachment: { known = {key,...}, pending_deletes = {key,...} }
function API.loadAnnotationSyncState(attachment_key)
    local state = { known = {}, pending_deletes = {} }
    if attachment_key == nil or attachment_key == "" then
        return state
    end
    local path = annotStatePath(attachment_key)
    local ok, data = pcall(function()
        return LuaSettings:open(path)
    end)
    if not ok or not data then
        return state
    end
    local known = data:readSetting("known", {}) or {}
    local pending = data:readSetting("pending_deletes", {}) or {}
    pcall(function()
        data:close()
    end)
    local function to_list(t)
        local out = {}
        if type(t) ~= "table" then
            return out
        end
        for k, v in pairs(t) do
            if type(k) == "number" and type(v) == "string" then
                table.insert(out, v)
            elseif type(k) == "string" and v then
                table.insert(out, k)
            end
        end
        return out
    end
    state.known = to_list(known)
    state.pending_deletes = to_list(pending)
    return state
end

function API.saveAnnotationSyncState(attachment_key, state)
    if attachment_key == nil or attachment_key == "" or API.annot_state_dir == nil then
        return
    end
    if not file_exists(API.annot_state_dir) then
        lfs.mkdir(API.annot_state_dir)
    end
    local path = annotStatePath(attachment_key)
    pcall(function()
        local ds = LuaSettings:open(path)
        ds:saveSetting("known", state.known or {})
        ds:saveSetting("pending_deletes", state.pending_deletes or {})
        ds:flush()
        ds:close()
    end)
end

function API.annotationSyncStateSets(attachment_key)
    local state = API.loadAnnotationSyncState(attachment_key)
    local known_set, pending_set = {}, {}
    for _, k in ipairs(state.known or {}) do
        known_set[k] = true
    end
    for _, k in ipairs(state.pending_deletes or {}) do
        pending_set[k] = true
    end
    return known_set, pending_set, state
end

local function persistAnnotState(attachment_key, current_keys_set, pending_set)
    current_keys_set = current_keys_set or {}
    pending_set = pending_set or {}
    -- Drop pending if the key reappeared in the sidecar
    for k, _ in pairs(pending_set) do
        if current_keys_set[k] then
            pending_set[k] = nil
        end
    end
    local new_pending = {}
    for k, _ in pairs(pending_set) do
        table.insert(new_pending, k)
    end
    -- known = current ∪ pending (so we remember what to delete)
    local known_list = {}
    local seen = {}
    for k, _ in pairs(current_keys_set) do
        if not seen[k] then
            table.insert(known_list, k)
            seen[k] = true
        end
    end
    for k, _ in pairs(pending_set) do
        if not seen[k] then
            table.insert(known_list, k)
            seen[k] = true
        end
    end
    API.saveAnnotationSyncState(attachment_key, {
        known = known_list,
        pending_deletes = new_pending,
    })
    logger.info(
        ("Zotero: annot-state %s known=%d pending=%d"):format(
            tostring(attachment_key),
            #known_list,
            #new_pending
        )
    )
    return pending_set
end

-- Record keys present in sidecar as known; mark missing known keys as pending deletes.
function API.noteLocalAnnotationDeletions(attachment_key, current_keys_set)
    if attachment_key == nil then
        return {}
    end
    local known_set, pending_set = API.annotationSyncStateSets(attachment_key)
    current_keys_set = current_keys_set or {}
    -- First seed: if we have never known anything, learn current keys (no deletes yet)
    if next(known_set) == nil and next(pending_set) == nil then
        local known_list = {}
        for k, _ in pairs(current_keys_set) do
            table.insert(known_list, k)
        end
        API.saveAnnotationSyncState(attachment_key, { known = known_list, pending_deletes = {} })
        return {}
    end
    for k, _ in pairs(known_set) do
        if not current_keys_set[k] then
            pending_set[k] = true
        end
    end
    return persistAnnotState(attachment_key, current_keys_set, pending_set)
end

-- Mark exactly one locally deleted annotation (preferred path — avoids false neighbours).
function API.noteExplicitLocalAnnotationDeletion(attachment_key, deleted_key, current_keys_set)
    if attachment_key == nil or deleted_key == nil or deleted_key == "" then
        return API.noteLocalAnnotationDeletions(attachment_key, current_keys_set)
    end
    local _, pending_set = API.annotationSyncStateSets(attachment_key)
    current_keys_set = current_keys_set or {}
    -- Ensure the deleted key is not considered present
    current_keys_set[deleted_key] = nil
    pending_set[deleted_key] = true
    return persistAnnotState(attachment_key, current_keys_set, pending_set)
end

function API.getStats()
    local db = API.openDB()

    local c, i, a, n = db:rowexec(ZOTERO_DB_STATS)
    local sy, name = db:rowexec("SELECT lastSync, name FROM libraries WHERE libraryID = 1;")
    local lastsync = os.date("%Y-%m-%d %X", tonumber(sy))
    local stats = {
        ["libVersion"] = API.getUserLibraryVersion(),
        ["name"] = name,
        ["lastSync"] = lastsync,
        ["collections"] = tonumber(c),
        ["items"] = tonumber(i),
        ["attachments"] = tonumber(a),
        ["annotations"] = tonumber(n),
    }
    --logger.info(JSON.encode(stats))
    return stats
end

function API.getAPIKey()
    return API.settings:readSetting("api_key")
end

function API.setAPIKey(api_key)
    API.settings:saveSetting("api_key", api_key)
    API.zoteroAcessVerified = false
end

function API.getUserID()
    return API.settings:readSetting("user_id")
end

function API.setUserID(user_id)
    API.settings:saveSetting("user_id", user_id)
    API.zoteroAcessVerified = false
end

function API.getWebDAVEnabled()
    return API.settings:isTrue("webdav_enabled")
end

function API.getWebDAVUser()
    return API.settings:readSetting("webdav_user")
end

function API.getWebDAVPassword()
    return API.settings:readSetting("webdav_password")
end

function API.getWebDAVUrl()
    return API.settings:readSetting("webdav_url")
end

function API.toggleWebDAVEnabled()
    API.settings:toggle("webdav_enabled")
end

function API.setWebDAVUser(user)
    API.settings:saveSetting("webdav_user", user)
end

function API.setWebDAVPassword(password)
    API.settings:saveSetting("webdav_password", password)
end

function API.setWebDAVUrl(url)
    API.settings:saveSetting("webdav_url", url)
end

-- Check database version. This should not change too often, but allows us to spot changes
-- and possibly enable database mgration to newer version...
function API.getDatabaseVersion()
    local db = API.openDB()
    local result, ncol = db:exec(ZOTERO_GET_DB_VERSION)
    assert(ncol == 1)
    return tonumber(result[1][1])
end

function API.setDatabaseVersion(version)
    --    API.libVersion
    local dbversion = tonumber(version)
    local db = API.openDB()
    local sql = "PRAGMA user_version = " .. tostring(dbversion) .. ";"
    db:exec(sql)
end

-- Zotero user library version. Used for syncing, as only changes since the last sync will
-- be requested from the Zotero server
function API.getUserLibraryVersion()
    if API.libVersion == nil then
        local db = API.openDB()
        local result, ncol = db:exec(ZOTERO_GET_USERLIB_VERSION)
        assert(ncol == 1)
        local version = tonumber(result[1][1])
        API.libVersion = version
    end
    return API.libVersion
end

-- Update the local Zotero user library version number and 'lastSync'
function API.setUserLibraryVersion(version)
    API.libVersion = tonumber(version)
    local db = API.openDB()
    local sql = "UPDATE libraries SET version = "
        .. tostring(API.libVersion)
        .. ", lastSync = unixepoch('now') WHERE libraryID = 1;"
    db:exec(sql)
end

-- HEAD the library so If-Unmodified-Since-Version matches the server (avoids 412).
function API.refreshUserLibraryVersionFromServer()
    local e = API.verifyZoteroAccess()
    if e ~= nil then
        return e
    end
    local req_headers = {}
    for hk, hv in pairs(API.zoteroHeader or {}) do
        req_headers[hk] = hv
    end
    local r, c, h = https.request({
        method = "HEAD",
        url = API.userLibraryURL .. "/items?limit=1",
        headers = req_headers,
    })
    e = API.verifyResponse(r, c)
    if e ~= nil then
        -- Some proxies break HEAD; try a tiny GET
        local body = {}
        r, c, h = https.request({
            method = "GET",
            url = API.userLibraryURL .. "/items?limit=1",
            headers = req_headers,
            sink = ltn12.sink.table(body),
        })
        e = API.verifyResponse(r, c)
        if e ~= nil then
            return e
        end
    end
    local ver = h and (h["last-modified-version"] or h["Last-Modified-Version"])
    if ver ~= nil then
        API.setUserLibraryVersion(ver)
        logger.info("Zotero: refreshed library version from server: ", ver)
    end
    return nil
end

-- Retrieve underlying settings object to make changes from the outside
function API.getSettings()
    return API.settings
end

-- Save settings to config file
function API.saveSettingsToFile()
    return API.settings:flush()
end

-- Large-screen layout options (dual-pane browser / side annotation panel)
local DEFAULT_LARGE_SCREEN_MIN_WIDTH = 1000

function API.getLargeScreenDualPane()
    return API.settings:isTrue("large_screen_dual_pane")
end

function API.setLargeScreenDualPane(enabled)
    API.settings:saveSetting("large_screen_dual_pane", enabled and true or false)
end

function API.toggleLargeScreenDualPane()
    API.setLargeScreenDualPane(not API.getLargeScreenDualPane())
end

function API.getLargeScreenAnnotationPanel()
    return API.settings:isTrue("large_screen_annotation_panel")
end

function API.setLargeScreenAnnotationPanel(enabled)
    API.settings:saveSetting("large_screen_annotation_panel", enabled and true or false)
end

function API.toggleLargeScreenAnnotationPanel()
    API.setLargeScreenAnnotationPanel(not API.getLargeScreenAnnotationPanel())
end

function API.getLargeScreenMinWidth()
    local n = tonumber(API.settings:readSetting("large_screen_min_width", DEFAULT_LARGE_SCREEN_MIN_WIDTH))
    if not n or n < 400 then
        return DEFAULT_LARGE_SCREEN_MIN_WIDTH
    end
    return math.floor(n)
end

function API.setLargeScreenMinWidth(width)
    local n = tonumber(width) or DEFAULT_LARGE_SCREEN_MIN_WIDTH
    if n < 400 then
        n = 400
    elseif n > 4000 then
        n = 4000
    end
    API.settings:saveSetting("large_screen_min_width", math.floor(n))
end

function API.isLargeScreen()
    local Device = require("device")
    local Screen = Device.screen
    return Screen:getWidth() >= API.getLargeScreenMinWidth()
end

-- Annotation destination settings (local / zotero / both)
function API.getAnnotationDestinationAsk()
    local v = API.settings:readSetting("annotation_destination_ask", true)
    if v == false or v == 0 or v == "false" then
        return false
    end
    return true
end

function API.setAnnotationDestinationAsk(ask)
    API.settings:saveSetting("annotation_destination_ask", ask and true or false)
end

function API.getAnnotationDestinationDefault()
    local Annotations = require("annotations")
    return Annotations.normalizeDestination(
        API.settings:readSetting("annotation_destination_default", Annotations.DEST_BOTH)
    )
end

function API.setAnnotationDestinationDefault(dest)
    local Annotations = require("annotations")
    API.settings:saveSetting("annotation_destination_default", Annotations.normalizeDestination(dest))
end

function API.getAnnotationDestinationLast()
    local Annotations = require("annotations")
    return Annotations.normalizeDestination(
        API.settings:readSetting("annotation_destination_last", API.getAnnotationDestinationDefault())
    )
end

function API.setAnnotationDestinationLast(dest)
    local Annotations = require("annotations")
    API.settings:saveSetting("annotation_destination_last", Annotations.normalizeDestination(dest))
end

-- For documents not linked to Zotero: "local" = write into PDF when possible, "sidecar" = sidecar only
function API.getAnnotationDestinationNonZotero()
    local v = API.settings:readSetting("annotation_destination_non_zotero", "local")
    if v == "sidecar" then
        return "sidecar"
    end
    return "local"
end

function API.setAnnotationDestinationNonZotero(mode)
    if mode == "sidecar" then
        API.settings:saveSetting("annotation_destination_non_zotero", "sidecar")
    else
        API.settings:saveSetting("annotation_destination_non_zotero", "local")
    end
end

-- Paths waiting for annotation sync while offline (survive close/open / other books).
function API.getAnnotSyncPending()
    local t = API.settings:readSetting("annot_sync_pending", {})
    if type(t) ~= "table" then
        return {}
    end
    return t
end

function API.markAnnotSyncPending(file_path)
    if file_path == nil or file_path == "" then
        return
    end
    local pending = API.getAnnotSyncPending()
    local norm = API.normalizePath(file_path) or file_path
    if pending[norm] then
        return
    end
    pending[norm] = true
    API.settings:saveSetting("annot_sync_pending", pending)
    pcall(API.saveSettingsToFile)
end

function API.clearAnnotSyncPending(file_path)
    if file_path == nil or file_path == "" then
        return
    end
    local pending = API.getAnnotSyncPending()
    local norm = API.normalizePath(file_path) or file_path
    if not pending[norm] then
        return
    end
    pending[norm] = nil
    API.settings:saveSetting("annot_sync_pending", pending)
    pcall(API.saveSettingsToFile)
end

function API.isAnnotSyncPending(file_path)
    if file_path == nil or file_path == "" then
        return false
    end
    local pending = API.getAnnotSyncPending()
    local norm = API.normalizePath(file_path) or file_path
    return pending[norm] == true
end

-- Effective destination for a new annotation on a Zotero-linked document (no dialog).
function API.getEffectiveZoteroDestination()
    if API.getAnnotationDestinationAsk() then
        return API.getAnnotationDestinationLast()
    end
    return API.getAnnotationDestinationDefault()
end

-- Default highlight appearance (KOReader drawer + color → also used when uploading to Zotero)
local DEFAULT_HL_COLORS = {
    "gray", -- darkest KOReader colour = best e-ink underline ("noir")
    "yellow",
    "orange",
    "red",
    "green",
    "blue",
    "purple",
}
local DEFAULT_HL_DRAWERS = {
    "lighten", -- highlight
    "underscore", -- underline
    "strikeout",
    "invert",
}

function API.getDefaultHighlightColor()
    local c = string.lower(tostring(API.settings:readSetting("annotation_default_color", "gray") or "gray"))
    if c == "black" or c == "grey" then
        c = "gray"
    end
    for _, name in ipairs(DEFAULT_HL_COLORS) do
        if name == c then
            return c
        end
    end
    return "gray"
end

function API.setDefaultHighlightColor(color)
    color = string.lower(tostring(color or "gray"))
    if color == "black" or color == "grey" then
        color = "gray"
    end
    local ok = false
    for _, name in ipairs(DEFAULT_HL_COLORS) do
        if name == color then
            ok = true
            break
        end
    end
    API.settings:saveSetting("annotation_default_color", ok and color or "gray")
end

function API.cycleDefaultHighlightColor()
    local cur = API.getDefaultHighlightColor()
    local next_c = DEFAULT_HL_COLORS[1]
    for i, name in ipairs(DEFAULT_HL_COLORS) do
        if name == cur then
            next_c = DEFAULT_HL_COLORS[(i % #DEFAULT_HL_COLORS) + 1]
            break
        end
    end
    API.setDefaultHighlightColor(next_c)
    return next_c
end

function API.getDefaultHighlightDrawer()
    local d = string.lower(tostring(API.settings:readSetting("annotation_default_drawer", "lighten") or "lighten"))
    for _, name in ipairs(DEFAULT_HL_DRAWERS) do
        if name == d then
            return d
        end
    end
    return "lighten"
end

function API.setDefaultHighlightDrawer(drawer)
    drawer = string.lower(tostring(drawer or "lighten"))
    local ok = false
    for _, name in ipairs(DEFAULT_HL_DRAWERS) do
        if name == drawer then
            ok = true
            break
        end
    end
    API.settings:saveSetting("annotation_default_drawer", ok and drawer or "lighten")
end

function API.cycleDefaultHighlightDrawer()
    local cur = API.getDefaultHighlightDrawer()
    local next_d = DEFAULT_HL_DRAWERS[1]
    for i, name in ipairs(DEFAULT_HL_DRAWERS) do
        if name == cur then
            next_d = DEFAULT_HL_DRAWERS[(i % #DEFAULT_HL_DRAWERS) + 1]
            break
        end
    end
    API.setDefaultHighlightDrawer(next_d)
    return next_d
end

function API.labelDefaultHighlightDrawer(drawer)
    drawer = drawer or API.getDefaultHighlightDrawer()
    if drawer == "underscore" then
        return _("Underline")
    elseif drawer == "strikeout" then
        return _("Strikeout")
    elseif drawer == "invert" then
        return _("Invert")
    end
    return _("Highlight")
end

function API.labelDefaultHighlightColor(color)
    color = color or API.getDefaultHighlightColor()
    local labels = {
        yellow = _("Yellow"),
        orange = _("Orange"),
        red = _("Red"),
        green = _("Green"),
        blue = _("Blue"),
        purple = _("Purple"),
        gray = _("Black (e-ink)"),
    }
    return labels[color] or color
end

-- Local files / linked files settings
function API.getLinkedFilesEnabled()
    return API.settings:isTrue("linked_files_enabled")
end

function API.toggleLinkedFilesEnabled()
    API.settings:toggle("linked_files_enabled")
end

function API.getLinkedFilesBase()
    return API.settings:readSetting("linked_files_base", "") or ""
end

function API.setLinkedFilesBase(path)
    API.settings:saveSetting("linked_files_base", API.normalizeDevicePath(path or ""))
end

-- True when file_path is under the configured linked-files (vault) folder.
function API.isPathUnderLinkedBase(file_path)
    if file_path == nil or file_path == "" then
        return false
    end
    if not API.getLinkedFilesEnabled() then
        return false
    end
    local base = API.getLinkedFilesBase()
    if base == nil or base == "" then
        return false
    end
    local nfile = API.normalizePathForCompare(file_path) or API.normalizePath(file_path)
    local nbase = API.normalizePathForCompare(base) or API.normalizePath(base)
    if nfile == nil or nfile == "" or nbase == nil or nbase == "" then
        return false
    end
    local fl = string.lower(nfile)
    local bl = string.lower(nbase)
    if fl == bl then
        return true
    end
    if bl:sub(-1) ~= "/" then
        bl = bl .. "/"
    end
    return fl:sub(1, #bl) == bl
end

local function joinDesktopPath(root, rel)
    root = tostring(root or ""):gsub("[/\\]+$", "")
    rel = tostring(rel or ""):gsub("^[/\\]+", "")
    if root == "" or rel == "" then
        return nil
    end
    -- Match existing library style: Windows absolute paths use backslashes
    if root:match("^%a:") then
        root = root:gsub("/", "\\")
        rel = rel:gsub("/", "\\")
        return root .. "\\" .. rel
    end
    root = root:gsub("\\", "/")
    rel = rel:gsub("\\", "/")
    return root .. "/" .. rel
end

-- Relative path of file under linked_files_base, or nil.
local function relPathUnderLinkedBase(file_path)
    local base = API.normalizePath(API.getLinkedFilesBase() or "")
    local file = API.normalizePath(file_path or "")
    if base == "" or file == "" then
        return nil
    end
    local bl = string.lower(base)
    local fl = string.lower(file)
    if fl == bl then
        return nil
    end
    if fl:sub(1, #bl) ~= bl then
        return nil
    end
    local rel = file:sub(#base + 1):gsub("^/", "")
    if rel == "" then
        return nil
    end
    return rel
end

-- Zotero linked-file path written into item.data.path.
-- Prefer absolute desktop paths (same style as existing library items: D:\Notes\...),
-- because attachments: requires a correctly configured base directory on every machine.
function API.linkedAttachmentZoteroPath(file_path)
    local file = API.normalizePath(file_path or "")

    -- 1) Reverse path mappings (device "to" → Zotero/PC "from")
    local mappings = API.getPathMappings()
    local best_from, best_rel, best_to_len = nil, nil, -1
    for _, m in ipairs(mappings) do
        local to = API.normalizePath(m.to or "")
        local from = m.from or ""
        if to ~= "" and from ~= "" and file ~= "" then
            local tl = string.lower(to)
            local fl = string.lower(file)
            if (fl == tl or fl:sub(1, #tl + 1) == tl .. "/") and #to > best_to_len then
                local map_rel = file:sub(#to + 1):gsub("^/", "")
                if map_rel ~= "" then
                    best_from = from
                    best_rel = map_rel
                    best_to_len = #to
                end
            end
        end
    end
    if best_from and best_rel then
        local joined = joinDesktopPath(best_from, best_rel)
        if joined then
            return joined
        end
    end

    -- 2) Infer desktop root from existing absolute linked_file paths in the library
    local rel = relPathUnderLinkedBase(file_path)
    if rel then
        local root = API.inferDesktopLinkedRoot()
        if root then
            local joined = joinDesktopPath(root, rel)
            if joined then
                return joined
            end
        end
    end

    -- 3) Fallback: portable attachments: form (needs Zotero base-dir config)
    if rel and rel ~= "" then
        return "attachments:" .. rel
    end
    local base_name = API.basenameOfPath(file_path) or "file"
    return "attachments:" .. base_name
end

-- If a linked attachment still uses attachments: but we can express an absolute
-- desktop path (matching the rest of the library), update it on Zotero.
function API.healLinkedAttachmentPath(file_path, attachment_key)
    if not file_path or not attachment_key then
        return false
    end
    local item = API.getItem(attachment_key)
    if not item or not item.data or item.data.linkMode ~= "linked_file" then
        return false
    end
    local cur = tostring(item.data.path or "")
    if not cur:match("^attachments:") then
        return false
    end
    local desired = API.linkedAttachmentZoteroPath(file_path)
    if desired == nil or desired == "" or desired == cur or desired:match("^attachments:") then
        return false
    end
    local version = item.version or (item.data and item.data.version)
    local payload = {
        key = attachment_key,
        version = version,
        path = desired,
    }
    logger.info(
        ("Zotero: healing linked path %s → %s"):format(cur, desired)
    )
    -- updateItems returns (updated, fails); fails is always a table (possibly empty)
    local updated, fails = API.updateItems({ payload })
    if type(fails) == "string" then
        logger.warn("Zotero: healLinkedAttachmentPath failed: ", fails)
        return false
    end
    if type(fails) == "table" and #fails > 0 then
        logger.warn("Zotero: healLinkedAttachmentPath failed: ", JSON.encode(fails))
        return false
    end
    local ok_item = updated and (updated[1] or updated[attachment_key])
    if not ok_item and type(updated) == "table" then
        for _, v in pairs(updated) do
            if type(v) == "table" and (v.key == attachment_key or v.data) then
                ok_item = v
                break
            end
        end
    end
    if ok_item then
        API.clearAttachmentPathCache()
        API.rememberAttachmentKeyForPath(file_path, attachment_key)
        return true
    end
    logger.warn("Zotero: healLinkedAttachmentPath: no updated item returned")
    return false
end

-- Fast path for menu enablement: under linked-files vault only (no DB scan).
-- "Already linked" is checked later in showAddLinkedBookDialog / createLinkedBookItem.
function API.canAddLinkedBook(file_path)
    return API.isPathUnderLinkedBase(file_path)
end

function API.getDisplaySquigglyBlack()
    return API.settings:isTrue("display_squiggly_black")
end

function API.setDisplaySquigglyBlack(enabled)
    API.settings:saveSetting("display_squiggly_black", enabled and true or false)
end

function API.toggleDisplaySquigglyBlack()
    API.settings:toggle("display_squiggly_black")
    return API.getDisplaySquigglyBlack()
end

function API.getExternalStorageEnabled()
    return API.settings:isTrue("external_storage_enabled")
end

function API.toggleExternalStorageEnabled()
    API.settings:toggle("external_storage_enabled")
end

function API.getExternalStorageDir()
    return API.settings:readSetting("external_storage_dir", "") or ""
end

function API.setExternalStorageDir(path)
    API.settings:saveSetting("external_storage_dir", API.normalizeDevicePath(path or ""))
end

function API.getPathMappings()
    local mappings = API.settings:readSetting("path_mappings")
    if type(mappings) ~= "table" then
        return {}
    end
    return mappings
end

function API.setPathMappings(mappings)
    API.settings:saveSetting("path_mappings", mappings or {})
end

function API.addPathMapping(from_prefix, to_prefix)
    local mappings = API.getPathMappings()
    table.insert(mappings, { from = from_prefix, to = to_prefix })
    API.setPathMappings(mappings)
end

function API.removePathMapping(index)
    local mappings = API.getPathMappings()
    if index >= 1 and index <= #mappings then
        table.remove(mappings, index)
        API.setPathMappings(mappings)
        return true
    end
    return false
end

function API.clearPathMappings()
    API.setPathMappings({})
end

function API.getSearchRoots()
    local roots = API.settings:readSetting("search_roots")
    if type(roots) ~= "table" then
        return {}
    end
    return roots
end

function API.setSearchRoots(roots)
    API.settings:saveSetting("search_roots", roots or {})
end

function API.addSearchRoot(path)
    if path == nil or path == "" then
        return
    end
    path = API.normalizeDevicePath(path)
    local roots = API.getSearchRoots()
    for _, r in ipairs(roots) do
        if API.pathsEqual(r, path) then
            return
        end
    end
    table.insert(roots, path)
    API.setSearchRoots(roots)
end

function API.removeSearchRoot(index)
    local roots = API.getSearchRoots()
    if index >= 1 and index <= #roots then
        table.remove(roots, index)
        API.setSearchRoots(roots)
        return true
    end
    return false
end

function API.getAllowStaleLocal()
    return API.settings:readSetting("allow_stale_local", true) ~= false
end

function API.toggleAllowStaleLocal()
    local cur = API.getAllowStaleLocal()
    API.settings:saveSetting("allow_stale_local", not cur)
end

function API.getLinkedFilesBases()
    local bases = API.settings:readSetting("linked_files_bases")
    if type(bases) ~= "table" then
        bases = {}
    end
    local primary = API.getLinkedFilesBase()
    if primary ~= "" then
        local found = false
        for _, b in ipairs(bases) do
            if API.pathsEqual(b, primary) then
                found = true
                break
            end
        end
        if not found then
            table.insert(bases, 1, primary)
        end
    end
    return bases
end

function API.basenameOfPath(p)
    if p == nil or p == "" then
        return nil
    end
    p = API.normalizePath(p)
    return p:match("([^/]+)$")
end

-- Directories to never descend into when resolving local files
-- (Syncthing versions, trash, VCS, …).
local SKIP_DIR_NAMES = {
    [".stversions"] = true,
    [".stfolder"] = true,
    [".trash"] = true,
    [".Trash"] = true,
    ["Trash"] = true,
    [".git"] = true,
    [".svn"] = true,
    [".thumbnails"] = true,
    ["@eaDir"] = true,
    ["node_modules"] = true,
    [".recycle"] = true,
    ["#recycle"] = true,
}

function API.isIgnoredPathSegment(name)
    if name == nil or name == "" then
        return false
    end
    if SKIP_DIR_NAMES[name] then
        return true
    end
    local lower = string.lower(name)
    if SKIP_DIR_NAMES[lower] then
        return true
    end
    -- Syncthing / backup style folders
    if lower:match("^%.st") or lower:match("%.stversions") then
        return true
    end
    return false
end

function API.pathContainsIgnoredSegment(path)
    if path == nil or path == "" then
        return false
    end
    path = API.normalizePath(path)
    for segment in string.gmatch(path, "[^/]+") do
        if API.isIgnoredPathSegment(segment) then
            return true
        end
    end
    return false
end

-- Recursively find a file by basename under root (depth-limited).
-- Skips backup/version folders. Prefers the first non-ignored match;
-- if only ignored paths exist, returns nil (never .stversions).
function API.findFileByBasename(root, basename, depth, results)
    depth = depth or 0
    results = results or {}
    if root == nil or root == "" or basename == nil or basename == "" or depth > 8 then
        if depth == 0 then
            return API.pickBestBasenameMatch(results)
        end
        return nil
    end
    if not file_exists(root) then
        if depth == 0 then
            return API.pickBestBasenameMatch(results)
        end
        return nil
    end
    local target_lower = string.lower(basename)
    for name in lfs.dir(root) do
        if name ~= "." and name ~= ".." and not API.isIgnoredPathSegment(name) then
            local path = BaseUtil.joinPath(root, name)
            local mode = lfs.attributes(path, "mode")
            if mode == "file" and string.lower(name) == target_lower then
                local norm = API.normalizePath(path)
                if not API.pathContainsIgnoredSegment(norm) then
                    table.insert(results, norm)
                end
            elseif mode == "directory" then
                API.findFileByBasename(path, basename, depth + 1, results)
            end
        end
    end
    if depth == 0 then
        return API.pickBestBasenameMatch(results)
    end
    return nil
end

-- Prefer shorter paths (closer to root) and paths without hidden segments.
function API.pickBestBasenameMatch(results)
    if results == nil or #results == 0 then
        return nil
    end
    table.sort(results, function(a, b)
        local a_ign = API.pathContainsIgnoredSegment(a) and 1 or 0
        local b_ign = API.pathContainsIgnoredSegment(b) and 1 or 0
        if a_ign ~= b_ign then
            return a_ign < b_ign
        end
        return #a < #b
    end)
    local best = results[1]
    if API.pathContainsIgnoredSegment(best) then
        return nil
    end
    return best
end

function API.collectSearchRoots()
    local roots = {}
    local function add(p)
        if p and p ~= "" then
            table.insert(roots, p)
        end
    end
    for _, b in ipairs(API.getLinkedFilesBases()) do
        add(b)
    end
    if API.getExternalStorageEnabled() then
        add(API.getExternalStorageDir())
    end
    for _, r in ipairs(API.getSearchRoots()) do
        add(r)
    end
    add(API.storage_dir)
    return roots
end

-- Fuzzy locate by basename. Prefer mapped / linked folders first (semi-manual
-- path mapping), then fall back to broader search roots.
function API.findAttachmentByBasename(filename)
    if filename == nil or filename == "" then
        return nil
    end
    local base = API.basenameOfPath(filename) or filename
    local mapped = API.collectMappedSearchRoots()
    for _, root in ipairs(mapped) do
        local found = API.findFileByBasename(root, base)
        if found then
            return found
        end
    end
    -- Broader search only if no mapping-based hit
    for _, root in ipairs(API.collectSearchRoots()) do
        local found = API.findFileByBasename(root, base)
        if found then
            return found
        end
    end
    return nil
end

function API.normalizePath(p)
    if p == nil or p == "" then
        return p
    end
    p = p:gsub("\\", "/")
    p = p:gsub("/+", "/")
    if #p > 1 and p:sub(-1) == "/" then
        p = p:sub(1, -2)
    end
    return p
end

function API.normalizePathForCompare(p)
    if p == nil or p == "" then
        return nil
    end
    local ok, real = pcall(BaseUtil.realpath, p)
    if ok and real then
        p = real
    end
    return API.normalizePath(p)
end

function API.pathsEqual(a, b)
    local na = API.normalizePathForCompare(a)
    local nb = API.normalizePathForCompare(b)
    return na ~= nil and nb ~= nil and na == nb
end

local function path_lower(s)
    return string.lower(s)
end

function API.isAbsolutePath(p)
    if p == nil or p == "" then
        return false
    end
    p = p:gsub("\\", "/")
    if p:match("^/") then
        return true
    end
    if p:match("^%a:[/\\]") or p:match("^%a:/") then
        return true
    end
    return false
end

function API.applyPathMappings(p, mappings)
    if p == nil or p == "" or mappings == nil or #mappings == 0 then
        return p
    end
    p = API.normalizePath(p)
    local sorted = {}
    for _, m in ipairs(mappings) do
        if m.from and m.from ~= "" then
            table.insert(sorted, m)
        end
    end
    table.sort(sorted, function(a, b)
        return #a.from > #b.from
    end)
    local p_lower = path_lower(p)
    for _, m in ipairs(sorted) do
        local from_norm = API.normalizePath(m.from)
        local from_lower = path_lower(from_norm)
        if #from_lower > 0 and p_lower:sub(1, #from_lower) == from_lower then
            local rest = p:sub(#from_norm + 1)
            if rest:sub(1, 1) == "/" then
                rest = rest:sub(2)
            end
            local to_norm = API.normalizePath(m.to or "")
            if to_norm == "" then
                return rest ~= "" and API.normalizePath(rest) or p
            end
            if rest == "" then
                return to_norm
            end
            return API.normalizePath(BaseUtil.joinPath(to_norm, rest))
        end
    end
    return p
end

function API.resolveLinkedPath(rawPath, linkedBase, mappings)
    if rawPath == nil or rawPath == "" then
        return nil
    end
    mappings = mappings or API.getPathMappings()

    local storage_key, storage_file = rawPath:match("^storage:(%w+)/(.+)$")
    if storage_key and storage_file then
        if API.getExternalStorageEnabled() then
            local ext_dir = API.getExternalStorageDir()
            if ext_dir ~= "" then
                return API.normalizePath(BaseUtil.joinPath(ext_dir, storage_key, storage_file))
            end
        end
        logger.warn("Zotero: storage: URI but external storage is not configured: " .. rawPath)
        return nil
    end

    local attach_name = rawPath:match("^attachments:(.+)$")
    if attach_name then
        -- Apply mappings to the relative part when it looks absolute after expand
        local mapped_rel = API.applyPathMappings(attach_name, mappings)
        local bases = {}
        if linkedBase and linkedBase ~= "" then
            table.insert(bases, linkedBase)
        end
        for _, b in ipairs(API.getLinkedFilesBases()) do
            table.insert(bases, b)
        end
        for _, base in ipairs(bases) do
            if base and base ~= "" then
                local candidate = API.normalizePath(BaseUtil.joinPath(base, mapped_rel))
                if file_exists(candidate) then
                    return candidate
                end
                -- also try unmapped relative
                candidate = API.normalizePath(BaseUtil.joinPath(base, attach_name))
                if file_exists(candidate) then
                    return candidate
                end
            end
        end
        if linkedBase and linkedBase ~= "" then
            return API.normalizePath(BaseUtil.joinPath(linkedBase, mapped_rel))
        end
        return nil
    end

    local path = API.normalizePath(rawPath)
    if API.isAbsolutePath(path) then
        local mapped = API.applyPathMappings(path, mappings)
        if file_exists(mapped) and not API.pathContainsIgnoredSegment(mapped) then
            return mapped
        end
        -- basename fallback under search roots (never returns .stversions etc.)
        local base = API.basenameOfPath(mapped)
        local found = API.findAttachmentByBasename(base)
        if found then
            return found
        end
        -- Do not return a mapped path that only exists under backup folders
        if file_exists(mapped) and API.pathContainsIgnoredSegment(mapped) then
            return nil
        end
        return mapped
    end
    -- relative path: try mappings then bases
    local mapped_rel = API.applyPathMappings(path, mappings)
    local bases = {}
    if linkedBase and linkedBase ~= "" then
        table.insert(bases, linkedBase)
    end
    for _, b in ipairs(API.getLinkedFilesBases()) do
        table.insert(bases, b)
    end
    for _, base in ipairs(bases) do
        if base and base ~= "" then
            local candidate = API.normalizePath(BaseUtil.joinPath(base, mapped_rel))
            if file_exists(candidate) then
                return candidate
            end
        end
    end
    if linkedBase == nil or linkedBase == "" then
        local found = API.findAttachmentByBasename(API.basenameOfPath(path))
        return found
    end
    return API.normalizePath(BaseUtil.joinPath(linkedBase, mapped_rel))
end

local SUPPORTED_LINK_MODES = {
    imported_file = true,
    imported_url = true,
    linked_file = true,
}

function API.isSupportedAttachmentLinkMode(linkMode)
    return SUPPORTED_LINK_MODES[linkMode] == true
end

local function isCachedAttachmentCurrent(targetPath, item)
    local file_ts = lfs.attributes(targetPath, "modification")
    if not file_ts then
        return false
    end
    local docSettings = DocSettings:open(targetPath)
    local libVersionAtLastSync = docSettings:readSetting("zoteroLibVersion", 0)
    docSettings:close()
    return libVersionAtLastSync >= item.version
end

function API.resolveAttachmentPath(item)
    if item == nil or item.data == nil then
        return nil
    end
    if API.settings:readSetting("prefer_local_files", true) == false then
        return nil
    end

    local linkMode = item.data.linkMode
    local mappings = API.getPathMappings()
    local allow_stale = API.getAllowStaleLocal()

    if linkMode == "linked_file" and API.getLinkedFilesEnabled() then
        local resolved = API.resolveLinkedPath(item.data.path, API.getLinkedFilesBase(), mappings)
        if
            resolved
            and file_exists(resolved)
            and not API.pathContainsIgnoredSegment(resolved)
        then
            logger.dbg("Zotero: resolved linked file at " .. resolved)
            return resolved
        end
        local base = item.data.filename or API.basenameOfPath(item.data.path)
        local found = API.findAttachmentByBasename(base)
        if found then
            logger.dbg("Zotero: resolved linked file by basename at " .. found)
            return found
        end
        return nil
    end

    if linkMode == "imported_file" or linkMode == "imported_url" then
        if API.getExternalStorageEnabled() then
            local ext_dir = API.getExternalStorageDir()
            if ext_dir ~= "" and item.data.filename then
                local ext_path = API.normalizePath(BaseUtil.joinPath(ext_dir, item.key, item.data.filename))
                if file_exists(ext_path) then
                    if isCachedAttachmentCurrent(ext_path, item) or allow_stale then
                        logger.dbg("Zotero: resolved external storage at " .. ext_path)
                        return ext_path
                    end
                    -- Externally synced files may not have plugin sidecar metadata yet
                    local docSettings = DocSettings:open(ext_path)
                    local libVersionAtLastSync = docSettings:readSetting("zoteroLibVersion", 0)
                    docSettings:close()
                    if libVersionAtLastSync == 0 then
                        logger.dbg("Zotero: resolved external storage (no sidecar version) at " .. ext_path)
                        return ext_path
                    end
                end
            end
        end
        local _, targetPath = API.getDirAndPath(item)
        if targetPath and file_exists(targetPath) then
            if isCachedAttachmentCurrent(targetPath, item) or allow_stale then
                logger.dbg("Zotero: resolved plugin storage at " .. targetPath)
                return targetPath
            end
        end
        -- basename search fallback
        if item.data.filename then
            local found = API.findAttachmentByBasename(item.data.filename)
            if found then
                logger.dbg("Zotero: resolved imported file by basename at " .. found)
                return found
            end
        end
    end

    return nil
end

local ZOTERO_LIST_ATTACHMENT_ITEMS = [[
SELECT itemData.value FROM itemData
INNER JOIN items ON items.itemID = itemData.itemID
WHERE items.itemTypeID = 3;
]]

-- Infer the desktop/Zotero absolute root that corresponds to linked_files_base,
-- by matching existing linked_file paths (e.g. D:\Notes\Lectures\foo.pdf).
-- Must live after ZOTERO_LIST_ATTACHMENT_ITEMS (Lua local scope).
function API.inferDesktopLinkedRoot()
    if API._inferred_desktop_root ~= nil then
        return API._inferred_desktop_root ~= false and API._inferred_desktop_root or nil
    end
    local base = API.normalizePath(API.getLinkedFilesBase() or "")
    if base == "" then
        API._inferred_desktop_root = false
        return nil
    end
    local votes = {}
    local ok_scan, err_scan = pcall(function()
        local db = API.openDB()
        local stmt = db:prepare(ZOTERO_LIST_ATTACHMENT_ITEMS)
        local row = stmt:reset():step()
        while row ~= nil do
            local ok, item = pcall(JSON.decode, row[1])
            if ok and item and item.data and item.data.linkMode == "linked_file" then
                local raw = tostring(item.data.path or "")
                if raw ~= "" and not raw:match("^attachments:") and API.isAbsolutePath(raw) then
                    local p = API.normalizePath(raw)
                    for _, choice in ipairs(API.listZoteroPathPrefixes(p)) do
                        local prefix_norm = API.normalizePath(choice.from or "")
                        if prefix_norm ~= "" and #p > #prefix_norm then
                            local rem = p:sub(#prefix_norm + 1):gsub("^/", "")
                            if rem ~= "" then
                                local candidate = API.normalizePath(BaseUtil.joinPath(base, rem))
                                if file_exists(candidate) then
                                    votes[prefix_norm] = (votes[prefix_norm] or 0) + 1
                                end
                            end
                        end
                    end
                end
            end
            row = stmt:step(row)
        end
        stmt:close()
    end)
    if not ok_scan then
        logger.warn("Zotero: inferDesktopLinkedRoot failed: ", err_scan)
    end
    local best, best_n = nil, 0
    for pref, n in pairs(votes) do
        -- Prefer more matches; on ties prefer shorter root (library base, not a subfolder)
        if n > best_n or (n == best_n and best ~= nil and #pref < #best) or (n == best_n and best == nil) then
            best, best_n = pref, n
        end
    end
    API._inferred_desktop_root = best or false
    return best
end

local function probe_path_entry(label, path)
    return {
        label = label,
        path = path,
        exists = path ~= nil and file_exists(path) or false,
    }
end

-- List candidate paths for an attachment (for settings preview; ignores prefer_local_files).
function API.probeAttachmentResolution(item)
    local probe = {
        key = item.key,
        filename = item.data.filename or "?",
        linkMode = item.data.linkMode or "?",
        contentType = item.data.contentType,
        zoteroPath = item.data.path,
        probes = {},
        foundPath = nil,
        note = nil,
    }

    if item.data.itemType ~= "attachment" then
        probe.note = "Not an attachment item"
        return probe
    end
    if not API.isSupportedAttachmentLinkMode(item.data.linkMode) then
        probe.note = "Unsupported link mode: " .. tostring(item.data.linkMode)
        return probe
    end
    if table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType) == false then
        probe.note = "Unsupported content type: " .. tostring(item.data.contentType)
        return probe
    end

    local linkMode = item.data.linkMode
    local mappings = API.getPathMappings()
    local linkedBase = API.getLinkedFilesBase()

    if linkMode == "linked_file" then
        if not API.getLinkedFilesEnabled() then
            probe.note = "Linked files folder is disabled in settings"
        elseif linkedBase == "" then
            probe.note = "Linked files folder path is not set"
        end
        local raw = item.data.path or ""
        if raw ~= "" then
            table.insert(probe.probes, probe_path_entry("Zotero path (raw)", API.normalizePath(raw)))
            if API.isAbsolutePath(raw) and #mappings > 0 then
                table.insert(
                    probe.probes,
                    probe_path_entry("After path mapping", API.applyPathMappings(API.normalizePath(raw), mappings))
                )
            end
        end
        local resolved = API.resolveLinkedPath(raw, linkedBase, mappings)
        if resolved then
            table.insert(probe.probes, probe_path_entry("Resolved linked path", resolved))
        end
        local base = item.data.filename or API.basenameOfPath(raw)
        if base then
            local found = API.findAttachmentByBasename(base)
            if found then
                table.insert(probe.probes, probe_path_entry("Basename search", found))
            end
        end
    elseif linkMode == "imported_file" or linkMode == "imported_url" then
        if API.getExternalStorageEnabled() then
            local ext_dir = API.getExternalStorageDir()
            if ext_dir == "" then
                probe.note = "External storage is enabled but folder path is not set"
            elseif item.data.filename then
                local ext_path = API.normalizePath(BaseUtil.joinPath(ext_dir, item.key, item.data.filename))
                table.insert(probe.probes, probe_path_entry("External storage", ext_path))
            end
        end
        local _, pluginPath = API.getDirAndPath(item)
        if pluginPath then
            table.insert(probe.probes, probe_path_entry("Plugin cache", pluginPath))
        end
        if item.data.filename then
            local found = API.findAttachmentByBasename(item.data.filename)
            if found then
                table.insert(probe.probes, probe_path_entry("Basename search", found))
            end
        end
    end

    for _, entry in ipairs(probe.probes) do
        if
            entry.exists
            and entry.path
            and not API.pathContainsIgnoredSegment(entry.path)
        then
            probe.foundPath = entry.path
            break
        end
    end

    return probe
end

function API.findFirstSupportedFileUnder(dir, depth)
    depth = depth or 0
    if dir == nil or dir == "" or depth > 6 or not file_exists(dir) then
        return nil
    end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and not API.isIgnoredPathSegment(name) then
            local path = BaseUtil.joinPath(dir, name)
            local mode = lfs.attributes(path, "mode")
            if mode == "file" then
                if name:match("%.pdf$") or name:match("%.epub$") or name:match("%.html?$") then
                    local norm = API.normalizePath(path)
                    if not API.pathContainsIgnoredSegment(norm) then
                        return norm
                    end
                end
            elseif mode == "directory" then
                local found = API.findFirstSupportedFileUnder(path, depth + 1)
                if found then
                    return found
                end
            end
        end
    end
    return nil
end

-- Directory prefix of a Zotero path (for path mapping "From").
function API.pathPrefixOfFile(p)
    if p == nil or p == "" then
        return ""
    end
    p = API.normalizePath(p)
    local base = API.basenameOfPath(p)
    if base == nil or #base >= #p then
        return p
    end
    local prefix = p:sub(1, #p - #base)
    if prefix:sub(-1) == "/" then
        prefix = prefix:sub(1, -2)
    end
    return prefix
end

-- Build selectable path prefixes from a Zotero absolute path (file or folder).
-- Example: D:/Notes/Lectures/book.pdf →
--   { "D:", "D:/Notes", "D:/Notes/Lectures" }
-- The last segment (filename) is excluded so the user maps folders only.
function API.listZoteroPathPrefixes(zotero_path)
    local choices = {}
    if zotero_path == nil or zotero_path == "" then
        return choices
    end
    local p = API.normalizePath(zotero_path)
    -- Drop filename if present
    local dir = API.pathPrefixOfFile(p)
    if dir == nil or dir == "" then
        return choices
    end
    -- Split into segments; keep drive letter as first segment on Windows paths
    local segments = {}
    if dir:match("^[A-Za-z]:") then
        table.insert(segments, dir:sub(1, 2)) -- "D:"
        local rest = dir:sub(3)
        if rest:sub(1, 1) == "/" then
            rest = rest:sub(2)
        end
        for seg in string.gmatch(rest, "[^/]+") do
            table.insert(segments, seg)
        end
    else
        -- Absolute Unix-style or relative
        local rest = dir
        if rest:sub(1, 1) == "/" then
            table.insert(segments, "") -- leading root marker
            rest = rest:sub(2)
        end
        for seg in string.gmatch(rest, "[^/]+") do
            table.insert(segments, seg)
        end
    end
    local acc = nil
    for i, seg in ipairs(segments) do
        if i == 1 and seg == "" then
            acc = ""
        elseif i == 1 then
            acc = seg
        elseif acc == "" then
            acc = "/" .. seg
        elseif acc:match("^[A-Za-z]:$") then
            acc = acc .. "/" .. seg
        else
            acc = acc .. "/" .. seg
        end
        local display = acc
        if display == "" then
            display = "/"
        end
        -- Skip bare drive "D:" alone (too short / useless); keep if user has only that
        table.insert(choices, {
            from = acc,
            label = display,
            depth = i,
        })
    end
    return choices
end

-- Prefer searching under path-mapping destinations (and linked base) before
-- a full-tree hunt — avoids .stversions and random deep matches.
function API.collectMappedSearchRoots()
    local roots = {}
    local seen = {}
    local function add(p)
        p = API.normalizePath(p or "")
        if p ~= "" and not seen[p] then
            seen[p] = true
            table.insert(roots, p)
        end
    end
    for _, m in ipairs(API.getPathMappings()) do
        if m and m.to then
            add(m.to)
        end
    end
    if API.getLinkedFilesEnabled() then
        add(API.getLinkedFilesBase())
        for _, b in ipairs(API.getLinkedFilesBases()) do
            add(b)
        end
    end
    return roots
end

-- Pick one linked_file attachment from the local Zotero DB (metadata), if any.
function API.getSampleLinkedAttachmentItem()
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_LIST_ATTACHMENT_ITEMS)
    local row = stmt:reset():step()
    local first_any = nil
    while row ~= nil do
        local ok, item = pcall(JSON.decode, row[1])
        if
            ok
            and item
            and item.data
            and item.data.itemType == "attachment"
            and table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType)
        then
            if item.data.linkMode == "linked_file" and item.data.path and item.data.path ~= "" then
                stmt:close()
                return item
            end
            if first_any == nil and API.isSupportedAttachmentLinkMode(item.data.linkMode) then
                first_any = item
            end
        end
        row = stmt:step(row)
    end
    stmt:close()
    return first_any
end

-- Preview based on a REAL Zotero attachment from the synced library (not a random disk file).
function API.getFirstLocalPathPreview()
    local item = API.getSampleLinkedAttachmentItem()
    if item then
        local probe = API.probeAttachmentResolution(item)
        if item.data.linkMode == "linked_file" then
            probe.note = "Example linked file from your Zotero library (after sync)." -- msgid for _()
        else
            probe.note = "Example attachment from your Zotero library (linkMode="
                .. tostring(item.data.linkMode)
                .. "). Prefer linked_file items for folder mapping."
        end
        -- Suggested mapping prefixes for the UI
        if item.data.path and item.data.path ~= "" then
            probe.suggestedFrom = API.pathPrefixOfFile(item.data.path)
            probe.suggestedTo = API.getLinkedFilesBase()
        end
        return probe
    end

    return {
        key = nil,
        filename = nil,
        linkMode = nil,
        zoteroPath = nil,
        probes = {},
        foundPath = nil,
        suggestedFrom = "",
        suggestedTo = API.getLinkedFilesBase() or "",
        note = "No attachment metadata in the local DB yet.\n"
            .. "Run Synchronize first — then this preview will show a real Zotero path\n"
            .. "(e.g. the Windows path stored on the linked file) and how it resolves here.",
    }
end

-- Path → attachment key cache (avoids multi-second full-library probes on every highlight).
local _file_to_key_cache = {}

function API.clearAttachmentPathCache()
    _file_to_key_cache = {}
    API._inferred_desktop_root = nil
end

-- One-shot: rewrite attachments: paths to absolute desktop paths when possible.
function API.healAllAttachmentsPrefixedPaths()
    local healed = 0
    local ok_scan, err_scan = pcall(function()
        local base = API.getLinkedFilesBase()
        local db = API.openDB()
        local stmt = db:prepare(ZOTERO_LIST_ATTACHMENT_ITEMS)
        local row = stmt:reset():step()
        local todos = {}
        while row ~= nil do
            local ok, item = pcall(JSON.decode, row[1])
            if ok and item and item.data and item.data.linkMode == "linked_file" then
                local raw = tostring(item.data.path or "")
                if raw:match("^attachments:") then
                    local local_path = API.resolveLinkedPath(raw, base)
                    if local_path and file_exists(local_path) then
                        table.insert(todos, { key = item.key, path = local_path })
                    end
                end
            end
            row = stmt:step(row)
        end
        stmt:close()
        for _, t in ipairs(todos) do
            if API.healLinkedAttachmentPath(t.path, t.key) then
                healed = healed + 1
            end
        end
    end)
    if not ok_scan then
        logger.warn("Zotero: healAllAttachmentsPrefixedPaths failed: ", err_scan)
    end
    if healed > 0 then
        logger.info("Zotero: healed ", healed, " linked attachment path(s)")
    end
    return healed
end

function API.rememberAttachmentKeyForPath(file_path, key)
    if file_path == nil or file_path == "" then
        return
    end
    local norm = API.normalizePathForCompare(file_path) or API.normalizePath(file_path)
    if norm then
        _file_to_key_cache[norm] = key or false
    end
    -- Persist on sidecar so the next open is instant even after restart
    if key then
        pcall(function()
            local ds = DocSettings:open(file_path)
            local prev = ds:readSetting("zoteroAttachmentKey")
            if prev ~= key then
                ds:saveSetting("zoteroAttachmentKey", key)
                ds:flush()
            end
            pcall(function()
                ds:close()
            end)
        end)
    end
end

-- Cheap candidate paths for an attachment (no recursive basename filesystem walk).
local function cheapAttachmentPaths(item)
    local paths = {}
    local data = item and item.data
    if not data then
        return paths
    end
    local linkMode = data.linkMode
    local mappings = API.getPathMappings()
    local linkedBase = API.getLinkedFilesBase()
    local function add(p)
        p = API.normalizePath(p or "")
        if p ~= "" then
            table.insert(paths, p)
        end
    end
    if linkMode == "linked_file" then
        local raw = data.path or ""
        if raw ~= "" then
            add(raw)
            if API.isAbsolutePath(raw) and #mappings > 0 then
                add(API.applyPathMappings(API.normalizePath(raw), mappings))
            end
            local resolved = API.resolveLinkedPath(raw, linkedBase, mappings)
            if resolved then
                add(resolved)
            end
        end
    elseif linkMode == "imported_file" or linkMode == "imported_url" then
        if API.getExternalStorageEnabled() and data.filename then
            local ext_dir = API.getExternalStorageDir()
            if ext_dir ~= "" then
                add(BaseUtil.joinPath(ext_dir, item.key, data.filename))
            end
        end
        local _, pluginPath = API.getDirAndPath(item)
        if pluginPath then
            add(pluginPath)
        end
    end
    return paths
end

-- Find Zotero attachment key for an on-disk file path (linked / external / cache).
-- Falls back to basename match so opening the "real" PDF (not .stversions) still links.
-- Must stay fast: called from onAnnotationsModified before the note dialog can open.
function API.findAttachmentKeyByFilePath(file_path)
    if file_path == nil or file_path == "" then
        return nil
    end
    local norm = API.normalizePathForCompare(file_path) or API.normalizePath(file_path)
    local cached = norm and _file_to_key_cache[norm]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    -- Sidecar hint from a previous successful match
    local sidecar_key = nil
    pcall(function()
        local ds = DocSettings:open(file_path)
        sidecar_key = ds:readSetting("zoteroAttachmentKey")
        pcall(function()
            ds:close()
        end)
    end)
    if sidecar_key and API.getItem(sidecar_key) then
        _file_to_key_cache[norm] = sidecar_key
        return sidecar_key
    end

    local want_base = string.lower(API.basenameOfPath(file_path) or "")
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_LIST_ATTACHMENT_ITEMS)
    local row = stmt:reset():step()
    local basename_hit = nil
    while row ~= nil do
        local ok_item, item = pcall(JSON.decode, row[1])
        if
            ok_item
            and item
            and item.data
            and item.data.itemType == "attachment"
            and API.isSupportedAttachmentLinkMode(item.data.linkMode)
            and (
                table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType)
                or (item.data.path and (item.data.path:match("%.pdf$") or item.data.path:match("%.epub$")))
            )
        then
            local zbase = string.lower(
                item.data.filename or API.basenameOfPath(item.data.path) or ""
            )
            local same_base = want_base ~= "" and zbase ~= "" and zbase == want_base
            -- Cheap path compare first (no recursive disk walks)
            for _, p in ipairs(cheapAttachmentPaths(item)) do
                if API.pathsEqual(p, file_path) then
                    stmt:close()
                    _file_to_key_cache[norm] = item.key
                    return item.key
                end
            end
            if same_base and basename_hit == nil then
                basename_hit = item.key
            end
        end
        row = stmt:step(row)
    end
    stmt:close()

    local result = basename_hit
    _file_to_key_cache[norm] = result or false
    return result
end

function API.formatLocalPathPreview(probe)
    if probe == nil then
        return _("No preview available.")
    end
    local lines = {}
    if probe.note then
        table.insert(lines, _(probe.note))
        table.insert(lines, "")
    end
    if probe.filename then
        table.insert(lines, _("Zotero attachment: ") .. probe.filename)
        table.insert(lines, "linkMode: " .. tostring(probe.linkMode) .. "  key: " .. tostring(probe.key))
        if probe.zoteroPath and probe.zoteroPath ~= "" then
            table.insert(lines, "")
            table.insert(lines, _("Path stored by Zotero:"))
            table.insert(lines, "  " .. probe.zoteroPath)
        else
            table.insert(lines, "")
            table.insert(lines, _("Path stored by Zotero:") .. " (empty)")
        end
        table.insert(lines, "")
    end
    if probe.probes and #probe.probes > 0 then
        table.insert(lines, _("Resolution on this device:"))
        for _, entry in ipairs(probe.probes) do
            local ignored = entry.path and API.pathContainsIgnoredSegment(entry.path)
            local status = "[missing]"
            if entry.exists and ignored then
                status = "[ignored]"
            elseif entry.exists then
                status = "[OK]"
            end
            table.insert(lines, status .. " " .. entry.label .. ":")
            table.insert(lines, "  " .. (entry.path or "?"))
        end
        table.insert(lines, "")
    end
    if probe.foundPath and not API.pathContainsIgnoredSegment(probe.foundPath) then
        table.insert(lines, _("→ File found on device:"))
        table.insert(lines, probe.foundPath)
    elseif probe.filename then
        table.insert(lines, _("→ File NOT found on device."))
        if probe.suggestedFrom and probe.suggestedFrom ~= "" then
            table.insert(lines, "")
            table.insert(lines, "Suggested path mapping:")
            table.insert(lines, "  From (PC/Zotero): " .. probe.suggestedFrom)
            table.insert(
                lines,
                "  To (this device): "
                    .. (probe.suggestedTo ~= "" and probe.suggestedTo or "(set Linked files folder)")
            )
        end
    end
    return table.concat(lines, "\n")
end

function API.tryResolveLocalAttachment(key)
    local item = API.getItem(key)
    if item == nil then
        return nil, "Error: the requested file can not be found in the database"
    end
    if item.data.itemType ~= "attachment" then
        return nil, "Error: this item is not an attachment"
    elseif not API.isSupportedAttachmentLinkMode(item.data.linkMode) then
        return nil, "Error: this item is not a stored attachment"
    elseif table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType) == false then
        return nil, "Error: this item has an unsupported content type (" .. item.data.contentType .. ")"
    end

    local localPath = API.resolveAttachmentPath(item)
    if localPath then
        API.getAttachmentInfo(item, localPath)
        local ok, err = pcall(API.attachItemAnnotations, item, nil, localPath)
        if not ok then
            logger.err("Zotero: attachItemAnnotations failed for ", localPath, ": ", err)
        end
        API.setAttachmentVersionByKey(key, item.version)
        return localPath, nil
    end
    return nil, nil
end

-- Check that a webdav connection works by performing a PROPFIND operation on the
-- URL with the associated credentials.
-- returns nil if no problems where found, otherwise error string
function API.checkWebDAV()
    local url = API.getWebDAVUrl()
    if url == nil then
        return "No WebDAV URL provided"
    end

    local user = API.getWebDAVUser()
    local pass = API.getWebDAVPassword()
    local headers = API.getWebDAVHeaders()

    local b, c, h = https.request({
        url = url,
        method = "PROPFIND",
        headers = headers,
    })

    if c == 200 or c == 207 then
        return nil
    elseif c == 400 or c == 401 then
        return "Reached server, but access forbidden. Check username and password."
    end
end

-- https GET call which decodes JSON data
function API.getZoteroData(page_url)
    local headers = API.zoteroHeader
    if headers == nil then
        return nil, "Error: Zotero header not set. Check user ID and API key"
    end
    local page_data = {}
    local r, c, h = https.request({
        method = "GET",
        url = page_url,
        headers = headers,
        sink = ltn12.sink.table(page_data),
        timeout = HTTP_TIMEOUT,
    })
    local e = API.verifyResponse(r, c)
    if e ~= nil then
        return nil, e
    end
    -- convert table page_data into a string:
    local content = table.concat(page_data, "")
    local ok, result = pcall(JSON.decode, content)
    if ok then
        return result, h
    else
        return nil, "Error: failed to parse JSON in response"
    end
end

-- Check the access provided by the Zotero API key (/keys/current).
function API.checkZoteroKey(page_url)
    local result, e = API.getZoteroData(page_url)
    if result == nil then
        return nil, "Zotero API key check: " .. tostring(e)
    end
    if result.access == nil then
        return nil, "Zotero API key check: unexpected response (no access field)"
    end
    logger.info("Zotero: API key OK for user " .. tostring(result.username) .. " (" .. tostring(result.userID) .. ")")
    logger.dbg("Zotero: Access: " .. JSON.encode(result.access))

    -- Persist library owner info with bound parameters (never interpolate strings into SQL).
    local db = API.openDB()
    local uid = tonumber(result.userID) or 0
    local uname = tostring(result.username or "")
    local ok_upd, upd_err = pcall(function()
        local stmt = db:prepare(
            "UPDATE libraries SET userID = ?1, name = ?2, editable = 0 WHERE libraryID = 1;"
        )
        stmt:reset():bind(uid, uname):step()
        stmt:close()
    end)
    if not ok_upd then
        logger.err("Zotero: failed to update libraries row: ", upd_err)
    end

    API.access = result.access
    return API.access, result
end

function API.verifyResponse(r, c)
    if r ~= 1 then
        if c == nil or c == "timeout" or c == "wantread" or c == "closed" then
            return "Error: network timeout or connection failed (check Wi‑Fi / API key)"
        end
        return ("Error: " .. tostring(c))
    elseif c == 0 then
        return "Error: network timeout or connection failed (status 0)"
    elseif c ~= 200 then
        return ("Error: API responded with status code " .. tostring(c))
    end

    return nil
end

function API.fetchCollectionSize(collection_url, headers)
    logger.dbg("Zotero: Determining size of '" .. collection_url .. "'")
    local r, c, h = https.request({
        method = "HEAD",
        url = collection_url,
        headers = headers,
        timeout = HTTP_TIMEOUT,
    })

    local e = API.verifyResponse(r, c)
    if e ~= nil then
        -- Some proxies break HEAD; fall back to a tiny GET
        logger.warn("Zotero: HEAD failed (" .. tostring(e) .. "), falling back to GET limit=1")
        local get_url = collection_url
        if get_url:find("?", 1, true) then
            get_url = get_url .. "&limit=1"
        else
            get_url = get_url .. "?limit=1"
        end
        local page_data = {}
        r, c, h = https.request({
            method = "GET",
            url = get_url,
            headers = headers,
            sink = ltn12.sink.table(page_data),
            timeout = HTTP_TIMEOUT,
        })
        e = API.verifyResponse(r, c)
        if e ~= nil then
            return nil, e
        end
    end

    local total_results = tonumber(h["total-results"])
    if total_results == nil or total_results < 0 then
        return nil, "Error: could not determine number of items in library"
    end

    return tonumber(total_results)
end

-- Fetches a paginated URL collection.
--
-- If no callback is given, it returns an array containing all entries of the collection.
--
-- If a callback is given, it will be called with the entries on each page as they are fetched
-- and the function will return the version number.
-- The second parameter to callback is the percentage of completion
--
-- If an error occurs, the function will return nil and the error message as second parameter.
function API.fetchCollectionPaginated(collection_url, headers, callback)
    -- Try to determine the size
    local collection_size, e = API.fetchCollectionSize(collection_url, headers)
    if e ~= nil then
        return nil, e
    end

    logger.info(("Zotero: Fetching %s items."):format(collection_size))
    -- The API returns the results in pages with 100 entries each, loop accordingly.
    local items = {}
    local library_version = 0
    local step_size = 100
    for item_nr = 0, collection_size, step_size do
        local page_url = ("%s&limit=%i&start=%i"):format(collection_url, step_size, item_nr)

        local result, header = API.getZoteroData(page_url)
        if result == nil then
            return nil, header
        end
        library_version = header["last-modified-version"]

        local percentage = 100 * item_nr / collection_size
        if collection_size == 0 then
            percentage = 100
        end

        if callback then
            callback(result, percentage)
        else
            -- add items to the list we return in the end
            table.move(result, 1, #result, #items + 1, items)
        end
    end

    if callback then
        return library_version, nil
    else
        return items, nil
    end
end

-- Verify that we can access Zotero API
function API.verifyZoteroAccess()
    if API.zoteroAcessVerified and API.zoteroHeader and API.userLibraryURL and API.access then
        return nil
    end

    local user_id = tostring(API.settings:readSetting("user_id", "") or "")
    local api_key = tostring(API.settings:readSetting("api_key", "") or "")

    if user_id == "" then
        return "Error: must set User ID (numeric, from https://www.zotero.org/settings/keys )"
    elseif api_key == "" then
        return "Error: must set API Key"
    end

    API.zoteroHeader = {
        ["zotero-api-key"] = api_key,
        ["Zotero-API-Key"] = api_key,
        ["zotero-api-version"] = "3",
        ["Zotero-API-Version"] = "3",
    }
    API.userLibraryURL = ZOTERO_BASE_URL .. ("/users/%s"):format(user_id)
    -- Correct endpoint is /keys/current (not under /users/{id}/…)
    local key_url = ZOTERO_BASE_URL .. "/keys/current"
    local access, key_info_or_err = API.checkZoteroKey(key_url)
    if access == nil then
        API.zoteroAcessVerified = false
        API.access = nil
        return key_info_or_err
    end

    -- Warn if configured user_id does not match the key owner
    if type(key_info_or_err) == "table" and key_info_or_err.userID then
        local key_uid = tostring(key_info_or_err.userID)
        if key_uid ~= user_id then
            logger.warn(
                "Zotero: configured user_id="
                    .. user_id
                    .. " but API key belongs to userID="
                    .. key_uid
            )
            return (
                "Error: User ID mismatch. Your API key belongs to user "
                .. key_uid
                .. " ("
                .. tostring(key_info_or_err.username or "?")
                .. "), but you entered "
                .. user_id
                .. ". Fix User ID in Settings."
            )
        end
    end

    API.zoteroAcessVerified = true
    return nil
end

-- Test credentials and return a human-readable status string (nil error = ok message).
-- Returns ok_message, err_message (one of them is nil).
function API.testCredentials()
    API.zoteroAcessVerified = false
    API.access = nil
    local e = API.verifyZoteroAccess()
    if e ~= nil then
        return nil, e
    end
    local user_id = tostring(API.getUserID() or "")
    local write = API.access and API.access.user and API.access.user.write
    local notes = API.access and API.access.user and API.access.user.notes
    local files = API.access and API.access.user and API.access.user.files
    local msg = _(
        "API key recognized.\n"
            .. "User ID: "
            .. user_id
            .. "\n"
            .. "Library: "
            .. tostring(files and "files OK" or "no files")
            .. ", "
            .. tostring(notes and "notes OK" or "no notes")
            .. ", "
            .. tostring(write and "write OK" or "read-only")
    )
    return msg, nil
end

-- Expand short Android paths like /Documents/... to a real absolute path.
function API.normalizeDevicePath(p)
    if p == nil or p == "" then
        return p
    end
    p = API.normalizePath(p)
    -- Common Android shortcuts (relative to internal storage)
    if p:match("^/Documents") or p:match("^/Download") or p:match("^/Books") or p:match("^/Notes") then
        local expanded = "/storage/emulated/0" .. p
        if file_exists(expanded) then
            return expanded
        end
        local sd = "/sdcard" .. p
        if file_exists(sd) then
            return API.normalizePath(sd)
        end
        return expanded
    end
    if p:match("^/sdcard/") then
        local alt = p:gsub("^/sdcard", "/storage/emulated/0")
        if file_exists(alt) then
            return alt
        end
    end
    return p
end

function API.getHeaders(api_key)
    return {
        ["zotero-api-key"] = api_key,
        ["zotero-api-version"] = "3",
    }
end

-- Add/update attachments to itemAttachments db table
-- Input is a table of containing itemkey and parentkey pairs
function API.setItemAttachments(attachments)
    local db = API.openDB()
    local stmt_upsert_attachments = db:prepare(ZOTERO_UPSERT_ITEM_ATTACHMENTS)
    local stmt_check_collection = db:prepare(ZOTERO_GET_COLLECTION_FOR_ITEM)
    local stmt_delete = db:prepare(ZOTERO_DELETE_ITEM_ATTACHMENT)
    for item, parent in pairs(attachments) do
        if stmt_check_collection:reset():bind1(1, parent):step() then
            stmt_upsert_attachments:reset():bind(item, parent):step()
        else -- parentItem is not part of a collection
            print("Deleting attachment " .. item .. " from itemsAttachment table")
            stmt_delete:reset():bind1(1, item):step()
        end
    end
    stmt_upsert_attachments:close()
end

-- Add/update annotations to itemAnnotations db table
-- Input is a table of containing item.key and parent.key pairs
function API.setAnnotations(annotations)
    local db = API.openDB()
    local stmt_upsert_annotations = db:prepare(ZOTERO_UPSERT_ITEM_ANNOTATIONS)
    for item, parent in pairs(annotations) do
        stmt_upsert_annotations:reset():bind(item, parent):step()
    end
    stmt_upsert_annotations:close()
end

-- Fetch (new) items from Zotero server and organise them into the local sqlite database
function API.fetchZoteroItems(since, progress_callback)
    local callback = progress_callback or function() end

    local db = API.openDB()
    if since == nil then
        since = API.getUserLibraryVersion()
    end
    -- verify access
    local e = API.verifyZoteroAccess()
    if e ~= nil then
        return e
    end

    local stmt_update_item = db:prepare(ZOTERO_DB_UPDATE_ITEM)
    local stmt_update_itemData = db:prepare(ZOTERO_DB_UPDATE_ITEMDATA)
    local stmt_get_ItemVersion = db:prepare(ZOTERO_GET_ITEM_VERSION)
    local stmt_delete_item = db:prepare(ZOTERO_DB_DELETE_ITEM)
    local stmt_update_collectionItems = db:prepare(ZOTERO_DB_UPDATE_COLLECTION_ITEMS)

    local headers = API.zoteroHeader
    logger.info(
        "Zotero: fetchZoteroItems called with since="
        .. tostring(since)
        .. ", library version="
        .. tostring(API.getUserLibraryVersion())
    )

    -- First, check for deleted items using the dedicated /deleted endpoint
    local deleted_url = API.userLibraryURL .. ("/deleted?since=%s"):format(since)
    logger.info("Zotero: Requesting deleted items URL: " .. deleted_url)

    local deleted_data, deleted_error = API.getZoteroData(deleted_url)
    if deleted_data ~= nil then
        logger.info("Zotero: Found deleted data: " .. JSON.encode(deleted_data))

        -- Process deleted items
        if deleted_data.items then
            for _, deleted_key in ipairs(deleted_data.items) do
                logger.info("Zotero: Processing deleted item: " .. deleted_key)
                local res = stmt_get_ItemVersion:reset():bind(deleted_key):step()
                if res ~= nil then
                    logger.info("Zotero: Deleting item from local database: " .. deleted_key)
                    stmt_delete_item:reset():bind(deleted_key):step()
                end
            end
        end

        -- Process deleted collections
        if deleted_data.collections then
            local stmt_delete_collection = db:prepare(ZOTERO_DB_DELETE_COLLECTION)
            for _, deleted_key in ipairs(deleted_data.collections) do
                logger.info("Zotero: Processing deleted collection: " .. deleted_key)
                stmt_delete_collection:reset():bind(deleted_key):step()
            end
            stmt_delete_collection:close()
        end
    elseif deleted_error then
        logger.warn("Zotero: Error fetching deleted items: " .. deleted_error)
    end

    -- Now fetch regular items (without includeTrashed since we handled deletions above)
    local items_url = API.userLibraryURL .. ("/items?since=%s"):format(since)
    logger.info("Zotero: Requesting items URL: " .. items_url)
    local attachments = {}
    local annotations = {}

    local annotationTypes = Annotations.supportedZoteroTypes()
    local inserted = 0
    local skipped_notype = 0

    local r, e = API.fetchCollectionPaginated(items_url, headers, function(partial_entries, percentage)
        callback(string.format("Syncing items %.0f%%", percentage))
        for i = 1, #partial_entries do
            -- Ruthlessly update our local items
            local item = partial_entries[i]
            local key = item.key

            -- Since we're not using includeTrashed anymore, we shouldn't get deleted items here
            -- But let's keep the check for safety
            if item.data.deleted then
                logger.info("Zotero: Item " .. key .. " has been deleted (from regular items endpoint).")
                -- check if we have this item in the local database; if so, delete it:
                local res = stmt_get_ItemVersion:reset():bind(key):step()
                if res ~= nil then
                    stmt_delete_item:reset():bind(key):step()
                end
            else -- not a deleted item, so we might want to add it to the local database
                -- remove some unused data
                item.links = nil
                item.library = nil

                stmt_update_item:reset():bind(1, item.data.itemType, key, item.version):step()
                -- If itemType is unknown, INSERT…SELECT inserts 0 rows — detect and recover
                local check = stmt_get_ItemVersion:reset():bind(key):step()
                if check == nil then
                    skipped_notype = skipped_notype + 1
                    logger.warn(
                        "Zotero: failed to insert item "
                            .. tostring(key)
                            .. " type="
                            .. tostring(item.data.itemType)
                            .. " — ensuring itemTypes and retrying"
                    )
                    local it_cnt = tonumber(db:rowexec("SELECT COUNT(*) FROM itemTypes")) or 0
                    if it_cnt == 0 then
                        local ok_it, err_it = pcall(function()
                            db:exec(ZOTERO_DB_INIT_ITEMTYPES)
                        end)
                        if not ok_it then
                            logger.err("Zotero: itemTypes init failed: ", err_it)
                        end
                    end
                    -- Fallback: insert with a generic document type if still missing
                    pcall(function()
                        stmt_update_item:reset():bind(1, item.data.itemType, key, item.version):step()
                    end)
                    check = stmt_get_ItemVersion:reset():bind(key):step()
                    if check == nil then
                        pcall(function()
                            stmt_update_item:reset():bind(1, "document", key, item.version):step()
                        end)
                        check = stmt_get_ItemVersion:reset():bind(key):step()
                    end
                end
                if check ~= nil then
                    stmt_update_itemData:reset():bind(key, JSON.encode(item)):step()
                    inserted = inserted + 1
                end

                -- Set the correct collection(s) for this item:
                if item.data.collections ~= nil then
                    if item.data.collections[1] == nil then -- no collection specified: put in root directory
                        stmt_update_collectionItems:reset():bind("/", item.key):step()
                    else
                        for _, coll in pairs(item.data.collections) do
                            stmt_update_collectionItems:reset():bind(coll, item.key):step()
                        end
                    end
                end

                -- Check if it is a (supported) attachment or annotation
                -- If so, add it to the relevant table
                if
                    item.data.itemType == "attachment"
                    and table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType)
                then
                    attachments[key] = item.data.parentItem or
                        key -- if there is no parent item then use the item as its own parent
                elseif
                    item.data.itemType == "annotation"
                    and table_contains(annotationTypes, item.data.annotationType)
                then
                    annotations[key] = item.data.parentItem
                end
            end
        end
    end)

    -- next is used to check whether table has entries.
    -- Apparently defining it as a local var makes this more efficient.
    local next = next
    -- deal with attachment items:
    if next(attachments) ~= nil then
        API.setItemAttachments(attachments)
    end

    -- deal with annotation items:
    if next(annotations) ~= nil then
        API.setAnnotations(annotations)
    end

    -- Close prepared statements
    stmt_update_item:close()
    stmt_update_itemData:close()
    stmt_get_ItemVersion:close()
    stmt_delete_item:close()
    stmt_update_collectionItems:close()

    logger.info(
        "Zotero: fetchZoteroItems done — inserted/updated≈"
            .. tostring(inserted)
            .. ", type failures="
            .. tostring(skipped_notype)
            .. ", libVersion="
            .. tostring(r)
    )

    if e ~= nil then
        return nil, e
    end
    return r, nil
end

-- Fetch (new) collections from Zotero server and organise them into the local sqlite database
function API.fetchZoteroCollections(since, progress_callback)
    local callback = progress_callback or function() end

    local db = API.openDB()
    if since == nil then
        since = API.getUserLibraryVersion()
    end
    -- verify access
    local e = API.verifyZoteroAccess()
    if e ~= nil then
        return e
    end

    -- to check whether changes where made
    local stmt_changes = db:prepare(ZOTERO_DB_CHANGES)

    local headers = API.zoteroHeader

    local collections_url = API.userLibraryURL .. ("/collections?since=%s&includeTrashed=true"):format(since)

    -- next is used to check whether table has entries. Apparently defining it as a local var makes this more efficient.
    local next = next

    -- Prepare sql commands
    local stmt_update_collection = db:prepare(ZOTERO_DB_UPDATE_COLLECTION)
    local stmt_delete_collection = db:prepare(ZOTERO_DB_DELETE_COLLECTION)
    local stmt_get_collectionVersion = db:prepare(ZOTERO_GET_COLLECTION_VERSION)

    local nestedCollections = {}
    local nCnt = 0

    local r, e = API.fetchCollectionPaginated(collections_url, headers, function(partial_entries, percentage)
        callback(string.format("Syncing collections %.0f%%", percentage))
        for i = 1, #partial_entries do
            -- Ruthlessly update our local items
            local collection = partial_entries[i].data
            local key = collection.key
            --logger.info(JSON.encode(collection))
            -- for collections Zotero seems to use collection.deleted = true
            if collection.deleted then
                logger.info("Zotero: Collection " .. key .. " has been deleted.")
                local localVersion = stmt_get_collectionVersion:reset():bind(key):step()
                if localVersion ~= nil then
                    stmt_delete_collection:reset():bind(key):step()
                    local cnt = stmt_changes:reset():step()
                    if cnt ~= nil then
                        logger.info("Zotero: Changes: ", tonumber(cnt[1]))
                    end
                end
            else
                -- collection has not been deleted
                if collection.parentCollection == false then
                    collection.parentCollection = "/"
                else
                    -- For nested collections sometimes the parent collection is not in the database yet.
                    -- In this case insert would fail. So set parentCollection to root to start with and
                    -- set the proper value once all the collections are in the db
                    nestedCollections[key] = collection.parentCollection
                    collection.parentCollection = "/"
                    nCnt = nCnt + 1
                end
                stmt_update_collection
                    :reset()
                    :bind(collection.name, collection.parentCollection, collection.key, collection.version)
                    :step()
                local cnt = stmt_changes:reset():step()
                if cnt ~= nil then
                    logger.info("Zotero: Collection changes: ", tonumber(cnt[1]))
                end
            end
        end
    end)
    stmt_update_collection:close()

    -- deal with nested collections.
    -- Now that the db for sure has entries for all collections we can safely set parent collections
    if nCnt > 0 then
        -- there are nestedCollections
        local stmt_update_parentCollection = db:prepare(ZOTERO_DB_UPDATE_PARENTCOLLECTION)
        for item, parent in pairs(nestedCollections) do
            stmt_update_parentCollection:reset():bind(item, parent):step()
        end
        stmt_update_parentCollection:close()
    end
    return r, e
end

-- Sync local db with zotero server
-- This includes:
-- 1. uploading local annotations
-- 2. downloading collections and organising them into local database structure
-- 3. same for items
-- 4. downloading attachments for marked collections
function API.syncAllItems(progress_callback)
    local callback = progress_callback or function() end
    API.clearAttachmentPathCache()

    -- Error tracking structure for sync summary
    local sync_stats = {
        annotation_upload_fails = 0,
        annotation_delete_fails = 0,
        file_download_fails = 0,
        failed_downloads = {}  -- stores {filename, error} pairs
    }

    local db = API.openDB()
    local since = API.getUserLibraryVersion() or 0
    local pre_stats = API.getStats()
    -- If version was advanced previously but the DB has no items, incremental
    -- sync (since=N) downloads nothing → stuck at Items: 0 forever. Force full pull.
    if since > 0 and (tonumber(pre_stats.items) or 0) == 0 then
        logger.warn(
            "Zotero: library version="
                .. tostring(since)
                .. " but local items=0 — forcing full resync (since=0)"
        )
        callback(_("Local library empty — downloading everything (this can take a while)…"))
        since = 0
    end

    callback(_("Checking Zotero API key…"))
    -- verify access
    local e = API.verifyZoteroAccess()
    if e ~= nil then
        return e
    end
    callback(_("API key OK. Syncing library (since=") .. tostring(since) .. ")…")

    -- Fetch catalogue first so itemAnnotations exist before push (avoids orphan-key
    -- deletion / re-upload duplicates). Push annotations after items are local.
    local r, e = API.fetchZoteroCollections(since, progress_callback)
    if e ~= nil then
        return e
    end

    local items_version
    items_version, e = API.fetchZoteroItems(since, callback)
    if e ~= nil then
        return e
    end

    -- Prefer version from items fetch; fall back to collections
    local new_version = items_version or r
    if new_version ~= nil then
        API.setUserLibraryVersion(new_version)
    end

    if API.access and API.access.user and API.access.user.write and API.access.user.notes then
        callback(_("Uploading local annotations…"))
        local upload_fails, delete_fails = API.syncAnnotations(callback)
        sync_stats.annotation_upload_fails = upload_fails or 0
        sync_stats.annotation_delete_fails = delete_fails or 0
    else
        logger.warn("Zotero: API key does not have write access for annotations")
    end

    local post_stats = API.getStats()
    if (tonumber(post_stats.items) or 0) == 0 then
        return _(
            "Sync finished but local library is still empty (0 items).\n"
                .. "Check User ID / API key, then try « Resync entire collection ».\n"
                .. "Library version reported: "
                .. tostring(API.getUserLibraryVersion())
        )
    end

    local download_fails, failed_downloads = API.batchDownload(callback)
    sync_stats.file_download_fails = download_fails or 0
    sync_stats.failed_downloads = failed_downloads or {}

    API.getStats()

    -- Format sync summary with error counts
    local function formatSyncSummary()
        local total_errors = sync_stats.annotation_upload_fails +
                            sync_stats.annotation_delete_fails +
                            sync_stats.file_download_fails

        if total_errors == 0 then
            return nil  -- No errors to report
        end

        local parts = {}
        table.insert(parts, string.format("\n%d total error(s):", total_errors))

        if sync_stats.annotation_upload_fails > 0 then
            table.insert(parts, string.format("- %d annotation upload failure(s)", sync_stats.annotation_upload_fails))
        end
        if sync_stats.annotation_delete_fails > 0 then
            table.insert(parts, string.format("- %d annotation deletion failure(s)", sync_stats.annotation_delete_fails))
        end
        if sync_stats.file_download_fails > 0 then
            table.insert(parts, string.format("- %d file download failure(s)", sync_stats.file_download_fails))
        end

        return table.concat(parts, "\n")
    end

    return formatSyncSummary()
end

---------------------
-- Check (local) library items
function API.checkItemData(progressCallBack)
    local db = API.openDB()

    local stats0 = API.getStats()
    local frac = 100 / stats0.items
    local dStep = math.max(math.floor(stats0.items / 100), 10)

    local stmt = db:prepare([[SELECT value FROM
    		itemData INNER JOIN items ON itemData.itemID = items.itemID]])

    local stmt_update_collectionItems = db:prepare(ZOTERO_DB_UPDATE_COLLECTION_ITEMS)

    -- to check whether changes where made
    local stmt_changes = db:prepare(ZOTERO_DB_CHANGES)

    local attachments = {}
    local annotations = {}

    local annotationTypes = Annotations.supportedZoteroTypes()

    db:exec("DELETE FROM collectionItems;")
    db:exec("DELETE FROM itemAnnotations;")
    db:exec("DELETE FROM itemAttachments;")
    local row = stmt:reset():step()
    local item
    local cnt = 0
    while row ~= nil do
        item = JSON.decode(row[1])

        -- Set the correct collection(s) for this item:
        if item.data.collections ~= nil then
            --if #item.data.collections > 1 then print("Item "..item.key.." is in ", #item.data.collections , " collections: ") end
            if item.data.collections[1] == nil then -- no collection specified: put in root directory
                stmt_update_collectionItems:reset():bind("/", item.key):step()
            else                                    -- some items might be in more than one collection, so loop over collections
                for i, coll in pairs(item.data.collections) do
                    -- This works, but maybe better check if collection exists first? Then could delete item if collection no longer there...
                    stmt_update_collectionItems:reset():bind(coll, item.key):step()
                end
            end
        end

        -- Check if it is a (supported) attachment or annotation
        -- If so, add it to the relevant table
        if item.data.itemType == "attachment" and table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType) then
            attachments[item.key] = item.data.parentItem or
                item.key -- if there is no parent item then use the item as its own parent
        elseif item.data.itemType == "annotation" and table_contains(annotationTypes, item.data.annotationType) then
            annotations[item.key] = item.data.parentItem
        end
        cnt = cnt + 1
        if progressCallBack and (cnt % dStep == 0) then
            progressCallBack(string.format("Re-analysing items: %.0f%%", cnt * frac))
        end
        row = stmt:step(row)
    end
    stmt:close()
    if progressCallBack then
        progressCallBack(string.format("Cataloguing attachments"))
    end
    API.setItemAttachments(attachments)
    if progressCallBack then
        progressCallBack(string.format("Cataloguing annotations"))
    end
    API.setAnnotations(annotations)
end

function API.getDirAndPath(item)
    if item == nil or item.key == nil then
        return nil, nil
    end
    if API.storage_dir == nil or API.storage_dir == "" then
        return nil, nil
    end
    local filename = item.data and item.data.filename
    if filename == nil or filename == "" then
        -- linked_file items often have path but empty filename
        filename = API.basenameOfPath(item.data and item.data.path) or (item.key .. ".bin")
    end
    local dir = BaseUtil.joinPath(API.storage_dir, item.key)
    local file = BaseUtil.joinPath(dir, filename)
    return dir, file
end

function API.getItem(key)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_GET_ITEM)
    stmt:reset():bind1(1, key)

    local result, nr = stmt:resultset()
    stmt:close()

    if nr == 0 then
        return nil
    else
        --print(result[1][1])
        return JSON.decode(result[1][1])
    end
end

-- Pull annotation children for one attachment from the Web API into the local DB.
-- Also removes local DB rows for annotations no longer on the server (remote delete).
-- known_sidecar_keys: optional set { [key]=true } of keys currently in the document sidecar.
-- Returns: ok, remote_keys_set (or error string)
function API.refreshAttachmentAnnotationsFromServer(parent_key, known_sidecar_keys)
    if parent_key == nil or parent_key == "" or API.userLibraryURL == nil then
        return false, "missing parent"
    end
    local e = API.verifyZoteroAccess()
    if e ~= nil then
        return false, e
    end

    -- Annotations are children of the *attachment*. Official endpoint is /children.
    -- parentItem= is undocumented and often returns [] (HTTP 200) — that used to abort
    -- the fallback, so new Zotero annotations never entered the local DB.
    local function countAnnotationPayload(payload)
        local n = 0
        if type(payload) ~= "table" then
            return 0
        end
        for _, item in pairs(payload) do
            if type(item) == "table"
                and item.key
                and item.data
                and item.data.itemType == "annotation"
            then
                n = n + 1
            end
        end
        return n
    end

    local urls = {
        API.userLibraryURL
            .. "/items/"
            .. tostring(parent_key)
            .. "/children?itemType=annotation&limit=100",
        API.userLibraryURL
            .. "/items?itemType=annotation&parentItem="
            .. tostring(parent_key)
            .. "&limit=100",
    }
    local data, err_or_headers, used_url = nil, nil, nil
    local best_data, best_headers, best_url, best_n = nil, nil, nil, -1
    for _, url in ipairs(urls) do
        local got, hdr_or_err = API.getZoteroData(url)
        if got == nil then
            logger.warn("Zotero: annotation pull failed for ", url, ": ", hdr_or_err)
        else
            local n = countAnnotationPayload(got)
            logger.info(
                ("Zotero: annotation pull %s → %d annotation(s)"):format(tostring(url), n)
            )
            if n > best_n then
                best_data, best_headers, best_url, best_n = got, hdr_or_err, url, n
            end
            -- Prefer the first non-empty result (children is first)
            if n > 0 then
                break
            end
        end
    end
    data, err_or_headers, used_url = best_data, best_headers, best_url
    if data == nil then
        logger.warn("Zotero: refreshAttachmentAnnotationsFromServer failed: ", err_or_headers)
        return false, err_or_headers
    end
    if type(data) ~= "table" then
        return false, "bad children response"
    end

    local remote_keys = {}
    local annotations_map = {}
    local db = API.openDB()
    local stmt_item = db:prepare(ZOTERO_DB_UPDATE_ITEM)
    local stmt_data = db:prepare(ZOTERO_DB_UPDATE_ITEMDATA)
    local stmt_del = db:prepare(ZOTERO_DB_DELETE_ITEM)

    -- Use pairs (not ipairs): some JSON decoders yield string keys for arrays
    local n_seen = 0
    for _, item in pairs(data) do
        if type(item) == "table" and item.key and item.data and item.data.itemType == "annotation" then
            n_seen = n_seen + 1
            -- Ensure we only keep annotations that belong to this attachment
            local parent = item.data.parentItem
            if parent and tostring(parent) ~= tostring(parent_key) then
                -- skip foreign parent
            elseif item.data.deleted then
                stmt_del:reset():bind(item.key):step()
            else
                remote_keys[item.key] = true
                annotations_map[item.key] = parent_key
                local ver = item.version or 0
                item.links = nil
                item.library = nil
                stmt_item:reset():bind(1, "annotation", item.key, ver):step()
                stmt_data:reset():bind(item.key, JSON.encode(item)):step()
            end
        end
    end
    stmt_item:close()
    stmt_data:close()
    stmt_del:close()
    stmt_del = nil

    if next(annotations_map) ~= nil then
        API.setAnnotations(annotations_map)
        logger.info(
            ("Zotero: upserted %d annotation link(s) for parent %s"):format(
                (function()
                    local n = 0
                    for _ in pairs(annotations_map) do
                        n = n + 1
                    end
                    return n
                end)(),
                tostring(parent_key)
            )
        )
    end

    -- Drop local annotation rows for this parent that are no longer on the server
    local stmt_list = db:prepare(ZOTERO_GET_ITEM_ANNOTATIONS_INFO)
    local local_keys = {}
    local local_count = 0
    local row = stmt_list:bind(parent_key):step()
    while row ~= nil do
        local_keys[row[1]] = true
        local_count = local_count + 1
        row = stmt_list:step(row)
    end
    stmt_list:close()

    local n_remote = 0
    for _ in pairs(remote_keys) do
        n_remote = n_remote + 1
    end

    -- Safety: empty API result while we still have local anns — probe one key on server
    -- before wiping (avoids nuking the library when parentItem filter misses).
    -- Close all stmts first so nested fetchItemFromServer can open the DB safely.
    if n_remote == 0 and local_count > 0 then
        local sample = next(local_keys)
        local still_remote = sample and API.fetchItemFromServer(sample) or nil
        if still_remote and still_remote.data and still_remote.data.itemType == "annotation" then
            logger.warn(
                "Zotero: annotation pull returned 0 for parent "
                    .. tostring(parent_key)
                    .. " but "
                    .. tostring(sample)
                    .. " still exists on server — abort wipe"
            )
            return false, "parentItem filter missed annotations"
        end
    end

    local to_remove = {}
    for key, _ in pairs(local_keys) do
        if not remote_keys[key] then
            to_remove[key] = true
        end
    end
    -- Sidecar keys not returned by API either (deleted remotely)
    if type(known_sidecar_keys) == "table" then
        for key, _ in pairs(known_sidecar_keys) do
            if key and not remote_keys[key] and not to_remove[key] then
                local still = API.getItem(key)
                if still ~= nil then
                    to_remove[key] = true
                end
            end
        end
    end
    local removed = 0
    stmt_del = db:prepare(ZOTERO_DB_DELETE_ITEM)
    for key, _ in pairs(to_remove) do
        logger.info("Zotero: remote delete — removing annotation " .. tostring(key) .. " from local DB")
        stmt_del:reset():bind(key):step()
        removed = removed + 1
    end
    stmt_del:close()

    local lib_ver = nil
    if type(err_or_headers) == "table" then
        lib_ver = err_or_headers["last-modified-version"]
            or err_or_headers["Last-Modified-Version"]
    end
    if lib_ver then
        API.setUserLibraryVersion(lib_ver)
    end

    logger.info(
        ("Zotero: refreshed attachment %s from server (seen=%d remote=%d removed=%d url=%s)"):format(
            tostring(parent_key),
            n_seen,
            n_remote,
            removed,
            tostring(used_url)
        )
    )
    return true, remote_keys
end

-- Fresh item from the Web API (avoids stale local version → 412 on update).
function API.fetchItemFromServer(key)
    if key == nil or key == "" or API.userLibraryURL == nil then
        return nil
    end
    local e = API.verifyZoteroAccess()
    if e ~= nil then
        return nil
    end
    local req_headers = {}
    for hk, hv in pairs(API.zoteroHeader or {}) do
        req_headers[hk] = hv
    end
    local body = {}
    local r, c, h = https.request({
        method = "GET",
        url = API.userLibraryURL .. "/items/" .. tostring(key),
        headers = req_headers,
        sink = ltn12.sink.table(body),
        timeout = HTTP_TIMEOUT,
    })
    e = API.verifyResponse(r, c)
    if e ~= nil then
        logger.warn("Zotero: fetchItemFromServer failed: ", e)
        return nil
    end
    local ok, item = pcall(JSON.decode, table.concat(body, ""))
    if not ok or type(item) ~= "table" or item.key == nil then
        return nil
    end
    pcall(function()
        local db = API.openDB()
        local ver = item.version or 0
        local stmt_item = db:prepare(ZOTERO_DB_UPDATE_ITEM)
        stmt_item:reset():bind(1, (item.data and item.data.itemType) or "annotation", key, ver):step()
        stmt_item:close()
        local stmt_data = db:prepare(ZOTERO_DB_UPDATE_ITEMDATA)
        stmt_data:reset():bind(key, JSON.encode(item)):step()
        stmt_data:close()
    end)
    local lib_ver = h and (h["last-modified-version"] or h["Last-Modified-Version"])
    if lib_ver then
        API.setUserLibraryVersion(lib_ver)
    end
    return item
end

function API.getItemWithAttachments(key)
    local item
    local db = API.openDB()
    -- get item first
    local stmt = db:prepare(ZOTERO_GET_ITEM)
    stmt:bind1(1, key)

    local result, nr = stmt:resultset()

    if nr > 0 then
        item = JSON.decode(result[1][1])

        local stmtAttachments = db:prepare(ZOTERO_GET_ITEM_ATTACHMENTS)
        stmtAttachments:bind1(1, key)

        result, nr = stmtAttachments:resultset()
        stmtAttachments:close()

        local attachments = {}

        for i = 1, nr do
            stmt:reset():bind1(1, result[1][i])
            local childResult, cnr = stmt:resultset()
            if cnr == 1 then
                local attach = JSON.decode(childResult[1][1]).data
                -- check whether its synced
                local syncedVersion, lastSync = API.getAttachmentVersion(attach.key)
                attach.syncedVersion = syncedVersion
                attach.lastSync = lastSync
                table.insert(attachments, attach)
            end
        end
        -- add an attachments field to item:
        item.attachments = attachments
    end
    stmt:close()
    --print(JSON.encode(item))
    return item
end

function API.getItemAttachments(key)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_GET_ITEM_ATTACHMENTS)
    stmt:reset()
    stmt:bind1(1, key)

    local result, nr = stmt:resultset()

    stmt:close()

    if nr == 0 then
        return nil
    end

    local items = {}

    for i = 1, nr do
        local item_key = result[1][i]
        local json_value = result[2][i]

        -- Parse JSON to extract filename
        local item_data = JSON.decode(json_value)
        local filename = item_data.data and item_data.data.filename or ""
        local is_pdf = item_data.data and item_data.data.contentType == "application/pdf"

        table.insert(items, {
            ["key"] = item_key,
            ["text"] = filename,
            ["type"] = "attachment",
            ["is_pdf"] = is_pdf,
        })
    end

    -- Sort by is_pdf (PDFs first), then by filename
    table.sort(items, function(a, b)
        if a.is_pdf ~= b.is_pdf then
            return a.is_pdf
        end
        return a.text < b.text
    end)

    return items
end

-- Downloads an attachment file to the correct directory and returns the path.
-- If the local version is up to date, no network request is made.
-- Before the download, the download_callback is called.
-- Returns tuple with path and error, if path is correct then error is nil.
function API.downloadAndGetPath(key, download_callback)
    local item = API.getItem(key)
    if item == nil then
        return nil, "Error: the requested file can not be found in the database"
    end

    if item.data.itemType ~= "attachment" then
        return nil, "Error: this item is not an attachment"
    elseif not API.isSupportedAttachmentLinkMode(item.data.linkMode) then
        return nil, "Error: this item is not a stored attachment"
    elseif table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType) == false then
        return nil, "Error: this item has an unsupported content type (" .. item.data.contentType .. ")"
    end

    local localPath, localErr = API.tryResolveLocalAttachment(key)
    if localErr ~= nil then
        return nil, localErr
    end
    if localPath then
        return localPath, nil
    end

    if item.data.linkMode == "linked_file" then
        return nil,
            "Error: linked file not found locally. Check linked files folder and path mappings in Zotero settings."
    end

    local e = API.verifyZoteroAccess()
    if e ~= nil then
        return nil, e
    end

    local downloadRequired = true

    local targetDir, targetPath = API.getDirAndPath(item)
    local file_ts = lfs.attributes(targetPath, "modification")
    if file_ts then -- file already exists locally
        -- get local file version from doc settings file
        local docSettings = DocSettings:open(targetPath)
        local libVersionAtLastSync = docSettings:readSetting("zoteroLibVersion", 0)
        docSettings:close()
        -- check what the database expected to find (can be out-of date for many reasons...)
        local local_version, lastSync, itemVersion, itemID = API.getAttachmentVersion(key)
        logger.info(
            "Zotero: ItemID:",
            itemID,
            ", local item:",
            local_version,
            "(synced at",
            lastSync,
            ", lib version",
            libVersionAtLastSync,
            "), item version:",
            itemVersion
        )
        if libVersionAtLastSync >= item.version then
            logger.dbg("Zotero: Up-to-date local file. No need for download.")
            downloadRequired = false
        end
    else -- file does not exist, so make sure the folder is there...
        lfs.mkdir(targetDir)
    end

    if downloadRequired then
        if download_callback ~= nil then
            download_callback()
        end

        local errormsg
        logger.info("Zotero: Downloading attachment file")
        if API.settings:isTrue("webdav_enabled") then
            local result
            result, errormsg = API.downloadWebDAV(key, targetDir, targetPath)
        else
            local url = API.userLibraryURL .. "/items/" .. key .. "/file"
            logger.dbg("Zotero: fetching " .. url)

            local r, c, h = https.request({
                url = url,
                headers = API.zoteroHeader,
                sink = ltn12.sink.file(io.open(targetPath, "wb")),
            })

            errormsg = API.verifyResponse(r, c)
        end
        if errormsg then
            if file_ts then
                logger.warn("Zotero: Failed to download updated attachtment version. Using local copy!")
            else
                logger.warn("Zotero: Failed to download attachtment")
                return nil, errormsg
            end
        end
        -- Make sure libVersion is added to metadata for non-pdf files...
        if item.data.contentType ~= SUPPORTED_MEDIA_TYPES[1] then
            local docSettings = DocSettings:open(targetPath)
            docSettings:saveSetting("zoteroLibVersion", API.getUserLibraryVersion())
            docSettings:flush()
        end
    end

    API.getAttachmentInfo(item, targetPath)

    local ok, err = pcall(API.attachItemAnnotations, item, nil, targetPath)
    if not ok then
        logger.err("Zotero: attachItemAnnotations failed for ", targetPath, ": ", err)
    end

    -- Update local db with synced item version number
    API.setAttachmentVersionByKey(key, item.version)

    return targetPath, nil
end

function API.downloadWebDAV(key, targetDir, targetPath)
    if API.getWebDAVUrl() == nil then
        return nil, "WebDAV url not set"
    end
    local url = API.getWebDAVUrl() .. "/" .. key .. ".zip"
    local headers = API.getWebDAVHeaders()
    local zipPath = targetDir .. "/" .. key .. ".zip"
    logger.dbg("Zotero: fetching URL " .. url)
    local r, c, h = https.request({
        method = "GET",
        url = url,
        headers = headers,
        sink = ltn12.sink.file(io.open(zipPath, "wb")),
    })

    if c ~= 200 then
        return nil, "Download failed with status code " .. c
    end

    -- Zotero WebDAV storage packs documents inside a zipfile
    -- Options: -qq : very quietly; -o : overwrite without prompting
    local zip_cmd = "unzip -qq -o '" .. zipPath .. "' -d '" .. targetDir .. "'"
    logger.dbg("Zotero: unzipping with " .. zip_cmd)
    local zip_result = os.execute(zip_cmd)

    local remove_result, e, ecode = os.remove(zipPath)
    if remove_result == nil then
        logger.err(("Zotero: failed to remove zip file %s, error %s"):format(zipPath, e))
    end

    if zip_result then
        return targetPath
    else
        return nil, "Unzipping failed"
    end
end

function API.getWebDAVHeaders()
    local user = API.getWebDAVUser() or ""
    local pass = API.getWebDAVPassword() or ""

    return {
        ["Authorization"] = "Basic " .. sha2.bin_to_base64(user .. ":" .. pass),
    }
end

-- Download all files that are part of an offline collection
function API.batchDownload(progress_callback)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_GET_OFFLINE_COLLECTION_ATTACHMENTS)

    local result, item_count = stmt:reset():resultset()

    logger.info("Zotero:", item_count, "offline items to download")

    -- Track download failures
    local download_fails = 0
    local failed_downloads = {}

    for i = 1, item_count do
        local download_key = result[1][i]
        local filename = result[2][i]
        progress_callback(string.format(_("Downloading attachment %i/%i"), i, item_count))
        local path, e = API.downloadAndGetPath(download_key, nil)

        if e ~= nil then
            progress_callback(string.format(_("Error downloading attachment %s: %s"), filename, e))
            download_fails = download_fails + 1
            table.insert(failed_downloads, {filename = filename, error = e})
        end
    end

    -- Return error counts and details
    return download_fails, failed_downloads
end

-- Return a table of entries of a collection.
--
-- If key is nil, entries of the root collection will be given.
-- Each entry is a table with at least two values, the key and name.
-- Collections will have a display name that ends with a slash and contain true
-- under the key "collection" in their table.
function API.displayCollection(key)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_QUERY_ITEMS)

    stmt:reset()
    stmt:clearbind()

    if key == nil then
        -- use fake key for root collection
        key = "/"
        --print("Key is nil")
    end
    stmt:bind1(1, key)

    local result = {}
    local row, _ = stmt:step({}, {})
    while row ~= nil do
        local item_key = row[1]
        local text = row[2]
        local item_type = row[3]

        -- For items (not collections), row[2] is JSON that needs to be parsed
        if item_type ~= "collection" then
            local item_data = JSON.decode(text)
            -- Construct display name: prepend creator summary if available
            local creator_summary = item_data.meta and item_data.meta.creatorSummary or ""
            local title = item_data.data and item_data.data.title or ""
            if creator_summary ~= "" then
                text = creator_summary .. " - " .. title
            else
                text = title
            end
        end

        table.insert(result, {
            ["key"] = item_key,
            ["text"] = text,
            ["type"] = item_type,
        })
        --print(row[1], row[2], row[3])
        row = stmt:step(row)
    end
    stmt:close()

    return result
end

function API.displaySearchResults(query)
    local queryExpr = "%" .. string.gsub(query, " ", "%") .. "%"
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_SEARCH_ITEMS)

    stmt:reset()
    stmt:clearbind()

    local result = {}
    local row, _ = stmt:step({}, {})
    while row ~= nil do
        local item_key = row[1]
        local json_value = row[2]
        local item_type = row[3]

        -- Parse JSON to extract title and creator summary
        local item_data = JSON.decode(json_value)
        local creator_summary = item_data.meta and item_data.meta.creatorSummary or ""
        local title = item_data.data and item_data.data.title or ""

        -- Construct display text
        local text
        if creator_summary ~= "" then
            text = creator_summary .. " - " .. title
        else
            text = title
        end

        -- Filter based on query match (case-insensitive)
        if text:lower():find(query:lower(), 1, true) then
            table.insert(result, {
                ["key"] = item_key,
                ["text"] = text,
                ["type"] = item_type,
            })
        end

        row = stmt:step(row)
    end
    stmt:close()

    -- Sort results by text
    table.sort(result, function(a, b)
        return a.text < b.text
    end)

    --print(JSON.encode(result))
    return result
end

function API.resetSyncState()
    API.closeDB()
    local bak_path = BaseUtil.joinPath(API.zotero_dir, "zotero.db.old")
    if not os.rename(API.db_path, bak_path) then
        os.delete(API.db_path)
    end
end

function API.isOfflineCollection(key)
    local db = API.openDB()

    local stmt = db:prepare(ZOTERO_GET_OFFLINE_COLLECTION):reset():bind1(1, key)

    local _, nr = stmt:resultset()

    return (nr > 0)
end

function API.addOfflineCollection(key)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_ADD_OFFLINE_COLLECTION)
    stmt:reset():bind1(1, key):step()
end

function API.removeOfflineCollection(key)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_REMOVE_OFFLINE_COLLECTION)
    stmt:reset():bind1(1, key):step()
end

function API.getAttachmentVersion(key)
    local db = API.openDB()
    --    local stmt = db:prepare(ZOTERO_GET_VERSION)
    local stmt = db:prepare(ZOTERO_GET_ATTACHMENT_VERSION)
    local result, nr = stmt:reset():bind(key):resultset()
    stmt:close()

    if nr == 0 then
        return nil
    else
        -- return syncedVersion, lastSync, version, items.itemID
        return tonumber(result[1][1]), tonumber(result[2][1]), tonumber(result[3][1]), tonumber(result[4][1])
    end
end

function API.setAttachmentVersion(id, version)
    local db = API.openDB()
    --    local stmt = db:prepare(ZOTERO_SET_VERSION)
    local stmt = db:prepare(ZOTERO_SET_ATTACHMENT_SYNCEDVERSION)
    stmt:reset():bind(id, version):step()
    stmt:close()
end

function API.setAttachmentVersionByKey(key, version)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_SET_ATTACHMENT_SYNCEDVERSION_KEY)
    stmt:reset():bind(key, version):step()
    stmt:close()
end

-- Get the version of an item from the database
function API.getItemVersion(key)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_GET_ITEM_VERSION)
    local result, nr = stmt:reset():bind(key):resultset()
    stmt:close()

    if nr == 0 then
        return nil
    else
        return tonumber(result[1][1])
    end
end

function API.syncAnnotations(progress_callback)
    local db = API.openDB()
    -- All known attachments (not only syncedVersion>0) so linked files are included
    local stmt = db:prepare(ZOTERO_LIST_ATTACHMENT_ITEMS)
    local row = stmt:reset():step()
    local keys = {}
    while row ~= nil do
        local ok, item = pcall(JSON.decode, row[1])
        if
            ok
            and item
            and item.data
            and item.data.itemType == "attachment"
            and API.isSupportedAttachmentLinkMode(item.data.linkMode)
            and (
                table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType)
                or (item.data.path and (item.data.path:match("%.pdf$") or item.data.path:match("%.epub$")))
            )
        then
            table.insert(keys, item.key)
        end
        row = stmt:step(row)
    end
    stmt:close()

    local item_count = #keys
    logger.info("Zotero: Checking annotations on " .. tostring(item_count) .. " attachments (incl. linked).")

    local total_upload_fails = 0
    local total_delete_fails = 0
    local total_update_fails = 0

    local defaultColor = API.settings:readSetting("annotation_default_color")
    Annotations.setDefaultColor(defaultColor)

    for i, key in ipairs(keys) do
        local item = API.getItem(key)
        local file_path = nil
        if item then
            file_path = API.resolveAttachmentPath(item)
            if file_path == nil then
                local ok_gp, dir, path = pcall(function()
                    return API.getDirAndPath(item)
                end)
                if ok_gp then
                    file_path = path
                end
            end
        end
        if file_path and file_exists(file_path) then
            local sidecarFile = nil
            pcall(function()
                sidecarFile = DocSettings:findSidecarFile(file_path)
            end)
            -- Sync if sidecar exists (linked files often never had lastSync set)
            if sidecarFile then
                local syncedVersion, lastSync = API.getAttachmentVersion(key)
                local db_ts = tonumber(lastSync) or 0
                local file_ts = lfs.attributes(sidecarFile, "modification") or 0
                -- Always sync if never tracked (linked files) or sidecar newer than last annotation sync
                if (syncedVersion == nil or tonumber(syncedVersion) == 0 or db_ts == 0) or file_ts > db_ts then
                    local upload_fails, delete_fails, update_fails =
                        API.syncAnnotationsForAttachment(key, file_path)
                    total_upload_fails = total_upload_fails + (upload_fails or 0)
                    total_delete_fails = total_delete_fails + (delete_fails or 0)
                    total_update_fails = total_update_fails + (update_fails or 0)
                    -- Ensure attachment is marked so future incremental syncs see it
                    pcall(API.setAttachmentVersionByKey, key, item.version or 1)
                end
            end
        end

        if progress_callback ~= nil and (i == 1 or i % 10 == 0 or i == item_count) then
            progress_callback(string.format(_("Syncing annotations of file %i/%i"), i, item_count))
        end
    end

    return total_upload_fails + total_update_fails, total_delete_fails
end

-- Sync create/update/delete annotations for one attachment file.
-- opts.push_only: skip server pull + sidecar attach (fast close / local-edit push).
-- Returns upload_fails, delete_fails, update_fails
function API.syncAnnotationsForAttachment(key, file_path, opts)
    opts = opts or {}
    local push_only = opts.push_only == true
    if key == nil or file_path == nil or not file_exists(file_path) then
        return 0, 0, 0
    end

    local defaultColor = API.settings:readSetting("annotation_default_color")
    Annotations.setDefaultColor(defaultColor)

    local db = API.openDB()
    local stmt_ts = db:prepare(ZOTERO_SET_ATTACHMENT_LASTSYNC)

    local doc_settings_pre = DocSettings:open(file_path)
    local sdr_before = doc_settings_pre:readSetting("annotations", {}) or {}
    local keys_now = {}
    for _, ann in ipairs(sdr_before) do
        if ann.zoteroKey then
            keys_now[ann.zoteroKey] = true
        end
    end
    doc_settings_pre:close()

    -- Detect local deletes via durable state file (NOT the KOReader sidecar).
    local local_delete_set = API.noteLocalAnnotationDeletions(key, keys_now) or {}
    local deleted_items = {}
    for del_key, _ in pairs(local_delete_set) do
        logger.info("Zotero: local delete candidate " .. tostring(del_key))
    end

    local remote_keys = {}
    local refresh_ok = false
    if not push_only then
        -- Refresh from Zotero API (remote adds / deletes / style). Must succeed for Z→K sync.
        local refresh_ret
        refresh_ok, refresh_ret = API.refreshAttachmentAnnotationsFromServer(key, keys_now)
        if refresh_ok and type(refresh_ret) == "table" then
            remote_keys = refresh_ret
        else
            logger.warn("Zotero: server annotation pull failed: ", refresh_ret)
        end

        -- Pull remote annotations into sidecar (skip keys the user deleted locally)
        local parent_item = API.getItem(key)
        if parent_item then
            local att_ok, att_err = pcall(
                API.attachItemAnnotations,
                parent_item,
                nil,
                file_path,
                true,
                local_delete_set
            )
            if not att_ok then
                logger.err("Zotero: attachItemAnnotations crashed: ", att_err)
            end
        else
            logger.warn("Zotero: no parent item for attachment " .. tostring(key))
        end
    end

    -- After pull (or push-only): strip local-deletes; remote-deletes only after a successful pull
    local doc_settings = DocSettings:open(file_path)
    local sdr_annotations = doc_settings:readSetting("annotations", {}) or {}
    local stripped = false
    for i = #sdr_annotations, 1, -1 do
        local zk = sdr_annotations[i].zoteroKey
        if zk then
            local drop = local_delete_set[zk]
            -- Only trust remote_keys when refresh succeeded (non-empty or empty both OK)
            if refresh_ok and not remote_keys[zk] then
                drop = true
                logger.info("Zotero: strip sidecar annotation " .. zk .. " (gone on server)")
            end
            if drop then
                table.remove(sdr_annotations, i)
                stripped = true
            end
        end
    end
    if stripped then
        doc_settings:saveSetting("annotations", sdr_annotations)
        doc_settings:flush()
    end

    -- Resolve versions for delete API
    local stmt_get_annotations = db:prepare(ZOTERO_GET_ITEM_ANNOTATIONS_INFO)
    local db_annotations = {}
    local row = stmt_get_annotations:bind(key):step()
    while row ~= nil do
        db_annotations[row[1]] = {
            version = tonumber(row[2]),
            syncedVersion = tonumber(row[3]),
        }
        row = stmt_get_annotations:step(row)
    end
    stmt_get_annotations:close()

    for del_key, _ in pairs(local_delete_set) do
        local info = db_annotations[del_key]
        local ver = info and info.version
        if ver == nil then
            local it = API.getItem(del_key)
            ver = it and it.version or 0
        end
        table.insert(deleted_items, { key = del_key, version = ver or 0 })
        logger.info(
            "Zotero: Detected deleted annotation: "
                .. del_key
                .. " (version: "
                .. tostring(ver)
                .. ")"
        )
    end
    doc_settings:close()

    local delete_fails = 0
    local successfully_deleted = {}
    if #deleted_items > 0 then
        delete_fails, successfully_deleted = API.deleteItems(deleted_items)
    end

    if #successfully_deleted > 0 then
        local stmt_delete = db:prepare(ZOTERO_DB_DELETE_ITEM)
        for _, del_key in ipairs(successfully_deleted) do
            stmt_delete:reset():bind1(1, del_key):step()
            logger.info("Zotero: Removed annotation " .. del_key .. " from local database")
        end
        stmt_delete:close()
    end

    local upload_fails, upload_err = Annotations.createAnnotations(file_path, key, API.createItems)
    upload_fails = upload_fails or 0

    local update_fails, update_err = Annotations.updateAnnotations(
        file_path,
        key,
        API.updateItems,
        API.getItem
    )
    update_fails = update_fails or 0

    -- Update durable sync state from final sidecar
    local ds_final = DocSettings:open(file_path)
    local sdr_final = ds_final:readSetting("annotations", {}) or {}
    ds_final:close()
    local success_set = {}
    for _, okk in ipairs(successfully_deleted) do
        success_set[okk] = true
    end
    local known_out = {}
    local pending_out = {}
    local seen = {}
    for _, ann in ipairs(sdr_final) do
        if ann.zoteroKey and not seen[ann.zoteroKey] then
            table.insert(known_out, ann.zoteroKey)
            seen[ann.zoteroKey] = true
        end
    end
    -- Failed deletes stay pending (+ in known) for retry
    for k, _ in pairs(local_delete_set) do
        if not success_set[k] then
            table.insert(pending_out, k)
            if not seen[k] then
                table.insert(known_out, k)
                seen[k] = true
            end
        end
    end
    API.saveAnnotationSyncState(key, { known = known_out, pending_deletes = pending_out })
    logger.info(
        ("Zotero: annot state known=%d pending_deletes=%d deleted_ok=%d"):format(
            #known_out,
            #pending_out,
            #successfully_deleted
        )
    )

    if upload_fails == 0 and delete_fails == 0 and update_fails == 0 then
        stmt_ts:reset():bind1(1, key):step()
    else
        if upload_fails > 0 then
            logger.info("Zotero: Failed annotation uploads: ", upload_fails, upload_err)
        end
        if update_fails > 0 then
            logger.info("Zotero: Failed annotation updates: ", update_fails, update_err)
        end
        if delete_fails > 0 then
            logger.info("Zotero: Failed annotation deletes: ", delete_fails)
        end
    end
    stmt_ts:close()

    return upload_fails, delete_fails, update_fails
end

-- Persist a newly created annotation item into the local SQLite catalogue so
-- subsequent pull/delete logic does not treat the zoteroKey as orphaned.
function API.upsertCreatedAnnotationItem(created, parent_key, request_payload)
    if created == nil or created.key == nil then
        return
    end
    local key = created.key
    local version = created.version or API.getUserLibraryVersion() or 0
    local item = created
    if item.data == nil and request_payload ~= nil then
        item = {
            key = key,
            version = version,
            data = request_payload,
        }
        item.data.key = key
        item.data.version = version
        item.data.itemType = item.data.itemType or "annotation"
    elseif item.data == nil then
        item = {
            key = key,
            version = version,
            data = {
                itemType = "annotation",
                key = key,
                version = version,
                parentItem = parent_key,
            },
        }
    end
    local ok, err = pcall(function()
        local db = API.openDB()
        local stmt_item = db:prepare(ZOTERO_DB_UPDATE_ITEM)
        stmt_item:reset():bind(1, "annotation", key, version):step()
        stmt_item:close()
        local stmt_data = db:prepare(ZOTERO_DB_UPDATE_ITEMDATA)
        stmt_data:reset():bind(key, JSON.encode(item)):step()
        stmt_data:close()
        if parent_key then
            local stmt_ann = db:prepare(ZOTERO_UPSERT_ITEM_ANNOTATIONS)
            stmt_ann:reset():bind(key, parent_key):step()
            stmt_ann:close()
        end
    end)
    if not ok then
        logger.err("Zotero: upsertCreatedAnnotationItem failed for ", key, ": ", err)
    end
end

-- Upsert a parent book + linked_file attachment into the local DB (not annotation-only).
function API.upsertCreatedLinkedBookItems(parent_created, child_created, parent_payload, child_payload)
    if parent_created == nil or parent_created.key == nil or child_created == nil or child_created.key == nil then
        return false, "missing created keys"
    end
    local parent_key = parent_created.key
    local child_key = child_created.key
    local parent_ver = parent_created.version or API.getUserLibraryVersion() or 0
    local child_ver = child_created.version or parent_ver

    local function build_item(created, payload, fallback_type)
        if created.data ~= nil then
            return created
        end
        local data = {}
        if type(payload) == "table" then
            for k, v in pairs(payload) do
                data[k] = v
            end
        end
        data.key = created.key
        data.version = created.version or parent_ver
        data.itemType = data.itemType or fallback_type
        return {
            key = created.key,
            version = data.version,
            data = data,
        }
    end

    local parent_item = build_item(parent_created, parent_payload, "book")
    local child_item = build_item(child_created, child_payload, "attachment")
    if child_item.data then
        child_item.data.parentItem = parent_key
    end

    local ok, err = pcall(function()
        local db = API.openDB()
        local stmt_item = db:prepare(ZOTERO_DB_UPDATE_ITEM)
        local stmt_data = db:prepare(ZOTERO_DB_UPDATE_ITEMDATA)
        stmt_item:reset():bind(1, "book", parent_key, parent_ver):step()
        stmt_data:reset():bind(parent_key, JSON.encode(parent_item)):step()
        stmt_item:reset():bind(1, "attachment", child_key, child_ver):step()
        stmt_data:reset():bind(child_key, JSON.encode(child_item)):step()
        stmt_item:close()
        stmt_data:close()
        -- Direct attachment link (do not require collection membership).
        local stmt_att = db:prepare(ZOTERO_UPSERT_ITEM_ATTACHMENTS)
        stmt_att:reset():bind(child_key, parent_key):step()
        stmt_att:close()
    end)
    if not ok then
        logger.err("Zotero: upsertCreatedLinkedBookItems failed: ", err)
        return false, err
    end
    return true, nil
end

local function parseCreatorsFromAuthorString(authors)
    local creators = {}
    if authors == nil or authors == "" then
        return creators
    end
    local raw = tostring(authors)
    -- Normalize separators then split
    raw = raw:gsub("%s+&%s+", ";"):gsub("%s+and%s+", ";"):gsub("%s*,%s*and%s+", ";")
    for chunk in raw:gmatch("[^;]+") do
        local name = chunk:gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" then
            local last, first = name:match("^([^,]+),%s*(.+)$")
            if last and first then
                table.insert(creators, {
                    creatorType = "author",
                    lastName = last:gsub("^%s+", ""):gsub("%s+$", ""),
                    firstName = first:gsub("^%s+", ""):gsub("%s+$", ""),
                })
            else
                local first_n, last_n = name:match("^(.+)%s+(%S+)$")
                if first_n and last_n and first_n ~= last_n then
                    table.insert(creators, {
                        creatorType = "author",
                        firstName = first_n,
                        lastName = last_n,
                    })
                else
                    table.insert(creators, {
                        creatorType = "author",
                        name = name,
                    })
                end
            end
        end
    end
    return creators
end

local function contentTypeForPath(file_path)
    local lower = string.lower(tostring(file_path or ""))
    if lower:match("%.epub$") then
        return "application/epub+zip"
    end
    if lower:match("%.html?$") then
        return "text/html"
    end
    return "application/pdf"
end

-- Create a Zotero book + linked_file attachment (no file upload).
-- opts: { title, authors, date, file_path }
-- Returns attachment_key, error_message
function API.createLinkedBookItem(opts)
    opts = opts or {}
    local file_path = opts.file_path
    if file_path == nil or file_path == "" then
        return nil, "missing file_path"
    end
    if not API.isPathUnderLinkedBase(file_path) then
        return nil, "File is not under the linked files folder"
    end
    local existing = API.findAttachmentKeyByFilePath(file_path)
    if existing then
        return existing, nil
    end

    local title = opts.title
    if title == nil or title == "" then
        title = API.basenameOfPath(file_path) or "Untitled"
        title = title:gsub("%.[^%.]+$", "")
    end
    local date = opts.date or ""
    local creators = parseCreatorsFromAuthorString(opts.authors)
    local filename = API.basenameOfPath(file_path) or title
    local zpath = API.linkedAttachmentZoteroPath(file_path)
    local content_type = contentTypeForPath(file_path)

    -- Client-supplied keys let parent+child share one POST (must match Zotero charset).
    local parent_tmp = newZoteroTempKey()
    local child_tmp = newZoteroTempKey()
    while child_tmp == parent_tmp do
        child_tmp = newZoteroTempKey()
    end

    -- Do NOT send empty tags/collections/creators tables: Lua {} encodes as JSON
    -- object {}, and Zotero rejects that ("must be an array"). Omit optional fields.
    local parent_payload = {
        key = parent_tmp,
        itemType = "book",
        title = title,
        date = date,
    }
    if type(creators) == "table" and #creators > 0 then
        parent_payload.creators = creators
    end
    local child_payload = {
        key = child_tmp,
        itemType = "attachment",
        parentItem = parent_tmp,
        linkMode = "linked_file",
        contentType = content_type,
        charset = "",
        path = zpath,
        title = filename,
        note = "",
    }

    local created, fails = API.createItems({ parent_payload, child_payload })
    if type(fails) == "string" then
        return nil, fails
    end
    if type(fails) == "table" and #fails > 0 and (created == nil or created[1] == nil or created[2] == nil) then
        local msg = fails[1] and (fails[1].message or JSON.encode(fails[1])) or "create failed"
        return nil, tostring(msg)
    end
    local parent_created = created and created[1]
    local child_created = created and created[2]
    if parent_created == nil or parent_created.key == nil or child_created == nil or child_created.key == nil then
        return nil, "Zotero did not return created item keys"
    end

    -- Rewrite payloads with real keys for local DB
    parent_payload.key = parent_created.key
    parent_payload.version = parent_created.version
    child_payload.key = child_created.key
    child_payload.version = child_created.version
    child_payload.parentItem = parent_created.key

    local ok_up, up_err = API.upsertCreatedLinkedBookItems(
        parent_created,
        child_created,
        parent_payload,
        child_payload
    )
    if not ok_up then
        logger.warn("Zotero: linked book created remotely but local upsert failed: ", up_err)
    end

    API.clearAttachmentPathCache()
    API.rememberAttachmentKeyForPath(file_path, child_created.key)
    logger.info(
        ("Zotero: created linked book parent=%s attachment=%s path=%s"):format(
            tostring(parent_created.key),
            tostring(child_created.key),
            zpath
        )
    )
    return child_created.key, nil
end

function API.createItems(items)
    -- up to 50 items can be created with one request, see https://www.zotero.org/support/dev/web_api/v3/write_requests#creating_multiple_objects for details
    local API_MAX_ITEMS_PER_REQUEST = 50
    local total_items = #items
    local total_requests = math.ceil(total_items / API_MAX_ITEMS_PER_REQUEST)

    local created_items = {}

    local e = API.verifyZoteroAccess()
    if e ~= nil then
        return created_items, e
    end
    -- Avoid 412: refresh library version at most once per minute
    local now = os.time()
    if not API._lib_ver_refreshed_at or (now - API._lib_ver_refreshed_at) > 60 then
        if pcall(API.refreshUserLibraryVersionFromServer) then
            API._lib_ver_refreshed_at = now
        end
    end

    local headers = API.zoteroHeader
    local create_url = API.userLibraryURL .. "/items"

    local fails = {}
    for request_no = 1, total_requests do
        local request_items = {}
        -- Lua arrays are 1-indexed; start_item is 0-based offset into the array
        local start_item = (request_no - 1) * API_MAX_ITEMS_PER_REQUEST
        local end_item = math.min(start_item + API_MAX_ITEMS_PER_REQUEST, total_items)
        for i = start_item + 1, end_item do
            local it = items[i]
            if type(it) == "table" then
                it._epubFullPosition = nil
            end
            table.insert(request_items, it)
        end

        local request_json = JSON.encode(request_items)
        local function do_post()
            local req_headers = {}
            for hk, hv in pairs(headers) do
                if string.lower(tostring(hk)) ~= "content-length" then
                    req_headers[hk] = hv
                end
            end
            req_headers["If-Unmodified-Since-Version"] = tostring(API.getUserLibraryVersion() or 0)
            req_headers["Content-Type"] = "application/json"
            local response = {}
            logger.info(("Zotero: POST create %d item(s) (libVer=%s)"):format(
                #request_items,
                tostring(req_headers["If-Unmodified-Since-Version"])
            ))
            logger.dbg(("Zotero: POST body:\n%s"):format(request_json))
            local r, c, response_headers = https.request({
                method = "POST",
                url = create_url,
                headers = req_headers,
                sink = ltn12.sink.table(response),
                source = ltn12.source.string(request_json),
                timeout = HTTP_TIMEOUT,
            })
            return r, c, response_headers, table.concat(response, "")
        end

        local r, c, response_headers, content = do_post()
        e = API.verifyResponse(r, c)
        -- One retry after refreshing version on 412
        if e ~= nil and tostring(c) == "412" then
            logger.warn("Zotero: createItems 412 — refreshing library version and retrying once")
            local found = content and content:match("found (%d+)")
            if found then
                API.setUserLibraryVersion(found)
            else
                pcall(API.refreshUserLibraryVersionFromServer)
            end
            r, c, response_headers, content = do_post()
            e = API.verifyResponse(r, c)
        end
        if e ~= nil then
            logger.err("Zotero: createItems HTTP error: ", e, " body=", content)
            return created_items, e
        end

        local ok, result = pcall(JSON.decode, content)
        if not ok or type(result) ~= "table" then
            logger.err("Zotero: createItems bad JSON: ", content)
            return created_items, "Error: failed to parse JSON in response to annotation creation request"
        end

        local n_ok, n_fail, n_unchanged = 0, 0, 0
        for k, v in pairs(result["successful"] or {}) do
            n_ok = n_ok + 1
            local index = start_item + (tonumber(k) or 0) + 1
            created_items[index] = v
            local req = items[index]
            local itype = req and req.itemType
            -- Only auto-upsert annotations; books/attachments are handled by callers
            if itype == nil or itype == "annotation" then
                local parent_key = req and req.parentItem
                API.upsertCreatedAnnotationItem(v, parent_key, req)
            end
        end

        for k, v in pairs(result["unchanged"] or {}) do
            n_unchanged = n_unchanged + 1
            local index = start_item + (tonumber(k) or 0) + 1
            local zotero_key = type(v) == "table" and v.key or v
            created_items[index] = {
                ["key"] = zotero_key,
                ["version"] = type(v) == "table" and v.version or nil,
            }
            local req = items[index]
            local itype = req and req.itemType
            if itype == nil or itype == "annotation" then
                local parent_key = req and req.parentItem
                API.upsertCreatedAnnotationItem(created_items[index], parent_key, req)
            end
        end
        for k, v in pairs(result["failed"] or {}) do
            n_fail = n_fail + 1
            logger.err("Zotero: create item failed [" .. tostring(k) .. "]: ", JSON.encode(v))
            table.insert(fails, v)
        end

        if n_ok == 0 and n_unchanged == 0 then
            logger.err(
                ("Zotero: createItems empty success (fail=%d) raw response: %s"):format(n_fail, content)
            )
            if n_fail == 0 and content ~= "" then
                table.insert(fails, {
                    code = 0,
                    message = "empty successful/failed maps",
                    raw = content,
                })
            end
        else
            logger.info(
                ("Zotero: createItems batch ok=%d unchanged=%d fail=%d"):format(n_ok, n_unchanged, n_fail)
            )
        end

        local new_library_version = response_headers and (
            response_headers["last-modified-version"] or response_headers["Last-Modified-Version"]
        )
        if new_library_version ~= nil then
            API.setUserLibraryVersion(new_library_version)
        end
    end
    if #fails > 0 then
        logger.info("Zotero: Zotero failed to create some items: ", JSON.encode(fails))
    end
    return created_items, fails
end

-- Update existing items (annotations). Payloads must include key and version.
-- Uses POST /items (Zotero multi-object write) same as create with key+version set.
function API.updateItems(items)
    local API_MAX_ITEMS_PER_REQUEST = 50
    local total_items = #items
    if total_items == 0 then
        return {}, nil
    end
    local total_requests = math.ceil(total_items / API_MAX_ITEMS_PER_REQUEST)

    local updated_items = {}

    local e = API.verifyZoteroAccess()
    if e ~= nil then
        return updated_items, e
    end
    -- Library version: refresh at most once per minute (or on 412)
    local now = os.time()
    if not API._lib_ver_refreshed_at or (now - API._lib_ver_refreshed_at) > 60 then
        if pcall(API.refreshUserLibraryVersionFromServer) then
            API._lib_ver_refreshed_at = now
        end
    end

    local headers = API.zoteroHeader
    local update_url = API.userLibraryURL .. "/items"

    local fails = {}
    for request_no = 1, total_requests do
        local request_items = {}
        local start_item = (request_no - 1) * API_MAX_ITEMS_PER_REQUEST
        local end_item = math.min(start_item + API_MAX_ITEMS_PER_REQUEST, total_items)
        for i = start_item + 1, end_item do
            local it = items[i]
            if type(it) == "table" then
                it._epubFullPosition = nil
                -- Use local/DB version first; fetch from server only on 412 retry
                if it.key and (it.version == nil) then
                    local remote = API.getItem(it.key)
                    if remote and remote.version then
                        it.version = remote.version
                    end
                end
            end
            table.insert(request_items, it)
        end

        local request_json = JSON.encode(request_items)
        local function do_post(json_body)
            local req_headers = {}
            for hk, hv in pairs(headers) do
                if string.lower(tostring(hk)) ~= "content-length" then
                    req_headers[hk] = hv
                end
            end
            req_headers["If-Unmodified-Since-Version"] = tostring(API.getUserLibraryVersion() or 0)
            req_headers["Content-Type"] = "application/json"
            local response = {}
            logger.info(("Zotero: POST update %d item(s) (libVer=%s)"):format(
                #request_items,
                tostring(req_headers["If-Unmodified-Since-Version"])
            ))
            logger.dbg(("Zotero: POST update body:\n%s"):format(json_body))
            local r, c, response_headers = https.request({
                method = "POST",
                url = update_url,
                headers = req_headers,
                sink = ltn12.sink.table(response),
                source = ltn12.source.string(json_body),
                timeout = HTTP_TIMEOUT,
            })
            return r, c, response_headers, table.concat(response, "")
        end

        local r, c, response_headers, content = do_post(request_json)
        e = API.verifyResponse(r, c)
        if e ~= nil and tostring(c) == "412" then
            logger.warn("Zotero: updateItems 412 — refreshing versions and retrying once")
            local found = content and content:match("found (%d+)")
            if found then
                API.setUserLibraryVersion(found)
            else
                pcall(API.refreshUserLibraryVersionFromServer)
            end
            for _, it in ipairs(request_items) do
                if it.key then
                    local remote = API.fetchItemFromServer(it.key)
                    if remote and remote.version then
                        it.version = remote.version
                    end
                end
            end
            request_json = JSON.encode(request_items)
            r, c, response_headers, content = do_post(request_json)
            e = API.verifyResponse(r, c)
        end
        if e ~= nil then
            logger.err("Zotero: updateItems HTTP error: ", e, " body=", content)
            return updated_items, e
        end

        local ok, result = pcall(JSON.decode, content)
        if not ok or type(result) ~= "table" then
            logger.err("Zotero: updateItems bad JSON: ", content)
            return updated_items, "Error: failed to parse JSON in response to annotation update request"
        end

        for k, v in pairs(result["successful"] or {}) do
            local index = start_item + (tonumber(k) or 0) + 1
            updated_items[index] = v
            if v.key and v.data then
                local db = API.openDB()
                local stmt2 = db:prepare(ZOTERO_DB_UPDATE_ITEMDATA)
                stmt2:reset():bind(v.key, JSON.encode(v)):step()
                stmt2:close()
            end
        end
        for k, v in pairs(result["unchanged"] or {}) do
            local index = start_item + (tonumber(k) or 0) + 1
            updated_items[index] = { ["key"] = type(v) == "table" and v.key or v }
        end
        -- Retry items that failed with per-item 412 (stale version)
        local retry_items = {}
        for k, v in pairs(result["failed"] or {}) do
            logger.err("Zotero: update item failed [" .. tostring(k) .. "]: ", JSON.encode(v))
            local idx = start_item + (tonumber(k) or 0) + 1
            local it = request_items[(tonumber(k) or 0) + 1]
            if type(v) == "table" and tonumber(v.code) == 412 and it and it.key then
                local remote = API.fetchItemFromServer(it.key)
                if remote and remote.version then
                    it.version = remote.version
                    table.insert(retry_items, it)
                else
                    table.insert(fails, v)
                end
            else
                table.insert(fails, v)
            end
        end
        if #retry_items > 0 then
            logger.warn(("Zotero: retrying %d item update(s) after per-item 412"):format(#retry_items))
            local retry_json = JSON.encode(retry_items)
            local rr, rc, rh, rcontent = do_post(retry_json)
            local re = API.verifyResponse(rr, rc)
            if re == nil then
                local rok, rresult = pcall(JSON.decode, rcontent)
                if rok and type(rresult) == "table" then
                    for k, v in pairs(rresult["successful"] or {}) do
                        table.insert(updated_items, v)
                        if v.key and v.data then
                            local db = API.openDB()
                            local stmt2 = db:prepare(ZOTERO_DB_UPDATE_ITEMDATA)
                            stmt2:reset():bind(v.key, JSON.encode(v)):step()
                            stmt2:close()
                        end
                    end
                    for _, v in pairs(rresult["failed"] or {}) do
                        table.insert(fails, v)
                    end
                    local new_lib = rh and (rh["last-modified-version"] or rh["Last-Modified-Version"])
                    if new_lib then
                        API.setUserLibraryVersion(new_lib)
                    end
                end
            else
                logger.err("Zotero: updateItems retry HTTP error: ", re)
            end
        end
        local new_library_version = response_headers and (
            response_headers["last-modified-version"] or response_headers["Last-Modified-Version"]
        )
        if new_library_version ~= nil then
            API.setUserLibraryVersion(new_library_version)
        end
    end
    if #fails > 0 then
        logger.info("Zotero: Zotero failed to update some items: ", JSON.encode(fails))
    end
    return updated_items, fails
end

-- Delete multiple items from Zotero
-- Returns: number of failed deletions, array of successfully deleted keys
-- item_keys can be either an array of strings (keys) or an array of tables with {key, version}
function API.deleteItems(item_keys)
    if #item_keys == 0 then
        return 0, {}
    end

    local e = API.verifyZoteroAccess()
    if e ~= nil then
        logger.err("Zotero: Cannot delete items - access verification failed: " .. e)
        return #item_keys, {}
    end

    local headers = API.zoteroHeader
    local failed_count = 0
    local successful_deletes = {}

    -- Prepare item data - normalize to {key, version} format
    local items_data = {}
    for _, item in ipairs(item_keys) do
        if type(item) == "string" then
            -- Legacy format - just a key, we'll need to look up the version
            local version = API.getItemVersion(item)
            table.insert(items_data, { key = item, version = version or API.getUserLibraryVersion() })
        else
            -- New format - {key, version} table
            table.insert(items_data, item)
        end
    end

    -- Delete items one by one (Zotero API doesn't support batch deletes)
    for _, item_data in ipairs(items_data) do
        local key = item_data.key
        local item_version = item_data.version

        -- Use the item's version for the deletion request
        headers["If-Unmodified-Since-Version"] = tostring(item_version)

        local delete_url = API.userLibraryURL .. "/items/" .. key

        local headers_str = ""
        for k, v in pairs(headers) do
            headers_str = headers_str .. k .. ": " .. v .. ", "
        end
        headers_str = headers_str:gsub(", $", "")

        logger.dbg("Zotero: DELETE headers are " .. headers_str)
        logger.dbg("Zotero: DELETE request to " .. delete_url)
        local r, c, response_headers = https.request({
            method = "DELETE",
            url = delete_url,
            headers = headers,
        })

        local function mark_ok()
            logger.info("Zotero: Successfully deleted item " .. key)
            table.insert(successful_deletes, key)
            local new_library_version = response_headers
                and (response_headers["last-modified-version"] or response_headers["Last-Modified-Version"])
            if new_library_version ~= nil then
                API.setUserLibraryVersion(new_library_version)
            end
        end

        if c == 204 then
            mark_ok()
        elseif c == 404 then
            logger.info("Zotero: Item " .. key .. " not found on server (already deleted?)")
            table.insert(successful_deletes, key)
        elseif c == 409 or c == 412 then
            -- Stale version — refresh from server and retry once
            logger.warn(
                ("Zotero: delete %s got HTTP %s (ver=%s) — refreshing and retrying"):format(
                    key,
                    tostring(c),
                    tostring(item_version)
                )
            )
            local remote = API.fetchItemFromServer(key)
            if remote == nil then
                -- Gone on server
                table.insert(successful_deletes, key)
            else
                headers["If-Unmodified-Since-Version"] = tostring(remote.version or item_version)
                local r2, c2, h2 = https.request({
                    method = "DELETE",
                    url = delete_url,
                    headers = headers,
                })
                response_headers = h2
                if c2 == 204 or c2 == 404 then
                    mark_ok()
                else
                    logger.err(
                        "Zotero: delete retry failed for "
                            .. key
                            .. " - HTTP "
                            .. tostring(c2)
                    )
                    failed_count = failed_count + 1
                end
            end
        else
            logger.err("Zotero: Failed to delete item " .. key .. " - HTTP " .. tostring(c))
            failed_count = failed_count + 1
        end
    end

    return failed_count, successful_deletes
end

-- Removed old getPageDimensions function - now using Annotations.getPageDimensions instead

function API.scanStorageDir(storage_dir, use_external_paths)
    if storage_dir == nil or storage_dir == "" or not file_exists(storage_dir) then
        return 0, {}
    end
    logger.info("Zotero: Scanning ", storage_dir)
    local extraDirs = {}
    local zotItems = 0
    for file in lfs.dir(storage_dir) do
        if file ~= "." and file ~= ".." then
            local f = BaseUtil.joinPath(storage_dir, file)
            local mode = lfs.attributes(f, "mode")
            if mode == "directory" then
                local local_version, lastSync, itemVersion, itemID = API.getAttachmentVersion(file)
                if itemID ~= nil then
                    local item = API.getItem(file)
                    local targetPath
                    if use_external_paths and item and item.data and item.data.filename then
                        targetPath = BaseUtil.joinPath(storage_dir, file, item.data.filename)
                    elseif item then
                        local _, path = API.getDirAndPath(item)
                        targetPath = path
                    end
                    local file_ts = targetPath and lfs.attributes(targetPath, "modification")
                    if file_ts then
                        zotItems = zotItems + 1
                        local docSettings = DocSettings:open(targetPath)
                        local libVersionAtLastSync = docSettings:readSetting("zoteroLibVersion", 0)
                        docSettings:close()
                        if libVersionAtLastSync >= itemVersion then
                            API.setAttachmentVersion(itemID, itemVersion)
                        else
                            API.setAttachmentVersion(itemID, 1)
                        end
                    end
                else
                    table.insert(extraDirs, file)
                end
            end
        end
    end
    return zotItems, extraDirs
end

function API.scanStorage()
    local zotItems, extraDirs = API.scanStorageDir(API.storage_dir, false)
    if API.getExternalStorageEnabled() then
        local ext_dir = API.getExternalStorageDir()
        if ext_dir ~= "" then
            local extItems, extExtra = API.scanStorageDir(ext_dir, true)
            zotItems = zotItems + extItems
            for _, d in ipairs(extExtra) do
                table.insert(extraDirs, d)
            end
        end
    end
    logger.info("Zotero: Storage scan found", zotItems, "local attachment items.")
    if #extraDirs > 0 then
        logger.info("Zotero: Found", #extraDirs, "extra directories: ", unpack(extraDirs))
    end
    return zotItems
end

-- Add Zotero document info to sidecar file
function API.getAttachmentInfo(item, filePathOverride)
    local itemKey = item.key
    local fileDir, filePath = API.getDirAndPath(item)
    if filePathOverride and filePathOverride ~= "" then
        filePath = filePathOverride
    end

    if filePath == nil then
        return "Error: could not find item"
    end
    if not file_exists(filePath) then
        return "Error: file does not exist at " .. tostring(filePath)
    end
    --print(JSON.encode(item))
    local customSettings = DocSettings:openSettingsFile()
    local docProps = {}
    if item.data.parentItem ~= nil then
        local parent = API.getItem(item.data.parentItem)
        --if item.data.title == item.data.filename then
        if parent.data.title then
            docProps["title"] = parent.data.title
        end
        --elseif item.data.title then
        --	docProps["title"] = item.data.title
        --end
        --print(JSON.encode(parent.data))
        --		if parent.meta.creatorSummary ~= "" then docProps["authors"] = parent.meta.creatorSummary end
        if parent.data.creators[1] ~= nil then
            local authors = {}
            for _, v in ipairs(parent.data.creators) do
                if v.creatorType == "author" then
                    table.insert(authors, v.firstName .. " " .. v.lastName)
                end
            end
            -- use \n to separate items, as KOReader seems to then split them up properly
            docProps["authors"] = table.concat(authors, "\n")
        end
        if parent.data.abstractNote ~= "" then
            docProps["description"] = parent.data.abstractNote
        end
        if parent.data.language ~= "" then
            docProps["language"] = parent.data.language
        end
        if parent.data.series ~= "" then
            docProps["series"] = parent.data.series
        end
        if parent.data.tags[1] ~= nil then
            local tags = {}
            for _, v in ipairs(parent.data.tags) do
                table.insert(tags, v.tag)
            end
            docProps["keywords"] = table.concat(tags, "\n")
        end
    elseif item.data.title then
        docProps["title"] = item.data.title
    end
    --print(JSON.encode(docProps))
    customSettings:saveSetting("custom_props", docProps)
    -- Need this, otherwise KOReader crashes when trying to edit the custom values
    -- Should set this properly, but this will do to stop crashes...
    customSettings:saveSetting("doc_props", docProps)
    customSettings:flushCustomMetadata(filePath)
end

-- Count annotations in itemAnnotations for an attachment key.
function API.countAttachmentAnnotations(attachment_key)
    if attachment_key == nil then
        return 0
    end
    local count = 0
    local ok = pcall(function()
        local db = API.openDB()
        local stmt = db:prepare(ZOTERO_GET_ITEM_ANNOTATIONS_INFO)
        local row = stmt:bind(attachment_key):step()
        while row ~= nil do
            count = count + 1
            row = stmt:step(row)
        end
        stmt:close()
    end)
    if not ok then
        return 0
    end
    return count
end

-- Count sidecar annotations that already carry a zoteroKey.
function API.countSidecarZoteroAnnotations(file_path)
    if file_path == nil or not file_exists(file_path) then
        return 0
    end
    local count = 0
    pcall(function()
        local docSettings = DocSettings:open(file_path)
        local anns = docSettings:readSetting("annotations", {}) or {}
        for _, ann in ipairs(anns) do
            if ann.zoteroKey then
                count = count + 1
            end
        end
        docSettings:close()
    end)
    return count
end

-- Prefer more precise EPUB XPointers (text().N) over coarse DocFragment/body stubs.
local function epubXpPrecision(xp)
    if type(xp) == "table" and type(xp.xpointer) == "string" then
        xp = xp.xpointer
    end
    if type(xp) ~= "string" or not xp:find("DocFragment", 1, true) then
        return 0
    end
    if xp:find("text()", 1, true) then
        return 3
    end
    if xp:match("^/body/DocFragment%[%d+%]/body$") then
        return 1
    end
    return 2
end

-- Preserve KOReader geometry (especially EPUB XPointer strings) when applying a Zotero item.
local function preserveLocalGeometry(converted, prev)
    if prev == nil then
        return
    end
    if prev.zoteroDestination then
        converted.zoteroDestination = prev.zoteroDestination
    end
    -- Keep the more precise XPointers (remote convert often only has DocFragment/body)
    if epubXpPrecision(prev.page) >= epubXpPrecision(converted.page) and type(prev.page) == "string" then
        converted.page = prev.page
    end
    if epubXpPrecision(prev.pos0) >= epubXpPrecision(converted.pos0) and prev.pos0 ~= nil then
        converted.pos0 = prev.pos0
    end
    if epubXpPrecision(prev.pos1) >= epubXpPrecision(converted.pos1) and prev.pos1 ~= nil then
        converted.pos1 = prev.pos1
    end
    if prev.pageno ~= nil then
        converted.pageno = prev.pageno
    end
    if prev.pboxes and #prev.pboxes > 0 then
        converted.pboxes = prev.pboxes
    end
    if prev.chapter then
        converted.chapter = prev.chapter
    end
    -- Never clobber a deliberate gray/black e-ink underline with a yellow fallback from a bad map
    local prev_c = string.lower(tostring(prev.color or ""))
    local new_c = string.lower(tostring(converted.color or ""))
    if (prev_c == "gray" or prev_c == "grey" or prev_c == "black") and new_c == "yellow" then
        converted.color = prev_c == "black" and "gray" or prev.color
    end
    if prev.drawer and converted.drawer and prev.drawer ~= converted.drawer then
        -- Keep local drawer when remote only differs because of type fallback noise
        if prev.drawer == "underscore" and converted.drawer == "lighten" then
            local match = converted._matchItem
            local remote_type = match and match.data and match.data.annotationType
            if remote_type == nil or remote_type == "" then
                converted.drawer = prev.drawer
            end
        end
    end
end

local function applyZoteroAnnotationToSidecar(koreaderAnnotations, localZotAnn, key, itemInfo, converted)
    if converted == nil then
        return false
    end
    -- Stash then ALWAYS drop: persisting _matchItem in the sidecar breaks KOReader drawing
    -- (nested Zotero item tables) and was left behind on the update-existing path.
    local match_item = converted._matchItem
    converted._matchItem = nil
    if localZotAnn[key] ~= nil then
        local prev = koreaderAnnotations[localZotAnn[key].position]
        local remote_newer = (tonumber(localZotAnn[key].version) or 0) < (tonumber(itemInfo.version) or 0)
        local style_diff = prev ~= nil
            and (
                tostring(prev.color or "") ~= tostring(converted.color or "")
                or tostring(prev.drawer or "") ~= tostring(converted.drawer or "")
                or tostring(prev.note or "") ~= tostring(converted.note or "")
                or tostring(prev.text or "") ~= tostring(converted.text or "")
            )
        if remote_newer or style_diff then
            preserveLocalGeometry(converted, prev)
            koreaderAnnotations[localZotAnn[key].position] = converted
            return true
        end
        return false
    end
    -- Merge into a matching local annotation (same page+text) to avoid duplicates
    local match_idx = nil
    if match_item then
        match_idx = Annotations.findMatchingLocalAnnotation(koreaderAnnotations, match_item)
    end
    if match_idx then
        local prev = koreaderAnnotations[match_idx]
        converted.zoteroDestination = prev.zoteroDestination
            or converted.zoteroDestination
            or Annotations.DEST_BOTH
        preserveLocalGeometry(converted, prev)
        koreaderAnnotations[match_idx] = converted
        localZotAnn[key] = { position = match_idx, version = itemInfo.version }
        return true
    end
    table.insert(koreaderAnnotations, converted)
    localZotAnn[key] = { position = #koreaderAnnotations, version = itemInfo.version }
    return true
end

-- Attach Zotero annotations for specified item by adding them to document settings.
-- skip_keys: optional set { [zoteroKey]=true } of annotations the user deleted locally
--            (must not be re-injected from a remote pull).
-- Returns nil on success, or an error/warning string.
function API.attachItemAnnotations(item, annotation_callback, filePathOverride, force, skip_keys)
    if item == nil or item.data == nil then
        return "Error: invalid item"
    end
    skip_keys = skip_keys or {}

    local filePath = filePathOverride
    if filePath == nil or filePath == "" then
        filePath = API.resolveAttachmentPath(item)
    end
    if filePath == nil or filePath == "" then
        local ok, _, path = pcall(function()
            return API.getDirAndPath(item)
        end)
        if ok then
            filePath = path
        end
    end

    local contentType = item.data.contentType
    local is_pdf = contentType == "application/pdf"
        or (filePath and string.lower(filePath):match("%.pdf$") ~= nil)
    local is_epub = contentType == "application/epub+zip"
        or (filePath and string.lower(filePath):match("%.epub$") ~= nil)
    if not is_pdf and not is_epub then
        return "Warning: Can only sync annotations for PDF and EPUB files"
    end

    local itemKey = item.key
    if filePath == nil then
        return "Error: could not find item"
    end
    if not file_exists(filePath) then
        return "Error: file does not exist at " .. tostring(filePath)
    end

    local zoteroItems = {}
    local zotCount = 0

    local docSettings = DocSettings:open(filePath)
    local lastSyncedLibVersion = docSettings:readSetting("zoteroLibVersion", 0)
    local libVersion = API.getUserLibraryVersion()
    local sidecar_zot = 0
    local anns_preview = docSettings:readSetting("annotations", {}) or {}
    for _, ann in ipairs(anns_preview) do
        if ann.zoteroKey then
            sidecar_zot = sidecar_zot + 1
        end
    end
    local db_zot = API.countAttachmentAnnotations(itemKey)
    -- Re-pull when forced, library newer, sidecar missing remote anns, OR sidecar still
    -- has anns deleted from the local DB (remote delete after library/API refresh).
    local needs_pull = force
        or (lastSyncedLibVersion < libVersion)
        or (db_zot > sidecar_zot)
        or (sidecar_zot > db_zot)

    if needs_pull then
        local db = API.openDB()
        local stmt_get_ItemAnnotationInfo = db:prepare(ZOTERO_GET_ITEM_ANNOTATIONS_INFO)
        local row = stmt_get_ItemAnnotationInfo:bind(itemKey):step()
        while row ~= nil do
            local key = row[1]
            zoteroItems[key] = { ["version"] = tonumber(row[2]), ["syncedVersion"] = tonumber(row[3]) }
            zotCount = zotCount + 1
            row = stmt_get_ItemAnnotationInfo:step(row)
        end
        stmt_get_ItemAnnotationInfo:close()
    end

    local applied = 0
    local failed = 0

    -- Always load sidecar when pulling: even with zotCount=0 we must remove
    -- annotations deleted remotely (otherwise they linger / corrupt rolling format).
    if needs_pull then
        local koreaderAnnotations = docSettings:readSetting("annotations", {}) or {}
        logger.dbg("Zotero: " .. #koreaderAnnotations .. " KOReader annotations in sidecar, zotCount=" .. tostring(zotCount))

        local localZotAnn = {}
        local annotationsToRemove = {}
        for idx, ann in ipairs(koreaderAnnotations) do
            if ann.zoteroKey ~= nil then
                if skip_keys[ann.zoteroKey] then
                    logger.info(
                        "Zotero: Remove local annotation "
                            .. ann.zoteroKey
                            .. " (deleted locally, skip re-pull)"
                    )
                    table.insert(annotationsToRemove, idx)
                elseif zoteroItems[ann.zoteroKey] ~= nil then
                    localZotAnn[ann.zoteroKey] = {
                        ["position"] = idx,
                        ["version"] = ann.zoteroVersion,
                    }
                else
                    -- Only remove if the item is truly gone from the whole DB
                    local gone = API.getItem(ann.zoteroKey)
                    if gone == nil then
                        logger.info(
                            "Zotero: Remove local annotation "
                                .. ann.zoteroKey
                                .. " (deleted remotely)"
                        )
                        table.insert(annotationsToRemove, idx)
                    end
                    -- Do NOT remove merely because version < libVersion (that caused re-uploads)
                end
            end
        end
        local removed = #annotationsToRemove
        for i = #annotationsToRemove, 1, -1 do
            table.remove(koreaderAnnotations, annotationsToRemove[i])
        end
        -- Rebuild localZotAnn positions after removals
        localZotAnn = {}
        for idx, ann in ipairs(koreaderAnnotations) do
            if ann.zoteroKey and zoteroItems[ann.zoteroKey] then
                localZotAnn[ann.zoteroKey] = {
                    position = idx,
                    version = ann.zoteroVersion,
                }
            end
        end

        -- Repair EPUB annotations: numeric page (paging) + coarse DocFragment/body
        -- (invisible). Reverse real CFIs from Zotero into precise xpointers.
        if is_epub then
            local EpubCfi = nil
            pcall(function()
                EpubCfi = require("epub_cfi")
            end)
            for _, ann in ipairs(koreaderAnnotations) do
                local xp0 = nil
                if type(ann.pos0) == "string" and ann.pos0:find("DocFragment", 1, true) then
                    xp0 = ann.pos0
                elseif type(ann.pos0) == "table" and type(ann.pos0.xpointer) == "string" then
                    xp0 = ann.pos0.xpointer
                elseif type(ann.page) == "string" and ann.page:find("DocFragment", 1, true) then
                    xp0 = ann.page
                end
                local xp1 = nil
                if type(ann.pos1) == "string" and ann.pos1:find("DocFragment", 1, true) then
                    xp1 = ann.pos1
                elseif type(ann.pos1) == "table" and type(ann.pos1.xpointer) == "string" then
                    xp1 = ann.pos1.xpointer
                end
                local cfi_val = ann.zoteroCfi
                if type(ann.zoteroAnnotationPosition) == "string" then
                    local ok_p, pos = pcall(JSON.decode, ann.zoteroAnnotationPosition)
                    if ok_p and type(pos) == "table" then
                        if type(pos.koreaderPos0) == "string" and pos.koreaderPos0:find("text()", 1, true) then
                            xp0 = pos.koreaderPos0
                        end
                        if type(pos.koreaderPos1) == "string" and pos.koreaderPos1:find("text()", 1, true) then
                            xp1 = pos.koreaderPos1
                        end
                        cfi_val = cfi_val or pos.value
                    end
                end
                if EpubCfi and EpubCfi.normalizeCfi and cfi_val then
                    cfi_val = EpubCfi.normalizeCfi(cfi_val) or cfi_val
                    ann.zoteroCfi = cfi_val
                end
                local coarse = not (type(xp0) == "string" and xp0:find("text()", 1, true))
                -- Also repair page="1" / page=1 (no DocFragment) which crash CRE on open
                local page_bad = type(ann.page) ~= "string"
                    or not tostring(ann.page):find("DocFragment", 1, true)
                if (coarse or page_bad) and EpubCfi and cfi_val then
                    local r0, r1 = EpubCfi.toKOReaderPositions(tostring(cfi_val), filePath)
                    if r0 then
                        xp0, xp1 = r0, r1 or r0
                        coarse = false
                        page_bad = false
                    end
                end
                if (not xp0 or page_bad) and cfi_val then
                    local frag = Annotations.docFragmentFromEpubCfi(cfi_val)
                    if frag then
                        xp0 = xp0 or string.format("/body/DocFragment[%d]/body", frag)
                    end
                end
                if not xp0 and type(ann.page) == "number" then
                    xp0 = string.format("/body/DocFragment[%d]/body", ann.page)
                elseif not xp0 and type(ann.page) == "string" and ann.page:match("^%d+$") then
                    xp0 = string.format("/body/DocFragment[%d]/body", tonumber(ann.page) or 1)
                end
                if xp0 then
                    ann.page = xp0
                    ann.pos0 = xp0
                    ann.pos1 = xp1 or xp0
                end
            end
            -- Clear stale paging/rolling copies so KOReader stays on `annotations`
            if docSettings.delSetting then
                docSettings:delSetting("annotations_paging")
                docSettings:delSetting("annotations_rolling")
            else
                docSettings:saveSetting("annotations_paging", nil)
                docSettings:saveSetting("annotations_rolling", nil)
            end
        end

        local page_dimensions = {}
        if is_pdf and zotCount > 0 then
            local pages_needed = {}
            for key, _ in pairs(zoteroItems) do
                local ann_item = API.getItem(key)
                if ann_item and ann_item.data then
                    local page = nil
                    if ann_item.data.annotationPosition then
                        local ok_p, pos = pcall(JSON.decode, ann_item.data.annotationPosition)
                        if ok_p and pos and pos.pageIndex ~= nil then
                            page = pos.pageIndex + 1
                        end
                    end
                    if page == nil and ann_item.data.annotationPageLabel then
                        page = tonumber(ann_item.data.annotationPageLabel)
                    end
                    if page then
                        pages_needed[page] = true
                    end
                end
            end
            local bbox_ok, bbox_err = pcall(function()
                page_dimensions = Annotations.getPageDimensions(filePath, pages_needed) or {}
            end)
            if not bbox_ok then
                logger.err("Zotero: getPageDimensions crashed: ", bbox_err)
                page_dimensions = {}
            end
            docSettings:saveSetting("page_bboxes", page_dimensions)
        end

        for key, itemInfo in pairs(zoteroItems) do
            if skip_keys[key] then
                logger.info("Zotero: skip re-pull of locally deleted annotation " .. tostring(key))
            else
                local ann_item = API.getItem(key)
                if ann_item and ann_item.data then
                    local converted
                    if is_pdf then
                        local page = 1
                        if ann_item.data.annotationPosition then
                            local ok_p, pos = pcall(JSON.decode, ann_item.data.annotationPosition)
                            if ok_p and pos and pos.pageIndex ~= nil then
                                page = pos.pageIndex + 1
                            end
                        end
                        local page_bbox = page_dimensions[page] or Annotations.fallbackPageBbox()
                        local ok_c, result = pcall(Annotations.convertZoteroToKOReader, ann_item, page_bbox)
                        if ok_c then
                            converted = result
                        else
                            logger.err("Zotero: convert PDF annotation failed ", key, ": ", result)
                            failed = failed + 1
                        end
                    else
                        local ok_c, result = pcall(Annotations.convertZoteroToKOReaderEpub, ann_item, filePath)
                        if ok_c then
                            converted = result
                        else
                            logger.err("Zotero: convert EPUB annotation failed ", key, ": ", result)
                            failed = failed + 1
                        end
                    end
                    if converted then
                        converted._matchItem = ann_item
                        if applyZoteroAnnotationToSidecar(
                            koreaderAnnotations,
                            localZotAnn,
                            key,
                            itemInfo,
                            converted
                        )
                        then
                            applied = applied + 1
                        end
                    end
                else
                    failed = failed + 1
                end
            end
        end

        table.sort(koreaderAnnotations, function(a, b)
            return (tostring(a.page or "") .. (a.zoteroSortIndex or ""))
                < (tostring(b.page or "") .. (b.zoteroSortIndex or ""))
        end)
        docSettings:saveSetting("annotations", koreaderAnnotations)
        logger.info(
            ("Zotero: attach done for %s (zotCount=%d applied=%d failed=%d removed=%d sidecar=%d)"):format(
                tostring(itemKey),
                zotCount,
                applied,
                failed,
                removed,
                #koreaderAnnotations
            )
        )
        if zotCount == 0 and removed == 0 then
            logger.info("Zotero: no annotations to attach (zotCount=0)")
        elseif zotCount == 0 and removed > 0 then
            logger.info("Zotero: removed " .. tostring(removed) .. " remotely deleted annotation(s)")
        end
    end

    -- Only advance sidecar lib version when pull succeeded reasonably
    if failed == 0 or (zotCount > 0 and applied > 0 and failed < zotCount) then
        if needs_pull then
            docSettings:saveSetting("zoteroLibVersion", libVersion)
        end
    else
        logger.warn(
            "Zotero: not advancing zoteroLibVersion (applied="
                .. tostring(applied)
                .. " failed="
                .. tostring(failed)
                .. " zotCount="
                .. tostring(zotCount)
                .. ")"
        )
    end
    docSettings:flush()
    if failed > 0 and applied == 0 and zotCount > 0 then
        return "Error: could not attach Zotero annotations"
    end
    return nil
end

-- Search annotations across the local library (itemAnnotations + itemData JSON).
-- Returns array of { key, parentKey, parentTitle, text, comment, page, color, attachmentKey }
function API.searchAnnotations(query)
    query = string.lower(query or "")
    local results = {}
    local db = API.openDB()
    local sql = [[
SELECT
	items.key,
	itemData.value,
	(SELECT key FROM items WHERE itemID = itemAnnotations.parentItemID),
	(SELECT value FROM itemData WHERE itemID = itemAnnotations.parentItemID)
FROM itemAnnotations
INNER JOIN items ON itemAnnotations.itemID = items.itemID
INNER JOIN itemData ON itemData.itemID = items.itemID
]]
    local stmt = db:prepare(sql)
    local row = stmt:reset():step()
    while row ~= nil do
        local ann_key = row[1]
        local ann_json = row[2]
        local attachment_key = row[3]
        local parent_json = row[4]
        local ann_item = nil
        local parent_item = nil
        pcall(function()
            ann_item = JSON.decode(ann_json)
        end)
        pcall(function()
            parent_item = JSON.decode(parent_json)
        end)
        if ann_item and ann_item.data then
            local text = ann_item.data.annotationText or ""
            local comment = ann_item.data.annotationComment or ""
            local page = ""
            if ann_item.data.annotationPageLabel then
                page = tostring(ann_item.data.annotationPageLabel)
            elseif ann_item.data.annotationPosition then
                local pos_ok, pos = pcall(JSON.decode, ann_item.data.annotationPosition)
                if pos_ok and pos and pos.pageIndex ~= nil then
                    page = tostring(pos.pageIndex + 1)
                end
            end
            local title = ""
            local parent_key = attachment_key
            if parent_item and parent_item.data then
                if parent_item.data.title then
                    title = parent_item.data.title
                elseif parent_item.data.filename then
                    title = parent_item.data.filename
                end
                if parent_item.data.parentItem then
                    parent_key = parent_item.data.parentItem
                    local grand = API.getItem(parent_key)
                    if grand and grand.data and grand.data.title then
                        title = grand.data.title
                    end
                end
            end
            local haystack = string.lower(text .. " " .. comment .. " " .. title .. " " .. page .. " " .. (ann_key or ""))
            if query == "" or haystack:find(query, 1, true) then
                table.insert(results, {
                    key = ann_key,
                    attachmentKey = attachment_key,
                    parentKey = parent_key,
                    parentTitle = title,
                    text = text,
                    comment = comment,
                    page = page,
                    color = ann_item.data.annotationColor,
                    version = ann_item.version,
                })
            end
        end
        row = stmt:step(row)
    end
    stmt:close()
    return results
end

-- List annotations for one attachment from the local DB (for Document panel union).
-- Returns array of { key, text, comment, page, color, version }
function API.listAttachmentAnnotations(attachment_key)
    local results = {}
    if attachment_key == nil then
        return results
    end
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_GET_ITEM_ANNOTATIONS_INFO)
    local row = stmt:bind(attachment_key):step()
    while row ~= nil do
        local ann_key = row[1]
        local ann_item = API.getItem(ann_key)
        if ann_item and ann_item.data then
            local text = ann_item.data.annotationText or ""
            local comment = ann_item.data.annotationComment or ""
            local page = ""
            if ann_item.data.annotationPageLabel then
                page = tostring(ann_item.data.annotationPageLabel)
            elseif ann_item.data.annotationPosition then
                local pos_ok, pos = pcall(JSON.decode, ann_item.data.annotationPosition)
                if pos_ok and pos and pos.pageIndex ~= nil then
                    page = tostring(pos.pageIndex + 1)
                end
            end
            table.insert(results, {
                key = ann_key,
                text = text,
                comment = comment,
                page = page,
                color = ann_item.data.annotationColor,
                version = tonumber(row[2]) or ann_item.version,
            })
        end
        row = stmt:step(row)
    end
    stmt:close()
    return results
end

return API
