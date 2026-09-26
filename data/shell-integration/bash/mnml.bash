# mnml.bash — mnml starts a shell pane's bash as `bash --init-file
# <this file>`, so it tells the terminal pane where each prompt,
# command line and command output starts (OSC 133) and which directory
# the shell is in (OSC 7), and nothing in the user's dotfiles has to
# change. It works on bash 3.2 (macOS's) and later.
#
#   133;A;redraw=last  a prompt starts; on a resize readline redraws
#                      only its last line
#   133;B              the prompt ends and the command line starts
#   133;C              the command runs; its output starts here
#   133;D;<status>     the command finished with this exit status
#
# ── 1. the startup files, as bash would have read them ──
# `--init-file` replaces ~/.bashrc and is only read by a shell that is
# NOT a login shell. The pane's shell is a login shell everywhere else
# (MNML_BASH_LOGIN says so), so this reads what a login bash reads:
# /etc/profile, then the first of ~/.bash_profile, ~/.bash_login and
# ~/.profile — which, as usual, is where ~/.bashrc gets sourced from.
if [ -n "${MNML_BASH_LOGIN-}" ]; then
    builtin unset MNML_BASH_LOGIN
    [ -r /etc/profile ] && builtin . /etc/profile
    if [ -r ~/.bash_profile ]; then
        builtin . ~/.bash_profile
    elif [ -r ~/.bash_login ]; then
        builtin . ~/.bash_login
    elif [ -r ~/.profile ]; then
        builtin . ~/.profile
    fi
else
    [ -r ~/.bashrc ] && builtin . ~/.bashrc
fi

# ── 2. the marks ──
# They add marks and nothing else: the prompt, aliases and plugins are
# the user's. They stand aside when another integration already marks
# prompts. A and B go INTO PS1, inside \[ \] so readline counts them as
# zero columns; C comes from a DEBUG trap (or bash-preexec's
# preexec_functions when that is loaded), D and OSC 7 from
# PROMPT_COMMAND.
[[ $- == *i* ]] || return 0
[[ -z ${__mnml_si_loaded-} ]] || return 0
__mnml_si_loaded=1

# Whether something else already writes OSC 133: a prompt or a
# PROMPT_COMMAND that carries a mark, a hook of a known integration
# (VS Code, ghostty, kitty, iTerm2, WezTerm, the mnml prompt), or any
# hook whose body writes one.
__mnml_si_other() {
    local text="${PROMPT_COMMAND[*]-} ${PS1-} ${PS0-}" f
    [[ $text == *'133;'* ]] && return 0
    # The hook names: PROMPT_COMMAND split into words, no globbing.
    local -a words
    local IFS=$' \t\n;&|' noglob=
    [[ $- == *f* ]] || noglob=1
    builtin set -f
    words=(${PROMPT_COMMAND[*]-})
    [[ -n $noglob ]] && builtin set +f
    IFS=$' \t\n'
    for f in "${words[@]}" "${precmd_functions[@]}" "${preexec_functions[@]}"; do
        case $f in
            __vsc_* | __ghostty* | _ksi_* | __ksi* | iterm2_* | __iterm2* | __wezterm* | __mnml_ps1) return 0 ;;
        esac
        if builtin declare -F -- "$f" >/dev/null 2>&1; then
            [[ $(builtin declare -f -- "$f") == *'133;'* ]] && return 0
        fi
    done
    return 1
}

if __mnml_si_other; then
    builtin unset -f __mnml_si_other
    return 0
fi
builtin unset -f __mnml_si_other

__mnml_si_a='\[\e]133;A;redraw=last\a\]'
__mnml_si_b='\[\e]133;B\a\]'
__mnml_si_ran=
__mnml_si_armed=
__mnml_si_pc_array=

# First in PROMPT_COMMAND: D for a command that ran (not for an empty
# line), with its status, which it hands on unchanged.
__mnml_si_pre() {
    local ret=$?
    __mnml_si_armed=
    if [[ -n $__mnml_si_ran ]]; then
        builtin printf '\033]133;D;%s\007' "$ret"
        __mnml_si_ran=
    fi
    return $ret
}

# Last in PROMPT_COMMAND: the directory, and the marks into the prompt
# again whenever a theme has rebuilt it since the last one.
__mnml_si_post() {
    local ret=$?
    __mnml_si_cwd
    if [[ $PS1 != "$__mnml_si_a"* || $PS1 != *"$__mnml_si_b" ]]; then
        PS1=${PS1//"$__mnml_si_a"/}
        PS1=${PS1//"$__mnml_si_b"/}
        PS1=$__mnml_si_a$PS1$__mnml_si_b
    fi
    # Stay last, so a hook added after this file still runs first (the
    # string form; an array's order is its owner's).
    if [[ -z $__mnml_si_pc_array && $PROMPT_COMMAND != *__mnml_si_post ]]; then
        PROMPT_COMMAND=${PROMPT_COMMAND//$'\n'__mnml_si_post/}$'\n'__mnml_si_post
    fi
    __mnml_si_armed=1
    return $ret
}

# C: the first command after a prompt. Not a PROMPT_COMMAND's own, a
# completion function's or a `bind -x` binding's.
__mnml_si_preexec() {
    [[ -n $__mnml_si_armed ]] || return 0
    [[ $BASH_COMMAND == __mnml_si_pre ]] && return 0
    [[ -n ${COMP_LINE-} || -n ${READLINE_LINE-} ]] && return 0
    __mnml_si_armed=
    __mnml_si_ran=1
    builtin printf '\033]133;C\007'
}

# OSC 7: file://host/path, the path's bytes percent-encoded where a URL
# needs it.
__mnml_si_cwd() {
    local LC_ALL=C url= c i
    for ((i = 0; i < ${#PWD}; i++)); do
        c=${PWD:i:1}
        case $c in
            [-/._~A-Za-z0-9]) url+=$c ;;
            *)
                builtin printf -v c '%%%02X' "'$c"
                url+=$c
                ;;
        esac
    done
    builtin printf '\033]7;file://%s%s\007' "${HOSTNAME-}" "$url"
}

# An array of more than one (bash 5.1's form) keeps its order; a string,
# or an array of one, is its first element.
if ((${#PROMPT_COMMAND[@]} > 1)); then
    PROMPT_COMMAND=(__mnml_si_pre "${PROMPT_COMMAND[@]}" __mnml_si_post)
    __mnml_si_pc_array=1
else
    PROMPT_COMMAND="__mnml_si_pre${PROMPT_COMMAND:+$'\n'$PROMPT_COMMAND}"$'\n'__mnml_si_post
fi
if builtin declare -F __bp_preexec_invoke_exec >/dev/null 2>&1; then
    # bash-preexec owns the DEBUG trap: ride its list instead.
    __mnml_si_bp_preexec() {
        __mnml_si_armed=
        __mnml_si_ran=1
        builtin printf '\033]133;C\007'
    }
    preexec_functions+=(__mnml_si_bp_preexec)
elif [[ -z $(builtin trap -p DEBUG) ]]; then
    builtin trap '__mnml_si_preexec' DEBUG
fi
