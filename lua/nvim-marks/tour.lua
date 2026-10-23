--- Guided marks ("tours"): a DAG of steps through code, walked with n / p in the marks panel.
--- This file is the format only (load, check, tree order, listing); tour_panel.lua is the UI that walks it.
---
--- Files: <g:nvim_marks_dir>/<repo>/<worktree>/tours-<slug>.jsonl, in the worktree's work-files folder (`main` for
--- the main checkout), one tour per file; older tours sit flat next to marks.jsonl. One step per line,
--- every line the same shape; the root step, written first, also carries the tour's name and description:
---   {"id":"s1","tour":"Save flow","description":"...","title":"...","file":"src/a.lua","row":12,"line":"<exact code>","text":"explanation","children":["s2"]}
---   {"id":"s2","title":"...","file":"src/b.lua","row":40,"line":"<exact code>","text":"explanation"}
--- A file is a tour when its first line has a "tour" key; marks.jsonl and marks-log.jsonl never do.
--- `file`, `row` and `line` are an anchor like a note's (see anchor.lua), so a step finds its line after edits and in
--- any worktree; an optional `commit` (HEAD when the step was written) finds a line that was rewritten. A step may
--- have several parents. The plugin only reads tours; people or the code-walkthrough skill write them.
--- The root step may also carry `info`: anything that helps find the code again, shown below the tree, e.g.
---   "info":{"worktree":"myapp-fix-login","branch":"fix/login","commit":"a2b6ce6f1d3e","pr":"https://github.com/...",
---           "jira":"https://....atlassian.net/browse/ENG-1"}
--- Any keys, string values; a value that is a URL can be opened from the panel.
--- (Earlier tours had a header line `{"tour":..., "description":..., "root":"s1"}` instead; still read.)
---
--- Walk order: the tree's order, depth-first, each step once (`n` goes down the numbered rows of the panel).
--- A step with several parents is shown once, under the first parent that reaches it.

local M = {}

--- Files in the repo's store folder that are never tours
local NOT_TOURS = {['marks.jsonl']=true, ['marks-log.jsonl']=true}

--- @return boolean # the file's first line has a "tour" key (the root step)
local function starts_with_root(path)
    local f = io.open(path, 'r')
    if not f then return false end
    local first = f:read('*l')
    f:close()
    local ok, header = pcall(vim.json.decode, first or '')
    return ok and type(header) == 'table' and header.tour ~= nil
end

--- @return table|nil, string|nil # tour {name, description, root, steps={id=step}, order={ids}, path}, or nil and an error
function M.load(path)
    local f = io.open(path, 'r')
    if not f then return nil, 'cannot read ' .. path end
    local root_step, header, steps, order = nil, nil, {}, {}
    local n = 0
    for line in f:lines() do
        n = n + 1
        if vim.trim(line) ~= '' then
            local ok, record = pcall(vim.json.decode, line)
            if not ok or type(record) ~= 'table' then
                f:close()
                return nil, string.format('%s:%d: not valid JSON', path, n)
            end
            if not record.id and record.tour and n == 1 then
                header = record  -- earlier format: a header line before the steps
            else
                if not record.id then f:close(); return nil, string.format('%s:%d: step without an id', path, n) end
                if steps[record.id] then f:close(); return nil, string.format('%s:%d: duplicate id %s', path, n, record.id) end
                if record.tour then
                    if root_step then f:close(); return nil, string.format('%s:%d: a second root step ("tour" key)', path, n) end
                    root_step = record
                end
                record.children = record.children or {}
                steps[record.id] = record
                table.insert(order, record.id)
            end
        end
    end
    f:close()
    local root
    if header then
        root = header.root or order[1]
        if not steps[root] then return nil, path .. ': root step ' .. tostring(root) .. ' not found' end
    elseif root_step then
        header, root = root_step, root_step.id
    else
        return nil, path .. ': no root step (the step with a "tour" key)'
    end
    for _, id in ipairs(order) do
        for _, child in ipairs(steps[id].children) do
            if not steps[child] then return nil, string.format('%s: step %s has unknown child %s', path, id, child) end
        end
    end
    local cycle = M.find_cycle(steps, root)
    if cycle then return nil, path .. ': cycle through ' .. table.concat(cycle, ' → ') end
    local info = type(header.info) == 'table' and header.info or {}
    return {name=header.tour, description=header.description or '', info=info, created=header.created,
            root=root, steps=steps, order=order, path=path}
end

--- @return string[]|nil # the ids of a cycle reachable from `root`, or nil
function M.find_cycle(steps, root)
    local state, stack = {}, {}  -- state: nil unvisited, 1 on the stack, 2 done
    local function visit(id)
        state[id] = 1
        table.insert(stack, id)
        for _, child in ipairs(steps[id].children or {}) do
            if state[child] == 1 then
                local cycle, started = {}, false
                for _, s in ipairs(stack) do
                    if s == child then started = true end
                    if started then table.insert(cycle, s) end
                end
                table.insert(cycle, child)
                return cycle
            elseif state[child] == nil then
                local found = visit(child)
                if found then return found end
            end
        end
        table.remove(stack)
        state[id] = 2
        return nil
    end
    return visit(root)
end

--- The tree as shown in the panel: each step once, in first-seen order, with its depth
---
--- @return table[] # [{id, depth, shared=true when it has more than one parent}]
function M.tree(tour)
    local rows, shown, parents = {}, {}, {}
    for _, id in ipairs(tour.order) do
        for _, child in ipairs(tour.steps[id].children) do parents[child] = (parents[child] or 0) + 1 end
    end
    local function visit(id, depth)
        if shown[id] then return end
        shown[id] = true
        table.insert(rows, {id=id, depth=depth, shared=(parents[id] or 0) > 1})
        for _, child in ipairs(tour.steps[id].children) do visit(child, depth + 1) end
    end
    visit(tour.root, 0)
    return rows
end

--- Tours live in the work-files folders: `<dir>/<repo>/<worktree>/...`, one folder per worktree (`main` for the main
--- checkout), nested folders included; older ones sit flat in `<dir>/<repo>/`. A `tours-*.jsonl` file always counts
--- (so a broken one shows its error); any other `.jsonl` counts only if its first line is a root step (has a "tour"
--- key). Backups and temp files (`*.bak*`, `*.tmp*`) end in something else, so they're skipped.
---
--- @param dir string # the folder to search, with everything under it
--- @return table[] # every tour under `dir`, most recent first: [{name, description, path, folder, steps_count, created}]
---                   plus [{path, error}] for files that didn't load, so the menu can say what's wrong
function M.list(dir)
    local tours = {}
    if vim.fn.isdirectory(dir) == 0 then return tours end
    for rel, kind in vim.fs.dir(dir, {depth=6}) do
        local name = vim.fs.basename(rel)
        local path = dir .. '/' .. rel
        if kind == 'file' and name:match('%.jsonl$') and not NOT_TOURS[name]
            and (name:match('^tours%-') or starts_with_root(path)) then
            local folder = vim.fs.dirname(rel) == '.' and '' or vim.fs.dirname(rel)
            local tour, err = M.load(path)
            -- when it was made: the root step's `created`, else the file's birth time (both UTC text, sort by time)
            local stat = vim.uv.fs_stat(path)
            local born = stat and os.date('!%Y-%m-%dT%H:%M:%SZ', (stat.birthtime.sec > 0 and stat.birthtime or stat.mtime).sec) or ''
            if tour then
                table.insert(tours, {name=tour.name, description=tour.description, path=path, folder=folder,
                                     steps_count=#tour.order, created=tour.created or born})
            else
                table.insert(tours, {name=name, path=path, folder=folder, error=err, created=born})
            end
        end
    end
    table.sort(tours, function(a, b)  -- most recent first
        if a.created ~= b.created then return a.created > b.created end
        return a.name < b.name
    end)
    return tours
end

--- The scopes around a row, innermost first, as row ranges: the enclosing functions, classes and blocks from
--- treesitter when the buffer has a parser, otherwise from indentation (each less-indented line above that opens a
--- block). Used to tell whether a step is "in the same function" as the cursor.
---
--- @param bufnr integer # a loaded buffer
--- @param row integer # 1-indexed
--- @return table[] # [{first, last}], 1-indexed, innermost first; empty at the top level
function M.scopes_at(bufnr, row)
    local scopes = {}
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if ok and parser then
        parser:parse()
        local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
        local col = #line:match('^%s*')
        local node = vim.treesitter.get_node({bufnr=bufnr, pos={row - 1, col}, ignore_injections=false})
        while node do
            local first, _, last = node:range()
            local kind = node:type()
            -- function / method / class / block-ish nodes spanning more than one line
            if last > first and (kind:find('function') or kind:find('method') or kind:find('class')
                or kind:find('arrow') or kind:find('lambda') or kind:find('def')) then
                table.insert(scopes, {first + 1, last + 1})
            end
            node = node:parent()
        end
        if #scopes > 0 then return scopes end
    end
    -- indentation: walk up to each line with less indent, its block runs until indent drops back to it or below
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local function indent(i) return #(lines[i]:match('^%s*')) end
    local function blank(i) return vim.trim(lines[i]) == '' end
    local function closer(i) return lines[i]:match('^%s*end%f[%W]') or vim.trim(lines[i]):match('^[%]%)}]') end
    local current = blank(row) and math.huge or indent(row)
    if not blank(row) and closer(row) then current = current + 1 end  -- a block's `end` / `}` is inside the block
    for i = row - 1, 1, -1 do
        if not blank(i) and indent(i) < current then
            current = indent(i)
            local last = i
            for j = i + 1, #lines do
                if not blank(j) then
                    if indent(j) <= current then break end
                    last = j
                end
            end
            -- the closing `end` / `}` at the opener's indent belongs to the block
            if lines[last + 1] and indent(last + 1) == current and closer(last + 1) then last = last + 1 end
            if last > i then table.insert(scopes, {i, last}) end
            if current == 0 then break end
        end
    end
    return scopes
end

--- The step of a tour that best matches a line: the step on that line, or else a step inside the innermost function
--- or block around the line (the closest one to it). Steps in other files never match.
---
--- @param tour table # from M.load
--- @param key string # the file's path from the repo root (as tour steps write it), or its absolute path
--- @param row integer # the line, 1-indexed
--- @param scopes table[] # from M.scopes_at, innermost first
--- @return string|nil, string|nil # step id and how it matched ('line' or 'scope'), nil when nothing matches
function M.match_step(tour, key, row, scopes, abs_path)
    local best, best_rank, best_dist, how = nil, math.huge, math.huge, nil
    for _, id in ipairs(tour.order) do
        local step = tour.steps[id]
        local same_file = step.file == key or (abs_path and step.file == abs_path)
        if same_file and step.row then
            local rank, kind
            if step.row == row then
                rank, kind = 0, 'line'
            else
                for depth, sc in ipairs(scopes) do
                    if step.row >= sc[1] and step.row <= sc[2] then rank, kind = depth, 'scope'; break end
                end
            end
            local dist = math.abs(step.row - row)
            if rank and (rank < best_rank or (rank == best_rank and dist < best_dist)) then
                best, best_rank, best_dist, how = id, rank, dist, kind
            end
        end
    end
    return best, how
end

--- Rewrite one step of a tour file in place (its line only), re-reading the file first so edits made meanwhile by
--- hand or by an LLM are kept. Used when a step's line was found at a new row or with new text.
---
--- @param fields table # e.g. {row=12, line='...', commit='a2b6ce6f1d3e'}
--- @return boolean # whether the file was written
function M.update_step(path, id, fields)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then return false end
    for i, text in ipairs(lines) do
        local decoded, record = pcall(vim.json.decode, text, {luanil={object=true, array=true}})
        if decoded and type(record) == 'table' and record.id == id then
            local changed = false
            for k, v in pairs(fields) do
                if record[k] ~= v then record[k], changed = v, true end
            end
            if not changed then return false end
            -- the same key order the line had, new keys at the end
            local order, seen = {}, {}
            for key in text:gmatch('"([%w_]+)"%s*:') do
                if record[key] ~= nil and not seen[key] then table.insert(order, key); seen[key] = true end
            end
            for k in pairs(record) do if not seen[k] then table.insert(order, k) end end
            local parts = {}
            for _, k in ipairs(order) do table.insert(parts, vim.json.encode(k) .. ':' .. vim.json.encode(record[k])) end
            lines[i] = '{' .. table.concat(parts, ',') .. '}'
            local tmp = path .. '.tmp' .. vim.fn.getpid()
            vim.fn.writefile(lines, tmp)
            return os.rename(tmp, path) ~= nil
        end
    end
    return false
end

return M
