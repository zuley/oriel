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

# Tell the terminal tab which directory the shell is in (OSC 7), once per prompt.
_oriel_report_cwd() {
    emulate -L zsh
    # Encode UTF-8 bytes, preserving only URI path separators and unreserved bytes.
    local LC_ALL=C
    local encoded_path='' path_byte
    local -i path_index
    for (( path_index = 1; path_index <= ${#PWD}; path_index++ )); do
        path_byte=${PWD[path_index]}
        case $path_byte in
            [a-zA-Z0-9/._~-]) encoded_path+=$path_byte ;;
            *) printf -v path_byte '%%%02X' "'$path_byte"; encoded_path+=$path_byte ;;
        esac
    done
    printf '\e]7;file://%s%s\a' "${HOST}" "$encoded_path"
}
precmd_functions+=(_oriel_report_cwd)
