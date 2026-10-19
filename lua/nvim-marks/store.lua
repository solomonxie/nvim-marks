--- One JSON file per repo holds the marks and notes of all its files, shared by every worktree and branch.
---
--- Location: `<dir>/<repo>/marks-history.json`, <dir> from setup({dir=...}) or g:nvim_marks_dir, default `stdpath('data')/nvim-marks`.
--- <repo> is the folder name of the repo's main checkout, the same for all its worktrees.
--- Files are keyed by their path from the repo root, so `src/a.lua` is the same file in every worktree.
---
--- {
---   version = 2,
---   files = {
---     ['src/a.lua'] = {
---       snapshot = {lines at last save},
---       marks = {{char='a', anchor={row, line, before, after}}},
---       notes = {{text={lines}, anchor={...}}},
---       orphans = {{char='b', anchor={...}} or {text={...}, anchor={...}}},  -- not found in the current version
---     },
---   },
--- }

local M = {}

M.DEFAULT_DIR = vim.fn.stdpath('data') .. '/nvim-marks'
M.dir_option = nil  --- @type string|nil # set by setup()

local RepoCache = {}  --- @type table<string, table> # {dir={top, repo}}

--- @param path string # absolute file path
--- @return table # {top=repo root or nil, repo=string}
function M.repo_info(path)
    local dir = vim.fs.dirname(path)
    if RepoCache[dir] then return RepoCache[dir] end
    local cmd = {'git', '-C', dir, 'rev-parse', '--path-format=absolute', '--show-toplevel', '--git-common-dir'}
    local obj = vim.system(cmd, {text=true}):wait()
    local info = {top=nil, repo='_no_repo'}
    if obj.code == 0 then
        local top, common_dir = unpack(vim.split(vim.trim(obj.stdout), '\n'))
        -- The main checkout holds the common git dir (`<main>/.git`); a bare repo is the common dir itself
        local main_dir = vim.fs.basename(common_dir) == '.git' and vim.fs.dirname(common_dir) or common_dir
        info = {
            top = top,
            repo = (vim.fs.basename(main_dir):gsub('%.git$', '')),
        }
    end
    RepoCache[dir] = info
    return info
end

--- @return string # path from the repo root, or the absolute path outside a repo
function M.file_key(path, info)
    if info.top and vim.startswith(path, info.top .. '/') then
        return path:sub(#info.top + 2)
    end
    return path
end

--- @return string # store file for the repo
function M.store_path(info)
    local dir = M.dir_option or vim.g.nvim_marks_dir or M.DEFAULT_DIR
    return vim.fn.expand(dir) .. '/' .. info.repo .. '/marks-history.json'
end

--- @return table # {version=2, files={}}
function M.load(store_path)
    local f = io.open(store_path, 'r')
    if not f then return {version=2, files={}} end
    local content = f:read('*all')
    f:close()
    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= 'table' then
        vim.notify('nvim-marks: cannot read ' .. store_path, vim.log.levels.WARN)
        return {version=2, files={}}
    end
    data.files = data.files or {}
    return data
end

--- Write to a temp file then rename, so a crash or another nvim never leaves half a file
function M.save(store_path, data)
    vim.fn.mkdir(vim.fs.dirname(store_path), 'p')
    local tmp_path = store_path .. '.tmp' .. vim.fn.getpid()
    local f = io.open(tmp_path, 'w')
    if not f then
        vim.notify('nvim-marks: cannot write ' .. store_path, vim.log.levels.WARN)
        return
    end
    f:write(vim.json.encode(data))
    f:close()
    os.rename(tmp_path, store_path)
end

--- Read marks saved by the old version (`<repo>/.git/persistent_marks/<project>/<a__b.lua>.json`), rows only
---
--- @return table|nil # {marks={{char, row}}, notes={{text, row}}}
function M.load_legacy(info, key)
    if not info.top then return nil end
    local flat_name = key:gsub('/', '__')
    local legacy_path = string.format('%s/.git/persistent_marks/%s/%s.json', info.top, vim.fs.basename(info.top), flat_name)
    local data = M.load(legacy_path)
    if data.vimmarks == nil and data.notes == nil then return nil end
    local legacy = {marks={}, notes={}}
    for _, item in ipairs(data.vimmarks or {}) do
        table.insert(legacy.marks, {char=item[1], row=item[2]})
    end
    for _, item in ipairs(data.notes or {}) do
        local text = {}
        for _, chunks in ipairs(item[4] or {}) do table.insert(text, chunks[1] and chunks[1][1] or '') end
        table.insert(legacy.notes, {text=text, row=item[2]})
    end
    return legacy
end


--- Tests: `nvim -l tests/run.lua`
local function eq(actual, expected, msg)
    assert(vim.deep_equal(actual, expected), string.format('%s: expected %s, got %s', msg, vim.inspect(expected), vim.inspect(actual)))
end

function M.test_store_path()
    local info = {top='/w/myapp-fix', repo='myapp'}
    M.dir_option = '/marks'
    eq(M.store_path(info), '/marks/myapp/marks-history.json', 'dir')
    M.dir_option = nil
end

function M.test_file_key()
    local info = {top='/w/myapp'}
    eq(M.file_key('/w/myapp/src/a.lua', info), 'src/a.lua', 'inside repo')
    eq(M.file_key('/other/b.lua', info), '/other/b.lua', 'outside repo')
end

return M
