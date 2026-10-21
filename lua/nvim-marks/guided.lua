--- Guided mode: walk a tour step by step. The marks panel shows the tour's tree (▶ on the current step) and the
--- step's explanation; the code window above jumps to each step's line and highlights it.
--- Keys in the panel: n next, p previous, <CR> jump to the step under the cursor, q / Ctrl-c leave.

local M = {}

local tour_lib = require('nvim-marks.tour')
local anchor = require('nvim-marks.anchor')
local utils = require('nvim-marks.utils')

local NS = vim.api.nvim_create_namespace('nvim-marks.guided')
local State = nil  --- @type table|nil # {tour, walk, pos, code_win, panel_buf, origin_bufnr, rows={panel row = step id}}

--- Find a step's line in its file now (it may have moved since the tour was written)
---
--- @return string|nil, integer|nil # path, row (nil when the file isn't in any checkout)
local function locate(step)
    local path, exists = utils.resolve_file(step.file, State.origin_bufnr)
    if not exists then return nil, nil end
    local lines = vim.fn.readfile(path)
    local row = step.line and anchor.locate({row=step.row or 1, line=step.line, above=step.above or {}, below=step.below or {}}, lines)
    return path, row or step.row or 1
end

--- Show the step in the code window: open its file, put the cursor on its line, center and highlight it
local function show_code(step)
    local path, row = locate(step)
    if not path then
        vim.api.nvim_echo({{'Not found in any checkout: ' .. step.file, 'WarningMsg'}}, false, {})
        return
    end
    vim.api.nvim_win_call(State.code_win, function()
        if vim.fn.resolve(vim.api.nvim_buf_get_name(0)) ~= vim.fn.resolve(path) then
            vim.cmd('edit ' .. vim.fn.fnameescape(path))
        end
        local bufnr = vim.api.nvim_get_current_buf()
        row = math.min(row, vim.api.nvim_buf_line_count(bufnr))
        vim.api.nvim_win_set_cursor(0, {row, 0})
        vim.cmd('normal! zz')
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_clear_namespace(b, NS, 0, -1) end
        end
        vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, 0, {line_hl_group='Visual', sign_text='▶', sign_hl_group='Title'})
    end)
end

--- @return string[], table, table # panel lines, {row = step id}, highlights [{row, col, end_col, group}]
local function render()
    local tour, walk = State.tour, State.walk
    local here = walk[State.pos]
    local visited = {}
    for i = 1, State.pos do visited[walk[i].id] = true end
    local lines, rows, hls = {''}, {}, {}
    local status = State.pos == #walk and 'end of tour' or ('step ' .. State.pos .. '/' .. #walk)
    table.insert(lines, '# ' .. tour.name .. ' · ' .. status)
    if tour.description ~= '' then table.insert(lines, tour.description) end
    table.insert(lines, '')
    local tree = tour_lib.tree(tour)
    local number_width = #tostring(#tree)
    for i, r in ipairs(tree) do
        local step = tour.steps[r.id]
        local marker = r.id == here.id and '▶' or ' '
        local number = string.rep(' ', number_width - #tostring(i)) .. i .. '.'
        local indent = r.depth > 0 and (string.rep('   ', r.depth - 1) .. '└─ ') or ''
        local location = vim.fs.basename(step.file or '') .. ':' .. tostring(step.row or '?')
        table.insert(lines, string.format('%s %s %s%s%s   %s', marker, number, indent, step.title or r.id, r.shared and ' (shared)' or '', location))
        rows[#lines] = r.id
        if r.id ~= here.id and visited[r.id] then
            table.insert(hls, {#lines, 0, -1, 'Comment'})  -- already seen
        elseif r.id == here.id then
            table.insert(hls, {#lines, 0, -1, 'Title'})
        end
    end
    local step = tour.steps[here.id]
    table.insert(lines, '')
    local heading = '## ' .. (step.title or here.id)
    if here.back then heading = heading .. '  (back to it)' elseif here.seen then heading = heading .. '  (seen already)' end
    table.insert(lines, heading)
    for _, l in ipairs(vim.split(step.text or '', '\n', {plain=true})) do table.insert(lines, l) end
    return lines, rows, hls
end

local function draw()
    local lines, rows, hls = render()
    local buf = State.panel_buf
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    for _, h in ipairs(hls) do
        vim.api.nvim_buf_set_extmark(buf, NS, h[1] - 1, 0, {end_row=h[1] - 1, end_col=#lines[h[1]], hl_group=h[4], priority=200})
    end
    State.rows = rows
    -- cursor on the current step's row in the tree
    for row, id in pairs(rows) do
        if id == State.walk[State.pos].id then vim.api.nvim_win_set_cursor(0, {row, 0}) end
    end
    show_code(State.tour.steps[State.walk[State.pos].id])
end

local function move(delta)
    local pos = State.pos + delta
    if pos < 1 or pos > #State.walk then
        vim.api.nvim_echo({{pos < 1 and 'At the start of the tour' or 'End of tour', 'Normal'}}, false, {})
        return
    end
    State.pos = pos
    draw()
end

--- Jump to the step under the cursor in the tree (its first place in the walk)
local function jump()
    local id = State.rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not id then return end
    for i, w in ipairs(State.walk) do
        if w.id == id and not w.back then
            State.pos = i
            return draw()
        end
    end
end

function M.quit()
    if not State then return end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_clear_namespace(b, NS, 0, -1) end
    end
    local panel = State.panel_buf
    State = nil
    if vim.api.nvim_buf_is_valid(panel) then vim.api.nvim_buf_delete(panel, {force=true}) end
end

--- Start guided mode for a tour file, from the marks panel
---
--- @param path string # tour file
--- @param origin_bufnr integer # the code buffer the menu was opened from (to know the repo)
--- @param create_window function # makes the panel window (init.lua's), returns its buffer
function M.start(path, origin_bufnr, create_window)
    local tour, err = tour_lib.load(path)
    if not tour then
        vim.api.nvim_echo({{'nvim-marks: ' .. err, 'ErrorMsg'}}, false, {})
        return
    end
    local code_win = vim.fn.win_getid(vim.fn.winnr('#'))  -- the window the menu was opened from
    if code_win == 0 or code_win == vim.api.nvim_get_current_win() then code_win = vim.api.nvim_get_current_win() end
    local walk = tour_lib.walk(tour)
    local panel_buf = create_window(#tour_lib.tree(tour) + 12)
    vim.b.is_marks_window = true
    State = {tour=tour, walk=walk, pos=1, code_win=code_win, panel_buf=panel_buf, origin_bufnr=origin_bufnr, rows={}}
    vim.wo.winbar = '%#Comment#' .. ('Help: n next | p previous | <CR> jump to step | q quit'):gsub('%%', '%%%%')
    local opts = {buffer=panel_buf, silent=true, nowait=true}
    vim.keymap.set('n', 'n', function() move(1) end, opts)
    vim.keymap.set('n', 'p', function() move(-1) end, opts)
    vim.keymap.set('n', '<CR>', jump, opts)
    vim.keymap.set('n', 'q', M.quit, opts)
    vim.keymap.set('n', '<C-c>', M.quit, opts)
    vim.keymap.set('n', '<Esc>', M.quit, opts)
    -- Leaving the panel keeps guided mode (you can read the code); wiping the panel ends it
    vim.api.nvim_create_autocmd('BufWipeout', {buffer=panel_buf, once=true, callback=function()
        if State and State.panel_buf == panel_buf then
            State.panel_buf = -1
            M.quit()
        end
    end})
    draw()
end

--- @return boolean
function M.active() return State ~= nil end

return M
