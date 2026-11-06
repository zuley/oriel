# Restore the normal startup directory before loading the user's zsh configuration.
if (( ${+ORIEL_ORIGINAL_ZDOTDIR} )); then
    export ZDOTDIR="$ORIEL_ORIGINAL_ZDOTDIR"
    unset ORIEL_ORIGINAL_ZDOTDIR
else
    unset ZDOTDIR
fi
if [[ -r "${ZDOTDIR-$HOME}/.zshenv" ]]; then
    source "${ZDOTDIR-$HOME}/.zshenv"
fi

# macOS sets its default prompt in /etc/zshrc, after this file runs.
_oriel_first_prompt() {
    precmd_functions=( "${precmd_functions[@]:#_oriel_first_prompt}" )
    if [[ $PROMPT == '%n@%m %1~ %# ' ]]; then
        PROMPT='%1~ %# '
    fi
    unfunction _oriel_first_prompt
}
typeset -ga precmd_functions
precmd_functions+=(_oriel_first_prompt)
