# mnml-integration.zsh — tells the terminal pane mnml runs this shell in
# where each prompt, command line and command output starts (OSC 133),
# and which directory the shell is in (OSC 7).
#
#   133;A;redraw=1  a prompt starts; zsh redraws it itself on a resize,
#                   so the terminal may blank it before reflowing it
#   133;B           the prompt ends and the command line starts
#   133;C           the command runs; its output starts here
#   133;D;<status>  the command finished with this exit status
#
# A and B go INTO the prompt, each wrapped in %{ %} so zsh counts them
# as zero columns, which is what lets zsh's own redraw after a resize
# mark the prompt again. C and D are written by the preexec / precmd
# hooks. mnml sources this from its .zshenv; to use it by hand, source
# it from an interactive zsh.
#
# It adds marks and nothing else: the prompt, aliases and plugins are
# the user's. It stands aside when another integration already marks
# prompts, and on a zsh without add-zsh-hook it does nothing at all.

[[ -o interactive ]] || return 0
(( ${+__mnml_si_loaded} )) && return 0
builtin autoload -Uz add-zsh-hook 2>/dev/null || return 0
typeset -g __mnml_si_loaded=1

typeset -g __mnml_si_a=$'\e]133;A;redraw=1\a'
typeset -g __mnml_si_b=$'\e]133;B\a'
typeset -g __mnml_si_ran=

# Whether something else already writes OSC 133: a hook of a known
# integration (ghostty, kitty, VS Code, iTerm2, WezTerm, the mnml
# prompt), any hook whose body writes a 133 mark, or a prompt that
# carries one.
__mnml_si_other() {
    local f
    for f in $precmd_functions $preexec_functions; do
        [[ $f == __mnml_si_* ]] && continue
        case $f in
            _ghostty_* | _ksi_* | __vsc_* | iterm2_* | __wezterm_* | __mnml_precmd | __mnml_preexec) return 0 ;;
        esac
        [[ ${functions[$f]-} == *133\;* ]] && return 0
    done
    [[ $PS1 == *133\;* ]]
}

# Runs once, at the first prompt: by then the user's .zshrc has set its
# prompt and hooks, so these land after theirs.
__mnml_si_init() {
    local ret=$?
    add-zsh-hook -d precmd __mnml_si_init
    unfunction __mnml_si_init
    if __mnml_si_other; then
        unset __mnml_si_a __mnml_si_b __mnml_si_ran
        unfunction __mnml_si_other __mnml_si_precmd __mnml_si_preexec __mnml_si_cwd
        return $ret
    fi
    add-zsh-hook precmd __mnml_si_precmd
    add-zsh-hook preexec __mnml_si_preexec
    # zsh runs this round's hooks from a copy of the list, so the new
    # one would first run at the next prompt: run it for this one now.
    __mnml_si_precmd $ret
}

__mnml_si_precmd() {
    local ret=${1:-$?}
    # D only for a command that ran (not for an empty line).
    if [[ -n $__mnml_si_ran ]]; then
        builtin print -rn -- $'\e]133;D;'$ret$'\a'
        __mnml_si_ran=
    fi
    __mnml_si_cwd
    # The marks go into the prompt itself, again whenever a theme has
    # rebuilt it since the last prompt. Outside %{ %} (no prompt_percent)
    # they are only miscounted, never shown.
    local a=$__mnml_si_a b=$__mnml_si_b
    if [[ -o prompt_percent ]]; then
        a="%{$a%}" b="%{$b%}"
    fi
    if [[ $PS1 != "$a"* || $PS1 != *"$b" ]]; then
        PS1=${PS1//"$a"/}
        PS1=${PS1//"$b"/}
        PS1=$a$PS1$b
    fi
    # Stay the last hook, so a theme that rebuilds the prompt in its own
    # precmd is marked too (from the next prompt on).
    if [[ ${precmd_functions[-1]} != __mnml_si_precmd ]]; then
        precmd_functions=(${precmd_functions:#__mnml_si_precmd} __mnml_si_precmd)
    fi
    return $ret
}

__mnml_si_preexec() {
    builtin print -rn -- $'\e]133;C\a'
    __mnml_si_ran=1
}

# OSC 7: file://host/path, the path's bytes percent-encoded where a URL
# needs it.
__mnml_si_cwd() {
    local LC_ALL=C url= c i
    for (( i = 1; i <= ${#PWD}; i++ )); do
        c=${PWD[i]}
        case $c in
            [-/._~A-Za-z0-9]) url+=$c ;;
            *)
                builtin printf -v c '%%%02X' "'$c"
                url+=$c
                ;;
        esac
    done
    builtin print -rn -- $'\e]7;file://'${HOST}${url}$'\a'
}

add-zsh-hook precmd __mnml_si_init 2>/dev/null || unset __mnml_si_loaded
