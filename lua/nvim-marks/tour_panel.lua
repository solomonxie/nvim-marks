--- Tour panel (guided mode): the UI that walks a tour step by step; tour.lua reads and checks the tour file.
--- Walk a tour step by step, in the order of its tree (each step once). The panel shows the tour's name and
--- description (virtual lines on top) and the tree with ▶ on the current step. The code window above puts its cursor
--- on each step's line, with the step's explanation as virtual lines above it.
--- Keys in the panel: n next, p previous, <CR> jump to the step under the cursor, Backspace back to the marks menu,
--- q / Ctrl-c leave.

local M = {}

local tour_lib = require('nvim-marks.tour')
local anchor = require('nvim-marks.anchor')
local utils = require('nvim-marks.utils')

local NS = vim.api.nvim_create_namespace('nvim-marks.tour-panel')
local NS_Sign = vim.api.nvim_create_namespace('nvim-marks.tour-sign')  -- the ▶ on the step's line in the code window
local NS_Header = vim.api.nvim_create_namespace('nvim-marks.tour-header')  -- tour name and description, virtual lines on top
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

--- Show the step in the code window: its file (with filetype/syntax, like :edit), cursor on its line, centered, a
--- green ▶ in the sign column on that line (the line itself isn't highlighted, the cursor line shows it), and the
--- step's explanation as virtual lines above it, gone when the tour moves on.
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
    vim.api.nvim_buf_set_extmark(bufnr, NS_Sign, row - 1, 0, {sign_text='▶', sign_hl_group='DiagnosticOk',
        priority=10000})  -- above the default 4096 of a note's `*`, a mark's letter and git signs: it wins the sign column
    -- The explanation above the line between two rules, indented like the code, wrapped to the window's width
    local virt_lines = {}
    if vim.trim(step.text or '') ~= '' then
        local indent = vim.api.nvim_buf_call(bufnr, function() return vim.fn.indent(row) end)
        local width = math.max(20, vim.api.nvim_win_get_width(State.code_win) - vim.fn.getwininfo(State.code_win)[1].textoff - indent - 1)
        local pad = {string.rep(' ', indent), 'Normal'}
        local longest = 0
        for _, l in ipairs(vim.split(vim.trim(step.text), '\n', {plain=true})) do
            for _, wrapped in ipairs(M.wrap_chunks({{l, 'Comment'}}, width)) do  -- all gray, `code` left as typed
                local text = vim.trim(table.concat(vim.tbl_map(function(c) return c[1] end, wrapped)))
                longest = math.max(longest, vim.fn.strdisplaywidth(text))
                table.insert(virt_lines, vim.list_extend({pad}, wrapped))
            end
        end
        -- rules above and below, as wide as the longest line
        local rule = {pad, {string.rep('-', longest), 'Comment'}}
        table.insert(virt_lines, 1, rule)
        table.insert(virt_lines, rule)
        vim.api.nvim_buf_set_extmark(bufnr, NS_Sign, row - 1, 0, {virt_lines=virt_lines, virt_lines_above=true})
    end
    vim.api.nvim_win_set_cursor(State.code_win, {row, 0})
    vim.api.nvim_win_call(State.code_win, function()
        vim.cmd('normal! zz')
        -- on the window's top line, lines above it only show when the view asks for them (topfill)
        local view = vim.fn.winsaveview()
        if view.topline == row then vim.fn.winrestview({topline=row, topfill=#virt_lines}) end
    end)
end

--- Split a line of text into chunks: `code` spans (backticks dropped) highlighted like markdown inline code, the
--- rest in `hl`
---
--- @return table[] # [{text, hl_group}]
function M.text_chunks(line, hl)
    local chunks, rest = {}, line
    while true do
        local before, code, after = rest:match('^(.-)`([^`]+)`(.*)$')
        if not before then break end
        if before ~= '' then table.insert(chunks, {before, hl}) end
        table.insert(chunks, {code, '@markup.raw.markdown_inline'})
        rest = after
    end
    if rest ~= '' then table.insert(chunks, {rest, hl}) end
    return chunks
end

--- Wrap chunks to `width` display columns at spaces (a word longer than the width is cut), keeping each chunk's
--- highlight; the space where a line breaks is dropped
---
--- @return table[][] # one list of chunks per screen line
function M.wrap_chunks(chunks, width)
    local out, line, used = {}, {}, 0
    local function newline()
        table.insert(out, line)
        line, used = {}, 0
    end
    for _, chunk in ipairs(chunks) do
        local text, hl = chunk[1], chunk[2]
        for word, space in text:gmatch('(%S*)(%s*)') do
            if word == '' and space == '' then break end
            local w = vim.fn.strdisplaywidth(word)
            if used > 0 and used + w > width then newline() end
            while w > width do  -- longer than a whole line: cut it
                local head = vim.fn.strcharpart(word, 0, width - used)
                table.insert(line, {head, hl})
                word = vim.fn.strcharpart(word, vim.fn.strchars(head))
                w = vim.fn.strdisplaywidth(word)
                newline()
            end
            local piece = word .. ((used + w + #space <= width) and space or '')
            if piece ~= '' then
                table.insert(line, {piece, hl})
                used = used + vim.fn.strdisplaywidth(piece)
            end
        end
    end
    if #line > 0 or #out == 0 then table.insert(out, line) end
    return out
end

--- Bold in the comment color: headings that stand out from the gray text without the bright white of `Bold`
local function heading_hl()
    local comment = vim.api.nvim_get_hl(0, {name='Comment', link=false})
    vim.api.nvim_set_hl(0, 'NvimMarksTourHeading', {default=true, fg=comment.fg, ctermfg=comment.ctermfg, bold=true})
    return 'NvimMarksTourHeading'
end

--- The tour's name and description above the tree as virtual lines, wrapped to the panel's width (redrawn when it's
--- resized). nvim draws lines above line 1 only when the view asks for them (topfill), see header_in_view.
local function show_header()
    local buf = State.panel_buf
    vim.api.nvim_buf_clear_namespace(buf, NS_Header, 0, -1)
    local win = vim.fn.bufwinid(buf)
    if win == -1 then return end
    local width = math.max(20, vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff - 1)
    local heading = heading_hl()
    local virt_lines = {{{'', 'Normal'}}}
    local function add(chunks)
        for _, wrapped in ipairs(M.wrap_chunks(chunks, width)) do table.insert(virt_lines, wrapped) end
    end
    local name = {{State.tour.name, heading}}
    if State.pos == #State.walk then table.insert(name, {'  · end of tour', 'Comment'}) end
    add(name)
    if State.tour.description ~= '' then add(M.text_chunks(State.tour.description, 'Comment')) end
    table.insert(virt_lines, {{'', 'Normal'}})
    vim.api.nvim_buf_set_extmark(buf, NS_Header, 0, 0, {virt_lines=virt_lines, virt_lines_above=true})
    State.header_height = #virt_lines
end

--- Fit the panel's height to what it shows now (name, tree, this step's explanation), within the max height, so
--- there's no empty space under a short explanation; the code window above gets the rest
local function fit_height()
    local win = vim.fn.bufwinid(State.panel_buf)
    if win == -1 then return end
    local wanted = State.header_height + #State.tree
    vim.api.nvim_win_set_height(win, require('nvim-marks').window_height(wanted))
end

--- Show the header whenever the view is at the top
local function header_in_view()
    if not State or vim.api.nvim_get_current_buf() ~= State.panel_buf then return end
    local view = vim.fn.winsaveview()
    if view.topline == 1 and view.topfill ~= State.header_height then
        vim.fn.winrestview({topline=1, topfill=State.header_height})
    end
end

--- @return string[], table, table # panel lines, {row = step id}, highlights [{row, col, end_col, group}]
local function render()
    local tour, tree = State.tour, State.tree
    local stop = State.walk[State.pos]
    local here = tree[stop.row]
    -- Only the tree is text; the tour's name, the current step and its explanation are virtual lines above it
    local lines, rows, hls = {}, {}, {}
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
    return lines, rows, hls
end

--- @param keep_size boolean|nil # resized: only re-wrap, don't refit the panel's height or move the code window
local function draw(keep_size)
    local lines, rows, hls = render()
    local buf = State.panel_buf
    vim.bo[buf].modifiable = true
    State.rows = rows
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    show_header()
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    for _, h in ipairs(hls) do
        vim.api.nvim_buf_set_extmark(buf, NS, h[1] - 1, 0, {end_row=h[1] - 1, end_col=#lines[h[1]], hl_group=h[4], priority=200})
    end
    if not keep_size then fit_height() end
    -- cursor on the current step's row in the tree; keep the top (the tour's name) in view while the row fits
    for row, id in pairs(rows) do
        if id == State.tree[State.walk[State.pos].row].id then
            vim.api.nvim_win_set_cursor(0, {row, 0})
            if row + State.header_height <= vim.api.nvim_win_get_height(0) then vim.fn.winrestview({topline=1}) end
            header_in_view()
        end
    end
    if not keep_size then show_code(State.tour.steps[State.tree[State.walk[State.pos].row].id]) end
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
            vim.api.nvim_buf_clear_namespace(b, NS_Header, 0, -1)
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
    local panel_buf = create_window(#tree)  -- fitted to the content on each step, see fit_height
    vim.b.is_marks_window = true
    -- No markdown here: the tree's deeper rows are indented 4+ spaces, which markdown draws as a code block (gray),
    -- so rows looked highlighted by depth. Only the current step stands out.
    pcall(vim.treesitter.stop, panel_buf)
    -- `code` spans in titles and explanations, drawn like markdown inline code (the backticks hidden)
    vim.cmd([[syntax region NvimMarksCode matchgroup=Conceal start=/`/ end=/`/ oneline concealends contained containedin=ALL]])
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
    vim.api.nvim_create_autocmd({'CursorMoved', 'WinScrolled'}, {buffer=panel_buf, callback=header_in_view})
    -- The header is wrapped to the window's width: wrap again when it changes
    vim.api.nvim_create_autocmd({'WinResized', 'VimResized'}, {callback=function()
        if State and State.panel_buf == panel_buf and vim.api.nvim_buf_is_valid(panel_buf) then
            -- redraw so the text re-wraps; not fit_height, setting the height here would fire WinResized again
            local cursor = vim.api.nvim_win_get_cursor(vim.fn.bufwinid(panel_buf))
            vim.api.nvim_buf_call(panel_buf, function()
                draw(true)
                vim.api.nvim_win_set_cursor(0, cursor)
                header_in_view()
            end)
        end
    end})
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



--- Tests: `nvim -l tests/run.lua`
local function eq(actual, expected, msg)
    assert(vim.deep_equal(actual, expected), string.format('%s: expected %s, got %s', msg, vim.inspect(expected), vim.inspect(actual)))
end

function M.test_wrap_chunks()
    local function texts(lines)
        return vim.tbl_map(function(l) return table.concat(vim.tbl_map(function(c) return c[1] end, l)) end, lines)
    end
    eq(texts(M.wrap_chunks({{'one two three four', 'Comment'}}, 9)), {'one two ', 'three ', 'four'}, 'wrapped at spaces')
    local lines = M.wrap_chunks(M.text_chunks('calls `save()` then exits', 'Comment'), 12)
    eq(texts(lines), {'calls save()', 'then exits'}, 'code span kept, backticks dropped')
    eq(lines[1][2], {'save()', '@markup.raw.markdown_inline'}, 'code span highlighted')
    eq(texts(M.wrap_chunks({{'abcdefghij', 'Comment'}}, 4)), {'abcd', 'efgh', 'ij'}, 'long word cut')
    eq(texts(M.wrap_chunks({}, 10)), {''}, 'empty line stays a line')
end

return M
