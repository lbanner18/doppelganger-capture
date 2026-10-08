# shellcheck shell=sh disable=SC2034 # variables here are used by the sourcing scripts
# Shared helpers for Project Doppelganger.
#
# POSIX sh only: these scripts run under BusyBox ash on the Alpine boot stick,
# and under dash or bash on the server. Source this file; do not execute it.

DG_VERSION=0.3.0
DG_FAT32_MAX=4294967295 # largest file FAT32 can store (4 GiB - 1 byte)
DG_DEFAULT_CHUNK=3900M
DG_MANIFEST_FORMAT=3

# Byte-wise sorting and globbing, so part names always sort in split order.
LC_ALL=C
export LC_ALL

DG_PROG=${0##*/}
DG_TMP=
DG_PIDS=
DG_FAILED=
DG_MONITOR_PID=
DG_ON_FAIL=
DG_ON_EXIT=

die() {
    printf '%s: error: %s\n' "$DG_PROG" "$*" >&2
    exit 1
}

warn() {
    printf '%s: warning: %s\n' "$DG_PROG" "$*" >&2
}

info() {
    [ "${DG_QUIET:-0}" = 1 ] || printf '%s\n' "$*" >&2
}

need() {
    for _cmd in "$@"; do
        command -v "$_cmd" >/dev/null 2>&1 || die "$_cmd is required but was not found in PATH"
    done
}

# ---------------------------------------------------------------------------
# Numbers and formatting

# parse_size SIZE: print SIZE in bytes. Accepts a plain byte count or a K, M or
# G suffix in either case (binary units), e.g. 3900M -> 4089446400.
parse_size() {
    _num=${1%[KkMmGg]}
    case $_num in '' | *[!0-9]*) return 1 ;; esac
    _num=${_num#"${_num%%[!0]*}"} # strip leading zeros so $(( )) is not octal
    [ -n "$_num" ] || _num=0
    case $1 in
        *[Kk]) _mult=1024 ;;
        *[Mm]) _mult=1048576 ;;
        *[Gg]) _mult=1073741824 ;;
        *) _mult=1 ;;
    esac
    echo $((_num * _mult))
}

human_bytes() {
    awk -v b="$1" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", unit, " ")
        i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        printf(i == 1 ? "%d %s\n" : "%.1f %s\n", b, unit[i])
    }'
}

human_duration() {
    awk -v s="$1" 'BEGIN {
        s = int(s); h = int(s / 3600); m = int(s % 3600 / 60)
        if (h > 0) printf("%dh%02dm%02ds\n", h, m, s % 60)
        else if (m > 0) printf("%dm%02ds\n", m, s % 60)
        else printf("%ds\n", s)
    }'
}

utc_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

file_size() {
    stat -c %s -- "$1"
}

sha256_file() {
    sha256sum <"$1" | cut -d ' ' -f 1
}

# manifest_get FILE KEY: print the value of the first KEY=value line.
manifest_get() {
    awk -v key="$2" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$1"
}

# dg_format_from_name PATH: guess a QEMU image format from the file extension.
dg_format_from_name() {
    case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
        *.qcow2) echo qcow2 ;;
        *.vmdk) echo vmdk ;;
        *.vhdx) echo vhdx ;;
        *.vdi) echo vdi ;;
        *.vhd | *.vpc) echo vpc ;;
        *) echo raw ;;
    esac
}

# ---------------------------------------------------------------------------
# Compression

# select_compression METHOD LEVEL: set DG_METHOD, DG_LEVEL, DG_COMPRESS and
# DG_DECOMPRESS. METHOD "auto" prefers zstd and falls back to gzip. The
# commands are plain words (no quoting needed) so they can run as simple
# background commands, which the shell execs without an extra subshell.
select_compression() {
    case $1 in
        auto)
            if command -v zstd >/dev/null 2>&1; then
                DG_METHOD=zstd
            elif command -v gzip >/dev/null 2>&1; then
                DG_METHOD=gzip
            else
                die "zstd or gzip is required"
            fi
            ;;
        zstd | gzip)
            need "$1"
            DG_METHOD=$1
            ;;
        *) die "unsupported compression: $1 (expected auto, zstd or gzip)" ;;
    esac

    DG_LEVEL=${2:-1}
    case $DG_LEVEL in '' | *[!0-9]*) die "compression level must be a number: $DG_LEVEL" ;; esac
    case $DG_METHOD in
        zstd)
            [ "$DG_LEVEL" -ge 1 ] && [ "$DG_LEVEL" -le 19 ] || die "zstd level must be 1-19"
            # --single-thread keeps memory low: no worker or async I/O threads.
            DG_COMPRESS="zstd -q -$DG_LEVEL --single-thread -c"
            DG_DECOMPRESS="zstd -q -d -c"
            ;;
        gzip)
            [ "$DG_LEVEL" -ge 1 ] && [ "$DG_LEVEL" -le 9 ] || die "gzip level must be 1-9"
            DG_COMPRESS="gzip -$DG_LEVEL -c"
            DG_DECOMPRESS="gzip -d -c"
            ;;
    esac
}

# set_decompression METHOD: set DG_DECOMPRESS for a method read from a manifest.
set_decompression() {
    case $1 in
        zstd | gzip) select_compression "$1" 1 ;;
        *) die "unsupported compression in manifest: ${1:-<missing>}" ;;
    esac
}

# ---------------------------------------------------------------------------
# Temporary files, background stages and cleanup
#
# Pipelines are built from background stages joined by named pipes instead of
# `a | b | c`. POSIX sh only reports the exit status of the last command in a
# pipeline, and BusyBox, dash and bash disagree about pipefail. With FIFOs
# every stage has its own PID, so we can wait for each one and see exactly
# which stage failed. That matters: if dd hits a read error, every later stage
# sees a clean end-of-file and succeeds, so only dd's own status reveals that
# the image is truncated.
#
# Rule for building stages: open the FIFO redirections first and any regular
# file second. If the file open fails, the stage exits with its FIFO already
# open, its neighbour sees EOF or SIGPIPE, and the pipeline unwinds instead of
# blocking forever in open().

dg_init() {
    DG_TMP=$(mktemp -d "${TMPDIR:-/tmp}/doppelganger.XXXXXX") || die "cannot create a temporary directory"
    trap dg_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

dg_cleanup() {
    _rc=$?
    trap - EXIT HUP INT TERM
    if [ -n "$DG_MONITOR_PID" ]; then
        kill "$DG_MONITOR_PID" 2>/dev/null || :
    fi
    if [ -n "$DG_PIDS" ]; then
        # shellcheck disable=SC2086 # intentional word splitting of the PID list
        kill $DG_PIDS 2>/dev/null || :
        wait 2>/dev/null || :
    fi
    # A script sets DG_ON_FAIL to a function that removes whatever it was
    # writing, so a failed or interrupted run leaves nothing half-written.
    if [ "$_rc" -ne 0 ] && [ -n "$DG_ON_FAIL" ]; then
        "$DG_ON_FAIL" || :
    fi
    # DG_ON_EXIT runs on every exit, before the temporary directory goes.
    if [ -n "$DG_ON_EXIT" ]; then
        "$DG_ON_EXIT" || :
    fi
    [ -z "$DG_TMP" ] || rm -rf -- "$DG_TMP"
    exit "$_rc"
}

# dg_wait NAME PID: wait for one stage and record it in DG_FAILED if it failed.
dg_wait() {
    _st=0
    wait "$2" || _st=$?
    [ "$_st" -eq 0 ] || DG_FAILED="$DG_FAILED $1(exit $_st)"
}

dg_stop_monitor() {
    if [ -n "$DG_MONITOR_PID" ]; then
        kill "$DG_MONITOR_PID" 2>/dev/null || :
        wait "$DG_MONITOR_PID" 2>/dev/null || :
        DG_MONITOR_PID=
        # Finish a carriage-return progress line.
        if [ -t 2 ] && [ "${DG_QUIET:-0}" != 1 ]; then printf '\n' >&2; fi
    fi
}

# dg_start_progress PID FIELD TOTAL LABEL [BASE]: in the background, report
# BASE + FIELD (rchar or wchar from /proc/PID/io) against TOTAL bytes until
# PID exits. BASE is how far earlier chunks got. BusyBox dd has no
# status=progress, and this also gives a percentage and an ETA.
dg_start_progress() {
    [ "${DG_PROGRESS:-1}" = 1 ] && [ "${DG_QUIET:-0}" != 1 ] || return 0
    [ -r "/proc/$1/io" ] || return 0
    _dg_progress_loop "$@" &
    DG_MONITOR_PID=$!
}

_dg_progress_loop() {
    # Never run the parent's cleanup from this background loop.
    trap - EXIT HUP INT TERM
    _pid=$1 _field=$2 _total=$3 _label=$4 _base=${5:-0}
    _start=$(date +%s)
    _tty=0
    [ -t 2 ] && _tty=1
    while kill -0 "$_pid" 2>/dev/null; do
        sleep "${DG_PROGRESS_INTERVAL:-5}"
        _done=$(awk -v f="$_field:" '$1 == f { print $2 }' "/proc/$_pid/io" 2>/dev/null) || break
        [ -n "$_done" ] || break
        awk -v now="$_done" -v base="$_base" -v total="${_total:-0}" -v elapsed=$(($(date +%s) - _start)) \
            -v label="$_label" -v tty="$_tty" '
            function h(b,   i, u) {
                split("B KiB MiB GiB TiB", u, " "); i = 1
                while (b >= 1024 && i < 5) { b /= 1024; i++ }
                return sprintf(i == 1 ? "%d %s" : "%.1f %s", b, u[i])
            }
            function d(s) {
                s = int(s)
                if (s >= 3600) return sprintf("%dh%02dm", s / 3600, s % 3600 / 60)
                return sprintf("%dm%02ds", s / 60, s % 60)
            }
            BEGIN {
                rate = elapsed > 0 ? now / elapsed : 0
                done = base + now
                line = sprintf("%s: %s", label, h(done))
                if (total > 0) line = line sprintf(" of %s (%.1f%%)", h(total), 100 * done / total)
                line = line sprintf(", %s/s", h(rate))
                if (total > 0 && rate > 0 && done < total) line = line ", ETA " d((total - done) / rate)
                if (tty) printf("\r%-79s", line); else print line
            }' >&2
    done
}

# ---------------------------------------------------------------------------
# Block device safety checks

# dg_block_family DEVICE: print the kernel names of DEVICE, its partitions and
# anything stacked on top of them (LVM, dm-crypt, md), one per line.
dg_block_family() {
    _sys=${DG_SYSFS:-/sys}
    _queue=$(basename "$(readlink -f "$1")")
    while [ -n "$_queue" ]; do
        # shellcheck disable=SC2086 # the queue is a space-separated word list
        set -- $_queue
        _cur=$1
        shift
        _queue=$*
        printf '%s\n' "$_cur"
        for _child in "$_sys/class/block/$_cur/$_cur"*; do
            [ -e "$_child/partition" ] && _queue="$_queue ${_child##*/}"
        done
        for _holder in "$_sys/class/block/$_cur/holders/"*; do
            [ -e "$_holder" ] && _queue="$_queue ${_holder##*/}"
        done
    done | sort -u
}

# dg_family_in_use FAMILY_FILE: print every mount or swap area that lives on a
# device named in FAMILY_FILE. Prints nothing if the family is idle.
dg_family_in_use() {
    while read -r _dev _mnt _rest; do
        case $_dev in /dev/*) ;; *) continue ;; esac
        _name=$(basename "$(readlink -f "$_dev" 2>/dev/null || printf '%s' "$_dev")")
        if grep -qx -- "$_name" "$1"; then
            printf '  %s mounted on %s\n' "$_dev" "$_mnt"
        fi
    done <"${DG_MOUNTS:-/proc/mounts}"
    if [ -r "${DG_SWAPS:-/proc/swaps}" ]; then
        while read -r _dev _rest; do
            case $_dev in /dev/*) ;; *) continue ;; esac
            _name=$(basename "$(readlink -f "$_dev" 2>/dev/null || printf '%s' "$_dev")")
            if grep -qx -- "$_name" "$1"; then
                printf '  %s in use as swap\n' "$_dev"
            fi
        done <"${DG_SWAPS:-/proc/swaps}"
    fi
}

# dg_path_on_family PATH FAMILY_FILE: succeed if PATH lives on a filesystem
# whose device is in FAMILY_FILE (compares st_dev with each device's
# major:minor, so it sees through bind mounts and /dev/disk/by-* names).
dg_path_on_family() {
    _sys=${DG_SYSFS:-/sys}
    _want=$(stat -c %d -- "$1") || return 1
    while IFS= read -r _name; do
        [ -r "$_sys/class/block/$_name/dev" ] || continue
        IFS=: read -r _maj _min <"$_sys/class/block/$_name/dev"
        # glibc/musl makedev() encoding of major:minor.
        [ "$_want" -eq $(((_maj << 8) | (_min & 255) | ((_min >> 8) << 20))) ] && return 0
    done <"$2"
    return 1
}

# ---------------------------------------------------------------------------
# Hardware facts for whoever turns the capture into a VM
#
# Read-only lookups in /sys and /proc on the machine being captured (booted
# from the stick, so "this machine" is the source). No serial numbers.

# Always succeeds: a missing fact is just empty. (Under set -e, a failing
# command substitution in an assignment would end the whole script.)
_dg_read_line() {
    if [ -r "$1" ]; then
        sed -n '1s/[[:space:]]*$//p' "$1" 2>/dev/null || :
    fi
}

# dg_storage_controller NAME: how block device NAME (e.g. sda, nvme0n1) is
# attached: nvme, sata-ahci, raid, ide, sas, scsi, usb or unknown. Walks up
# the device's sysfs path and reads each PCI device's class. A RAID-class
# controller further up (Intel RST/VMD) is reported as "+raid", because
# Windows installed in that mode often cannot boot on a VM's plain controller.
dg_storage_controller() {
    _sys=${DG_SYSFS:-/sys}
    _dir=$(readlink -f "$_sys/class/block/$1/device" 2>/dev/null) || _dir=
    if [ -z "$_dir" ] || [ ! -d "$_dir" ]; then
        echo unknown
        return
    fi
    _kind=
    _raid=
    while [ -n "$_dir" ] && [ "$_dir" != / ]; do
        case $_dir in */usb[0-9]*) [ -n "$_kind" ] || _kind=usb ;; esac
        if [ -r "$_dir/class" ]; then
            case $(cat "$_dir/class") in
                0x0108*) _this=nvme ;;
                0x0106*) _this=sata-ahci ;;
                0x0104*) _this=raid ;;
                0x0101*) _this=ide ;;
                0x0107*) _this=sas ;;
                0x0100*) _this=scsi ;;
                *) _this= ;;
            esac
            if [ "$_this" = raid ]; then
                _raid=1
                [ -n "$_kind" ] || _kind=raid
            elif [ -n "$_this" ] && [ -z "$_kind" ]; then
                _kind=$_this
            fi
        fi
        _dir=${_dir%/*}
    done
    case $_kind in
        '') echo unknown ;;
        raid) echo raid ;;
        *) if [ -n "$_raid" ]; then echo "$_kind+raid"; else echo "$_kind"; fi ;;
    esac
}

# dg_hardware_info KIND NAME: print key=value facts about this machine and the
# source disk NAME (KIND is block or file).
dg_hardware_info() {
    _sys=${DG_SYSFS:-/sys}
    _proc=${DG_PROC:-/proc}
    _vendor=$(_dg_read_line "$_sys/class/dmi/id/sys_vendor")
    _product=$(_dg_read_line "$_sys/class/dmi/id/product_name")
    _machine=$(printf '%s %s' "$_vendor" "$_product" | sed 's/^ *//; s/ *$//') || _machine=
    _cpu=$(awk -F': *' '$1 ~ /^(model name|Hardware|cpu model)[[:space:]]*$/ { print $2; exit }' "$_proc/cpuinfo" 2>/dev/null) || _cpu=
    _threads=$(grep -c '^processor' "$_proc/cpuinfo" 2>/dev/null) || _threads=
    _memory=$(awk '$1 == "MemTotal:" { printf("%.0f\n", $2 * 1024) }' "$_proc/meminfo" 2>/dev/null) || _memory=
    if [ -d "$_sys/firmware/efi" ]; then
        _firmware=uefi
        _secure=unknown
        for _var in "$_sys"/firmware/efi/efivars/SecureBoot-*; do
            [ -r "$_var" ] || continue
            # 4 bytes of attributes, then the value: 1 = on, 0 = off.
            case $(od -An -tu1 -j4 -N1 "$_var" 2>/dev/null | tr -d ' ') in
                1) _secure=on ;;
                0) _secure=off ;;
            esac
        done
    elif [ -d "$_sys/firmware" ]; then
        _firmware=bios
        _secure=n/a
    else
        _firmware=unknown
        _secure=unknown
    fi
    if [ -e "$_sys/class/tpm/tpm0" ]; then
        _tpm=present
        _major=$(_dg_read_line "$_sys/class/tpm/tpm0/tpm_version_major")
        [ -z "$_major" ] || _tpm="present (TPM $_major)"
    elif [ -d "$_sys/class" ]; then
        _tpm=absent
    else
        _tpm=unknown
    fi
    if [ "$1" = block ]; then
        _controller=$(dg_storage_controller "$2")
    else
        _controller=n/a
    fi
    printf 'machine=%s\n' "${_machine:-unknown}"
    printf 'cpu=%s\n' "${_cpu:-unknown}"
    printf 'cpu_threads=%s\n' "${_threads:-unknown}"
    printf 'architecture=%s\n' "$(uname -m)"
    printf 'memory_bytes=%s\n' "${_memory:-unknown}"
    printf 'firmware=%s\n' "$_firmware"
    printf 'secure_boot=%s\n' "$_secure"
    printf 'tpm=%s\n' "$_tpm"
    printf 'storage_controller=%s\n' "$_controller"
}

# ---------------------------------------------------------------------------
# Reading a capture

# dg_load_capture CAPTURE: read a capture and set CAP_FORMAT, CAP_METHOD,
# CAP_BYTES, CAP_DIR and DG_DECOMPRESS. CAPTURE is a capture folder (format 3)
# or the prefix of a format 1 or 2 capture. Writes the ordered part paths to
# $DG_TMP/parts.list and "HASH PATH" lines to $DG_TMP/parts.expected (empty
# for format 1).
#   Format 3 also sets CAP_CHUNK, CAP_COUNT and CAP_DIGEST, and writes
#   "INDEX OFFSET RAW_BYTES RAW_SHA256 PATH" lines to $DG_TMP/chunks.list.
#   Formats 1 and 2 set CAP_SHA256, the hash of the whole image.
dg_load_capture() {
    : >"$DG_TMP/parts.expected"
    : >"$DG_TMP/parts.list"
    : >"$DG_TMP/chunks.list"
    if [ -d "$1" ]; then
        _dg_load_folder "$1"
    else
        _dg_load_prefix "$1"
    fi
}

_dg_load_folder() {
    CAP_DIR=${1%/}
    CAP_MANIFEST=$CAP_DIR/manifest
    CAP_GLOB=$CAP_DIR/part-
    if [ ! -f "$CAP_MANIFEST" ]; then
        if [ -f "$CAP_DIR/session" ]; then
            _done=$(grep -c . "$CAP_DIR/chunks" 2>/dev/null) || _done=0
            _total=$(manifest_get "$CAP_DIR/session" chunk_count)
            die "the capture in $CAP_DIR is unfinished ($_done of ${_total:-?} chunks); run capture_to_parts.sh again with the same destination to resume it"
        fi
        die "not a capture folder (no manifest): $CAP_DIR"
    fi
    CAP_FORMAT=$(manifest_get "$CAP_MANIFEST" format)
    [ "$CAP_FORMAT" = 3 ] || die "unsupported manifest format in $CAP_MANIFEST: ${CAP_FORMAT:-<missing>}"
    CAP_METHOD=$(manifest_get "$CAP_MANIFEST" compression)
    set_decompression "$CAP_METHOD"
    CAP_BYTES=$(manifest_get "$CAP_MANIFEST" image_bytes)
    CAP_CHUNK=$(manifest_get "$CAP_MANIFEST" chunk_bytes)
    CAP_COUNT=$(manifest_get "$CAP_MANIFEST" chunk_count)
    CAP_DIGEST=$(manifest_get "$CAP_MANIFEST" content_digest)
    for _value in "$CAP_BYTES" "$CAP_CHUNK" "$CAP_COUNT"; do
        case $_value in '' | *[!0-9]*) die "manifest is missing sizes: $CAP_MANIFEST" ;; esac
    done
    [ "$CAP_CHUNK" -gt 0 ] || die "manifest has a zero chunk size: $CAP_MANIFEST"
    case $CAP_DIGEST in '' | *[!0-9a-f]*) die "manifest has no valid content digest" ;; esac
    [ ${#CAP_DIGEST} -eq 64 ] || die "manifest has no valid content digest"
    [ -f "$CAP_DIR/chunks" ] || die "missing chunk ledger: $CAP_DIR/chunks"

    # The ledger travelled with the image, so check every line against the
    # chunk layout before trusting it: contiguous indexes, offsets and sizes
    # that follow from the chunk size, well-formed hashes.
    awk -v dir="$CAP_DIR" -v chunk="$CAP_CHUNK" -v image="$CAP_BYTES" -v count="$CAP_COUNT" \
        -v expf="$DG_TMP/parts.expected" -v lst="$DG_TMP/parts.list" -v chk="$DG_TMP/chunks.list" '
        function bad(why) { printf("chunk ledger line %d: %s\n", NR, why) > "/dev/stderr"; failed = 1; exit 1 }
        {
            if (NF != 6) bad("expected 6 fields")
            for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/) bad("field " i " is not a number")
            if ($5 !~ /^[0-9a-f]+$/ || length($5) != 64) bad("bad raw SHA-256")
            if ($6 !~ /^[0-9a-f]+$/ || length($6) != 64) bad("bad part SHA-256")
            if ($1 != NR - 1) bad("chunk index out of order")
            if ($2 != $1 * chunk) bad("offset does not match the chunk size")
            want = image - $2; if (want > chunk) want = chunk
            if ($3 != want) bad("raw size does not match the chunk layout")
            path = sprintf("%s/part-%06d", dir, $1)
            print $6 " " path > expf
            print path > lst
            print $1 " " $2 " " $3 " " $5 " " path > chk
            total += $3
        }
        END {
            if (failed) exit 1
            if (NR != count) { printf("chunk ledger has %d chunks but the manifest says %d\n", NR, count) > "/dev/stderr"; exit 1 }
            if (total != image) { printf("chunk ledger covers %.0f bytes but the image is %.0f\n", total, image) > "/dev/stderr"; exit 1 }
        }' "$CAP_DIR/chunks" || die "the chunk ledger is damaged: $CAP_DIR/chunks"

    _digest=$(awk '{ print $5 }' "$CAP_DIR/chunks" | sha256sum | cut -d ' ' -f 1)
    [ "$_digest" = "$CAP_DIGEST" ] || die "the chunk ledger does not match the manifest's content digest; the ledger or manifest was changed"
}

_dg_load_prefix() {
    CAP_PREFIX=$1
    CAP_DIR=$(dirname -- "$1")
    CAP_BASE=$(basename -- "$1")
    CAP_MANIFEST=$1.manifest
    CAP_GLOB=$CAP_DIR/$CAP_BASE.part-
    [ -f "$CAP_MANIFEST" ] || die "missing manifest: $CAP_MANIFEST (an interrupted capture never writes one)"

    CAP_FORMAT=$(manifest_get "$CAP_MANIFEST" format)
    CAP_METHOD=$(manifest_get "$CAP_MANIFEST" compression)
    set_decompression "$CAP_METHOD"

    case ${CAP_FORMAT:-1} in
        1)
            # Prototype format: bare hash in PREFIX.sha256, parts found by glob.
            [ -f "$1.sha256" ] || die "missing hash file: $1.sha256"
            CAP_SHA256=$(tr -d '[:space:]' <"$1.sha256")
            CAP_BYTES=
            for _part in "$CAP_GLOB"*; do
                [ -f "$_part" ] && printf '%s\n' "$_part"
            done >"$DG_TMP/parts.list"
            ;;
        2)
            CAP_SHA256=$(manifest_get "$CAP_MANIFEST" image_sha256)
            CAP_BYTES=$(manifest_get "$CAP_MANIFEST" image_bytes)
            _parts_file=$CAP_DIR/$(manifest_get "$CAP_MANIFEST" parts_file)
            [ -f "$_parts_file" ] || die "missing parts list: $_parts_file"
            # Part names come from a file that travelled with the image, so
            # accept only names this tool generates: no paths, no surprises.
            awk -v dir="$CAP_DIR" -v base="$CAP_BASE" '
                {
                    hash = $1; name = $0; sub(/^[^ ]+ [ *]/, "", name)
                    if (hash !~ /^[0-9a-f]+$/ || length(hash) != 64 ||
                        index(name, base ".part-") != 1 || name ~ /\// ||
                        substr(name, length(base) + 7) !~ /^[a-z]+$/) {
                        printf("invalid line %d in parts list: %s\n", NR, $0) > "/dev/stderr"
                        exit 1
                    }
                    print hash " " dir "/" name
                }' "$_parts_file" >"$DG_TMP/parts.expected" || die "parts list is malformed: $_parts_file"
            cut -d ' ' -f 2- "$DG_TMP/parts.expected" >"$DG_TMP/parts.list"
            _want=$(manifest_get "$CAP_MANIFEST" part_count)
            _have=$(wc -l <"$DG_TMP/parts.list" | tr -d ' ')
            [ "$_have" = "$_want" ] || die "parts list has $_have entries but the manifest says $_want"
            ;;
        *) die "unsupported manifest format: $CAP_FORMAT (written by a newer version?)" ;;
    esac

    case $CAP_SHA256 in '' | *[!0-9a-f]*) die "manifest has no valid image SHA-256" ;; esac
    [ ${#CAP_SHA256} -eq 64 ] || die "manifest has no valid image SHA-256"
    [ -s "$DG_TMP/parts.list" ] || die "no image parts found for prefix: $1"
}

# dg_check_parts_present: fail listing every missing part; warn about strays.
dg_check_parts_present() {
    _missing=0
    while IFS= read -r _part; do
        if [ ! -f "$_part" ]; then
            printf '  MISSING  %s\n' "$_part" >&2
            _missing=$((_missing + 1))
        fi
    done <"$DG_TMP/parts.list"
    [ "$_missing" -eq 0 ] || die "$_missing part(s) missing"
    for _part in "$CAP_GLOB"*; do
        [ -e "$_part" ] || continue
        grep -qxF -- "$_part" "$DG_TMP/parts.list" || warn "ignoring part not listed in the manifest: $_part"
    done
}

# dg_check_part_hashes: compare every part with its recorded SHA-256 and name
# the bad ones, so a corrupt copy can be fixed by re-copying a single part.
dg_check_part_hashes() {
    [ -s "$DG_TMP/parts.expected" ] || return 0
    _total=$(wc -l <"$DG_TMP/parts.expected" | tr -d ' ')
    _n=0
    _bad=0
    while read -r _hash _part; do
        _n=$((_n + 1))
        if [ "$(sha256_file "$_part")" = "$_hash" ]; then
            info "  [$_n/$_total] ok       ${_part##*/}"
        else
            printf '  [%s/%s] CORRUPT  %s\n' "$_n" "$_total" "$_part" >&2
            _bad=$((_bad + 1))
        fi
    done <"$DG_TMP/parts.expected"
    [ "$_bad" -eq 0 ] || die "$_bad of $_total part(s) do not match their recorded SHA-256; re-copy them from the original media"
}

# dg_restore_stream LIST OUTPUT [TOTAL]: decompress the parts listed in LIST
# and write the image to OUTPUT, or discard it if OUTPUT is empty. Sets
# DG_RESTORED_SHA256 and DG_RESTORED_BYTES. Writes sparsely (holes instead
# of zero blocks) when GNU dd is available and DG_SPARSE is not 0.
dg_restore_stream() {
    _list=$1 _out=$2 _total=${3:-}
    _z=$DG_TMP/restore.z _raw=$DG_TMP/restore.raw _w=$DG_TMP/restore.write
    _hf=$DG_TMP/restore.hash _cf=$DG_TMP/restore.count
    mkfifo "$_z" "$_raw" "$_w" "$_hf" "$_cf"
    DG_FAILED=

    sha256sum <"$_hf" >"$DG_TMP/restore.sha256" &
    _pid_hash=$!
    wc -c <"$_cf" >"$DG_TMP/restore.bytes" &
    _pid_count=$!
    _pid_write=
    if [ -n "$_out" ]; then
        if [ "${DG_SPARSE:-1}" = 1 ] && dd if=/dev/null of=/dev/null conv=sparse status=none 2>/dev/null; then
            dd bs=1M iflag=fullblock conv=sparse status=none of="$_out" <"$_w" &
        else
            cat <"$_w" >"$_out" &
        fi
        _pid_write=$!
        tee "$_hf" "$_cf" <"$_raw" >"$_w" &
    else
        tee "$_hf" "$_cf" <"$_raw" >/dev/null &
    fi
    _pid_tee=$!
    # shellcheck disable=SC2086 # DG_DECOMPRESS is a plain word list
    $DG_DECOMPRESS <"$_z" >"$_raw" &
    _pid_dec=$!
    (
        while IFS= read -r _part; do
            cat -- "$_part" || exit 1
        done <"$_list"
    ) >"$_z" &
    _pid_read=$!
    DG_PIDS="$_pid_hash $_pid_count $_pid_write $_pid_tee $_pid_dec $_pid_read"

    dg_start_progress "$_pid_dec" wchar "$_total" restore
    dg_wait read "$_pid_read"
    dg_wait decompress "$_pid_dec"
    dg_wait tee "$_pid_tee"
    dg_wait sha256sum "$_pid_hash"
    dg_wait wc "$_pid_count"
    [ -z "$_pid_write" ] || dg_wait write "$_pid_write"
    dg_stop_monitor
    DG_PIDS=
    [ -z "$DG_FAILED" ] || return 1

    DG_RESTORED_SHA256=$(cut -d ' ' -f 1 <"$DG_TMP/restore.sha256")
    DG_RESTORED_BYTES=$(awk '{ print $1 }' "$DG_TMP/restore.bytes")
}

# dg_restore_chunks OUTPUT TOTAL: decompress a format-3 capture chunk by chunk
# (from $DG_TMP/chunks.list) into OUTPUT, or discard it if OUTPUT is empty.
# Each chunk is checked against its recorded raw SHA-256 before the next one
# starts, and written at its own offset, sparsely where GNU dd allows. On a
# failure, sets DG_BAD_CHUNK to the chunk's index and returns non-zero.
dg_restore_chunks() {
    _out=$1 _total=$2
    _raw=$DG_TMP/restore.raw _w=$DG_TMP/restore.write _hf=$DG_TMP/restore.hash
    mkfifo "$_raw" "$_w" "$_hf"
    DG_BAD_CHUNK=
    DG_BAD_REASON=
    _sparse=0
    if [ -n "$_out" ]; then
        : >"$_out"
        if [ "${DG_SPARSE:-1}" = 1 ] && dd if=/dev/null of=/dev/null conv=sparse status=none 2>/dev/null; then
            _sparse=1
        fi
    fi
    _done=0
    while read -r _idx _off _len _sha _part; do
        DG_FAILED=
        sha256sum <"$_hf" >"$DG_TMP/restore.sha256" &
        _pid_hash=$!
        _pid_write=
        if [ -n "$_out" ]; then
            if [ "$_sparse" = 1 ]; then
                dd bs=1M iflag=fullblock oflag=seek_bytes seek="$_off" conv=sparse,notrunc status=none of="$_out" <"$_w" &
            else
                dd bs=1M oflag=seek_bytes seek="$_off" conv=notrunc of="$_out" <"$_w" 2>/dev/null &
            fi
            _pid_write=$!
            tee "$_hf" <"$_raw" >"$_w" &
        else
            tee "$_hf" <"$_raw" >/dev/null &
        fi
        _pid_tee=$!
        # shellcheck disable=SC2086 # DG_DECOMPRESS is a plain word list
        $DG_DECOMPRESS >"$_raw" <"$_part" &
        _pid_dec=$!
        DG_PIDS="$_pid_hash $_pid_write $_pid_tee $_pid_dec"

        dg_start_progress "$_pid_dec" wchar "$_total" restore "$_done"
        dg_wait decompress "$_pid_dec"
        dg_wait tee "$_pid_tee"
        dg_wait sha256sum "$_pid_hash"
        [ -z "$_pid_write" ] || dg_wait write "$_pid_write"
        dg_stop_monitor
        DG_PIDS=
        if [ -n "$DG_FAILED" ]; then
            DG_BAD_CHUNK=$_idx
            DG_BAD_REASON="failed in:$DG_FAILED"
            return 1
        fi
        if [ "$(cut -d ' ' -f 1 <"$DG_TMP/restore.sha256")" != "$_sha" ]; then
            DG_BAD_CHUNK=$_idx
            DG_BAD_REASON="decompressed data does not match its recorded SHA-256"
            return 1
        fi
        _done=$((_done + _len))
    done <"$DG_TMP/chunks.list"

    # A sparse write leaves a trailing run of zeros as a hole; give the file
    # its full size.
    if [ -n "$_out" ] && [ "$(file_size "$_out")" -lt "$_total" ]; then
        dd if=/dev/null of="$_out" bs=1 seek="$_total" count=0 2>/dev/null
    fi
    DG_RESTORED_BYTES=$_done
}
