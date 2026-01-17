" Options:
let g:restore_global_marks = 1  "At vim start, this will restore global marks for unopened files, which may trigger some BufEnter actions

" Keymaps:
" map m <C-m>
" nnoremap <silent> <nowait> m :lua require('nvim-marks').openMarks()<CR>
" nnoremap <silent> <nowait> m :lua require('nvim-marks.refactor').openMarks()<CR>

" Actions:
" autocmd BufEnter * lua require('nvim-marks').bufferSetup()
autocmd BufEnter * lua require('nvim-marks.refactor').setupBuffer()


echom 'plugin/nvim-marks.vim is loaded.'
redraw!
