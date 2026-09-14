#!/bin/bash
# lsl-win-backup.sh - back up selected Windows folders (on mounted NTFS) to
# squashfs, with per-job include/exclude regexes, a space *estimate*, and a
# daily incremental mode that captures files modified in the last ~24h.
#
# The "last 24 hours" capture uses a *chaining* window so files are never
# missed: each run captures everything newer than (the previous run's timestamp
# minus LSL_BACKUP_INCR_SLACK_SEC). The first run (no history) falls back to a
# fixed LSL_BACKUP_WINDOW_HOURS window measured from now - default 24.1h, which
# is where the "24.1" slack number comes from: it is slightly more than 24h so
# daily cron jitter and files exactly on the boundary are never skipped.
#
# Usage:
#   lsl-win-backup.sh --list                 # show configured jobs
#   lsl-win-backup.sh --estimate             # show file count + raw + estimated squashfs size
#   lsl-win-backup.sh --dry-run              # show what WOULD be captured (no writes)
#   lsl-win-backup.sh --run                  # perform the backups now
#   lsl-win-backup.sh --add-folder           # interactively add a backup job
#   lsl-win-backup.sh --install-timer        # enable the daily systemd timer
#   lsl-win-backup.sh --config /path/to/conf # use an alternate config file
#
# Config file format (default: $LSL_BACKUP_CONF). Blank lines and # comments
# are ignored. A job starts with `job <name>` and accumulates options until the
# next `job` line:
#   job Documents
#   source /mnt/c/Users/you/Documents
#   include \.txt$          # POSIX ERE, matched against the path RELATIVE to
#   include \.md$           #   source (e.g. "a.txt" / "sub/b.md"); OR'd together
#   exclude node_modules    # POSIX ERE, OR'd; any match excludes the file
#   exclude \.tmp$
#   mode incremental       # full | incremental | both  (default: both)
#   window_hours 24.1       # per-job override of the incremental window
#   dest /mnt/d/backups     # optional per-job output dir (default: $LSL_BACKUP_DIR/<name>)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lsl-common.sh"
lsl_load_config

# --- config (from lsl-usb.env, all optional) -------------------------------
LSL_BACKUP_DIR="${LSL_BACKUP_DIR:-${LSL_DATA_DIR:-/mnt/c/Users/lsl-usb}/backups}"
LSL_BACKUP_CONF="${LSL_BACKUP_CONF:-$LSL_BACKUP_DIR/backup.conf}"
LSL_BACKUP_WINDOW_HOURS="${LSL_BACKUP_WINDOW_HOURS:-24.1}"   # first-run / --full window
LSL_BACKUP_INCR_SLACK_SEC="${LSL_BACKUP_INCR_SLACK_SEC:-600}" # overlap past last run
LSL_BACKUP_KEEP="${LSL_BACKUP_KEEP:-7}"                      # retained sfs per job
LSL_BACKUP_EST_FACTOR="${LSL_BACKUP_EST_FACTOR:-0.6}"        # fallback compress ratio
LSL_BACKUP_SAMPLE_MIB="${LSL_BACKUP_SAMPLE_MIB:-64}"         # sample size for estimate

MODE="help"
while [ $# -gt 0 ]; do
    case "$1" in
        --list) MODE=list ;;
        --estimate) MODE=estimate ;;
        --dry-run) MODE=dryrun ;;
        --run) MODE=run ;;
        --add-folder) MODE=add ;;
        --install-timer) MODE=install_timer ;;
        --config) shift; LSL_BACKUP_CONF="${1:-}"; [ -z "$LSL_BACKUP_CONF" ] && { echo "error: --config needs a path" >&2; exit 2; } ;;
        -h|--help) MODE=help ;;
        *) echo "Unknown option: $1" >&2; MODE=help; break ;;
    esac
    shift || true
done

STATE_DIR="$LSL_BACKUP_DIR/.state"
mkdir -p "$LSL_BACKUP_DIR" "$STATE_DIR" 2>/dev/null || true

# --- helpers ---------------------------------------------------------------
human() {
    awk -v b="$1" 'BEGIN{
        if (b>=1073741824) printf "%.1f GiB", b/1073741824;
        else if (b>=1048576) printf "%.1f MiB", b/1048576;
        else if (b>=1024) printf "%.1f KiB", b/1024;
        else printf "%d B", b+0;
    }'
}

safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

log() { echo "[$(date +%F' '%T)] $*"; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required." >&2; exit 1; }
}

count_lines() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

# Filter a list of relative paths through include/exclude POSIX EREs.
# Includes are OR'd; if none, all pass. Excludes are OR'd; any match drops the
# line. Reads stdin (relative paths), writes to stdout.
filter_regex() {
    local inc="$1" exc="$2" ipat epat
    if [ -n "$inc" ]; then
        ipat="$(printf '%s\n' "$inc" | paste -sd'|' -)"
        grep -E "$ipat"
    else
        cat
    fi | if [ -n "$exc" ]; then
        epat="$(printf '%s\n' "$exc" | paste -sd'|' -)"
        grep -E -v "$epat"
    else
        cat
    fi
}

# Emit the captured file list (relative paths, one per line) into $1.
emit_list() {
    local out="$1" src="$2" inc="$3" exc="$4" incremental="$5" threshold="$6"
    ( cd "$src" && {
          if [ "$incremental" = "1" ]; then
              find . -type f -newermt "@$threshold" -printf '%P\n'
          else
              find . -type f -printf '%P\n'
          fi
      } | filter_regex "$inc" "$exc" > "$out" )
}

# --- config parsing -> parallel arrays -------------------------------------
J_NAME=(); J_SOURCE=(); J_MODE=(); J_WINDOW=(); J_DEST=(); J_INC=(); J_EXC=()
_PARSE_NAME=""; _PARSE_SOURCE=""; _PARSE_MODE="both"; _PARSE_WINDOW=""; _PARSE_DEST=""; _PARSE_INC=""; _PARSE_EXC=""

lsl_backup_flush() {
    [ -n "$_PARSE_NAME" ] || return 0
    J_NAME+=("$_PARSE_NAME"); J_SOURCE+=("$_PARSE_SOURCE"); J_MODE+=("$_PARSE_MODE")
    J_WINDOW+=("$_PARSE_WINDOW"); J_DEST+=("$_PARSE_DEST"); J_INC+=("$_PARSE_INC"); J_EXC+=("$_PARSE_EXC")
}

parse_config() {
    local f="$1"
    [ -f "$f" ] || return 0
    local ln key val
    while IFS= read -r ln || [ -n "$ln" ]; do
        case "$ln" in
            ''|'#'*) continue ;;
        esac
        ln="$(printf '%s' "$ln" | sed -e 's/[[:space:]]*$//')"
        key="${ln%% *}"; val="${ln#* }"
        [ "$val" = "$ln" ] && val=""
        case "$key" in
            job)
                lsl_backup_flush
                _PARSE_NAME="$val"; _PARSE_SOURCE=""; _PARSE_MODE="both"
                _PARSE_WINDOW=""; _PARSE_DEST=""; _PARSE_INC=""; _PARSE_EXC=""
                ;;
            source) _PARSE_SOURCE="$val" ;;
            mode)   _PARSE_MODE="$val" ;;
            window_hours) _PARSE_WINDOW="$val" ;;
            dest)   _PARSE_DEST="$val" ;;
            include) [ -n "$_PARSE_INC" ] && _PARSE_INC+=$'\n'; _PARSE_INC+="$val" ;;
            exclude) [ -n "$_PARSE_EXC" ] && _PARSE_EXC+=$'\n'; _PARSE_EXC+="$val" ;;
        esac
    done < "$f"
    lsl_backup_flush
    _PARSE_NAME=""
}

# Compute the incremental threshold (epoch seconds) for a job.
incr_threshold() {
    local job="$1" window="${2:-}" now
    now="$(date +%s)"
    local lastf
    lastf="$STATE_DIR/last_$(safe_name "$job").ts"
    if [ -f "$lastf" ]; then
        local last; last="$(cat "$lastf" 2>/dev/null || echo 0)"
        case "$last" in ''|*[!0-9]*) last=0 ;; esac
        echo $(( last - LSL_BACKUP_INCR_SLACK_SEC ))
    else
        local wh="${window:-$LSL_BACKUP_WINDOW_HOURS}"
        local sec; sec="$(awk -v h="$wh" 'BEGIN{printf "%d", h*3600}')"
        echo $(( now - sec ))
    fi
}

record_run() { printf '%s' "$(date +%s)" > "$STATE_DIR/last_$(safe_name "$1").ts"; }

record_ratio() {
    local job="$1" unc="$2" comp="$3"
    [ "${unc:-0}" -gt 0 ] 2>/dev/null || return 0
    printf '%s\t%s\n' "$unc" "$comp" > "$STATE_DIR/ratio_$(safe_name "$job").tsv"
}

learned_ratio() {
    local f
    f="$STATE_DIR/ratio_$(safe_name "$1").tsv"
    [ -f "$f" ] || { printf ''; return; }
    awk -F'\t' 'NF>=2 && $1>0 {printf "%.4f", $2/$1; exit}' "$f"
}

# Estimate compressed size for a job given raw bytes + sampled list file.
# Prints "<est_bytes> <basis>" where basis is learned|sampled|default.
estimate_compressed() {
    local job="$1" raw="$2" listfile="$3" r
    r="$(learned_ratio "$job")"
    if [ -n "$r" ]; then
        awk -v raw="$raw" -v rr="$r" 'BEGIN{printf "%d learned", raw*rr+0.5}'
        return
    fi
    local cap=$(( LSL_BACKUP_SAMPLE_MIB * 1048576 )) sum=0 f p
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        p="$SRC_FOR_SAMPLE/$f"
        [ -f "$p" ] || continue
        local sz; sz="$(stat -c %s "$p" 2>/dev/null || echo 0)"
        [ "$sz" -gt 0 ] 2>/dev/null || continue
        sum=$(( sum + sz ))
        [ "$sum" -ge "$cap" ] && break
    done < "$listfile"
    if [ "$sum" -gt 4096 ] 2>/dev/null; then
        local inb
        inb="$(sed "s#^\?#$SRC_FOR_SAMPLE/#" "$listfile" | xargs -d '\n' -r cat 2>/dev/null | zstd -1 -q -c 2>/dev/null | wc -c)"
        if [ "${inb:-0}" -gt 0 ] 2>/dev/null; then
            awk -v raw="$raw" -v inb="$inb" -v sum="$sum" 'BEGIN{printf "%d sampled", raw*(inb/sum)+0.5}' 2>/dev/null
            return
        fi
    fi
    awk -v raw="$raw" -v f="$LSL_BACKUP_EST_FACTOR" 'BEGIN{printf "%d default", raw*f+0.5}'
}

sum_sizes_from_list() {
    local listfile="$1" src="$2" total=0 f sz
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        sz="$(stat -c %s "$src/$f" 2>/dev/null || echo 0)"
        total=$(( total + sz ))
    done < "$listfile"
    echo "$total"
}

# --- per-job processing ----------------------------------------------------
run_job() {
    local idx="$1"
    local name="${J_NAME[$idx]}" src="${J_SOURCE[$idx]}" mode="${J_MODE[$idx]}"
    local window="${J_WINDOW[$idx]}" dest="${J_DEST[$idx]}" inc="${J_INC[$idx]}" exc="${J_EXC[$idx]}"
    [ -n "$dest" ] || dest="$LSL_BACKUP_DIR/$name"
    echo "=== Job: $name  (source=$src, mode=$mode) ==="
    if [ ! -d "$src" ]; then
        echo "  SKIP: source directory not found or not mounted: $src" >&2
        return 0
    fi
    mkdir -p "$dest" 2>/dev/null || { echo "  SKIP: cannot create dest $dest" >&2; return 1; }

    local do_full=0 do_incr=0
    case "$mode" in
        full) do_full=1 ;;
        incremental) do_incr=1 ;;
        both) do_full=1; do_incr=1 ;;
        *) echo "  SKIP: unknown mode '$mode'" >&2; return 1 ;;
    esac

    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local wrote=0

    if [ "$do_full" -eq 1 ]; then
        local listf; listf="$(mktemp)"
        emit_list "$listf" "$src" "$inc" "$exc" 0 0
        local cnt; cnt="$(count_lines "$listf")"
        if [ "${cnt:-0}" -eq 0 ]; then
            echo "  full: no files matched (include/exclude), skipping."
        else
            local out="$dest/${name}_${ts}_full.squashfs"
            echo "  full: $cnt file(s) -> $out"
            ( cd "$src" && tar -c -f - --no-recursion -T "$listf" ) | \
                mksquashfs - "$out" -tar -comp zstd -Xcompression-level 22 -noappend >/dev/null
            local unc; unc="$(sum_sizes_from_list "$listf" "$src")"
            local comp; comp="$(stat -c %s "$out" 2>/dev/null || echo 0)"
            record_ratio "$name" "$unc" "$comp"
            echo "  full: wrote $(human "$comp") (raw $(human "$unc"))."
            wrote=1
        fi
        rm -f "$listf" 2>/dev/null || true
    fi

    if [ "$do_incr" -eq 1 ]; then
        local thr; thr="$(incr_threshold "$name" "$window")"
        local listf; listf="$(mktemp)"
        emit_list "$listf" "$src" "$inc" "$exc" 1 "$thr"
        local cnt; cnt="$(count_lines "$listf")"
        if [ "${cnt:-0}" -eq 0 ]; then
            echo "  incremental: no files changed since last run, skipping."
        else
            local out="$dest/${name}_${ts}_incr.squashfs"
            echo "  incremental: $cnt changed file(s) since $(date -d "@$thr" '+%F %T' 2>/dev/null || echo "epoch $thr") -> $out"
            ( cd "$src" && tar -c -f - --no-recursion -T "$listf" ) | \
                mksquashfs - "$out" -tar -comp zstd -Xcompression-level 22 -noappend >/dev/null
            local unc; unc="$(sum_sizes_from_list "$listf" "$src")"
            local comp; comp="$(stat -c %s "$out" 2>/dev/null || echo 0)"
            echo "  incremental: wrote $(human "$comp") (raw $(human "$unc"))."
            record_run "$name"
            wrote=1
        fi
        rm -f "$listf" 2>/dev/null || true
    fi

    # Prune old sfs for this job, keeping the newest LSL_BACKUP_KEEP.
    if [ "$wrote" -eq 1 ] && [ "${LSL_BACKUP_KEEP:-0}" -gt 0 ] 2>/dev/null; then
        local old
        old="$(ls -1t "$dest/${name}_"*.squashfs 2>/dev/null | tail -n +$(( LSL_BACKUP_KEEP + 1 )) )"
        if [ -n "$old" ]; then
            printf '%s\n' "$old" | while IFS= read -r f; do
                echo "  pruning old: $(basename "$f")"; rm -f "$f"
            done
        fi
    fi
}

# --- modes -----------------------------------------------------------------
do_list() {
    parse_config "$LSL_BACKUP_CONF"
    if [ "${#J_NAME[@]}" -eq 0 ]; then
        echo "No backup jobs configured in $LSL_BACKUP_CONF"
        echo "Add one with: lsl-win-backup.sh --add-folder"
        return 0
    fi
    echo "Configured backup jobs ($LSL_BACKUP_CONF):"
    local i
    for i in "${!J_NAME[@]}"; do
        echo "  - ${J_NAME[$i]}  source=${J_SOURCE[$i]:-(unset)}  mode=${J_MODE[$i]}"
        [ -n "${J_INC[$i]}" ] && echo "      include: $(printf '%s' "${J_INC[$i]}" | tr '\n' ' ')"
        [ -n "${J_EXC[$i]}" ] && echo "      exclude: $(printf '%s' "${J_EXC[$i]}" | tr '\n' ' ')"
        [ -n "${J_DEST[$i]}" ] && echo "      dest=${J_DEST[$i]}"
    done
}

do_estimate() {
    need_cmd mksquashfs
    parse_config "$LSL_BACKUP_CONF"
    if [ "${#J_NAME[@]}" -eq 0 ]; then
        echo "No backup jobs configured. Add one with: lsl-win-backup.sh --add-folder"
        return 0
    fi
    printf '%-18s %-12s %10s %12s %14s\n' JOB MODE FILES RAW EST_SFS
    printf '%s\n' "--------------------------------------------------------------------------"
    local i total_raw=0 total_est=0
    for i in "${!J_NAME[@]}"; do
        local name="${J_NAME[$i]}" src="${J_SOURCE[$i]}" mode="${J_MODE[$i]}" window="${J_WINDOW[$i]}"
        local inc="${J_INC[$i]}" exc="${J_EXC[$i]}"
        if [ ! -d "$src" ]; then
            printf '%-18s %-12s %10s %12s %14s\n' "$name" "$mode" "-" "n/a" "(source missing)"
            continue
        fi
        local listf; listf="$(mktemp)"
        emit_list "$listf" "$src" "$inc" "$exc" 0 0
        local cnt; cnt="$(count_lines "$listf")"
        local raw; raw="$(sum_sizes_from_list "$listf" "$src")"
        SRC_FOR_SAMPLE="$src"
        local estline; estline="$(estimate_compressed "$name" "$raw" "$listf")"
        local est; est="$(printf '%s' "$estline" | awk '{print $1}')"
        local basis; basis="$(printf '%s' "$estline" | awk '{print $2}')"
        total_raw=$(( total_raw + raw )); total_est=$(( total_est + est ))
        printf '%-18s %-12s %10s %12s %14s\n' "$name" "$mode" "$cnt" "$(human "$raw")" "$(human "$est")"
        echo "      (estimate basis: $basis; include='$(printf '%s' "$inc" | tr '\n' '/')' exclude='$(printf '%s' "$exc" | tr '\n' '/')')"
        rm -f "$listf" 2>/dev/null || true
    done
    printf '%s\n' "--------------------------------------------------------------------------"
    printf '%-18s %-12s %10s %12s %14s\n' TOTAL "" "" "$(human "$total_raw")" "$(human "$total_est")"
    local free; free="$(df -B1 --output=avail "$LSL_BACKUP_DIR" 2>/dev/null | tail -1 | tr -d ' ')"
    [ -n "$free" ] && echo "Backup target $LSL_BACKUP_DIR has $(human "${free:-0}") free."
}

do_dryrun() {
    need_cmd mksquashfs
    parse_config "$LSL_BACKUP_CONF"
    if [ "${#J_NAME[@]}" -eq 0 ]; then echo "No backup jobs configured."; return 0; fi
    local i
    for i in "${!J_NAME[@]}"; do
        local name="${J_NAME[$i]}" src="${J_SOURCE[$i]}" mode="${J_MODE[$i]}" window="${J_WINDOW[$i]}"
        local inc="${J_INC[$i]}" exc="${J_EXC[$i]}"
        echo "=== Job: $name (source=$src, mode=$mode) ==="
        [ -d "$src" ] || { echo "  source missing: $src"; continue; }
        local listf; listf="$(mktemp)"
        emit_list "$listf" "$src" "$inc" "$exc" 0 0
        local cnt; cnt="$(count_lines "$listf")"
        echo "  full set: $cnt file(s). Sample (first 10):"
        head -n 10 "$listf" | sed 's/^/    /'
        [ "${cnt:-0}" -gt 10 ] && echo "    ... and $(( cnt - 10 )) more"
        local thr; thr="$(incr_threshold "$name" "$window")"
        local ilistf; ilistf="$(mktemp)"
        emit_list "$ilistf" "$src" "$inc" "$exc" 1 "$thr"
        local icnt; icnt="$(count_lines "$ilistf")"
        echo "  incremental (since $(date -d "@$thr" '+%F %T' 2>/dev/null || echo "epoch $thr")): $icnt file(s)."
        rm -f "$listf" "$ilistf" 2>/dev/null || true
    done
}

do_run() {
    need_cmd mksquashfs
    parse_config "$LSL_BACKUP_CONF"
    if [ "${#J_NAME[@]}" -eq 0 ]; then
        echo "No backup jobs configured in $LSL_BACKUP_CONF; nothing to do." >&2
        echo "Add one with: lsl-win-backup.sh --add-folder" >&2
        exit 1
    fi
    local i
    for i in "${!J_NAME[@]}"; do
        run_job "$i" || true
    done
    echo "Done. Backups in: $LSL_BACKUP_DIR"
}

do_add_folder() {
    parse_config "$LSL_BACKUP_CONF" 2>/dev/null || true
    mkdir -p "$(dirname "$LSL_BACKUP_CONF")" 2>/dev/null || true
    echo "Add a backup job (captured to $LSL_BACKUP_CONF)"
    local name src mode inc exc
    read -r -p "  Job name (e.g. Documents): " name
    [ -n "$name" ] || { echo "aborted (no name)."; exit 1; }
    read -r -p "  Source folder on a mounted Windows drive (e.g. /mnt/c/Users/you/Documents): " src
    [ -n "$src" ] || { echo "aborted (no source)."; exit 1; }
    read -r -p "  Mode [both]: " mode; [ -z "$mode" ] && mode=both
    read -r -p "  Include regexes (space-separated, empty = all; POSIX ERE, matched vs relative path): " inc
    read -r -p "  Exclude regexes (space-separated, empty = none): " exc
    {
        echo ""
        echo "job $name"
        echo "source $src"
        echo "mode $mode"
        for r in $inc; do echo "include $r"; done
        for r in $exc; do echo "exclude $r"; done
    } >> "$LSL_BACKUP_CONF"
    echo "Added job '$name'. Review with: lsl-win-backup.sh --list"
    echo "Run with: lsl-win-backup.sh --run   (or --estimate first)"
}

do_install_timer() {
    [ "$(id -u)" -eq 0 ] || { echo "error: --install-timer needs root." >&2; exit 1; }
    for u in lsl-win-backup.timer lsl-win-backup.service; do
        if [ -f "$SCRIPT_DIR/../systemd/$u" ]; then
            cp "$SCRIPT_DIR/../systemd/$u" /etc/systemd/system/ 2>/dev/null || true
        fi
    done
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now lsl-win-backup.timer 2>/dev/null || true
    echo "Enabled lsl-win-backup.timer (daily). Status:"
    systemctl status lsl-win-backup.timer --no-pager 2>/dev/null | head -n 5 || true
}

show_help() {
    grep -E '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '1,40p'
    echo "Config file: $LSL_BACKUP_CONF"
    echo "Backup dir : $LSL_BACKUP_DIR"
}

case "$MODE" in
    list) do_list ;;
    estimate) do_estimate ;;
    dryrun) do_dryrun ;;
    run) do_run ;;
    add) do_add_folder ;;
    install_timer) do_install_timer ;;
    help|*) show_help ;;
esac
