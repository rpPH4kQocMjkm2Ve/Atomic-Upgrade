# /usr/share/bash-completion/completions/atomic-env

_atomic_env() {
    local cur prev words cword
    _init_completion || return

    local commands="create update delete boot list"

    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands -h --help -V --version" -- "$cur"))
        return
    fi

    local cmd="${words[1]}"

    case "$cmd" in
        create)
            # No completion for name (user provides new name)
            # After --, complete with system commands
            local i has_dashdash=0
            for ((i=2; i < cword; i++)); do
                [[ "${words[i]}" == "--" ]] && { has_dashdash=1; break; }
            done
            if [[ $has_dashdash -eq 1 ]]; then
                COMPREPLY=($(compgen -c -- "$cur"))
            elif [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "--" -- "$cur"))
            fi
            ;;
        update)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "$(_atomic_env_names)" -- "$cur"))
            else
                local i has_dashdash=0
                for ((i=2; i < cword; i++)); do
                    [[ "${words[i]}" == "--" ]] && { has_dashdash=1; break; }
                done
                if [[ $has_dashdash -eq 1 ]]; then
                    COMPREPLY=($(compgen -c -- "$cur"))
                elif [[ "$cur" == -* ]]; then
                    COMPREPLY=($(compgen -W "--" -- "$cur"))
                fi
            fi
            ;;
        delete)
            case "$cur" in
                -*) COMPREPLY=($(compgen -W "-y --yes" -- "$cur")) ;;
                *)  COMPREPLY=($(compgen -W "$(_atomic_env_names)" -- "$cur")) ;;
            esac
            ;;
        boot)
            case "$prev" in
                --default) COMPREPLY=($(compgen -W "$(_atomic_env_names)" -- "$cur")) ;;
                *)         COMPREPLY=($(compgen -W "--default --reset" -- "$cur")) ;;
            esac
            ;;
        list) ;;
    esac
}

_atomic_env_names() {
    local esp="${ESP:-/efi}"
    local names=()
    for f in "${esp}"/EFI/Linux/arch-env-*.efi; do
        [[ -e "$f" ]] || continue
        local n="${f##*/}"
        n="${n#arch-env-}"
        n="${n%.efi}"
        names+=("$n")
    done
    echo "${names[*]}"
}

complete -F _atomic_env atomic-env
