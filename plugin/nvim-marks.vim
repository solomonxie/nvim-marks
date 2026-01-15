
map m <C-m>
nnoremap <silent> <nowait> m :lua require('nvim-marks').openMarks()<CR>

echom 'plugin/nvim-marks.vim is loaded.'
redraw!
