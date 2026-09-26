# mnml.fish — mnml starts a shell pane's fish with `--init-command`
# sourcing this file (its path rides in MNML_FISH_INIT), which fish runs
# after config.fish, so it tells the terminal pane where each prompt,
# command line and command output starts (OSC 133) and which directory
# the shell is in (OSC 7), and nothing in the user's dotfiles has to
# change.
#
#   133;A;redraw=1  a prompt starts; fish repaints the whole prompt on
#                   a resize
#   133;B           the prompt ends and the command line starts
#   133;C           the command runs; its output starts here
#   133;D;<status>  the command finished with this exit status
#
# It adds marks and nothing else: the prompt, functions and plugins are
# the user's. It stands aside when something already marks prompts —
# fish itself from 4.0 on (unless `no-mark-prompt` turned that off), or
# another terminal's integration.

if status is-interactive; and not set -q __mnml_si_loaded
    set -g __mnml_si_loaded 1

    function __mnml_si_other
        # fish's own marks (feature `mark-prompt`, fish 4.0 and later).
        status test-feature mark-prompt 2>/dev/null; and return 0
        for f in (functions --all --names)
            switch $f
                case '__ghostty*' '__ksi*' '_ksi_*' '__vsc*' 'iterm2_*' '__iterm2*' '__wezterm*'
                    return 0
            end
        end
        string match -q -- '*133;*' (functions fish_prompt 2>/dev/null); and return 0
        return 1
    end

    if __mnml_si_other
        functions -e __mnml_si_other
    else
        functions -e __mnml_si_other

        # Hand the prompt the status it would have had.
        function __mnml_si_status
            return $argv[1]
        end

        # The marks go INTO the prompt, so fish's own repaint (a resize,
        # a key binding's) marks it again. A theme that replaces
        # fish_prompt later is wrapped again at the next prompt.
        function __mnml_si_wrap
            functions -q fish_prompt; or return
            functions -e __mnml_si_user_prompt
            functions -c fish_prompt __mnml_si_user_prompt
            function fish_prompt
                set -l s $status
                printf '\e]133;A;redraw=1\a'
                __mnml_si_status $s
                __mnml_si_user_prompt
                printf '\e]133;B\a'
            end
        end
        __mnml_si_wrap

        function __mnml_si_prompt --on-event fish_prompt
            set -l s $status
            if not functions fish_prompt | string match -q '*__mnml_si_user_prompt*'
                __mnml_si_wrap
            end
            # OSC 7: file://host/path, percent-encoded where a URL needs it.
            printf '\e]7;file://%s%s\a' $hostname (string escape --style=url -- $PWD)
            __mnml_si_status $s
        end

        function __mnml_si_preexec --on-event fish_preexec
            printf '\e]133;C\a'
        end

        # Only a command that ran gets here (an empty line does not).
        function __mnml_si_postexec --on-event fish_postexec
            printf '\e]133;D;%s\a' $status
        end
    end
end
