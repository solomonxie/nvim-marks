--- Guided marks ("tours"): a DAG of steps through code, walked with n / p in the marks panel.
--- This file is the format only (load, check, tree order, listing); tour_panel.lua is the UI that walks it.
---
--- Files: <g:nvim_marks_dir>/<repo>/tours-<slug>.jsonl, next to marks.jsonl, one tour per file. One step per line,
--- every line the same shape; the root step, written first, also carries the tour's name and description:
---   {"id":"s1","tour":"Save flow","description":"...","title":"...","file":"src/a.lua","row":12,"line":"<exact code>","text":"explanation","children":["s2"]}
---   {"id":"s2","title":"...","file":"src/b.lua","row":40,"line":"<exact code>","text":"explanation"}
--- A file is a tour when its first line has a "tour" key; marks.jsonl and marks-log.jsonl never do.
--- `file`, `row` and `line` are an anchor like a note's (see anchor.lua), so a step finds its line after edits and in
--- any worktree; an optional `commit` (HEAD when the step was written) finds a line that was rewritten. A step may
--- have several parents. The plugin only reads tours; people or the code-walkthrough skill write them.
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

--- The order `n` walks: the tree's rows top to bottom (depth-first), and when the next step isn't a child of the
--- current one, first a stop back on its parent, so you see where the new branch starts. Ends on the last step:
---   A─┬─B─┬─D        A B D B E A C
---     │   └─E
---     └─C
--- Going back isn't a new step: each stop carries the index of its row in M.tree(tour) (`row`), and `back=true`
--- when it revisits a step.
---
--- @return table[] # [{row, back}] where row indexes the list M.tree(tour) returns
function M.walk(tour, tree)
    tree = tree or M.tree(tour)
    local walk, parent_row, at_depth = {}, {}, {}
    for i, r in ipairs(tree) do
        at_depth[r.depth] = i
        parent_row[i] = r.depth > 0 and at_depth[r.depth - 1] or nil
        if i > 1 and parent_row[i] ~= i - 1 then table.insert(walk, {row=parent_row[i], back=true}) end
        table.insert(walk, {row=i})
    end
    return walk
end

--- Tour files sit next to marks.jsonl. A `tours-*.jsonl` file always counts (so a broken one shows its error);
--- any other `.jsonl` counts only if its first line is a root step (has a "tour" key). Backups and temp files (`*.bak*`, `*.tmp*`)
--- end in something else, so they're skipped.
---
--- @return table[] # every tour in the repo's store folder, sorted by name: [{name, description, path, steps_count}]
---                   plus [{path, error}] for files that didn't load, so the menu can say what's wrong
function M.list(store_dir)
    local tours = {}
    if vim.fn.isdirectory(store_dir) == 0 then return tours end
    for name, kind in vim.fs.dir(store_dir) do
        local path = store_dir .. '/' .. name
        if kind == 'file' and name:match('%.jsonl$') and not NOT_TOURS[name]
            and (name:match('^tours%-') or starts_with_root(path)) then
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

function M.test_walk()
    local tour = assert(M.load(fixture_path('tours/save-flow.jsonl')))
    local tree = M.tree(tour)
    local walk = M.walk(tour, tree)
    eq(vim.tbl_map(function(s) return tree[s.row].id .. (s.back and '<' or '') end, walk),
       {'s1', 's2', 's4', 's1<', 's3', 's5'}, 'back to the parent of the next branch, shared step once')
    -- the step number is the tree row, so walking back never goes past the number of steps
    local max_row = 0
    for _, s in ipairs(walk) do max_row = math.max(max_row, s.row) end
    eq(max_row, #tree, 'step numbers stay within 1..N')
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
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile(vim.fn.readfile(fixture_path('tours/save-flow.jsonl')), dir .. '/tours-save-flow.jsonl')
    vim.fn.writefile({'not json'}, dir .. '/tours-broken.jsonl')
    local tours = M.list(dir)
    eq(#tours, 2, 'both tour files listed')
    local ok = vim.tbl_filter(function(t) return not t.error end, tours)[1]
    eq({ok.name, ok.steps_count}, {'Save flow', 5}, 'good tour')
    eq(vim.tbl_filter(function(t) return t.error end, tours)[1].error:find('not valid JSON', 1, true) ~= nil, true, 'broken one says why')
    vim.fn.delete(dir, 'rf')
end

--- Tours sit next to the marks store: only the tour is listed, not marks.jsonl, marks-log.jsonl or a backup
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
