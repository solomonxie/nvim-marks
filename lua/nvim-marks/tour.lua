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
    return {name=header.tour, description=header.description or '', info=info, root=root, steps=steps, order=order, path=path}
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
--- @return table[] # every tour under `dir`, sorted by folder then name: [{name, description, path, folder, steps_count}]
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
            if tour then
                table.insert(tours, {name=tour.name, description=tour.description, path=path, folder=folder, steps_count=#tour.order})
            else
                table.insert(tours, {name=name, path=path, folder=folder, error=err})
            end
        end
    end
    table.sort(tours, function(a, b)
        if a.folder ~= b.folder then return a.folder < b.folder end
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

--- Tests: `nvim -l tests/run.lua`
local function fixture_path(name)
    return vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/../../tests/fixtures/' .. name
end

local function eq(actual, expected, msg)
    assert(vim.deep_equal(actual, expected), string.format('%s: expected %s, got %s', msg, vim.inspect(expected), vim.inspect(actual)))
end

function M.test_load()
    local tour = assert(M.load(fixture_path('tours/save-flow.jsonl')))
    eq(tour.name, 'Save flow', 'name')
    eq(tour.root, 's1', 'root')
    eq(#tour.order, 5, 'steps')
    eq(tour.steps.s3.children, {'s4', 's5'}, 'children')
    eq(tour.info, {}, 'no info: empty')
    -- earlier format, a header line before the steps
    local tmp = vim.fn.tempname() .. '.jsonl'
    vim.fn.writefile({'{"tour":"Old","description":"d","root":"b"}', '{"id":"a"}', '{"id":"b","children":["a"]}'}, tmp)
    local old = assert(M.load(tmp))
    eq({old.name, old.description, old.root, #old.order}, {'Old', 'd', 'b', 2}, 'header line still read')
    vim.fn.delete(tmp)
end

function M.test_tree()
    local tour = assert(M.load(fixture_path('tours/save-flow.jsonl')))
    eq(vim.tbl_map(function(r) return string.rep(' ', r.depth) .. r.id .. (r.shared and '*' or '') end, M.tree(tour)),
       {'s1', ' s2', '  s4*', ' s3', '  s5'}, 'each step once, shared marked')
end

function M.test_rejects_bad_tours()
    local tmp = vim.fn.tempname() .. '.jsonl'
    local function check(lines, want)
        vim.fn.writefile(lines, tmp)
        local tour, err = M.load(tmp)
        assert(tour == nil and err and err:find(want, 1, true), 'expected error with "' .. want .. '", got ' .. tostring(err))
    end
    check({'{"id":"a","tour":"t","children":["b"]}', '{"id":"b","children":["a"]}'}, 'cycle through a → b → a')
    check({'{"id":"a","tour":"t","children":["zz"]}'}, 'unknown child zz')
    check({'{"id":"a"}'}, 'no root step')
    check({'{"id":"a","tour":"t"}', '{"id":"b","tour":"u"}'}, 'a second root step')
    check({'{"tour":"t","root":"nope"}', '{"id":"a"}'}, 'root step nope not found')
    check({'{"id":"a","tour":"t"}', '{"id":"a"}'}, 'duplicate id a')
    vim.fn.delete(tmp)
end

function M.test_list()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/myapp-fix/notes', 'p')
    vim.fn.writefile(vim.fn.readfile(fixture_path('tours/save-flow.jsonl')), dir .. '/myapp-fix/notes/tours-nested.jsonl')
    local nested = M.list(dir)
    eq({#nested, nested[1].folder}, {1, 'myapp-fix/notes'}, 'nested in a worktree folder, folder kept')
    vim.fn.delete(dir .. '/myapp-fix', 'rf')
    vim.fn.writefile(vim.fn.readfile(fixture_path('tours/save-flow.jsonl')), dir .. '/tours-save-flow.jsonl')
    vim.fn.writefile({'not json'}, dir .. '/tours-broken.jsonl')
    local tours = M.list(dir)
    eq(#tours, 2, 'both tour files listed')
    local ok = vim.tbl_filter(function(t) return not t.error end, tours)[1]
    eq({ok.name, ok.steps_count}, {'Save flow', 5}, 'good tour')
    eq(vim.tbl_filter(function(t) return t.error end, tours)[1].error:find('not valid JSON', 1, true) ~= nil, true, 'broken one says why')
    vim.fn.delete(dir, 'rf')
end

--- A line matches the tour step on it, or else a step in the same function (innermost first, then the closest)
function M.test_match_step()
    local tour = assert(M.load(fixture_path('tours/save-flow.jsonl')))
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.fn.readfile(fixture_path('v1.lua')))
    local function match(row) return {M.match_step(tour, 'v1.lua', row, M.scopes_at(bufnr, row))} end
    -- steps: s1 row 1, s2 row 5 (encode), s4 row 6 (inside encode), s3 row 8 (save), s5 row 10 (inside save)
    eq(match(10), {'s5', 'line'}, 'the step on this line')
    eq(match(11), {'s5', 'scope'}, 'a line of save(): the closest step in that function')
    eq(match(9), {'s3', 'scope'}, 'equally close: the earlier step')
    eq(match(7), {'s4', 'scope'}, 'the `end` of encode() belongs to it')
    eq(match(3), {}, 'top-level line with no step on it: no match')
    eq({M.match_step(tour, 'other.lua', 10, {})}, {}, 'another file: no match')
    vim.api.nvim_buf_delete(bufnr, {force=true})
end

--- Tours share the repo's folder with the marks store: only the tour is listed, not marks.jsonl, marks-log.jsonl or a backup

--- A found step's new row and text are written back to its own line; other lines and edits made meanwhile stay
function M.test_update_step()
    local tmp = vim.fn.tempname() .. '.jsonl'
    local lines = vim.fn.readfile(fixture_path('tours/save-flow.jsonl'))
    vim.fn.writefile(lines, tmp)
    eq(M.update_step(tmp, 's3', {row=11, line='local function save(data)'}), true, 'written')
    local after = vim.fn.readfile(tmp)
    eq(#after, #lines, 'same number of lines')
    eq(after[1], lines[1], 'other steps untouched')
    local s3 = vim.json.decode(after[3])
    eq({s3.id, s3.row, s3.title, s3.children}, {'s3', 11, 'save', {'s4', 's5'}}, 'row updated, rest kept')
    eq(after[3]:match('^{"id":"s3","title"') ~= nil, true, 'key order kept')
    eq(M.update_step(tmp, 's3', {row=11}), false, 'no change: not written')
    vim.fn.delete(tmp)
end
function M.test_list_skips_marks_files()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile({'{"id":"a1","file":"x.lua","kind":"note","text":"q","row":1,"line":"x"}'}, dir .. '/marks.jsonl')
    vim.fn.writefile({'{"ts":"2026-10-21T00:00:00Z","op":"add","id":"a1","file":"x.lua"}'}, dir .. '/marks-log.jsonl')
    vim.fn.writefile({'{"id":"a1"}'}, dir .. '/marks.jsonl.bak-20261021')
    vim.fn.writefile(vim.fn.readfile(fixture_path('tours/save-flow.jsonl')), dir .. '/tours-save-flow.jsonl')
    vim.fn.writefile(vim.fn.readfile(fixture_path('tours/save-flow.jsonl')), dir .. '/my-walk.jsonl')
    local names = vim.tbl_map(function(t) return vim.fs.basename(t.path) end, M.list(dir))
    table.sort(names)
    eq(names, {'my-walk.jsonl', 'tours-save-flow.jsonl'}, 'tours only, by name or by header')
    vim.fn.delete(dir, 'rf')
end

return M
