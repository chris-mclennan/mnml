# mnml-prompt.sh — themed powerline prompt for bash + zsh.
#
# Sourced by the user's `.zshrc` / `.bashrc` via:
#
#     [ -n "$MNML_PROMPT_SCRIPT" ] && source "$MNML_PROMPT_SCRIPT"
#
# `$MNML_PROMPT_SCRIPT` is exported by mnml/tmnl before they spawn a
# shell; outside their child shells the line above is a no-op.
#
# Theming is via env vars — also exported by mnml/tmnl before spawn —
# so the prompt automatically picks up the active mnml palette colors.
# Unset vars fall back to a tokyo-night-ish default so the script
# still looks reasonable if sourced standalone.
#
# Segments (left to right):
#   1. cwd            — accent bg, truncated to ~/proj/subdir
#   2. git branch + dirty marker (±)  — green when clean, yellow when dirty
#   3. exit code (non-zero only)      — red
#
# Right-aligned (zsh RPROMPT; bash via the same PROMPT_COMMAND):
#   4. clock HH:MM    — dim grey
#   5. context chip   — "mnml" / "tmnl" / shell-name, dim grey
#
# Glyphs are powerline + nerd-font:    ±   ❯
#
# Shells handled: bash 3+, zsh 5+. Fish + nu intentionally out of scope.

# --- Defaults (tokyo-night-ish) ---------------------------------------------
: "${MNML_PROMPT_BG:=#1a1b26}"
: "${MNML_PROMPT_FG:=#c0caf5}"
: "${MNML_PROMPT_ACCENT:=#7aa2f7}"
: "${MNML_PROMPT_GREEN:=#9ece6a}"
: "${MNML_PROMPT_RED:=#f7768e}"
: "${MNML_PROMPT_YELLOW:=#e0af68}"
: "${MNML_PROMPT_GREY:=#565f89}"
: "${MNML_CONTEXT:=}"

# --- Color helpers ----------------------------------------------------------
# Hex "#RRGGBB" → ANSI 24-bit fg/bg escape. Caller must wrap with
# %{...%} (zsh) or \[...\] (bash) for PS1/PROMPT cursor accounting —
# done in the build functions below.
_mnml_fg() {
    local h="${1#\#}"
    printf '\033[38;2;%d;%d;%dm' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
}
_mnml_bg() {
    local h="${1#\#}"
    printf '\033[48;2;%d;%d;%dm' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
}
_mnml_reset='\033[0m'

# Powerline + nerd-font glyphs.
_mnml_sep=$''      #  — right-pointing solid arrow (segment end)
_mnml_sep_r=$''    #  — left-pointing solid arrow (right-side seg)
_mnml_branch=$''   #  — branch
_mnml_arrow='❯'

# --- Segment builders -------------------------------------------------------
_mnml_seg_cwd() {
    local p="${PWD/#$HOME/~}"
    # Truncate to the trailing N path components if very deep (keep last 3).
    case "$p" in
        */*/*/*)
            local IFS=/
            # shellcheck disable=SC2206
            local parts=( $p )
            local n=${#parts[@]}
            p=".../${parts[$((n - 3))]}/${parts[$((n - 2))]}/${parts[$((n - 1))]}"
            ;;
    esac
    printf '%s' "$p"
}

# Outputs "branch±" / "branch" / "" — caller checks for empty.
_mnml_seg_git() {
    command -v git >/dev/null 2>&1 || return
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null) || \
        branch=$(git rev-parse --short HEAD 2>/dev/null) || return
    local dirty=""
    if ! git diff --quiet --ignore-submodules HEAD 2>/dev/null; then
        dirty="±"
    fi
    printf '%s%s' "$branch" "$dirty"
}

# Returns "1" when the working tree is dirty, "0" otherwise. Used to
# pick the git segment's bg color (green / yellow).
_mnml_seg_git_dirty() {
    if git diff --quiet --ignore-submodules HEAD 2>/dev/null; then
        printf 0
    else
        printf 1
    fi
}

# --- Left-side builder ------------------------------------------------------
# Constructs the prompt string. The `$1` argument is the last exit
# code (passed in from PROMPT_COMMAND / precmd). Returns a string
# containing raw escape codes — wrap with shell-specific brackets at
# the call site.
_mnml_build_left() {
    local last_exit=$1
    local out=""
    local cwd_text
    cwd_text=$(_mnml_seg_cwd)

    # cwd segment: accent bg, bg-color fg.
    out+="$(_mnml_bg "$MNML_PROMPT_ACCENT")$(_mnml_fg "$MNML_PROMPT_BG") ${cwd_text} "

    local git_text
    git_text=$(_mnml_seg_git)
    if [ -n "$git_text" ]; then
        local git_bg="$MNML_PROMPT_GREEN"
        if [ "$(_mnml_seg_git_dirty)" = "1" ]; then
            git_bg="$MNML_PROMPT_YELLOW"
        fi
        # accent-fg arrow → git bg.
        out+="$(_mnml_bg "$git_bg")$(_mnml_fg "$MNML_PROMPT_ACCENT")${_mnml_sep}"
        out+="$(_mnml_bg "$git_bg")$(_mnml_fg "$MNML_PROMPT_BG") ${_mnml_branch} ${git_text} "
        # git bg → reset (terminal bg).
        out+="${_mnml_reset}$(_mnml_fg "$git_bg")${_mnml_sep}${_mnml_reset}"
    else
        out+="${_mnml_reset}$(_mnml_fg "$MNML_PROMPT_ACCENT")${_mnml_sep}${_mnml_reset}"
    fi

    # Last-exit indicator: red ❯ when non-zero, green otherwise.
    local arrow_fg="$MNML_PROMPT_GREEN"
    if [ "$last_exit" != "0" ] && [ -n "$last_exit" ]; then
        arrow_fg="$MNML_PROMPT_RED"
        out+=" $(_mnml_fg "$MNML_PROMPT_RED")[$last_exit]${_mnml_reset}"
    fi
    out+=" $(_mnml_fg "$arrow_fg")${_mnml_arrow}${_mnml_reset} "

    printf '%s' "$out"
}

_mnml_build_right() {
    local out=""
    local context_label="${MNML_CONTEXT:-$( basename "${SHELL:-sh}" )}"
    out+="$(_mnml_fg "$MNML_PROMPT_GREY")$(date +%H:%M) · ${context_label}${_mnml_reset}"
    printf '%s' "$out"
}

# --- Wire to shell ----------------------------------------------------------
if [ -n "${ZSH_VERSION:-}" ]; then
    setopt PROMPT_SUBST
    # %{...%} bracket the non-printing escapes so zsh tracks the
    # visible-column count correctly (otherwise line wrap breaks).
    PROMPT='%{$(_mnml_build_left "$?")%}'
    RPROMPT='%{$(_mnml_build_right)%}'
elif [ -n "${BASH_VERSION:-}" ]; then
    # bash builds the prompt via PROMPT_COMMAND so `$?` is captured
    # before any other command runs. \[...\] brackets the non-printing
    # escapes (same role as zsh's %{...%}).
    _mnml_set_ps1() {
        local last=$?
        # We can't easily right-align on bash without `tput cols` math
        # per-redraw; inline the right side at the end of PS1 with a
        # newline split so the layout still looks clean.
        local left right
        left=$(_mnml_build_left "$last")
        right=$(_mnml_build_right)
        PS1="\[${left}\]\[${right}\]\n\[\033[0m\]"
    }
    case "$PROMPT_COMMAND" in
        *_mnml_set_ps1*) : ;;
        '') PROMPT_COMMAND='_mnml_set_ps1' ;;
        *)  PROMPT_COMMAND="_mnml_set_ps1; $PROMPT_COMMAND" ;;
    esac
fi
