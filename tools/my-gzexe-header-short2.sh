#!/bin/sh
E(){awk '/^9$/{f=1;next}f' "$0"|gunzip;}
G=${XDG_CACHE_HOME:-$HOME/.cache}/${0##*/%.sh}
[ "$0" -nt "$G" ]&&{
    mkdir -p "${G%/*}"||{echo "mkdir failed">&2;exit 9;}
    E>"$G"||{echo "gunzip failed">&2;exit 9;}
    chmod 700 "$G"||{echo "chmod failed on $G">&2;exit 9;}
    echo "unpacked binary at $G">&2
}
[ -x "$G" ]&&exec "$G" "$@"
echo "exec failed">&2
exit 9
