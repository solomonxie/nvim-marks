--- Tour panel (guided mode): the UI that walks a tour step by step; tour.lua reads and checks the tour file.
--- Walk a tour step by step, in the order of its tree (each step once). The marks panel shows the tree
--- (▶ on the current step) and the step's explanation; the code window above puts its cursor on each step's line.
--- Keys in the panel: n next, p previous, <CR> jump to the step under the cursor, Backspace back to the marks menu,
--- q / Ctrl-c leave.

local M = {}

local tour_lib = require('nvim-marks.tour')
local anchor = require('nvim-marks.anchor')
local utils = require('nvim-marks.utils')

local NS = vim.api.nvim_create_namespace('nvim-marks.tour-panel')
local NS_Sign = vim.api.nvim_create_namespace('nvim-marks.tour-sign')  -- the ▶ on the step's line in the code window
local State = nil  --- @type table|nil # {tour, tree, pos, code_win, panel_buf, origin_bufnr, origin_view, opened, rows={panel row = step id}}

--- Find a step's line in its file now (it may have moved since the tour was written)
---
--- @return string|nil, integer|nil # path, row (nil when the file isn't in any checkout)
local function locate(step)
    local path, exists = utils.resolve_file(step.file, State.origin_bufnr)
    if not exists then return nil, nil end
    local lines = vim.fn.readfile(path)
    local row = step.line and (anchor.locate({row=step.row or 1, line=step.line, above=step.above or {}, below=step.below or {}}, lines)
                               or utils.relocate_step(step, State.origin_bufnr, lines))
    return path, row or step.row or 1
end

--- Show the step in the code window: its file (with filetype/syntax, like :edit), cursor on its line, centered, and a
--- green ▶ in the sign column on that line (the line itself isn't highlighted, the cursor line shows it).
--- The tour reuses that one window; each file is opened with :edit (an ordinary buffer). A file the tour opened is
--- closed when it moves to another file, so there's one at a time; files you had open are left alone.
local function show_code(step)
    local path, row = locate(step)
    if not path then
        vim.api.nvim_echo({{'Not found in any checkout: ' .. step.file, 'WarningMsg'}}, false, {})
        return
    end
    if not vim.api.nvim_win_is_valid(State.code_win) then return end
    local bufnr, opened = utils.show_in_window(State.code_win, path)
    if not bufnr then return end
    if State.opened and State.opened ~= bufnr then utils.close_preview_buffer(State.opened) end
    if opened then State.opened = bufnr elseif State.opened ~= bufnr then State.opened = nil end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_clear_namespace(b, NS_Sign, 0, -1) end
    end
    row = math.min(row, vim.api.nvim_buf_line_count(bufnr))
    vim.api.nvim_win_set_cursor(State.code_win, {row, 0})
    vim.api.nvim_win_call(State.code_win, function() vim.cmd('normal! zz') end)
    vim.api.nvim_buf_set_extmark(bufnr, NS_Sign, row - 1, 0, {sign_text='▶', sign_hl_group='DiagnosticOk',
        priority=10000})  -- above the default 4096 of a note's `*`, a mark's letter and git signs: it wins the sign column
end

--- @return string[], table, table # panel lines, {row = step id}, highlights [{row, col, end_col, group}]
local function render()
    local tour, tree = State.tour, State.tree
    local stop = State.walk[State.pos]
    local here = tree[stop.row]
    local lines, rows, hls = {''}, {}, {}
    -- no step counter: the ▶ in the numbered tree shows where you are; only say when the tour has ended
    table.insert(lines, '# ' .. tour.name .. (State.pos == #State.walk and ' · end of tour' or ''))
    if tour.description ~= '' then table.insert(lines, tour.description) end
    table.insert(lines, '')
    local number_width = #tostring(#tree)
    for i, r in ipairs(tree) do
        local step = tour.steps[r.id]
        local marker = r.id == here.id and '▶' or ' '
        local number = string.rep(' ', number_width - #tostring(i)) .. i .. '.'
        local indent = r.depth > 0 and (string.rep('   ', r.depth - 1) .. '└─ ') or ''
        local location = vim.fs.basename(step.file or '') .. ':' .. tostring(step.row or '?')
        table.insert(lines, string.format('%s %s %s%s%s   %s', marker, number, indent, step.title or r.id, r.shared and ' (shared)' or '', location))
        rows[#lines] = r.id
        if r.id == here.id then table.insert(hls, {#lines, 0, -1, 'Title'}) end  -- only the current step stands out
    end
    local step = tour.steps[here.id]
    table.insert(lines, '')
    table.insert(lines, '## ' .. (step.title or here.id))
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
        if id == State.tree[State.walk[State.pos].row].id then vim.api.nvim_win_set_cursor(0, {row, 0}) end
    end
    show_code(State.tour.steps[State.tree[State.walk[State.pos].row].id])
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

--- Jump to the step under the cursor in the tree
local function jump()
    local id = State.rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not id then return end
    -- go to the first stop on that step (its first visit, not a walk back)
    for i, stop in ipairs(State.walk) do
        if not stop.back and State.tree[stop.row].id == id then
            State.pos = i
            return draw()
        end
    end
end

--- Leave guided mode. The code window stays on the current step's file, which stays open.
function M.quit()
    if not State then return end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) then
            vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
            vim.api.nvim_buf_clear_namespace(b, NS_Sign, 0, -1)
        end
    end
    local state = State
    State = nil
    if vim.api.nvim_buf_is_valid(state.panel_buf) then vim.api.nvim_buf_delete(state.panel_buf, {force=true}) end
end

--- Leave the tour and open the marks menu again, from the file and line the tour was started from
local function back_to_menu()
    if not State then return end
    local code_win, origin_bufnr, origin_view, state_opened = State.code_win, State.origin_bufnr, State.origin_view, State.opened
    M.quit()
    if not vim.api.nvim_win_is_valid(code_win) then return end
    vim.api.nvim_set_current_win(code_win)
    if vim.api.nvim_buf_is_valid(origin_bufnr) then
        local opened = vim.api.nvim_win_get_buf(code_win)
        utils.show_in_window(code_win, origin_bufnr)
        if origin_view then vim.fn.winrestview(origin_view) end
        if opened == state_opened then utils.close_preview_buffer(opened) end  -- the tour's file, not yours
    end
    require('nvim-marks').openMarks()
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
    local tree = tour_lib.tree(tour)
    local origin_view = vim.api.nvim_win_call(code_win, vim.fn.winsaveview)
    local panel_buf = create_window(#tree + 12)
    vim.b.is_marks_window = true
    -- No markdown here: the tree's deeper rows are indented 4+ spaces, which markdown draws as a code block (gray),
    -- so rows looked highlighted by depth. Only the titles and the current step stand out.
    pcall(vim.treesitter.stop, panel_buf)
    vim.cmd([[syntax match NvimMarksTitle /^#.*$/]])
    vim.cmd([[highlight default link NvimMarksTitle Title]])
    -- `code` spans in step titles and explanations, drawn like markdown inline code (the backticks hidden)
    vim.cmd([[syntax region NvimMarksCode matchgroup=Conceal start=/`/ end=/`/ oneline concealends]])
    vim.cmd([[highlight default link NvimMarksCode @markup.raw.markdown_inline]])
    vim.wo.conceallevel = 2
    vim.wo.concealcursor = 'nc'
    State = {tour=tour, tree=tree, walk=tour_lib.walk(tour, tree), pos=1, code_win=code_win, panel_buf=panel_buf,
             origin_bufnr=origin_bufnr, origin_view=origin_view, rows={}}
    vim.wo.winbar = '%#Comment#' .. ('Help: n next | p previous | <CR> jump to step | Backspace main menu | q quit'):gsub('%%', '%%%%')
    local opts = {buffer=panel_buf, silent=true, nowait=true}
    vim.keymap.set('n', 'n', function() move(1) end, opts)
    vim.keymap.set('n', 'p', function() move(-1) end, opts)
    vim.keymap.set('n', '<CR>', jump, opts)
    vim.keymap.set('n', '<BS>', back_to_menu, opts)
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
