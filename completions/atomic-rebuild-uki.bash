# bash completion for atomic-rebuild-uki

_atomic_rebuild_uki() {
    local cur prev words cword
    _init_completion || return

    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-h --help -l --list" -- "$cur") )
        return
    fi

    # GEN_ID only as first positional argument
    if [[ $cword -eq 1 ]]; then
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
}

complete -F _atomic_rebuild_uki atomic-rebuild-uki
