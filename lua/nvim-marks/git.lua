--- Git questions the plugin asks about a checkout: which repo and worktree a file is in, HEAD, a file as it was at a
--- commit, whether a commit is in HEAD's history, and files renamed since a commit. Answers are cached per repo.

local M = {}

M.COMMIT_LEN = 12  -- git lengthens its own short hashes as a repo grows, 7 can turn ambiguous
local WorktreeCache = {}  --- @type table<string, string[]> # {root={worktree root, ...}}

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
        info = {top=top, repo=M.repo_name(top, common_dir)}
    end
    RepoCache[dir] = info
    return info
end

--- Name of a repo, the same in every worktree: the folder name of its main checkout
---
--- @param top string # this checkout's root
--- @param common_dir string # git dir shared by all worktrees
function M.repo_name(top, common_dir)
    if vim.fs.basename(common_dir) == '.git' then
        return vim.fs.basename(vim.fs.dirname(common_dir))  -- `<main>/.git`
    end
    if vim.fs.basename(common_dir):match('^%.') then
        return vim.fs.basename(top)  -- separate git dir like `~/.dot.git` for `~/dot`: name it after the checkout
    end
    return (vim.fs.basename(common_dir):gsub('%.git$', ''))  -- bare repo `myapp.git`
end

--- @return string[] # roots of every worktree of the git repo at `root` (empty when it isn't one)
function M.worktrees(root)
    if WorktreeCache[root] then return WorktreeCache[root] end
    local roots = {}
    local obj = vim.system({'git', '-C', root, 'worktree', 'list', '--porcelain'}, {text=true}):wait()
    if obj.code == 0 then
        for _, line in ipairs(vim.split(obj.stdout, '\n')) do
            local wt = line:match('^worktree (.+)')
            if wt then table.insert(roots, vim.fn.resolve(wt)) end
        end
    end
    WorktreeCache[root] = roots
    return roots
end

local HeadCache = {}  --- @type table<string, table> # {top={commit, at}}: HEAD, read again after HEAD_TTL_NS
local HEAD_TTL_NS = 2e9
local FileAtCommit = {}  --- @type table<string, string[]|false> # {'top|commit|file'=lines}, a commit never changes
local RenameCache = {}  --- @type table<string, table> # {'top|commit|head'={old path=new path}}

--- @param top string|nil # repo root
--- @return string|nil # HEAD, short; nil outside a git repo (e.g. work files), or before the first commit
function M.head_commit(top)
    if not top then return nil end
    local now = vim.uv.hrtime()
    local cached = HeadCache[top]
    if cached and now - cached.at < HEAD_TTL_NS then return cached.commit or nil end
    local obj = vim.system({'git', '-C', top, 'rev-parse', '--show-toplevel', 'HEAD'}, {text=true}):wait()
    local commit = false
    if obj.code == 0 then
        local toplevel, head = unpack(vim.split(vim.trim(obj.stdout), '\n'))
        -- A folder inside another repo (the work-files folder in a dotfiles repo): paths aren't from that repo's root
        if vim.fn.resolve(toplevel) == vim.fn.resolve(top) and head then commit = head:sub(1, M.COMMIT_LEN) end
    end
    HeadCache[top] = {commit=commit, at=now}
    return commit or nil
end

--- @return string[]|nil # the file's lines at `commit`, nil when the commit is gone (rebased away) or hadn't the file
function M.file_at_commit(top, commit, file)
    local key = top .. '|' .. commit .. '|' .. file
    if FileAtCommit[key] == nil then
        local obj = vim.system({'git', '-C', top, 'show', commit .. ':' .. file}, {text=true}):wait()
        FileAtCommit[key] = obj.code == 0 and vim.split(obj.stdout:gsub('\n$', ''), '\n', {plain=true}) or false
    end
    return FileAtCommit[key] or nil
end

local AncestorCache = {}  --- @type table<string, boolean> # {'top|commit|head'=is ancestor}

--- @return boolean # `commit` is in HEAD's history. A note saved on another branch isn't: its line may still be there,
---                   so it stays an orphan instead of being moved by a diff against an unrelated version
function M.is_ancestor(top, commit)
    local head = M.head_commit(top)
    if not head then return false end
    local key = top .. '|' .. commit .. '|' .. head
    if AncestorCache[key] == nil then
        local obj = vim.system({'git', '-C', top, 'merge-base', '--is-ancestor', commit, 'HEAD'}):wait()
        AncestorCache[key] = obj.code == 0
    end
    return AncestorCache[key]
end

--- @return table<string, string> # {old path=new path} for files renamed since `commit`, up to the working tree
function M.renames_since(top, commit)
    local key = top .. '|' .. commit .. '|' .. (M.head_commit(top) or '')
    if RenameCache[key] then return RenameCache[key] end
    local renames = {}
    local obj = vim.system({'git', '-C', top, 'diff', '-M', '--name-status', '--diff-filter=R', commit, '--'}, {text=true}):wait()
    if obj.code == 0 then
        for _, line in ipairs(vim.split(obj.stdout, '\n')) do
            local old, new = line:match('^R%d*\t([^\t]+)\t([^\t]+)$')
            if old then renames[old] = new end
        end
    end
    RenameCache[key] = renames
    return renames
end

return M
