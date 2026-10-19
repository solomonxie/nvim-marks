" Options:
let g:nvim_marks_restore_global = get(g:, 'nvim_marks_restore_global', 1)  "Set A-Z marks of the repo's other files so 'A works before opening them

" let g:nvim_marks_dir = '~/notes/marks'  "Marks saved to <dir>/<repo>/marks-history.json, default dir: stdpath('data')/nvim-marks

" Keymaps:
map m <C-m>
nnoremap <silent> <nowait> m :lua require('nvim-marks').openMarks()<CR>

" Actions:
autocmd BufEnter,BufReadPost * lua require('nvim-marks').setupBuffer()


echom 'plugin/nvim-marks.vim is loaded.'
redraw!
