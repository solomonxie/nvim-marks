--- Guided marks ("tours"): a DAG of steps through code, walked with n / p in the marks panel.
---
--- Files: <g:nvim_marks_dir>/<repo>/tours/*.jsonl, one tour per file. Line 1 is the header, then one step per line:
---   {"tour":"Save flow","description":"...","root":"s1"}
---   {"id":"s1","title":"...","file":"src/a.lua","row":12,"line":"<exact code>","text":"explanation","children":["s2"]}
--- `file`, `row` and `line` are an anchor like a note's (see anchor.lua), so a step finds its line after edits and in
--- any worktree. A step may have several parents. The plugin only reads tours; people or the code-walkthrough
--- skill write them.
---
--- Walk order: depth-first, and after a leaf it walks back up one step at a time instead of jumping to the next
--- branch, ending back at the root:  A─┬─B─┬─D  →  A B D B E B A C A
---                                     │   └─E
---                                     └─C
--- A step reached again through another parent is shown, but its children aren't walked again.

local M = {}

M.DIR_NAME = 'tours'

--- @return table|nil, string|nil # tour {name, description, root, steps={id=step}, order={ids}, path}, or nil and an error
function M.load(path)
    local f = io.open(path, 'r')
    if not f then return nil, 'cannot read ' .. path end
    local header, steps, order = nil, {}, {}
    local n = 0
    for line in f:lines() do
        n = n + 1
        if vim.trim(line) ~= '' then
            local ok, record = pcall(vim.json.decode, line)
            if not ok or type(record) ~= 'table' then
                f:close()
                return nil, string.format('%s:%d: not valid JSON', path, n)
            end
            if header == nil then
                if not record.tour then f:close(); return nil, path .. ':1: first line must be the header ({"tour": ...})' end
                header = record
            else
                if not record.id then f:close(); return nil, string.format('%s:%d: step without an id', path, n) end
                if steps[record.id] then f:close(); return nil, string.format('%s:%d: duplicate id %s', path, n, record.id) end
                record.children = record.children or {}
                steps[record.id] = record
                table.insert(order, record.id)
            end
        end
    end
    f:close()
    if header == nil then return nil, path .. ': empty' end
    local root = header.root or order[1]
    if not steps[root] then return nil, path .. ': root step ' .. tostring(root) .. ' not found' end
    for _, id in ipairs(order) do
        for _, child in ipairs(steps[id].children) do
            if not steps[child] then return nil, string.format('%s: step %s has unknown child %s', path, id, child) end
        end
    end
    local cycle = M.find_cycle(steps, root)
    if cycle then return nil, path .. ': cycle through ' .. table.concat(cycle, ' → ') end
    return {name=header.tour, description=header.description or '', root=root, steps=steps, order=order, path=path}
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

--- Every step of the walk, in order
---
--- @return table[] # [{id, depth, back=true when returning to a step already shown, seen=true for a repeat via another parent}]
function M.walk(tour)
    local walk, expanded = {}, {}
    local function visit(id, depth)
        if expanded[id] then
            table.insert(walk, {id=id, depth=depth, seen=true})
            return
        end
        expanded[id] = true
        table.insert(walk, {id=id, depth=depth})
        for _, child in ipairs(tour.steps[id].children) do
            visit(child, depth + 1)
            table.insert(walk, {id=id, depth=depth, back=true})  -- unwind one step after each child
        end
    end
    visit(tour.root, 0)
    return walk
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

--- @return table[] # every tour in the repo's tours folder, sorted by name: [{name, description, path, steps_count}]
---                   plus [{path, error}] for files that didn't load, so the menu can say what's wrong
function M.list(store_dir)
    local dir = store_dir .. '/' .. M.DIR_NAME
    local tours = {}
    if vim.fn.isdirectory(dir) == 0 then return tours end
    for name, kind in vim.fs.dir(dir) do
        if kind == 'file' and name:match('%.jsonl$') then
            local path = dir .. '/' .. name
            local tour, err = M.load(path)
            if tour then
                table.insert(tours, {name=tour.name, description=tour.description, path=path, steps_count=#tour.order})
            else
                table.insert(tours, {name=name, path=path, error=err})
            end
        end
    end
    table.sort(tours, function(a, b) return a.name < b.name end)
    return tours
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
end

function M.test_walk_unwinds_and_skips_shared_children()
    local tour = assert(M.load(fixture_path('tours/save-flow.jsonl')))
    local function show(w)
        local tag = w.back and '<' or (w.seen and '=' or '')
        return tag .. w.id
    end
    -- s1 ─┬─ s2 ── s4          s4 has two parents: shown again under s3 as seen, not walked twice
    --     └─ s3 ─┬─ s4
    --            └─ s5
    eq(vim.tbl_map(show, M.walk(tour)), {'s1', 's2', 's4', '<s2', '<s1', 's3', '=s4', '<s3', 's5', '<s3', '<s1'}, 'walk order')
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
    check({'{"tour":"t","root":"a"}', '{"id":"a","children":["b"]}', '{"id":"b","children":["a"]}'}, 'cycle through a → b → a')
    check({'{"tour":"t","root":"a"}', '{"id":"a","children":["zz"]}'}, 'unknown child zz')
    check({'{"id":"a"}'}, 'first line must be the header')
    check({'{"tour":"t","root":"nope"}', '{"id":"a"}'}, 'root step nope not found')
    check({'{"tour":"t"}', '{"id":"a"}', '{"id":"a"}'}, 'duplicate id a')
    vim.fn.delete(tmp)
end

function M.test_list()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/tours', 'p')
    vim.fn.writefile(vim.fn.readfile(fixture_path('tours/save-flow.jsonl')), dir .. '/tours/save-flow.jsonl')
    vim.fn.writefile({'not json'}, dir .. '/tours/broken.jsonl')
    local tours = M.list(dir)
    eq(#tours, 2, 'both files listed')
    local ok = vim.tbl_filter(function(t) return not t.error end, tours)[1]
    eq({ok.name, ok.steps_count}, {'Save flow', 5}, 'good tour')
    eq(vim.tbl_filter(function(t) return t.error end, tours)[1].error:find('not valid JSON', 1, true) ~= nil, true, 'broken one says why')
    vim.fn.delete(dir, 'rf')
end

return M
