--- NOTE:
--- 1. We use native Vimmarks for marks, we use extmarks for notes
--- 2. We try not to disrupt native vimmarks key bindings, will just forward the keystroke
--- 3. We save all info into one local file involved all code files in the project.
--- 4. For vim global marks (A-Z), the problem is that we cannot restore the mark without opening the file,
---    which is tricky because we don't want to open a buffer which may trigger other plugin reactions.
---    An easier way: we only restore marks upon BufEnter, if user wants to jump to global marks, has to jump from Marks window,
---    so `'A` won't jump until buffer is opened at least once (unless viminfo/shada were enabled)
--- 5. It should only care about the CURRENT BUFFER

local M = {}

local utils = require('nvim-marks.utils')

local IsBufferSetup = {}


--- Swith to note editing mode allows user to type notes
function M.switchEditMode(target_bufnr, target_row)
    local edit_bufnr = M.create_window()
    vim.api.nvim_buf_set_lines(edit_bufnr, 0, -1, false, {
        '> Help: Press `S` edit; `q` Quit; `Ctrl-s` save and quit',
    })
    vim.keymap.set({'n', 'i', 'v'}, '<C-s>', function() M.save_note(edit_bufnr, target_bufnr, target_row) end, {buffer=true, silent=true, nowait=true })
end

function M.openMarks()
    local target_bufnr = vim.api.nvim_get_current_buf()
    local target_row, _ = unpack(vim.api.nvim_win_get_cursor(0))  -- 0: current window_id
    local filename = vim.api.nvim_buf_get_name(target_bufnr)
    -- Prepare content
    local content_lines = {
        '> Help: Press `a-Z` Add mark | `+` Add note | `-` Delete  | `*` List all | `q` Quit',
    }
    -- Render marks
    local vimmarks = utils.scan_vimmarks(target_bufnr)
    if #vimmarks > 0 then
        table.insert(content_lines, '')
        table.insert(content_lines, '# Marks')
    end
    for _, item in ipairs(vimmarks) do
        local char, row = unpack(item)
        local display = string.format("(%s) %s:%d", char, filename, row)
        table.insert(content_lines, display)
    end
    -- Render global marks
    local global_marks = utils.scan_global_vimmarks()
    for _, item in ipairs(global_marks) do
        local char, row, global_filename = unpack(item)
        local display = string.format("(%s) %s:%d", char, global_filename, row)
        table.insert(content_lines, display)
    end
    -- Render notes
    local notes = utils.scan_notes(target_bufnr)
    if #notes ~= 0 then
        table.insert(content_lines, '')
        table.insert(content_lines, '# Notes')
    end
    for _, item in ipairs(notes) do
        local _, row, virt_lines = unpack(item)
        local preview = ''
        if virt_lines and virt_lines[1] and virt_lines[1][1] then
            preview = '>> ' .. virt_lines[1][1][1]:sub(1, 30) .. '...'
        end
        local display = string.format("* %s:%d %s", filename, row, preview)
        table.insert(content_lines, display)
    end
    -- Create a window and display
    local win_bufnr = M.create_window()
    vim.api.nvim_buf_set_lines(win_bufnr, 0, -1, false, content_lines)
    vim.cmd('setlocal readonly nomodifiable')
    vim.cmd('redraw')
    -- Listen for user's next keystroke
    -- TODO: allow user to scroll
    local key = vim.fn.getcharstr()
    vim.cmd('bwipeout!')  -- Close window no matter what
    if key == '-' then
        utils.delete_vimmark(target_bufnr, target_row)
        utils.delete_note(target_bufnr, target_row)
    elseif key == "+" then
        M.switchEditMode(target_bufnr, target_row)
    elseif key == 'q' or key == '\3' or key == '\27' then  -- q | <Ctrl-c> | <ESC>
        -- Do nothing.
    elseif key:match('[a-zA-Z]') then  -- Any other a-zA-Z letter
        utils.set_vimmark(target_bufnr, key, target_row)
    end
    utils.refresh_sign_bar(target_bufnr)
end

--- @return integer # Mark-window's Buffer id
function M.create_window()
    if vim.b.is_marks_window == true then vim.cmd('bwipeout!') end  -- Close existing quick window
    vim.cmd('botright 10 new')  -- Create new window and jump to the buffer context
    vim.b.is_marks_window = true
    vim.opt_local.buftype = 'nofile'
    vim.opt_local.filetype = 'markdown'
    vim.cmd('mapclear <buffer>')
    vim.cmd('autocmd BufLeave,BufWinLeave,BufHidden <buffer> ++once  :bd!')
    vim.cmd('nnoremap <buffer> <silent> <nowait> q :bwipeout!<CR>')
    vim.cmd('nnoremap <buffer> <silent> <nowait> <ESC> :bwipeout!<CR>')
    vim.cmd('nnoremap <buffer> <silent> <nowait> <C-c> :bwipeout!<CR>')
    vim.cmd('setlocal buftype=nofile bufhidden=wipe noswapfile nonumber norelativenumber nowrap nocursorline')
    return vim.api.nvim_get_current_buf()
end

--- Read from user edits, save it to an extmark attached to the target
---
--- @param edit_bufnr integer # editor-buffer's id
--- @param target_bufnr integer # target-buffer's id
--- @param target_row integer # target-buffer's row number
function M.save_note(edit_bufnr, target_bufnr, target_row)
    local virt_lines = {}
    local read_lines = vim.api.nvim_buf_get_lines(edit_bufnr, 0, -1, false)
    for _, line in ipairs(read_lines) do
        table.insert(virt_lines, {{line, "Comment"}})
    end
    vim.api.nvim_buf_set_extmark(target_bufnr, utils.NS_Notes, target_row-1, 0, {
        id=math.random(1000, 9999),
        end_row=target_row-1,  -- extmark is 0-indexed
        end_col=0,
        sign_text='*',
        sign_hl_group='Comment',
        virt_lines=virt_lines,
    })
    vim.cmd('bwipeout!')
    vim.cmd('stopinsert!')
    utils.refresh_sign_bar(target_bufnr)
end

--- Save global vimmarks and local vimmarks+notes
function M.save_all(bufnr)
    utils.update_git_blame_cache()  -- Update latest blames before saving (could be changed by external editors)
    print('saving all for', bufnr)
    local filename = vim.api.nvim_buf_get_name(bufnr)
    -- Save global vimmarks
    local global_marks = utils.scan_global_vimmarks()
    local json_path = utils.make_json_path('vimmarks_global')
    if #global_marks > 0 then
        utils.save_json(global_marks, json_path)
    else
        os.remove(json_path)
    end
    if bufnr == nil then return end
    -- Save buffer-only vimmarks+notes
    local vimmarks = utils.scan_vimmarks(bufnr)
    local notes = utils.scan_notes(bufnr)
    local data = {vimmarks=vimmarks, notes=notes}
    json_path = utils.make_json_path(filename)
    if #vimmarks > 0 or #notes > 0 then
        utils.save_json(data, json_path)
    else
        os.remove(json_path) -- Delete empty files if no marks at all
    end
end

--- On buffer init(once), restore marks from persistent file
function M.setupBuffer()
    local bufnr = vim.api.nvim_get_current_buf()
    local is_file = utils.is_real_file(bufnr)
    if not is_file then return end
    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":.")
    if IsBufferSetup[bufnr] == nil then
        utils.update_git_blame_cache()
        utils.restore_global_marks()
        utils.restore_marks(bufnr)
        utils.refresh_sign_bar(bufnr)
        -- Register auto saving/updating logic
        vim.api.nvim_create_autocmd('BufHidden', {  -- BufHidden include BufLeave/BufWinLeave
            buffer = bufnr,
            callback = function() M.save_all(bufnr) end,
        })
        vim.api.nvim_create_autocmd('BufEnter', {
            buffer = bufnr,
            callback = function() utils.refresh_sign_bar(bufnr) end,
        })
        IsBufferSetup[bufnr] = true
    end
end


function M.setup(opt)
    -- TODO: handle options (file location, keymaps, etc)
    -- ...
end

return M
