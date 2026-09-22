# mnml-prompt.sh — the mnml prompt for zsh and bash.
#
# mnml exports MNML_PROMPT_SCRIPT (the path of this file, kept current
# in mnml's data root) to every shell it opens in a terminal pane. Opt
# in with one line in ~/.zshrc or ~/.bashrc:
#
#     [ -n "$MNML_PROMPT_SCRIPT" ] && . "$MNML_PROMPT_SCRIPT"
#
# Outside mnml the variable is unset and the line does nothing.
#
# The colours come from the theme mnml is showing, as MNML_PROMPT_BG,
# _FG, _ACCENT, _BLUE, _GREEN, _RED, _YELLOW and _GREY (#rrggbb);
# MNML_CONTEXT is the word on the right ("mnml"). Unset ones fall back
# to the defaults below, so the file also works sourced by hand.
#
# The prompt: the directory, the git branch (± when the tree is dirty),
# a failed command's exit status, and on the right the time and the
# context. MNML_PROMPT_ASCII=1 draws it without Nerd Font glyphs.
#
# It also tells the terminal where the shell is (OSC 7, so a saved
# session brings the pane back in that directory) and where each prompt
# and command output starts (OSC 133, what the prompt-jump commands
# `term.prev_prompt` / `term.next_prompt` move between).

: "${MNML_PROMPT_BG:=#1e222a}"
: "${MNML_PROMPT_FG:=#abb2bf}"
: "${MNML_PROMPT_ACCENT:=#519aba}"
: "${MNML_PROMPT_BLUE:=#61afef}"
: "${MNML_PROMPT_GREEN:=#98c379}"
: "${MNML_PROMPT_RED:=#e06c75}"
: "${MNML_PROMPT_YELLOW:=#e7c787}"
: "${MNML_PROMPT_GREY:=#5c6370}"
: "${MNML_CONTEXT:=mnml}"

# Escapes a line editor must not count as columns: zsh brackets them in
# %{ %}, bash in \[ \].
if [ -n "${ZSH_VERSION:-}" ]; then
    __mnml_o='%{' __mnml_c='%}'
else
    __mnml_o='\[' __mnml_c='\]'
fi

# "#rrggbb" and 38 (fg) or 48 (bg) → a bracketed truecolor escape.
__mnml_rgb() {
    local h="${2#\#}"
    printf '%s\033[%s;2;%d;%d;%dm%s' "$__mnml_o" "$1" \
        "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}" "$__mnml_c"
}
__mnml_off="${__mnml_o}"$'\033[0m'"${__mnml_c}"

if [ "${MNML_PROMPT_ASCII:-0}" = "1" ]; then
    __mnml_end='' __mnml_git='git:' __mnml_mark='>'
else
    __mnml_end=$'' __mnml_git=$' ' __mnml_mark='❯'
fi

# Text from the filesystem or git, made inert for the prompt it lands
# in: zsh reads `%` as a prompt escape; bash expands `$` and backticks
# in PS1, so a directory named `$(…)` would otherwise run.
__mnml_inert() {
    local t=$1
    if [ -n "${ZSH_VERSION:-}" ]; then
        t=${t//\%/%%}
    else
        t=${t//\\/\\\\}
        t=${t//\$/\\\$}
        t=${t//\`/\\\`}
    fi
    printf '%s' "$t"
}

# The directory, ~ for home, the last three components when deeper.
__mnml_dir() {
    local d="${PWD/#$HOME/~}"
    case "$d" in
        */*/*/*/*) d="…/${d#"${d%/*/*/*}"/}" ;;
    esac
    __mnml_inert "$d"
}

# "branch" or "branch±"; nothing outside a repository.
__mnml_branch() {
    command -v git >/dev/null 2>&1 || return 0
    local b
    b=$(git symbolic-ref --short -q HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null) || return 0
    [ -n "$b" ] || return 0
    b=$(__mnml_inert "$b")
    if git diff --quiet --ignore-submodules HEAD 2>/dev/null; then
        printf '%s' "$b"
    else
        printf '%s±' "$b"
    fi
}

__mnml_left() {
    local code=$1 out branch ground
    out="$(__mnml_rgb 48 "$MNML_PROMPT_BLUE")$(__mnml_rgb 38 "$MNML_PROMPT_BG") $(__mnml_dir) ${__mnml_off}"
    out+="$(__mnml_rgb 38 "$MNML_PROMPT_BLUE")${__mnml_end}${__mnml_off}"
    branch=$(__mnml_branch)
    if [ -n "$branch" ]; then
        ground=$MNML_PROMPT_GREEN
        case "$branch" in *±) ground=$MNML_PROMPT_YELLOW ;; esac
        out+=" $(__mnml_rgb 48 "$ground")$(__mnml_rgb 38 "$MNML_PROMPT_BG") ${__mnml_git}${branch} ${__mnml_off}"
        out+="$(__mnml_rgb 38 "$ground")${__mnml_end}${__mnml_off}"
    fi
    # A failed command's status; Ctrl+C (130), a typo (127) and the
    # usual kill signals are the user's own doing and stay quiet.
    local mark=$MNML_PROMPT_GREEN
    case "$code" in
        0 | 127 | 130 | 131 | 137 | 143 | '') ;;
        *)
            out+=" $(__mnml_rgb 38 "$MNML_PROMPT_RED")[$code]${__mnml_off}"
            mark=$MNML_PROMPT_RED
            ;;
    esac
    # OSC 133 B: the prompt ends and the command line begins.
    printf '%s %s%s%s %s\033]133;B\007%s' "$out" "$(__mnml_rgb 38 "$mark")" "$__mnml_mark" "$__mnml_off" "$__mnml_o" "$__mnml_c"
}

__mnml_right() {
    printf '%s%s · %s%s' "$(__mnml_rgb 38 "$MNML_PROMPT_GREY")" "$(date +%H:%M)" "$MNML_CONTEXT" "$__mnml_off"
}

# OSC 7 (the directory) and OSC 133 A (a prompt starts), written
# straight to the terminal before each prompt.
__mnml_report() {
    printf '\033]133;D;%s\007' "$1"
    printf '\033]7;file://%s%s\007' "${HOSTNAME:-$(hostname)}" "$PWD"
    printf '\033]133;A\007'
}

if [ -n "${ZSH_VERSION:-}" ]; then
    setopt PROMPT_SUBST
    __mnml_status=0
    __mnml_precmd() {
        __mnml_status=$?
        __mnml_report "$__mnml_status"
    }
    # Command substitution in the prompt itself: its output is not
    # expanded again, so nothing a directory is called can run.
    PROMPT='$(__mnml_left "$__mnml_status")'
    RPROMPT='$(__mnml_right)'
    # OSC 133 C: the command's output starts here.
    __mnml_preexec() { printf '\033]133;C\007'; }
    autoload -Uz add-zsh-hook 2>/dev/null
    if command -v add-zsh-hook >/dev/null 2>&1; then
        add-zsh-hook precmd __mnml_precmd
        add-zsh-hook preexec __mnml_preexec
    else
        precmd_functions+=(__mnml_precmd)
        preexec_functions+=(__mnml_preexec)
    fi
elif [ -n "${BASH_VERSION:-}" ]; then
    __mnml_ps1() {
        local s=$?
        __mnml_report "$s"
        # bash has no right prompt: the time and context go on a
        # second line.
        PS1="$(__mnml_left "$s")"$'\n'"$(__mnml_right) "
    }
    case "${PROMPT_COMMAND:-}" in
        *__mnml_ps1*) ;;
        '') PROMPT_COMMAND=__mnml_ps1 ;;
        *) PROMPT_COMMAND="__mnml_ps1; $PROMPT_COMMAND" ;;
    esac
fi
