# completions/atomic-gc.bash
# bash completion for atomic-gc

_atomic_gc() {
    local cur prev words cword
    _init_completion || return

    local esp="/efi"
    if [[ -r /etc/atomic.conf ]]; then
        while IFS='=' read -r key val; do
            key="${key// /}"
            [[ "$key" == "ESP" ]] || continue
            val="${val%%#*}"
            val="${val#\"}" ; val="${val%\"}"
            val="${val#\'}" ; val="${val%\'}"
            val="${val## }" ; val="${val%% }"
            [[ -n "$val" ]] && esp="$val"
            break
        done < /etc/atomic.conf
    fi

    if [[ $cword -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "list rm -h --help -n --dry-run" -- "$cur") )
        return
    fi

    case "${words[1]}" in
        rm)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=( $(compgen -W "-n --dry-run -y --yes" -- "$cur") )
            else
                local -a gens=()
                local f name
                for f in "$esp"/EFI/Linux/arch-*.efi; do
                    [[ -e "$f" ]] || continue
                    name="${f##*/}"
                    name="${name#arch-}"
                    name="${name%.efi}"
                    gens+=("$name")
                done
                COMPREPLY=( $(compgen -W "${gens[*]}" -- "$cur") )
            fi
            ;;
    esac
}

complete -F _atomic_gc atomic-gc
