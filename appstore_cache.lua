local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local ffiUtil = require("ffi/util")
local util = require("util")
local json = require("json")
local logger = require("logger")

local Cache = {}

local DB_SCHEMA_VERSION = 20241121
local DB_DIRECTORY = ffiUtil.joinPath(DataStorage:getDataDir(), "cache/appstore")
local DB_PATH = ffiUtil.joinPath(DB_DIRECTORY, "appstore.sqlite3")

local SCHEMA_STATEMENTS = {
    [[CREATE TABLE IF NOT EXISTS repos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        repo_id INTEGER NOT NULL,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        owner TEXT NOT NULL,
        full_name TEXT NOT NULL,
        description TEXT,
        stars INTEGER NOT NULL DEFAULT 0,
        language TEXT,
        homepage TEXT,
        fetched_at INTEGER NOT NULL,
        data TEXT NOT NULL,
        UNIQUE(repo_id, kind)
    );]],
    [[CREATE INDEX IF NOT EXISTS idx_repos_kind_stars ON repos(kind, stars DESC);]],
    [[CREATE TABLE IF NOT EXISTS patch_files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        repo_id INTEGER NOT NULL,
        path TEXT NOT NULL,
        filename TEXT NOT NULL,
        branch TEXT,
        sha TEXT,
        size INTEGER,
        download_url TEXT,
        fetched_at INTEGER NOT NULL,
        UNIQUE(repo_id, path)
    );]],
    [[CREATE INDEX IF NOT EXISTS idx_patch_files_repo ON patch_files(repo_id);]],
}

local initialized = false

local function ensureDirectory()
    local ok, err = util.makePath(DB_DIRECTORY)
    if not ok then
        logger.warn("appstore cache directory creation failed", err)
    end
end

local function openConnection()
    ensureDirectory()
    local conn = SQ3.open(DB_PATH)
    conn:exec("PRAGMA journal_mode = WAL;")
    conn:exec("PRAGMA synchronous = NORMAL;")
    conn:exec("PRAGMA foreign_keys = ON;")
    return conn
end

local function withConnection(fn)
    Cache.init()
    local conn = openConnection()
    local ok, result = pcall(fn, conn)
    conn:close()
    if not ok then
        error(result)
    end
    return result
end

local function normalizeString(value)
    if value == nil or value == json.null then
        return ""
    end
    return tostring(value)
end

local function normalizeNumber(value)
    if value == nil or value == json.null then
        return 0
    end
    return tonumber(value) or 0
end

function Cache.storePatchFiles(repo_id, entries)
    repo_id = tonumber(repo_id)
    if not repo_id then
        return
    end
    local fetched_at = os.time()
    withConnection(function(conn)
        conn:exec("BEGIN;")
        local delete_stmt = conn:prepare([[DELETE FROM patch_files WHERE repo_id = ?;]])
        delete_stmt:bind(repo_id)
        delete_stmt:step()
        delete_stmt:close()
        if entries and #entries > 0 then
            local insert_sql = [[INSERT INTO patch_files (repo_id, path, filename, branch, sha, size, download_url, fetched_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);]]
            local stmt = conn:prepare(insert_sql)
            for _, entry in ipairs(entries) do
                stmt:bind(
                    repo_id,
                    normalizeString(entry.path),
                    normalizeString(entry.filename),
                    normalizeString(entry.branch),
                    normalizeString(entry.sha),
                    normalizeNumber(entry.size),
                    normalizeString(entry.download_url),
                    fetched_at
                )
                stmt:step()
                stmt:reset()
            end
            stmt:close()
        end
        conn:exec("COMMIT;")
    end)
end

function Cache.listPatchFiles(repo_id)
    repo_id = tonumber(repo_id)
    if not repo_id then
        return {}
    end
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT path, filename, branch, sha, size, download_url
            FROM patch_files WHERE repo_id = ? ORDER BY filename COLLATE NOCASE;]])
        stmt:bind(repo_id)
        local dataset = stmt:resultset("hi")
        stmt:close()
        local result = {}
        if not dataset then
            return result
        end
        local headers = dataset[0]
        if not headers then
            return result
        end
        local first_column = dataset[1]
        if type(first_column) ~= "table" then
            return result
        end
        local row_count = #first_column
        for row_index = 1, row_count do
            local row = {}
            for col_index, header in ipairs(headers) do
                row[header] = dataset[col_index][row_index]
            end
            table.insert(result, row)
        end
        return result
    end)
end

function Cache.clearPatchFiles(kind)
    withConnection(function(conn)
        if kind == "plugin" then
            return -- no-op
        end
        if kind == "patch" or not kind then
            conn:exec("DELETE FROM patch_files;")
        end
    end)
end

local function execStatements(conn, statements)
    for _, statement in ipairs(statements) do
        local trimmed = util.trim(statement)
        if trimmed ~= "" then
            local final_stmt = trimmed
            if not final_stmt:find(";%s*$") then
                final_stmt = final_stmt .. ";"
            end
            local ok, err = pcall(conn.exec, conn, final_stmt)
            if not ok then
                error(string.format("appstore cache schema error: %s -- %s", final_stmt, err))
            end
        end
    end
end

function Cache.init()
    if initialized then
        return
    end
    local conn = openConnection()
    local current_version = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
    if current_version < DB_SCHEMA_VERSION then
        conn:exec("PRAGMA writable_schema = ON;")
        conn:exec("DELETE FROM sqlite_master WHERE type IN ('table','index','trigger');")
        conn:exec("PRAGMA writable_schema = OFF;")
        conn:exec("VACUUM;")
        conn:exec("PRAGMA user_version = " .. DB_SCHEMA_VERSION .. ";")
    end
    execStatements(conn, SCHEMA_STATEMENTS)
    conn:close()
    initialized = true
end

local function getOwnerLogin(owner)
    if type(owner) == "table" and owner.login then
        return tostring(owner.login)
    end
    return ""
end

function Cache.storeRepos(kind, repos)
    if not kind or type(repos) ~= "table" then
        return
    end
    local fetched_at = os.time()
    withConnection(function(conn)
        conn:exec("BEGIN;")
        local delete_stmt = conn:prepare([[DELETE FROM repos WHERE kind = ?;]])
        delete_stmt:bind(kind)
        delete_stmt:step()
        delete_stmt:close()

        local insert_sql = [[INSERT INTO repos (repo_id, kind, name, owner, full_name, description, stars, language, homepage, fetched_at, data)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);]]
        local stmt = conn:prepare(insert_sql)
        for _, repo in ipairs(repos) do
            local owner_login = getOwnerLogin(repo.owner)
            local ok, serialized = pcall(json.encode, repo)
            local encoded = ""
            if ok and type(serialized) == "string" then
                encoded = serialized
            else
                logger.warn("appstore cache encode error", serialized)
            end
            stmt:bind(
                normalizeNumber(repo.id),
                kind,
                normalizeString(repo.name),
                owner_login,
                normalizeString(repo.full_name),
                normalizeString(repo.description),
                normalizeNumber(repo.stargazers_count),
                normalizeString(repo.language),
                normalizeString(repo.homepage),
                fetched_at,
                encoded
            )
            stmt:step()
            stmt:reset()
        end
        stmt:close()
        conn:exec("COMMIT;")
    end)
end

local function decodeRow(row)
    local decoded
    if row.data and row.data ~= "" then
        local ok, parsed = pcall(json.decode, row.data)
        if ok then
            decoded = parsed
        else
            logger.warn("appstore cache decode error", parsed)
        end
    end
    return {
        repo_id = tonumber(row.repo_id),
        kind = row.kind,
        name = row.name,
        owner = row.owner,
        full_name = row.full_name,
        description = row.description,
        stars = tonumber(row.stars) or 0,
        language = row.language,
        homepage = row.homepage,
        fetched_at = tonumber(row.fetched_at) or 0,
        data = decoded,
    }
end

local function fetchRows(kind)
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT repo_id, kind, name, owner, full_name, description, stars, language, homepage, fetched_at, data
            FROM repos WHERE kind = ? ORDER BY stars DESC, name COLLATE NOCASE;]])
        stmt:bind(kind)
        local dataset = stmt:resultset("hi")
        stmt:close()
        return dataset
    end)
end

function Cache.listRepos(kind)
    kind = kind or "plugin"
    local dataset = fetchRows(kind)
    local result = {}
    if not dataset then
        return result
    end
    local headers = dataset[0]
    if not headers then
        return result
    end
    local first_column = dataset[1]
    if type(first_column) ~= "table" then
        return result
    end
    local row_count = #first_column
    if row_count == 0 then
        return result
    end
    for row_index = 1, row_count do
        local row = {}
        for col_index, header in ipairs(headers) do
            row[header] = dataset[col_index][row_index]
        end
        table.insert(result, decodeRow(row))
    end
    return result
end

function Cache.getLastFetched(kind)
    kind = kind or "plugin"
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT MAX(fetched_at) FROM repos WHERE kind = ?;]])
        stmt:bind(kind)
        local row = stmt:step()
        local value = row and row[1] or nil
        stmt:close()
        return tonumber(value)
    end)
end

function Cache.clear()
    withConnection(function(conn)
        conn:exec("DELETE FROM repos;")
    end)
end

return Cache

