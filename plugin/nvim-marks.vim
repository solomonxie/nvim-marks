
map m <C-m>
nnoremap <silent> <nowait> m :lua require('nvim-marks').openMarks()<CR>
autocmd BufEnter * lua require('nvim-marks').bufferSetup()
" autocmd BufEnter * lua require('nvim-marks').loadMarks()

echom 'plugin/nvim-marks.vim is loaded.'
redraw!
