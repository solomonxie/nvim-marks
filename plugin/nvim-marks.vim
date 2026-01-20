" Options:
let g:nvim_marks_restore_global = 1  "At vim start, this will restore global marks for unopened files, which may trigger some BufEnter actions

" let g:persistent_dir = expand('~/Documents/nvim-marks')

" Keymaps:
map m <C-m>
nnoremap <silent> <nowait> m :lua require('nvim-marks').openMarks()<CR>

" Actions:
autocmd BufEnter * lua require('nvim-marks').setupBuffer()


echom 'plugin/nvim-marks.vim is loaded.'
redraw!
