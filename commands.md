# mnml commands — 695 total across 35 groups

Hit Ctrl+F to search this buffer. `id` is what the palette and `[keys.*]` config
reference. Blank `keys` = palette-only (no default chord).

## ai  (49)

  ai.apply                      AI: apply suggested change                                    
  ai.ask                        AI: ask Claude a question                                     
  ai.cancel                     AI: cancel running job                                        
  ai.chat                       AI: Claude chat — prompt + file/selection context             
  ai.claude_code                AI: open Claude Code (right dock)                             
  ai.claude_code_new            AI: open a NEW Claude Code session (multi-session)            
  ai.claude_code_new_bottom     AI: new Claude Code session in bottom half                    
  ai.claude_code_new_left       AI: new Claude Code session in left half                      
  ai.claude_code_new_right      AI: new Claude Code session in right half                     
  ai.claude_code_new_top        AI: new Claude Code session in top half                       
  ai.codex                      AI: open Codex (right dock)                                   
  ai.codex_new                  AI: open a NEW Codex session (multi-session)                  
  ai.codex_new_bottom           AI: new Codex session in bottom half                          
  ai.codex_new_left             AI: new Codex session in left half                            
  ai.codex_new_right            AI: new Codex session in right half                           
  ai.codex_new_top              AI: new Codex session in top half                             
  ai.dashboard                  AI: open Claude Agents dashboard (also lists Codex sessions)  
  ai.dashboard.export_markdown  AI dashboard: export the focused session's transcript as markdown  
  ai.dashboard.kill             AI dashboard: kill the focused session (with confirm)         
  ai.dashboard.open_transcript  AI dashboard: open the focused session's transcript           
  ai.dashboard.resume_in_pty    AI dashboard: resume the focused session in a new mnml pty pane  
  ai.dashboard.yank_cwd         AI dashboard: yank the focused session's cwd                  
  ai.dashboard.yank_session_id  AI dashboard: yank the focused session's id                   
  ai.explain                    AI: explain the selection (or this file)                      
  ai.explain_diff               AI: explain the staged diff (or working-tree diff) — Claude walks through it  
  ai.fix                        AI: find & fix bugs in the selection (or this file)           
  ai.link_claude_token          AI: link Claude Code OAuth token (for usage meter)            
  ai.promote                    AI: promote to interactive (claude --resume)                  
  ai.reask                      AI: re-ask (fresh session)                                    
  ai.recompose_branch           AI: draft rewritten commit messages for this branch (does NOT mutate history)  
  ai.refactor                   AI: refactor the selection (or this file)                     
  ai.refresh_usage              AI: refresh usage meter (Claude + Codex)                      
  ai.session_picker             AI: pick from past Claude sessions for this workspace         
  ai.session_search             AI: grep every Claude transcript for a substring              
  ai.session_view               AI: mirror this Claude session's transcript (live)            
  ai.setup_suggestions          AI: pick inline-suggestion backend (Claude API / local)       
  ai.show_config                AI: show current backend / model / tools                      
  ai.show_last_response         AI: show last Claude quota response (debug)                   
  ai.spend_today                AI: today's token + cost spend across all sessions (Claude + Codex)  
  ai.suggestion_stats           AI: inline-suggestion accept rate                             
  ai.toggle_backend             AI: toggle backend (cli ↔ api / direct HTTP)                  
  ai.toggle_inline_suggestions  AI: toggle inline ghost-text suggestions (Cursor-style)       
  ai.token_usage                AI: token usage + cost estimate                               
  ai.usage                      AI: show Claude usage panel (session + weekly + per-model)    
  ai.write_branch_name          AI: suggest a branch name from a natural-language description  
  ai.write_pr_description       AI: draft a PR description from this branch's commits + diff vs main  
  ai.write_tests                AI: write tests for the selection (or this file)              
  mixr.copy_track               Mixr: copy the now-playing track title to clipboard           
  mixr.show                     Mixr: open the TUI DJ in a Pty pane                           

## app  (4)

  app.choose_data_layout  Choose data layout — Portable (mnml-data/) or Normal (~/.config/mnml/)  
  app.quit                Quit mnml                                                     ctrl+q
  app.reset_to_defaults   Reset mnml to factory defaults (backup + relaunch)            
  app.restart             Restart mnml (rebuild + relaunch via run.sh)                  

## browser  (33)

  browser.add_cookie             Browser: add a cookie scoped to the current origin (a in cookies panel)  
  browser.add_storage            Browser: add a Web Storage entry (a in storage panel)         
  browser.autocapture_toggle     Browser: toggle auto-append network entries to captured log   
  browser.back                   Browser: navigate back (window.history.back)                  
  browser.clear_snapshots        Browser: clear all captured snapshots                         
  browser.cookies                Browser: toggle the cookies panel (K) — Network.getCookies    
  browser.copy_url               Browser: copy current URL to clipboard                        
  browser.delete_cookie          Browser: delete the selected cookie (d in cookies panel)      
  browser.delete_storage         Browser: delete the selected Web Storage entry (d in storage panel)  
  browser.device_picker          Browser: device emulation picker (m) — mobile UA + viewport   
  browser.devtools               Browser: open DevTools (chrome://inspect hint)                
  browser.diff_snapshot          Browser: diff latest snapshot vs current state                
  browser.dock_toggle            Browser: dock Chrome side-by-side (macOS) / restore           
  browser.dom                    Browser: open the DOM panel (selectable nodes, copy selector)  
  browser.edit_cookie            Browser: edit the selected cookie's value (e in cookies panel)  
  browser.edit_storage           Browser: edit the selected Web Storage entry (e in storage panel)  
  browser.forward                Browser: navigate forward (window.history.forward)            
  browser.install_cft            Browser: install Chrome for Testing via npx                   
  browser.navigate               Browser: navigate to a URL (prompt, seeded with current)      
  browser.network_throttle       Browser: network throttle picker (Online/Offline/3G/WiFi)     
  browser.open                   Browser: open Chrome (CDP) — console / nav / eval             
  browser.open_url               Browser: open Chrome at a URL (prompt)                        
  browser.perf                   Browser: toggle the performance panel (P) — timings + Core Web Vitals  
  browser.print_pdf              Browser: print the page to PDF (p) → .mnml/screenshots/       
  browser.reload                 Browser: reload the current page (Page.reload)                
  browser.screenshot             Browser: screenshot the page → .mnml/screenshots/             
  browser.screenshot_node        Browser: screenshot the selected DOM node → .mnml/screenshots/  
  browser.scroll_node_into_view  Browser: scroll the selected DOM node into view               
  browser.snapshot               Browser: snapshot state (URL + network + cookies + storage)   
  browser.storage                Browser: toggle the Web Storage panel (L) — localStorage + sessionStorage  
  browser.toggle_headless        Toggle CDP headless launch (takes effect on next browser.open)  
  browser.url_history            Browser: fuzzy pick a previously-visited URL (Ctrl+R)         
  browser.wipe_profile           Browser: wipe Chrome's user-data-dir (next open starts fresh)  

## buffer  (11)

  buffer.clear_mru        Clear the buffer MRU (nav back/forward history)        
  buffer.close            Close buffer                                           ctrl+w
  buffer.last             Switch to previously-active buffer (vim `Ctrl+^`)      ctrl+tab
  buffer.next             Next buffer (positional)                               ctrl+pagedown
  buffer.next_dirty       Jump to next unsaved buffer                            
  buffer.pin_toggle       Pin / Unpin the active tab (sticks to front of strip)  
  buffer.prev             Previous buffer (positional)                           ctrl+pageup
  buffer.prev_dirty       Jump to previous unsaved buffer                        
  buffer.reopen           Re-open the most-recently-closed buffer                ctrl+shift+t
  scratch.from_clipboard  New scratch buffer from clipboard                      
  scratch.new             New scratch buffer (empty, no file)                    

## clock  (4)

  clock.hide   Clock: hide statusline clock chip  
  clock.local  Clock: show local time             
  clock.menu   Open clock menu (local ⇄ UTC)      
  clock.utc    Clock: show UTC                    

## cloud_agents  (2)

  cloud_agents.view_compact   Cloud Agents: compact row density   
  cloud_agents.view_standard  Cloud Agents: standard row density  

## dap  (23)

  dap.add_watch                      DAP: add a watch expression                                   
  dap.attach                         DAP: attach to a running process (→ picker)                   
  dap.clear_all_breakpoints          DAP: clear all breakpoints in this buffer                     
  dap.clear_watches                  DAP: clear all watch expressions                              
  dap.continue                       DAP: continue (resume from breakpoint)                        shift+f5
  dap.exceptions                     DAP: toggle exception breakpoints (→ picker)                  
  dap.list_breakpoints               DAP: list all breakpoints across open buffers                 
  dap.next                           DAP: step over                                                f10
  dap.pause                          DAP: pause running thread                                     
  dap.pick_thread                    DAP: switch to a different thread (→ picker)                  
  dap.remove_watch                   DAP: remove a watch expression (→ picker)                     
  dap.repl                           DAP: open the REPL pane (evaluate expressions)                
  dap.reverse_continue               DAP: reverse-continue to previous breakpoint                  
  dap.run                            DAP: start debug session for active buffer's filetype         f5
  dap.set_breakpoint_hit_count       DAP: set hit-count on breakpoint (e.g. >= 5, % 10)            
  dap.set_variable                   DAP: set the value of the selected variable                   
  dap.show                           DAP: show debug pane (call stack + output)                    
  dap.step_back                      DAP: step backward (reverse — requires record-replay adapter)  
  dap.step_in                        DAP: step into                                                f11
  dap.step_out                       DAP: step out                                                 shift+f11
  dap.terminate                      DAP: terminate session                                        
  dap.toggle_breakpoint              DAP: toggle breakpoint at cursor line                         f9
  dap.toggle_breakpoint_conditional  DAP: toggle conditional breakpoint at cursor                  shift+f9

## debug  (1)

  debug.toggle_click_inspector  Debug: toggle click inspector (toast rect names on each click)  

## dock  (7)

  dock.close_all         Dock: close all widgets                   
  dock.move_corner_next  Dock: move focused widget to next corner  
  dock.new_log_tail      Dock: tail a file (bottom-left)           
  dock.new_text          Dock: new text widget (bottom-left)       
  dock.new_text_br       Dock: new text widget (bottom-right)      
  dock.new_text_tl       Dock: new text widget (top-left)          
  dock.new_text_tr       Dock: new text widget (top-right)         

## edit  (6)

  picker.clipboard          Clipboard: pick from register history and paste at cursor  
  snippet.expand            Snippet: expand trigger word at cursor                     ctrl+j
  snippet.next_placeholder  Snippet: jump to next placeholder                          
  snippet.pick              Snippet: insert from picker                                
  snippet.pick_all          Snippets: list ALL (every scope)…                          
  snippet.prev_placeholder  Snippet: jump to previous placeholder                      

## editor  (55)

  editor.add_cursor_above             Add cursor on the line above (VSCode `Ctrl+Alt+Up`)           ctrl+alt+up / ctrl+alt+k
  editor.add_cursor_at_next_word      Select word / add cursor at next occurrence (VSCode `Ctrl+D`)  ctrl+d
  editor.add_cursor_below             Add cursor on the line below (VSCode `Ctrl+Alt+Down`)         ctrl+alt+down / ctrl+alt+j
  editor.bracket_match                Jump to matching bracket                                      ctrl+]
  editor.char_info                    Toast char info: dec / hex / U+XXXX (vim `ga`)                
  editor.char_utf8                    Toast UTF-8 byte sequence of char under cursor (vim `g8`)     
  editor.clear_extra_cursors          Drop all extra cursors (keep the primary)                     
  editor.copy                         Copy (Ctrl+C) — selection or current line                     
  editor.cut                          Cut (Ctrl+X) — selection or current line                      
  editor.delete_line                  Delete the current line (VSCode `Ctrl+Shift+K`)               ctrl+shift+k
  editor.file_info                    Toast file info: <path> · Ln N/M · X% (vim `Ctrl+G`)          
  editor.file_stats                   File stats: lines / words / chars / bytes / cursor position (vim `g Ctrl+G`)  
  editor.fold_all_brackets            Fold every multi-line bracket pair (`zM` fallback)            
  editor.fold_next                    Jump to next fold (`zj`)                                      
  editor.fold_prev                    Jump to previous fold (`zk`)                                  
  editor.fold_selection               Fold the visual selection (`zf` in Visual)                    
  editor.format                       Format buffer (LSP if attached, else external formatter)      
  editor.format_external              Format buffer with external formatter (prettier / rustfmt / gofmt / ruff / …)  
  editor.goto_line                    Go to line… (1-based)                                         ctrl+g
  editor.indent_line                  Indent the focused editor line (VSCode `Ctrl+]`)              
  editor.input_mode_menu              Open mode menu (vim / standard)                               
  editor.insert_alt_filename          Insert alt-buffer path (vim insert `Ctrl+R #`)                
  editor.insert_bigword_under_cursor  Insert WORD under cursor (vim insert `Ctrl+R Ctrl+A`)         
  editor.insert_current_filename      Insert current buffer's path (vim insert `Ctrl+R %`)          
  editor.insert_last_cmdline          Insert last ex-command (vim insert `Ctrl+R :`)                
  editor.insert_last_inserted         Insert last inserted text (vim insert `Ctrl+R .`)             
  editor.insert_last_search           Insert last search query (vim insert `Ctrl+R /`)              
  editor.insert_word_under_cursor     Insert identifier under cursor (vim insert `Ctrl+R Ctrl+W`)   
  editor.jump_next_edit               Jump to next edit position (vim `g,`)                         
  editor.jump_prev_edit               Jump to previous edit position (vim `g;`)                     
  editor.keyword_complete             Keyword completion: scan buffer for matches (vim insert `Ctrl+N`)  
  editor.keyword_complete_back        Keyword completion (backward, vim insert `Ctrl+P`)            
  editor.lint_external                Lint buffer with external linter (eslint / tsc / ruff / shellcheck / …)  
  editor.move_line_down               Move current line / selection down (Alt+J / Alt+Down)         alt+down / alt+j
  editor.move_line_up                 Move current line / selection up (Alt+K / Alt+Up)             alt+up / alt+k
  editor.open_at_cursor               Open path under cursor (supports `:line:col`) — palette / vim `gf`  
  editor.open_url_at_cursor           Open URL under cursor in OS browser (vim `gx`)                
  editor.outdent_line                 Outdent the focused editor line (VSCode `Ctrl+[`)             
  editor.paste                        Paste (Ctrl+V)                                                
  editor.redo                         Redo (Ctrl+Shift+Z / Ctrl+Y)                                  ctrl+shift+z
  editor.reflow_paragraph             Reflow current paragraph to text_width (vim `gqq`)            
  editor.repeat_last_substitute       Repeat last :s on current line (vim `&`)                      
  editor.section_next_end             Jump to end of next section (vim `][`)                        
  editor.section_next_start           Jump to next section start (vim `]]`)                         
  editor.section_prev_end             Jump to end of previous section (vim `[]`)                    
  editor.section_prev_start           Jump to previous section start (vim `[[`)                     
  editor.select_all                   Select all (Ctrl+A)                                           
  editor.select_all_occurrences       Select all occurrences of word at cursor (VSCode `Ctrl+Shift+L`)  ctrl+shift+l
  editor.toggle_auto_pair             Toggle bracket / quote auto-pairing                           
  editor.toggle_fold                  Toggle fold at cursor (vim `za`-ish; VS Code Ctrl+Shift+[)    Ctrl+Shift+[
  editor.toggle_keymap                Editing: toggle vim ⇄ standard keymap                         
  editor.undo                         Undo (Ctrl+Z)                                                 
  editor.unfold_all                   Unfold every fold in the active buffer (vim `zR`-ish; VS Code Ctrl+Shift+])  Ctrl+Shift+]
  editor.use_standard                 Editing: use standard (VSCode) keymap                         
  editor.use_vim                      Editing: use vim keymap                                       

## file  (26)

  file.clear_recent   Clear recent files list                                       
  file.copy           Copy selected tree file (Ctrl+C, tree focus · paste = duplicate)  
  file.cut            Cut selected tree file (Ctrl+X, tree focus · paste = move)    
  file.delete         Delete the selected tree file (Delete)                        delete
  file.duplicate      Duplicate the selected tree file in place (Ctrl+D, tree focus · name-copy.ext)  
  file.move_to        Move the selected tree file to a chosen folder…               
  file.new            New file… (workspace-relative path)                           ctrl+n
  file.new_folder     New folder… (workspace-relative path)                         
  file.open_recent_0  Open recent file #1                                           
  file.open_recent_1  Open recent file #2                                           
  file.open_recent_2  Open recent file #3                                           
  file.open_recent_3  Open recent file #4                                           
  file.open_recent_4  Open recent file #5                                           
  file.open_recent_5  Open recent file #6                                           
  file.open_recent_6  Open recent file #7                                           
  file.open_recent_7  Open recent file #8                                           
  file.open_recent_8  Open recent file #9                                           
  file.open_recent_9  Open recent file #10                                          
  file.open_settings  Open mnml config TOML in an editor pane (escape hatch — schema overlay is Ctrl+,)  
  file.paste          Paste the file clipboard into the tree row's dir (Ctrl+V, tree focus)  
  file.reload         Reload active buffer from disk (refuses if dirty)             
  file.rename         Rename the selected tree file (F2, when tree focused)         
  file.save           Save file                                                     ctrl+s
  file.save_all       Save all files                                                
  keys.edit           Customize keybindings (opens [keys.standard] in config.toml)  
  noop                (no-op — placeholder for disabled menu items)                 

## find  (15)

  find.clear                  Find: clear highlights                                       
  find.find                   Find in buffer                                               ctrl+f
  find.find_backward          Find (reverse — vim ?)                                       
  find.grep                   Grep workspace (rg / git grep) → results pane                ctrl+shift+f
  find.grep_replace           Replace every grep hit across every file (active grep pane)  
  find.next                   Find: next match                                             f3
  find.prev                   Find: previous match                                         shift+f3
  find.replace                Replace every match of the active find                       ctrl+h
  find.select_match_backward  Select previous find match (vim `gN`)                        
  find.select_match_forward   Select next find match (vim `gn`)                            
  find.selection_backward     Find: selected text (backward) — vim visual `#`              
  find.selection_forward      Find: selected text (forward) — vim visual `*`               
  find.toggle_regex           Find: toggle regex mode (sticky)                             alt+r
  find.word_backward          Find: word under cursor (backward) — vim `#`                 
  find.word_forward           Find: word under cursor (forward) — vim `*`                  

## git  (56)

  git.ai_commit               Git: write a commit message with Claude (from the staged diff)  
  git.ai_recompose            Git: rewrite HEAD's message with Claude (--amend)             
  git.blame_toggle            Git: toggle blame gutter                                      ctrl+k b
  git.branch_menu             Open branch menu                                              
  git.browse                  Git: open file at cursor on remote (GitHub / GitLab / Bitbucket)  
  git.checkout                Git: checkout a branch (local or remote)                      
  git.cherry_pick             Git: cherry-pick the selected graph commit onto HEAD          
  git.codex_commit            Git: write a commit message with Codex (from the staged diff)  
  git.commit                  Git: commit staged changes                                    ctrl+k g c
  git.copy_current_branch     Git: copy current branch name to clipboard                    
  git.copy_head_sha           Git: copy HEAD SHA (full hex) to clipboard                    
  git.delete_branch           Git: delete a local branch (picker, force -D, confirm prompt)  
  git.diff                    Git: diff the worktree                                        
  git.diff_all                Git: diff everything vs HEAD (staged + unstaged)              
  git.diff_file               Git: diff this file (split)                                   
  git.diff_next_file          Git: jump to next file in the diff pane (]f)                  
  git.diff_orig               Git: diff active buffer against on-disk version (vim :DiffOrig)  
  git.diff_prev_file          Git: jump to previous file in the diff pane ([f)              
  git.fetch                   Git: fetch --all --prune (refresh remote refs)                
  git.file_history            Git: file history (commits touching this file)                
  git.graph                   Git: commit graph (DAG browser)                               
  git.graph_filter_author     Graph: filter by author…                                      
  git.graph_filter_branch     Graph: filter by branch…                                      
  git.graph_filter_clear      Graph: clear branch filter (show all)                         
  git.graph_filter_date       Graph: filter by date range…                                  
  git.graph_filter_reset_all  Graph: clear ALL filters (branch / date / author / subject)   
  git.graph_filter_subject    Graph: filter by subject (grep)…                              
  git.jump_next_change        Git: jump to next changed hunk in this buffer (vim `]c`)      
  git.jump_prev_change        Git: jump to previous changed hunk in this buffer (vim `[c`)  
  git.merge                   Git: merge a branch into the current (--no-edit)              
  git.new_branch              Git: create a new branch                                      
  git.next_repo               Git: cycle to next repo (multi-repo workspace)                alt+]
  git.peek_change             Git: peek change at cursor (popup of HEAD diff)               
  git.prev_repo               Git: cycle to previous repo (multi-repo workspace)            alt+[
  git.pull                    Git: pull --ff-only (fail on non-fast-forward)                
  git.push                    Git: push (auto --set-upstream on first push)                 
  git.push_tags               Git: push --tags (publish all local tags to origin)           
  git.rebase                  Git: rebase the current branch onto another (local or remote)  
  git.recent_branches         Git: recent branches (sorted by last commit date)             
  git.redo                    Git: redo the last undone commit                              
  git.reflog                  Git: reflog (HEAD history; pick to open commit diff)          
  git.refresh_repos           Git: rediscover repos under workspace                         
  git.revert                  Git: revert the selected graph commit (creates a new commit)  
  git.stash                   Git: stash (push -u, optional message)                        
  git.stash_drop              Git: stash drop (pick a stash to delete)                      
  git.stash_list              Git: stash list (pick to apply — keeps the stash)             
  git.stash_pop               Git: stash pop (apply + drop most recent)                     
  git.status_pane             Git: status / staging view                                    
  git.switch_repo             Git: switch active repo (multi-repo workspace)                
  git.tag                     Git: create tag (annotated; on HEAD or selected graph commit)  
  git.tag_delete              Git: delete tag (picker)                                      
  git.undo                    Git: undo last commit (reset --soft HEAD~1)                   
  git.worktree_add            Git: add a linked worktree (prompt for path + branch)         
  git.worktree_list           Git: open another worktree as a workspace                     
  git.worktree_remove         Git: remove a linked worktree (confirm prompt)                
  git.worktrees               Git: worktrees → open a shell in one                          

## go  (12)

  nav.back                Go back (previous cursor / file; in Browser pane: history.back)  alt+left
  nav.forward             Go forward (undo an Alt+Left; in Browser pane: history.forward)  alt+right
  nav.jump_toggle_prev    Vim: toggle to previous jump position (`` ` ` ``)             
  palette                 Command palette                                               ctrl+shift+p
  picker.buffers          Switch buffer…                                                
  picker.files            Open file…                                                    ctrl+p
  picker.marks            Pick a mark to jump to (local + global)                       
  picker.recent_commands  Pick a recently-run command                                   
  qf.first                Quickfix: first grep result                                   
  qf.last                 Quickfix: last grep result                                    
  qf.next                 Quickfix: next grep result (`:cnext`)                         
  qf.prev                 Quickfix: prev grep result (`:cprev`)                         

## harpoon  (11)

  harpoon.add     Harpoon: pin the active file into the next free slot  
  harpoon.goto_1  Harpoon: jump to slot 1                               
  harpoon.goto_2  Harpoon: jump to slot 2                               
  harpoon.goto_3  Harpoon: jump to slot 3                               
  harpoon.goto_4  Harpoon: jump to slot 4                               
  harpoon.goto_5  Harpoon: jump to slot 5                               
  harpoon.goto_6  Harpoon: jump to slot 6                               
  harpoon.goto_7  Harpoon: jump to slot 7                               
  harpoon.goto_8  Harpoon: jump to slot 8                               
  harpoon.goto_9  Harpoon: jump to slot 9                               
  harpoon.menu    Harpoon: open the pinned-files picker                 

## http  (89)

  auth.apply_preset              Auth: apply a saved preset → active Request Authorization header  
  auth.extract_bearer            Auth: extract bearer token from clipboard text                
  auth.save_preset               Auth: save current Authorization header as a named preset     
  cookies.clear                  Cookies: clear every cookie in the jar                        
  cookies.delete                 Cookies: remove one cookie (picker)                           
  cookies.normalize_clipboard    Cookies: normalize clipboard text → canonical `name=v; name=v` form  
  cookies.persist                Cookies: write the jar to .mnml/cookies.json                  
  cookies.show                   Cookies: open picker over the persistent jar                  
  http.abort                     HTTP: cancel any in-flight bench / sync work                  
  http.ai_build                  HTTP: build a request from a natural-language description (Claude)  
  http.ai_debug                  HTTP: ask Claude why this request is failing                  
  http.bench                     HTTP: bench active request 10× (concurrent)                   
  http.capture_now               HTTP: append browser pane network entries → captured log      
  http.capture_start             HTTP: launch browser + start capturing (or dump current if browser is open)  
  http.clear_captured            HTTP: clear the CAPTURED log (truncates captured.jsonl)       
  http.clear_recent              HTTP: clear the RECENT history (truncates history.jsonl)      
  http.copy_ai_prompt            HTTP: copy AI-ready "debug this failure" prompt to clipboard  
  http.copy_as                   HTTP: copy request as code (curl / Python / JS / Go / wget / HTTPie)  
  http.copy_curl                 HTTP: copy the request as a curl command                      
  http.copy_response_body        HTTP: copy the response body                                  
  http.copy_response_headers     HTTP: copy the response headers                               
  http.cycle_method              HTTP: cycle method (GET→POST→PUT→DELETE→PATCH→…)              
  http.delete_env_key            HTTP: delete env var (from active .env)                       
  http.diff_last_two             HTTP: diff the active Request pane's last two responses       
  http.edit_env                  HTTP: structured editor for the active env file (.rqst/env/<name>.env)  
  http.fan_envs                  HTTP: fan the active request out against every env file in parallel  
  http.field_copy                HTTP: copy focused Request field to clipboard                 
  http.field_cut                 HTTP: cut focused Request field to clipboard                  
  http.field_paste               HTTP: paste clipboard at Request field cursor                 
  http.field_select_all          HTTP: snap cursor to end + copy field                         
  http.format_body               HTTP: pretty-print JSON Body field of the active Request pane  
  http.generate_code             HTTP: copy request as code (alias for http.copy_as)           
  http.history                   HTTP: open .rqst/history.jsonl (one-line-per-send log)        
  http.history_global            HTTP: history picker across all workspaces (~/.config/mnml/history-global.jsonl)  
  http.import_har                HTTP: import a .har file from clipboard or path               
  http.import_postman            HTTP: import a Postman Collection from clipboard              
  http.insert_header             HTTP: insert a common header (Accept, Content-Type, Authorization, …)  
  http.jump_to_env_var           HTTP: jump to env var definition at cursor / active request pane  
  http.lookup                    HTTP: lookup — fill an env var from a live API response       
  http.new                       HTTP: new blank request pane (Postman-style scratch)          
  http.new_chain                 HTTP: create a new .chain.json in .mnml/chains/               
  http.new_collection            HTTP: create a new request collection under .mnml/collections/  
  http.new_env                   HTTP: create a new .env in .mnml/env/                         
  http.new_request               HTTP: create a new blank .http request                        
  http.next_block                HTTP: move cursor to the next ### block in a multi-block file  
  http.params_add                HTTP: add a query parameter (?key=value) to the active Request URL  
  http.params_clear              HTTP: clear all query parameters from the active Request URL  
  http.paste_curl                HTTP: paste curl from clipboard — populate active Request pane  
  http.paste_source              HTTP: parse Source tab buffer into Method/URL/Headers/Body    
  http.pick_env                  HTTP: pick .env file (session override)                       
  http.prev_block                HTTP: move cursor to the previous ### block                   
  http.refresh                   HTTP: rescan collections / files / envs / captured log        
  http.regenerate_body           HTTP: regenerate body dynamic values (fresh timestamps + UUIDs)  
  http.replay_mock               HTTP: replay integration .mock.json into the active request pane  
  http.reset_env                 HTTP: reset .env override (fall back to MNML_ENV)             
  http.revalidate_schema         HTTP: re-run schema validation on the active Request pane's last response  
  http.run_chain                 HTTP: run a .chain.json from .mnml/chains (multi-step request chain)  
  http.save                      HTTP: save request (Save-As if new)                           
  http.save_mock                 HTTP: save current response as a integration .mock.json       
  http.save_response             HTTP: save active Response body to a file (prompt for path)   
  http.send                      HTTP: send request (.http/.curl) — or re-fire a request pane  
  http.send_streaming            HTTP: send active request as a Server-Sent Events stream      
  http.set_env_var_value         HTTP: set value for env var at cursor / active request pane   
  http.set_method.delete         HTTP: set method = DELETE                                     
  http.set_method.get            HTTP: set method = GET                                        
  http.set_method.head           HTTP: set method = HEAD                                       
  http.set_method.options        HTTP: set method = OPTIONS                                    
  http.set_method.patch          HTTP: set method = PATCH                                      
  http.set_method.post           HTTP: set method = POST                                       
  http.set_method.put            HTTP: set method = PUT                                        
  http.show_schema_errors        HTTP: open scratch buffer with response schema validation errors  
  http.sync                      HTTP: sync swagger sources → .curl stub files                 
  http.sync_check                HTTP: check for drift between swagger sources + on-disk stubs (dry run)  
  http.toggle_auto_format_body   HTTP: toggle auto-format request body (paste/send/load)       
  http.toggle_collapse_all       HTTP: collapse / expand all sidebar sections                  
  http.toggle_edit_split         HTTP: split the Request edit area side-by-side (Body | Vars)  
  http.toggle_response_wrap      HTTP: toggle response body wrap                               
  http.toggle_split_orientation  HTTP: cycle Request/Response split orientation (Auto → Vertical → Horizontal)  
  http.toggle_sync_normalize     HTTP: toggle sync normalization ({{$isoTimestamp}} / {{$uuid}} substitution)  
  http.toggle_view               HTTP: toggle Request pane between Edit ⇄ Response             
  http.view_captured             HTTP: open .rqst/captured/log.jsonl (captured browser traffic)  
  http.view_source               HTTP: open the active request's source file as text           
  jwt.decode                     JWT: decode clipboard token (claims only, no signature)       
  sse.parse_active_response      SSE: parse active Response pane body as Server-Sent Events    
  ws.connect                     WebSocket: connect to a URL (native, persistent)              
  ws.disconnect                  WebSocket: close the active connection                        
  ws.history                     WebSocket: picker over past URLs (~/.mnml/ws-history)         
  ws.send                        WebSocket: send the active .ws file via websocat              
  ws.send_message                WebSocket: send a message on the active connection            

## integrations  (18)

  integrations.bake_ai_glyphs           Integrations: bake AI chip glyphs (Claude + Codex) into MnmlSymbols  
  integrations.bake_all_glyphs          Integrations: bake ALL mnml glyphs (AI + AWS + Dev) into MnmlSymbols  
  integrations.bake_integration_glyphs  Integrations: bake integration-shipped SVGs from ~/.config/mnml/glyphs/ into MnmlSymbols  
  integrations.copy_id                  Integrations: copy an id to clipboard (picker)                
  integrations.edit                     Integrations: edit a chip (picker)                            
  integrations.edit_claude_glyph        Integrations: open glyph builder for Claude Code (F1E00)      
  integrations.edit_codex_glyph         Integrations: open glyph builder for Codex (F1E01)            
  integrations.glyph_builder            Integrations: add custom glyph (SVG → font with live preview)  
  integrations.icon_picker              Integrations: browse Nerd Font glyphs (copies to clipboard)   
  integrations.patch_nerd_font_svg      Integrations: bake an SVG into your Nerd Font as a glyph      
  integrations.refresh                  Integrations: re-scan manifests in .mnml/integrations/ + ~/.config/mnml/integrations/  
  integrations.refresh_binary_cache     Integrations: refresh installed-binary detection              
  integrations.remove                   Integrations: remove a chip (picker)                          
  integrations.show_details             Integrations: open detail pane for the focused integration    ctrl+k i d
  integrations.show_manifest            Integrations: open a chip's manifest file (picker)            
  integrations.toggle_enabled           Integrations: enable / disable a chip (picker)                
  launcher.add_local                    Launcher: add a local chip (glyph / label / :term <cmd>)      
  marketplace.refresh                   Marketplace: refresh (fetch published apps + community launchers)  

## lsp  (34)

  lsp.clear_highlights         LSP: clear symbol highlights                                  
  lsp.code_action              LSP: code actions at cursor (→ picker)                        ctrl+.
  lsp.completion               LSP: complete at cursor (→ picker)                            ctrl+space
  lsp.diagnostics              LSP: diagnostics list (project problems)                      ctrl+shift+m
  lsp.diagnostics_filter       LSP: cycle diagnostics severity filter (All ↔ Warnings ↔ Errors)  
  lsp.fold_all                 LSP: fold all (server-suggested ranges)                       
  lsp.format                   LSP: format document                                          ctrl+shift+i
  lsp.goto_declaration         LSP: go to declaration                                        
  lsp.goto_definition          LSP: go to definition                                         f12
  lsp.goto_implementation      LSP: go to implementation                                     
  lsp.goto_type_definition     LSP: go to type definition                                    
  lsp.highlight_symbol         LSP: highlight all usages of symbol at cursor                 
  lsp.hover                    LSP: hover (docs at cursor)                                   ctrl+k ctrl+i
  lsp.incoming_calls           LSP: incoming calls (who calls this)                          
  lsp.inlay_hints_toggle       LSP: toggle inlay hints (type / parameter chips)              
  lsp.next_diagnostic          LSP: next diagnostic                                          
  lsp.organize_imports         LSP: organize imports                                         alt+shift+o
  lsp.outgoing_calls           LSP: outgoing calls (what this calls)                         
  lsp.peek_definition          LSP: peek definition in a horizontal split below the current pane  
  lsp.peek_definition_overlay  LSP: peek definition as a floating overlay (cursor doesn't move; VS Code Alt+F12)  Alt+F12
  lsp.prev_diagnostic          LSP: previous diagnostic                                      
  lsp.quick_fix                LSP: quick fix (auto-apply first code action)                 alt+enter
  lsp.references               LSP: find references (→ picker)                               shift+f12
  lsp.rename                   LSP: rename symbol                                            f2
  lsp.selection_expand         LSP: expand selection to next semantic range                  
  lsp.selection_shrink         LSP: shrink selection to previous semantic range              
  lsp.signature_help           LSP: signature help (param info popup at cursor)              ctrl+shift+space
  lsp.signature_next           LSP: next signature (overload)                                
  lsp.signature_prev           LSP: previous signature (overload)                            
  lsp.subtypes                 LSP: subtypes of type at cursor                               
  lsp.supertypes               LSP: supertypes of type at cursor                             
  lsp.symbols                  LSP: symbols in this file (→ picker)                          ctrl+shift+o
  lsp.workspace_symbols        LSP: workspace symbols — search across the project            
  outline.show                 LSP: outline pane (symbols sidebar for this file)             

## markdown  (1)

  markdown.cycle_engine  Markdown preview engine — cycle builtin / glow (external ANSI renderer)  

## misc  (1)

  noop.info  (info row · no action)  

## mount  (4)

  integration.install  Integration: install any family integration by id (Pty or Mount)  
  mount.open           Mount: open a hosted integration pane (prompts for binary)    
  mounts.install       Mounts: install a Mount-capable family integration (auto-registers manifest)  
  mounts.refresh       Mounts: re-scan manifests in .mnml/mounts/ + ~/.config/mnml/mounts/  

## notes  (1)

  notes.new  Notes: create a new note in .mnml/notes/  

## perf  (4)

  perf.hide_stress    Perf: hide the stress meter chip                  
  perf.reset_stress   Perf: reset the stress meter's frame-time window  
  perf.toast_stress   Perf: toast the current stress numbers            
  perf.toggle_stress  Perf: toggle the stress meter chip                

## picker  (2)

  picker.recent            Recent files                                ctrl+r
  picker.workspace_symbol  Go to Symbol in Workspace (VS Code Ctrl+T)  ctrl+t

## pr  (2)

  pr.picker   PRs: cross-host fuzzy picker (Enter ⇒ URL · Tab ⇒ pipeline)  
  pr.refresh  PRs: refresh cross-host cache (background)                   

## project  (3)

  project.next_todo  Jump to next TODO / FIXME / HACK / XXX (vim ]t)       
  project.prev_todo  Jump to previous TODO / FIXME / HACK / XXX (vim [t)   
  project.todos      Project: scan for TODO / FIXME / HACK / XXX comments  

## tab  (21)

  tab.close       Close active tab page                    
  tab.first       First tab page                           
  tab.goto_1      Jump to tab page 1                       alt+1
  tab.goto_2      Jump to tab page 2                       alt+2
  tab.goto_3      Jump to tab page 3                       alt+3
  tab.goto_4      Jump to tab page 4                       alt+4
  tab.goto_5      Jump to tab page 5                       alt+5
  tab.goto_6      Jump to tab page 6                       alt+6
  tab.goto_7      Jump to tab page 7                       alt+7
  tab.goto_8      Jump to tab page 8                       alt+8
  tab.goto_9      Jump to tab page 9                       alt+9
  tab.last        Last tab page                            
  tab.list        List tab pages                           
  tab.move_left   Move active tab page one position left   
  tab.move_right  Move active tab page one position right  
  tab.new         New tab page                             ctrl+k n
  tab.next        Next tab page (vim gt)                   
  tab.only        Close all other tab pages                
  tab.picker      Fuzzy picker over tab pages              
  tab.prev        Previous tab page (vim gT)               
  tab.reopen      Reopen last closed tab page              

## term  (19)

  task.run                  Tasks: run a configured task in a terminal pane       
  term.btop                 Term: open btop (alias of tools.btop)                 
  term.focus_or_open_shell  Terminal: focus existing shell or open one            
  term.htop                 Term: open htop (alias of tools.htop)                 
  term.iftop                Term: open iftop (alias of tools.iftop)               
  term.rename               Terminal: rename this session (shown in the tab)      
  term.scratch_toggle       Terminal: quick scratch strip at the bottom (Ctrl+`)  ctrl+`
  term.shell                Terminal: open a NEW shell (split beside)             
  term.shell_bottom         Terminal: new shell in bottom half                    
  term.shell_left           Terminal: new shell in left half                      
  term.shell_right          Terminal: new shell in right half                     
  term.shell_top            Terminal: new shell in top half                       
  tools.btop                Tools: open btop (or hint brew install)               
  tools.dust                Tools: open dust (or hint brew install)               
  tools.gh                  Tools: open gh (GitHub CLI, or hint brew install)     
  tools.htop                Tools: open htop (or hint brew install)               
  tools.iftop               Tools: open iftop (or hint brew install)              
  tools.lazygit             Tools: open lazygit (or hint brew install)            
  tools.ncdu                Tools: open ncdu (or hint brew install)               

## terminal  (3)

  term.clear    Terminal: clear screen (`Ctrl+L` in the child)      
  term.paste    Terminal: paste clipboard into the active Pty pane  
  term.restart  Terminal: restart the child process in this pane    

## test  (25)

  cargo.build         Cargo: run `cargo build` in a pty pane                        
  cargo.check         Cargo: run `cargo check` in a pty pane                        
  cargo.clippy        Cargo: run `cargo clippy --all-targets` in a pty pane         
  cargo.fmt           Cargo: run `cargo fmt` in a pty pane                          
  cargo.test          Cargo: run `cargo test` in a pty pane                         
  flaky.show          Test: flaky-test dashboard (wobbly tests from history)        
  go.build            Go: run `go build ./...` in a pty pane                        
  go.run              Go: run `go run .` in a pty pane                              
  go.run_path         go: prompt for a package path → run `go run <path>`           
  go.test             Go: run `go test ./...` in a pty pane                         
  go.vet              Go: run `go vet ./...` in a pty pane                          
  npm.build           npm: run `npm run build` in a pty pane                        
  npm.install         npm: run `npm install` in a pty pane                          
  npm.lint            npm: run `npm run lint` in a pty pane                         
  npm.run             npm: run `npm run dev` (use npm.run_script for a different script)  
  npm.run_script      npm: prompt for a script name → run `npm run <script>`        
  npm.start           npm: run `npm start` in a pty pane                            
  npm.test            npm: run `npm test` in a pty pane                             
  pytest.failed       pytest: re-run only last-failed (`--lf`)                      
  pytest.run          pytest: run the suite in a pty pane                           
  test.heal           Tests: ask Claude to fix the highlighted failing test         
  test.rerun_failed   Tests: re-run last-failed (Playwright --last-failed)          
  test.run_all        Tests: run the whole Playwright suite                         
  test.run_at_cursor  Tests: run the test at the cursor                             
  test.run_file       Tests: run this spec file                                     

## toast  (2)

  toast.dismiss_all      Toast: dismiss every ephemeral toast    
  toast.dismiss_current  Toast: dismiss the right-clicked toast  

## tools  (1)

  tools.installer  Browse external tools (Mason-style — LSPs / formatters / linters)  

## view  (146)

  agents.new_from_pr                 Agents: + New session from a PR (Claude Agent SDK · multi-select + action)  
  cloud_agents.focus_quick_input     Cloud agents: focus the quick-fire prompt input               
  cloud_agents.new_run               Cloud agents: fire a new ECS run for a Jira ticket            
  cloud_agents.new_run_wizard        Cloud agents: + New cloud run (Managed Agents · ECS)          
  cloud_agents.refresh_run_detail    Cloud agents: refresh the active run-detail pane (logs + artifacts)  
  cloud_agents.spawn_worker          Cloud agents: spawn ant beta:worker poll for a self-hosted sandbox  
  cloud_agents.toggle_view           Cloud agents: toggle row density (compact ↔ standard)         
  cloud_agents.webhook_docs          Cloud agents: open webhook-handler docs (alternative to ant poll)  
  focus.cycle                        Cycle focus (tree ⇄ editor)                                   ctrl+e
  integrations.show_installed        Integrations: show Installed tab                              
  integrations.show_marketplace      Integrations: show Marketplace tab                            
  integrations.toggle_tab            Integrations: toggle Installed/Marketplace tab                
  layout.merge_to_tabs               Layout: merge splits into tabs (splits→tabs)                  
  layout.spread_to_splits            Layout: spread tabs into splits (tabs→splits)                 
  markdown.edit_raw                  Markdown: swap the active preview for the raw editor          
  markdown.link_check                Markdown: check all link targets (broken ones → Quickfix)     
  markdown.preview                   Markdown: open rendered preview (split)                       
  setup.install_to_path              Setup: install mnml to PATH (so `mnml .` works anywhere)      
  theme.pick                         Pick theme…                                                   
  theme.reset                        Theme: reset to config default                                
  theme.toggle                       Theme: toggle (light ↔ dark)                                  ctrl+k t
  todos.refresh                      TODOs: rescan the workspace                                   
  tree.collapse_all                  Collapse all folders in the file tree                         
  tree.expand_all                    Expand all folders in the file tree                           
  tree.refresh                       Refresh file tree                                             
  tree.toggle_collapse_all           Toggle: collapse-all / expand-all                             
  view.about                         About mnml (version + workspace metadata)                     
  view.activity_agents               Activity: show Agents (Claude / Codex dashboard)              
  view.activity_cloud_agents         Activity: show Cloud agents (ECS runner)                      
  view.activity_debug                Activity: show Debug                                          ctrl+shift+d
  view.activity_explorer             Activity: show Explorer                                       
  view.activity_git                  Activity: open git graph                                      ctrl+shift+g
  view.activity_http                 Activity: show HTTP (.http files + recent requests)           
  view.activity_integrations         Activity: show Integrations                                   ctrl+shift+x
  view.activity_notes                Activity: show Notes (workspace scratch notes)                
  view.activity_search               Activity: show Search                                         
  view.activity_sessions             Activity: show Sessions (vertical session tabs)               ctrl+k s
  view.activity_todos                Activity: show TODOs (TODO/FIXME/XXX/HACK/REVIEW markers)     
  view.add_workspace                 Add a workspace (runtime — not persisted)                     
  view.ai_chip_toggle_font           Toggle AI chip font (JBM-NF patched ↔ mnml-baked)             
  view.ai_layout_grid                AI layout: grid (auto-tile splits, max 8)                     
  view.ai_layout_tabs                AI layout: tabs (append to active leaf)                       
  view.cheatsheet                    Open the cheatsheet pane (every chord → command)              
  view.close_others                  Close all other panes (keep active; respects unsaved guards)  
  view.close_split                   Close split / buffer                                          
  view.cluster_mode_auto             Top-bar cluster mode: Auto                                    
  view.cluster_mode_compact          Top-bar cluster mode: Compact                                 
  view.cluster_mode_expanded         Top-bar cluster mode: Expanded                                
  view.cmdline_history               Open cmdline-history pane (vim q:)                            
  view.commands_reference            Commands reference — every mnml command, grouped, in a scratch buffer  
  view.context_menu_at_focus         Open the context menu for the focused element (Shift+F10)     shift+f10
  view.cursor_to_bottom              Scroll cursor to viewport bottom (vim `zb`)                   
  view.cursor_to_center              Scroll cursor to viewport center (vim `zz`)                   
  view.cursor_to_top                 Scroll cursor to viewport top (vim `zt`)                      
  view.discovery                     Click discovery overlay (palette: 'view: discovery')          
  view.equalize_splits               Equalize every split so all panes render at equal size (vim `Ctrl+W =`)  
  view.focus_down                    Focus split down                                              ctrl+k ctrl+down
  view.focus_left                    Focus split left                                              ctrl+k ctrl+left
  view.focus_next_split              Focus next split                                              
  view.focus_pane                    Focus the active pane (reverse of view.focus_tree)            
  view.focus_right                   Focus split right                                             ctrl+k ctrl+right
  view.focus_right_panel             Focus the right side panel                                    ctrl+k r
  view.focus_tab_1                   Focus tab 1                                                   ctrl+1
  view.focus_tab_2                   Focus tab 2                                                   ctrl+2
  view.focus_tab_3                   Focus tab 3                                                   ctrl+3
  view.focus_tab_4                   Focus tab 4                                                   ctrl+4
  view.focus_tab_5                   Focus tab 5                                                   ctrl+5
  view.focus_tab_6                   Focus tab 6                                                   ctrl+6
  view.focus_tab_7                   Focus tab 7                                                   ctrl+7
  view.focus_tab_8                   Focus tab 8                                                   ctrl+8
  view.focus_tab_last                Focus last tab (VS Code Ctrl+9 convention)                    ctrl+9
  view.focus_tree                    Focus the file tree (without toggling)                        ctrl+shift+e
  view.focus_up                      Focus split up                                                ctrl+k ctrl+up
  view.git_commit_focus              Activity: focus the Git section's commit textarea             
  view.help                          Help overlay (auto-generated keymap reference)                f1
  view.hscroll_left                  Scroll viewport one column left (vim `zh`)                    
  view.hscroll_left_half             Scroll viewport a half-screen left (vim `zH`)                 
  view.hscroll_right                 Scroll viewport one column right (vim `zl`)                   
  view.hscroll_right_half            Scroll viewport a half-screen right (vim `zL`)                
  view.image_open                    View: open image file (PNG/JPG/GIF/WebP/BMP)                  
  view.manage_workspaces             Manage workspaces… (rename / reorder / group)                 
  view.maximize_height               Maximize active split height (vim `Ctrl+W _`)                 
  view.maximize_width                Maximize active split width (vim `Ctrl+W |`)                  
  view.menu_bar_cycle                Cycle menu bar visibility (always → auto-hide → hidden)       
  view.move_cursor_view_bottom       Move cursor to bottom of viewport (vim `L`)                   
  view.move_cursor_view_middle       Move cursor to middle of viewport (vim `M`)                   
  view.move_cursor_view_top          Move cursor to top of viewport (vim `H`)                      
  view.move_split_down               Move active split to the bottom of its parent (vim `Ctrl+W J`)  
  view.move_split_left               Move active split to the left of its parent (vim `Ctrl+W H`)  
  view.move_split_right              Move active split to the right of its parent (vim `Ctrl+W L`)  
  view.move_split_up                 Move active split to the top of its parent (vim `Ctrl+W K`)   
  view.move_to_new_tab               Move active split to a new tab page (vim `Ctrl+W T`)          
  view.open_default_workspace        Open the configured default workspace                         
  view.redraw                        Force a full redraw (clears the terminal)                     
  view.remove_workspace              Remove an extra workspace (runtime)                           
  view.reset_tree_width              Reset file tree width to the config default                   
  view.reveal_active                 Reveal active file in OS Finder / Explorer                    
  view.right_panel_close_tab         Right panel: close the active tab                             ctrl+alt+w
  view.right_panel_next_tab          Right panel: switch to next tab                               
  view.right_panel_prev_tab          Right panel: switch to previous tab                           
  view.rotate_splits                 Rotate the active split with its integration (vim `Ctrl+W r`)  
  view.scroll_buffer_down            Scroll buffer one line down (vim `Ctrl+E`)                    
  view.scroll_buffer_up              Scroll buffer one line up (vim `Ctrl+Y`)                      
  view.settings                      Settings overlay (keyboard-driven schema editor)              ctrl+,
  view.split_down                    Split editor down (stacked)                                   ctrl+shift+\
  view.split_goto_definition         Split + jump to definition (vim `Ctrl+W d`)                   
  view.split_grow_height             Grow active split's height (vim `Ctrl+W +`)                   
  view.split_grow_width              Grow active split's width (vim `Ctrl+W >`)                    
  view.split_new_scratch             Split + open a fresh scratch buffer (vim `Ctrl+W n`)          
  view.split_open_file_under_cursor  Split + open file under cursor (vim `Ctrl+W f`)               
  view.split_right                   Split editor right (side by side)                             ctrl+\
  view.split_shrink_height           Shrink active split's height (vim `Ctrl+W -`)                 
  view.split_shrink_width            Shrink active split's width (vim `Ctrl+W <`)                  
  view.switch_workspace              Switch workspace (primary ↔ extras)                           ctrl+k ctrl+o
  view.tab_bar_ai_both               Tab bar AI chips: show Claude + Codex                         
  view.tab_bar_ai_claude_only        Tab bar AI chips: show Claude only                            
  view.tab_bar_ai_codex_only         Tab bar AI chips: show Codex only                             
  view.tab_bar_ai_none               Tab bar AI chips: hide (show none)                            
  view.toggle_auto_equalize_splits   Auto-equalize splits on split / close (toggle)                
  view.toggle_auto_md_preview        Toggle auto-open markdown preview on file open                
  view.toggle_bracket_rainbow        Toggle rainbow brackets (depth-cycling color on ()[]{})       
  view.toggle_breadcrumb             Toggle the editor breadcrumb row (path above each pane)       
  view.toggle_color_column           Toggle line-length color column (vim :set cc=80)              
  view.toggle_hidden                 Toggle hidden files in focused tree section                   
  view.toggle_hidden_all             Toggle hidden files across every workspace section            
  view.toggle_highlight_trailing_ws  Toggle trailing-whitespace highlight (red bg on trailing space/tab)  
  view.toggle_highlight_word         Toggle 'highlight other occurrences of word under cursor'     
  view.toggle_hover_help             Toggle the Ableton-style hover-help strip (bottom-left)       
  view.toggle_integrations_section   Toggle the integrations section in the rail (collapse/expand)  
  view.toggle_picker_position        Picker: toggle position (center ⇄ top)                        
  view.toggle_relative_numbers       Toggle relative line numbers                                  
  view.toggle_render_markdown        Toggle inline-rendered markdown (render-markdown.nvim style)  
  view.toggle_right_panel            Toggle the right side panel                                   Ctrl+Shift+B
  view.toggle_scrollbar              Toggle the editor scrollbar (right-edge thumb)                
  view.toggle_sticky_context         Toggle sticky scope context (treesitter-context-style header)  
  view.toggle_todo_highlight         Toggle TODO/FIXME/HACK/XXX keyword highlight                  
  view.toggle_tree                   Toggle file tree (rail on/off)                                ctrl+b
  view.toggle_tree_section           Toggle workspace section (collapse/expand the file list)      
  view.toggle_whitespace             Toggle visible whitespace markers (· / →)                     
  view.toggle_wrap                   Toggle line wrapping (vim :set wrap)                          
  view.welcome                       Welcome overlay (shortcuts cheatsheet)                        
  view.workspace_menu                Open workspace menu                                           
  view.workspace_up                  Navigate the workspace root up one level (..)                 
  view.zen                           Zen mode (hide tree + bufferline + statusline)                ctrl+k z
  whichkey.leader                    Leader menu (which-key)                                       ctrl+k

## vim  (4)

  vim.dot_repeat         Vim: repeat last change (.)                 
  vim.go_to_last_insert  Vim: jump to last edit + enter Insert (gi)  
  vim.macro_replay       Vim: replay last recorded macro (@)         
  vim.macro_toggle       Vim: start / stop macro recording (q)       

