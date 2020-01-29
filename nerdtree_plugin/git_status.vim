" ============================================================================
" File:        git_status.vim
" Description: plugin for NERD Tree that provides git status support
" Maintainer:  Xuyuan Pang <xuyuanp at gmail dot com>
" Last Change: 4 Apr 2014
" License:     This program is free software. It comes without any warranty,
"              to the extent permitted by applicable law. You can redistribute
"              it and/or modify it under the terms of the Do What The Fuck You
"              Want To Public License, Version 2, as published by Sam Hocevar.
"              See http://sam.zoy.org/wtfpl/COPYING for more details.
" ============================================================================
if exists('g:loaded_nerdtree_git_status')
    finish
endif
let g:loaded_nerdtree_git_status = 1

if !exists('g:NERDTreeShowGitStatus')
    let g:NERDTreeShowGitStatus = 1
endif

if g:NERDTreeShowGitStatus == 0
    finish
endif

if !exists('g:NERDTreeMapNextHunk')
    let g:NERDTreeMapNextHunk = ']c'
endif

if !exists('g:NERDTreeMapPrevHunk')
    let g:NERDTreeMapPrevHunk = '[c'
endif

if !exists('g:NERDTreeUpdateOnWrite')
    let g:NERDTreeUpdateOnWrite = 1
endif

if !exists('g:NERDTreeUpdateOnCursorHold')
    let g:NERDTreeUpdateOnCursorHold = 1
endif

if !exists('g:NERDTreeShowIgnoredStatus')
    let g:NERDTreeShowIgnoredStatus = 0
endif

if !exists('s:NERDTreeIndicatorMap')
    let s:NERDTreeIndicatorMap = {
                \ 'Modified'  : '✹',
                \ 'Staged'    : '✚',
                \ 'Untracked' : '✭',
                \ 'Renamed'   : '➜',
                \ 'Unmerged'  : '═',
                \ 'Deleted'   : '✖',
                \ 'Dirty'     : '✗',
                \ 'Clean'     : '✔︎',
                \ 'Ignored'   : '☒',
                \ 'Unknown'   : '?'
                \ }
endif

let s:supports_async =
    \ (
    \     (v:version >= 800 && exists('*job_start'))
    \         || (has('nvim') && exists('*jobstart'))
    \ )

let s:is_async =
    \ (exists('g:nerdtree_git_async') && g:nerdtree_git_async)
        \ && s:supports_async

function! s:get_key(tree)
    return a:tree.GetWinNum()
endfunction

function! NERDTreeGitStatusRefreshListener(event)
    let l:key = s:get_key(a:event.nerdtree)
    if !exists('s:refresh_data['.l:key.']') || !exists('s:refresh_data['.l:key.'].not_git')
        call g:NERDTreeGitStatusRefresh(a:event.nerdtree)
    endif
    let l:path = a:event.subject
    let l:flag = g:NERDTreeGetGitStatusPrefix(a:event.nerdtree, l:path)
    call l:path.flagSet.clearFlags('git')
    if l:flag !=# ''
        call l:path.flagSet.addFlag('git', l:flag)
    endif
endfunction

" FUNCTION: g:NERDTreeGitStatusRefresh() {{{2
let s:refresh_data = { }

" refresh cached git status
function! g:NERDTreeGitStatusRefresh(tree)
    let l:key = s:get_key(a:tree)

    let s:refresh_data[l:key] = {
        \ 'file_status': { },
        \ 'dirty_dir': { },
        \ 'not_git': 1
        \ }

    " should i do a sync update or start an async one?
    if s:is_async
        call s:NERDTreeGitStatusRefreshAsync(a:tree)
    else
        call s:NERDTreeGitStatusRefreshSync(a:tree)
    endif
endfunction

function! s:NERDTreeGitStatusRefreshSync(tree)
    let l:key = s:get_key(a:tree)
    let l:gitcmd = s:NERDTreeGitStatusRefreshCommand(a:tree)
    let l:statusesStr = system(l:gitcmd)
    call s:NERDTreeGitStatusRefreshUpdateCache(a:tree, l:statusesStr)
endfunction

function! s:NERDTreeGitStatusRefreshAsync(tree)
    let l:key = s:get_key(a:tree)
    let l:refresh_data = s:refresh_data[l:key]

    call s:NERDTreeGitStopAsyncRefresh(l:key)

    let l:argv = [ &shell, &shellcmdflag, s:NERDTreeGitStatusRefreshCommand(a:tree) ]

    if has('nvim')
        let l:refresh_data.job = jobstart(l:argv, {
            \ 'out_cb':  function('s:NERDTreeGitStatusRefresh_AsyncProgress', [ a:tree ]),
            \ 'exit_cb': function('s:NERDTreeGitStatusRefresh_AsyncExit', [ a:tree ])
            \ })
    else
        let l:refresh_data.job = job_start(l:argv, {
            \ 'out_cb':  function('s:NERDTreeGitStatusRefresh_AsyncProgress', [ a:tree ]),
            \ 'exit_cb': function('s:NERDTreeGitStatusRefresh_AsyncExit', [ a:tree ])
            \ })
    endif
endfunction

function! s:NERDTreeGitStatusRefreshCommand(tree)
    let l:root = fnamemodify(a:tree.root.path.str(), ':p:gs?\\?/?:S')
    let l:gitcmd = 'git -c color.status=false -C ' . l:root . ' status -s'
    if g:NERDTreeShowIgnoredStatus
        let l:gitcmd = l:gitcmd . ' --ignored'
    endif
    if exists('g:NERDTreeGitStatusIgnoreSubmodules')
        let l:gitcmd = l:gitcmd . ' --ignore-submodules'
        if g:NERDTreeGitStatusIgnoreSubmodules ==# 'all' || g:NERDTreeGitStatusIgnoreSubmodules ==# 'dirty' || g:NERDTreeGitStatusIgnoreSubmodules ==# 'untracked'
            let l:gitcmd = l:gitcmd . '=' . g:NERDTreeGitStatusIgnoreSubmodules
        endif
    endif
    return l:gitcmd
endfunction

function! s:NERDTreeGitStatusRefreshUpdateCache(tree, statuses)
    let l:statusesSplit = split(a:statuses, '\n')
    if l:statusesSplit != [] && l:statusesSplit[0] =~# 'fatal:.*'
        let l:statusesSplit = []
        return
    endif

    let l:key = s:get_key(a:tree)
    let l:refresh_data = s:refresh_data[l:key]
    let l:refresh_data.not_git = 0

    for l:statusLine in l:statusesSplit
        " cache git status of files
        let l:pathStr = substitute(l:statusLine, '...', '', '')
        let l:pathSplit = split(l:pathStr, ' -> ')
        if len(l:pathSplit) == 2
            call s:NERDTreeCacheDirtyDir(l:key, l:pathSplit[0])
            let l:pathStr = l:pathSplit[1]
        else
            let l:pathStr = l:pathSplit[0]
        endif
        let l:pathStr = s:NERDTreeTrimDoubleQuotes(l:pathStr)
        if l:pathStr =~# '\.\./.*'
            continue
        endif
        let l:statusKey = s:NERDTreeGetFileGitStatusKey(l:statusLine[0], l:statusLine[1])
        let l:refresh_data.file_status[fnameescape(l:pathStr)] = l:statusKey

        if l:statusKey == 'Ignored'
            if isdirectory(l:pathStr)
                let l:refresh_data.dirty_dir[fnameescape(l:pathStr)] = l:statusKey
            endif
        else
            call s:NERDTreeCacheDirtyDir(l:key, l:pathStr)
        endif
    endfor
endfunction

function! s:NERDTreeGitStopAsyncRefresh(key)
	if exists('s:refresh_data['.a:key.']') && exists('s:refresh_data['.a:key.'].job')
	    let l:job = s:refresh_data[a:key].job
		if has('nvim')
			call jobstop(l:job)
		else
			call job_stop(l:job)
		endif
		unlet s:refresh_data[a:key].job
    endif
endfunction

function! s:NERDTreeGitStatusRefresh_AsyncProgress(tree, job, data, ...)
    call s:NERDTreeGitStatusRefreshUpdateCache(a:tree, a:data)
endfunction

function! s:NERDTreeGitStatusRefresh_AsyncExit(tree, ...)
    let l:key = s:get_key(a:tree)
	if exists('s:refresh_data['.l:key.'].job')
		unlet s:refresh_data[l:key].job
	endif

    " force a nerdtree refresh
    call a:tree.root.refreshFlags()
    if exists('b:NERDTree')
        call NERDTreeRender()
    endif
endfunction

function! s:NERDTreeCacheDirtyDir(key, pathStr)
    " cache dirty dir
    let l:dirtyPath = s:NERDTreeTrimDoubleQuotes(a:pathStr)
    if l:dirtyPath =~# '\.\./.*'
        return
    endif
    let l:dirty_dir = s:refresh_data[a:key].dirty_dir
    let l:dirtyPath = substitute(l:dirtyPath, '/[^/]*$', '/', '')
    while l:dirtyPath =~# '.\+/.*' && has_key(l:dirty_dir, fnameescape(l:dirtyPath)) == 0
        let l:dirty_dir[fnameescape(l:dirtyPath)] = 'Dirty'
        let l:dirtyPath = substitute(l:dirtyPath, '/[^/]*/$', '/', '')
    endwhile
endfunction

function! s:NERDTreeTrimDoubleQuotes(pathStr)
    let l:toReturn = substitute(a:pathStr, '^"', '', '')
    let l:toReturn = substitute(l:toReturn, '"$', '', '')
    return l:toReturn
endfunction

" FUNCTION: g:NERDTreeGetGitStatusPrefix(tree, path) {{{2
" return the indicator of the path in the tree
" Args: path
let s:GitStatusCacheTimeExpiry = 2
let s:GitStatusCacheTime = 0
function! g:NERDTreeGetGitStatusPrefix(tree, path)
    if localtime() - s:GitStatusCacheTime > s:GitStatusCacheTimeExpiry
        let s:GitStatusCacheTime = localtime()
        call g:NERDTreeGitStatusRefresh(a:tree)
    endif
    let l:pathStr = a:path.str()
    let l:cwd = a:tree.root.path.str() . a:path.Slash()
    if nerdtree#runningWindows()
        let l:pathStr = a:path.WinToUnixPath(l:pathStr)
        let l:cwd = a:path.WinToUnixPath(l:cwd)
    endif
    let l:cwd = substitute(l:cwd, '\~', '\\~', 'g')
    let l:pathStr = substitute(l:pathStr, l:cwd, '', '')
    let l:statusKey = ''

    let l:key = s:get_key(a:tree)
    let l:refresh_data = s:refresh_data[l:key]
    if a:path.isDirectory
        let l:statusKey = get(l:refresh_data.dirty_dir, fnameescape(l:pathStr . '/'), '')
    else
        let l:statusKey = get(l:refresh_data.file_status, fnameescape(l:pathStr), '')
    endif
    return s:NERDTreeGetIndicator(l:statusKey)
endfunction

" FUNCTION: s:NERDTreeGetCWDGitStatus() {{{2
" return the indicator of cwd
function! g:NERDTreeGetCWDGitStatus()
    " TODO: is this the best thing to do here?
    let l:key = s:get_key(b:NERDTree)

    let l:refresh_data = s:refresh_data[l:key]
    if l:refresh_data.not_git
        return ''
    elseif l:refresh_data.dirty_dir == {} && l:refresh_data.file_status == {}
        return s:NERDTreeGetIndicator('Clean')
    endif
    return s:NERDTreeGetIndicator('Dirty')
endfunction

function! s:NERDTreeGetIndicator(statusKey)
    if exists('g:NERDTreeIndicatorMapCustom')
        let l:indicator = get(g:NERDTreeIndicatorMapCustom, a:statusKey, '')
        if l:indicator !=# ''
            return l:indicator
        endif
    endif
    let l:indicator = get(s:NERDTreeIndicatorMap, a:statusKey, '')
    if l:indicator !=# ''
        return l:indicator
    endif
    return ''
endfunction

function! s:NERDTreeGetFileGitStatusKey(us, them)
    if a:us ==# '?' && a:them ==# '?'
        return 'Untracked'
    elseif a:us ==# ' ' && a:them ==# 'M'
        return 'Modified'
    elseif a:us =~# '[MAC]'
        return 'Staged'
    elseif a:us ==# 'R'
        return 'Renamed'
    elseif a:us ==# 'U' || a:them ==# 'U' || a:us ==# 'A' && a:them ==# 'A' || a:us ==# 'D' && a:them ==# 'D'
        return 'Unmerged'
    elseif a:them ==# 'D'
        return 'Deleted'
    elseif a:us ==# '!'
        return 'Ignored'
    else
        return 'Unknown'
    endif
endfunction

" FUNCTION: s:jumpToNextHunk(node) {{{2
function! s:jumpToNextHunk(node)
    let l:position = search('\[[^{RO}].*\]', '')
    if l:position
        call nerdtree#echo('Jump to next hunk ')
    endif
endfunction

" FUNCTION: s:jumpToPrevHunk(node) {{{2
function! s:jumpToPrevHunk(node)
    let l:position = search('\[[^{RO}].*\]', 'b')
    if l:position
        call nerdtree#echo('Jump to prev hunk ')
    endif
endfunction

" Function: s:SID()   {{{2
function s:SID()
    if !exists('s:sid')
        let s:sid = matchstr(expand('<sfile>'), '<SNR>\zs\d\+\ze_SID$')
    endif
    return s:sid
endfun

" FUNCTION: s:NERDTreeGitStatusKeyMapping {{{2
function! s:NERDTreeGitStatusKeyMapping()
    let l:s = '<SNR>' . s:SID() . '_'

    call NERDTreeAddKeyMap({
        \ 'key': g:NERDTreeMapNextHunk,
        \ 'scope': 'Node',
        \ 'callback': l:s.'jumpToNextHunk',
        \ 'quickhelpText': 'Jump to next git hunk' })

    call NERDTreeAddKeyMap({
        \ 'key': g:NERDTreeMapPrevHunk,
        \ 'scope': 'Node',
        \ 'callback': l:s.'jumpToPrevHunk',
        \ 'quickhelpText': 'Jump to prev git hunk' })

endfunction

augroup nerdtreegitplugin
    autocmd CursorHold * silent! call s:CursorHoldUpdate()
augroup END
" FUNCTION: s:CursorHoldUpdate() {{{2
function! s:CursorHoldUpdate()
    if g:NERDTreeUpdateOnCursorHold != 1
        return
    endif

    if !g:NERDTree.IsOpen()
        return
    endif

    " Do not update when a special buffer is selected
    if !empty(&l:buftype)
        return
    endif

    let l:winnr = winnr()
    let l:altwinnr = winnr('#')

    call g:NERDTree.CursorToTreeWin()
    call b:NERDTree.root.refreshFlags()
    call NERDTreeRender()

    exec l:altwinnr . 'wincmd w'
    exec l:winnr . 'wincmd w'
endfunction

augroup nerdtreegitplugin
    autocmd BufWritePost * call s:FileUpdate(expand('%:p'))
augroup END
" FUNCTION: s:FileUpdate(fname) {{{2
function! s:FileUpdate(fname)
    if g:NERDTreeUpdateOnWrite != 1
        return
    endif

    if !g:NERDTree.IsOpen()
        return
    endif

    let l:winnr = winnr()
    let l:altwinnr = winnr('#')

    call g:NERDTree.CursorToTreeWin()
    let l:node = b:NERDTree.root.findNode(g:NERDTreePath.New(a:fname))
    if l:node == {}
        return
    endif
    call l:node.refreshFlags()
    let l:node = l:node.parent
    while !empty(l:node)
        call l:node.refreshDirFlags()
        let l:node = l:node.parent
    endwhile

    " this will force an update
    call s:CursorHoldUpdate()

    exec l:altwinnr . 'wincmd w'
    exec l:winnr . 'wincmd w'
endfunction

augroup AddHighlighting
    autocmd FileType nerdtree call s:AddHighlighting()
augroup END
function! s:AddHighlighting()
    let l:synmap = {
                \ 'NERDTreeGitStatusModified'    : s:NERDTreeGetIndicator('Modified'),
                \ 'NERDTreeGitStatusStaged'      : s:NERDTreeGetIndicator('Staged'),
                \ 'NERDTreeGitStatusUntracked'   : s:NERDTreeGetIndicator('Untracked'),
                \ 'NERDTreeGitStatusRenamed'     : s:NERDTreeGetIndicator('Renamed'),
                \ 'NERDTreeGitStatusIgnored'     : s:NERDTreeGetIndicator('Ignored'),
                \ 'NERDTreeGitStatusDirDirty'    : s:NERDTreeGetIndicator('Dirty'),
                \ 'NERDTreeGitStatusDirClean'    : s:NERDTreeGetIndicator('Clean')
                \ }

    for l:name in keys(l:synmap)
        exec 'syn match ' . l:name . ' #' . escape(l:synmap[l:name], '~') . '# containedin=NERDTreeFlags'
    endfor

    hi def link NERDTreeGitStatusModified Special
    hi def link NERDTreeGitStatusStaged Function
    hi def link NERDTreeGitStatusRenamed Title
    hi def link NERDTreeGitStatusUnmerged Label
    hi def link NERDTreeGitStatusUntracked Comment
    hi def link NERDTreeGitStatusDirDirty Tag
    hi def link NERDTreeGitStatusDirClean DiffAdd
    " TODO: use diff color
    hi def link NERDTreeGitStatusIgnored DiffAdd
endfunction

function! s:SetupListeners()
    call g:NERDTreePathNotifier.AddListener('init', 'NERDTreeGitStatusRefreshListener')
    call g:NERDTreePathNotifier.AddListener('refresh', 'NERDTreeGitStatusRefreshListener')
    call g:NERDTreePathNotifier.AddListener('refreshFlags', 'NERDTreeGitStatusRefreshListener')
endfunction

if g:NERDTreeShowGitStatus && executable('git')
    call s:NERDTreeGitStatusKeyMapping()
    call s:SetupListeners()
endif
