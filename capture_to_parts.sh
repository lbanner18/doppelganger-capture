#!/bin/sh
# Capture a disk into a folder of independently compressed chunks, locally or
# on a server over SSH. A capture that stops part-way resumes from the next
# chunk when the same command is run again. Runs under BusyBox ash.
set -eu

# shellcheck source=lib/common.sh
. "$(dirname -- "$0")/lib/common.sh"

usage() {
    cat <<EOF
Usage: $DG_PROG [options] SOURCE DESTINATION

Read SOURCE (a block device) in chunks, compress each chunk on its own and
store it in the DESTINATION folder, with a ledger recording every finished
chunk. If a capture stops part-way (power loss, Ctrl-C, a dropped network),
run the same command again: it checks what is already on the destination
and carries on from the next chunk.

DESTINATION is a folder: a local path, or [user@]host:/path to stream to a
server over SSH. It is created if needed; its parent folder must exist.

Examples:
  $DG_PROG /dev/sdX imager@10.77.0.1:/srv/doppelganger/drop/client_image
  $DG_PROG /dev/sdX /mnt/usb/client_image

Options:
  --chunk-size SIZE     raw bytes per chunk: bytes or K/M/G (default
                        $DG_DEFAULT_CHUNK, so every compressed part fits on FAT32)
  --compression NAME    auto (default: zstd, else gzip), zstd or gzip
  --level N             compression level (default 1)
  --allow-file          allow SOURCE to be a regular file (re-pack an image file)
  --allow-mounted       capture even if SOURCE or a partition on it is mounted
  --allow-large-chunks  allow chunks whose compressed part could pass FAT32's
                        4 GiB - 1 byte file limit
  --no-progress         do not print progress
  -h, --help            show this help

The folder ends up holding part-000000, part-000001, ... (one compressed
chunk each), chunks (the ledger), parts.sha256, hardware (facts about this
machine for building the VM), status (progress, for a dashboard to read), and
manifest, which is written last and marks the capture complete.

Nothing is read until you type the exact SOURCE path to confirm.

Environment: DG_SSH is the SSH command (default "ssh"). With OpenSSH the
capture shares one connection for every step; other clients (for example
DG_SSH="dbclient -y" for Dropbear) open a connection per step, so use key
authentication.
EOF
}

CHUNK=${CHUNK_SIZE:-$DG_DEFAULT_CHUNK}
COMPRESSION=${COMPRESSION:-auto}
LEVEL=1
CHUNK_GIVEN=0
COMPRESSION_GIVEN=0
LEVEL_GIVEN=0
[ -z "${CHUNK_SIZE:-}" ] || CHUNK_GIVEN=1
ALLOW_FILE=0
ALLOW_MOUNTED=0
ALLOW_LARGE=0
SOURCE=
DESTINATION=

add_positional() {
    if [ -z "$SOURCE" ]; then
        SOURCE=$1
    elif [ -z "$DESTINATION" ]; then
        DESTINATION=$1
    else
        usage >&2
        die "unexpected argument: $1"
    fi
}

while [ $# -gt 0 ]; do
    case $1 in
        -h | --help)
            usage
            exit 0
            ;;
        --chunk-size | --compression | --level)
            [ $# -ge 2 ] || die "$1 needs a value"
            case $1 in
                --chunk-size) CHUNK=$2 CHUNK_GIVEN=1 ;;
                --compression) COMPRESSION=$2 COMPRESSION_GIVEN=1 ;;
                --level) LEVEL=$2 LEVEL_GIVEN=1 ;;
            esac
            shift
            ;;
        --chunk-size=*) CHUNK=${1#*=} CHUNK_GIVEN=1 ;;
        --compression=*) COMPRESSION=${1#*=} COMPRESSION_GIVEN=1 ;;
        --level=*) LEVEL=${1#*=} LEVEL_GIVEN=1 ;;
        --allow-file) ALLOW_FILE=1 ;;
        --allow-mounted) ALLOW_MOUNTED=1 ;;
        --allow-large-chunks) ALLOW_LARGE=1 ;;
        --no-progress) DG_PROGRESS=0 ;;
        --)
            shift
            break
            ;;
        -*)
            usage >&2
            die "unknown option: $1"
            ;;
        *) add_positional "$1" ;;
    esac
    shift
done
for arg in "$@"; do add_positional "$arg"; done
if [ -z "$SOURCE" ] || [ -z "$DESTINATION" ]; then
    usage >&2
    exit 2
fi

# --- Settings ---------------------------------------------------------------

CHUNK_BYTES=$(parse_size "$CHUNK") || die "invalid chunk size: $CHUNK"
[ "$CHUNK_BYTES" -gt 0 ] || die "chunk size must be greater than zero"
# Data that does not compress can come out of zstd up to about 1/256 bigger.
if [ $((CHUNK_BYTES + CHUNK_BYTES / 256 + 1048576)) -gt "$DG_FAT32_MAX" ] && [ "$ALLOW_LARGE" != 1 ]; then
    die "a $CHUNK chunk could compress to more than FAT32's 4 GiB - 1 byte file limit; use 3900M or less, or pass --allow-large-chunks"
fi
select_compression "$COMPRESSION" "$LEVEL"
need dd sha256sum tee wc mkfifo mktemp stat
dg_init
# A disk image holds everything on the disk; keep the parts private.
umask 077

# --- Source -----------------------------------------------------------------

SOURCE_NAME=
if [ -b "$SOURCE" ]; then
    case $SOURCE in /dev/*) ;; *) die "refusing a block device outside /dev: $SOURCE" ;; esac
    SOURCE_KIND='block'
elif [ -f "$SOURCE" ]; then
    [ "$ALLOW_FILE" = 1 ] || die "source is a regular file, not a block device: $SOURCE (pass --allow-file to re-pack an image file)"
    SOURCE_KIND='file'
elif [ -e "$SOURCE" ]; then
    die "source is neither a block device nor a regular file: $SOURCE"
else
    die "source does not exist: $SOURCE"
fi
dd if="$SOURCE" bs=512 count=1 of=/dev/null 2>/dev/null || die "cannot read $SOURCE (run as root?)"

SOURCE_MODEL=
if [ "$SOURCE_KIND" = block ]; then
    SOURCE_NAME=$(basename "$(readlink -f "$SOURCE")")
    SOURCE_BYTES=
    if command -v blockdev >/dev/null 2>&1; then
        SOURCE_BYTES=$(blockdev --getsize64 "$SOURCE" 2>/dev/null) || SOURCE_BYTES=
    fi
    if [ -z "$SOURCE_BYTES" ] && [ -r "/sys/class/block/$SOURCE_NAME/size" ]; then
        SOURCE_BYTES=$(($(cat "/sys/class/block/$SOURCE_NAME/size") * 512))
    fi
    if [ -r "/sys/class/block/$SOURCE_NAME/device/model" ]; then
        SOURCE_MODEL=$(sed 's/[[:space:]]*$//' "/sys/class/block/$SOURCE_NAME/device/model")
    fi
else
    SOURCE_BYTES=$(file_size "$SOURCE")
fi
case $SOURCE_BYTES in '' | *[!0-9]*) die "cannot determine the size of $SOURCE" ;; esac

# --- Destination ------------------------------------------------------------
#
# [user@]host:/path streams to a server over SSH. Anything else is a local
# path; write ./name:with:colons for a local name like that.

REMOTE_HOST=
DEST=$DESTINATION
case $DEST in
    /* | ./* | ../*) ;;
    *:*)
        case ${DEST%%:*} in
            '' | */*) ;;
            *)
                REMOTE_HOST=${DEST%%:*}
                DEST=${DEST#*:}
                ;;
        esac
        ;;
esac
while :; do
    case $DEST in
        ?*/) DEST=${DEST%/} ;;
        *) break ;;
    esac
done
case $DEST in '' | /) die "the destination must name a folder, e.g. ${REMOTE_HOST:+$REMOTE_HOST:}/srv/doppelganger/drop/client_image" ;; esac
DEST_PARENT=$(dirname -- "$DEST")
DEST_NAME=$(basename -- "$DEST")
case $DEST_NAME in
    -* | .*) die "the folder name must not start with '-' or '.': $DEST_NAME" ;;
    *[!A-Za-z0-9._-]*) die "the folder name may only use letters, digits, '.', '_' and '-': $DEST_NAME" ;;
esac
DEST_LABEL=${REMOTE_HOST:+$REMOTE_HOST:}$DEST

# With OpenSSH, every step of the capture shares one authenticated
# connection (a "control master") instead of logging in again for each chunk.
# Its socket lives in DG_TMP; Unix socket paths must stay under 108 bytes, and
# %C expands to 40 characters, so a long TMPDIR just means no sharing.
SSH_CMD=${DG_SSH:-ssh}
if [ -n "$REMOTE_HOST" ]; then
    # shellcheck disable=SC2086 # SSH_CMD may carry options
    need ${SSH_CMD%% *}
    case $DG_TMP in
        *[!A-Za-z0-9._/-]*) ;;
        *)
            if [ ${#DG_TMP} -le 55 ] && [ -z "${DG_SSH:-}" ] && ssh -V 2>&1 | grep -q OpenSSH; then
                SSH_CMD="ssh -o ControlMaster=auto -o ControlPath=$DG_TMP/ssh-%C -o ControlPersist=120"
                close_ssh_master() {
                    ssh -o ControlPath="$DG_TMP/ssh-%C" -O exit "$REMOTE_HOST" >/dev/null 2>&1 || :
                }
                DG_ON_EXIT=close_ssh_master
            fi
            ;;
    esac
fi

# sq WORD: quote WORD for a POSIX shell command line.
sq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# in_dir_cmd DIR COMMAND: COMMAND as a shell command line that runs in DIR.
in_dir_cmd() {
    printf 'cd %s && umask 077 && %s' "$(sq "$1")" "$2"
}

# run_in DIR COMMAND: run COMMAND with sh in DIR, here or on the SSH host.
# Every destination operation goes through this one path, so the local tests
# also exercise the commands the remote side runs.
run_in() {
    if [ -n "$REMOTE_HOST" ]; then
        # The remote login shell might not be sh-compatible, so hand the
        # command to sh explicitly.
        # shellcheck disable=SC2086 # SSH_CMD may carry options
        $SSH_CMD "$REMOTE_HOST" "sh -c $(sq "$(in_dir_cmd "$1" "$2")")"
    else
        sh -c "$(in_dir_cmd "$1" "$2")"
    fi
}

dest_sh() {
    run_in "$DEST" "$1"
}

if [ -z "$REMOTE_HOST" ] && [ ! -d "$DEST_PARENT" ]; then
    die "the destination's parent folder does not exist: $DEST_PARENT"
fi
[ -z "$REMOTE_HOST" ] || info "Checking $DEST_LABEL over SSH..."
Q_NAME=$(sq "$DEST_NAME")
STATE=$(run_in "$DEST_PARENT" "if ! command -v sha256sum >/dev/null || ! command -v mkfifo >/dev/null ||
        ! command -v mktemp >/dev/null || ! command -v tee >/dev/null; then echo tools
    elif [ ! -e $Q_NAME ]; then if [ -w . ]; then echo new; else echo readonly; fi
    elif [ ! -d $Q_NAME ]; then echo notdir
    elif [ ! -w $Q_NAME ]; then echo readonly
    elif [ -f $Q_NAME/manifest ]; then echo complete
    elif [ -f $Q_NAME/session ]; then echo resume
    elif [ -z \"\$(ls -A $Q_NAME)\" ]; then echo empty
    else echo foreign; fi" </dev/null) ||
    die "cannot reach ${REMOTE_HOST:-the destination} or enter $DEST_PARENT there"
case $STATE in
    new | empty | resume) ;;
    tools) die "${REMOTE_HOST:-this machine} needs sha256sum, mkfifo, mktemp and tee" ;;
    readonly) die "not writable: $DEST_LABEL" ;;
    notdir) die "the destination exists and is not a folder: $DEST_LABEL" ;;
    complete) die "a finished capture is already in $DEST_LABEL; choose another folder or archive this one" ;;
    foreign) die "$DEST_LABEL is not empty and is not a capture folder; choose a new or empty folder" ;;
    *) die "unexpected reply from ${REMOTE_HOST:-the destination}: $STATE" ;;
esac

# --- Safety checks for a real disk ------------------------------------------

if [ "$SOURCE_KIND" = block ]; then
    dg_block_family "$SOURCE" >"$DG_TMP/family"
    if [ -z "$REMOTE_HOST" ] && dg_path_on_family "$DEST_PARENT" "$DG_TMP/family"; then
        die "destination $DEST is on the source disk $SOURCE; the capture would overwrite the disk it is reading"
    fi
    IN_USE=$(dg_family_in_use "$DG_TMP/family")
    if [ -n "$IN_USE" ]; then
        printf '%s\n' "$IN_USE" >&2
        if [ "$ALLOW_MOUNTED" = 1 ]; then
            warn "$SOURCE is in use; the image may be inconsistent if anything writes to it"
        else
            die "$SOURCE is in use. Boot the source machine from the capture stick so its disk stays idle, or pass --allow-mounted"
        fi
    fi
fi

# --- An unfinished capture to resume? ---------------------------------------
#
# Nothing is read from the source or changed on the destination until after
# the confirmation; this only gathers what is already there.

START=0
RESUMING=0
: >"$DG_TMP/chunks"
if [ "$STATE" = resume ]; then
    RESUMING=1
    dest_sh "cat session" </dev/null >"$DG_TMP/session" || die "cannot read $DEST_LABEL/session"
    dest_sh "cat chunks 2>/dev/null || :" </dev/null >"$DG_TMP/remote_chunks" || die "cannot read $DEST_LABEL/chunks"
    session_get() {
        manifest_get "$DG_TMP/session" "$1"
    }
    [ "$(session_get format)" = 3 ] ||
        die "$DEST_LABEL holds an unfinished capture from another version; use a new folder"
    S_BYTES=$(session_get source_bytes)
    S_MODEL=$(session_get source_model)
    S_CHUNK=$(session_get chunk_bytes)
    S_METHOD=$(session_get compression)
    S_LEVEL=$(session_get compression_level)
    if [ "$S_BYTES" != "$SOURCE_BYTES" ]; then
        die "the unfinished capture in $DEST_LABEL is of a $(human_bytes "${S_BYTES:-0}") source, but $SOURCE is $(human_bytes "$SOURCE_BYTES"); it is a different disk, so use a new folder"
    fi
    if [ -n "$S_MODEL" ] && [ "$S_MODEL" != "$SOURCE_MODEL" ]; then
        die "the unfinished capture in $DEST_LABEL was of a \"$S_MODEL\" disk, but $SOURCE is \"$SOURCE_MODEL\"; use a new folder"
    fi
    if [ "$CHUNK_GIVEN" = 1 ] && [ "$CHUNK_BYTES" != "$S_CHUNK" ]; then
        die "this capture was started with --chunk-size $S_CHUNK; run it again without --chunk-size, or use a new folder"
    fi
    if [ "$COMPRESSION_GIVEN" = 1 ] && [ "$COMPRESSION" != auto ] && [ "$COMPRESSION" != "$S_METHOD" ]; then
        die "this capture was started with --compression $S_METHOD; run it again without --compression, or use a new folder"
    fi
    if [ "$LEVEL_GIVEN" = 1 ] && [ "$LEVEL" != "$S_LEVEL" ]; then
        die "this capture was started with --level $S_LEVEL; run it again without --level, or use a new folder"
    fi
    case $S_CHUNK in '' | *[!0-9]*) die "$DEST_LABEL/session is damaged; use a new folder" ;; esac
    CHUNK_BYTES=$S_CHUNK
    select_compression "$S_METHOD" "$S_LEVEL"
    STARTED_UTC=$(session_get started_utc)
    # Keep the longest run of well-formed ledger lines from chunk 0; anything
    # after the first bad line is redone.
    awk -v chunk="$CHUNK_BYTES" -v image="$SOURCE_BYTES" '
        NF != 6 || $1 != NR - 1 || $2 != $1 * chunk { exit }
        { want = image - $2; if (want > chunk) want = chunk }
        $3 != want || $4 !~ /^[0-9]+$/ { exit }
        $5 !~ /^[0-9a-f]+$/ || length($5) != 64 || $6 !~ /^[0-9a-f]+$/ || length($6) != 64 { exit }
        { print }' "$DG_TMP/remote_chunks" >"$DG_TMP/chunks"
    START=$(grep -c . "$DG_TMP/chunks") || START=0
fi

CHUNK_COUNT=$(((SOURCE_BYTES + CHUNK_BYTES - 1) / CHUNK_BYTES))
[ "$CHUNK_COUNT" -le 999999 ] || die "that is $CHUNK_COUNT chunks; use a bigger --chunk-size (at most 999999 chunks)"

dg_hardware_info "$SOURCE_KIND" "$SOURCE_NAME" >"$DG_TMP/hardware"

# --- Confirm ----------------------------------------------------------------

{
    printf 'Source:       %s (%s, %s' "$SOURCE" "$SOURCE_KIND" "$(human_bytes "$SOURCE_BYTES")"
    [ -z "$SOURCE_MODEL" ] || printf ', %s' "$SOURCE_MODEL"
    printf ')\n'
    if [ "$SOURCE_KIND" = block ] && command -v lsblk >/dev/null 2>&1; then
        lsblk "$SOURCE" 2>/dev/null | sed 's/^/              /' || :
    fi
    printf 'Machine:      %s; %s firmware; storage: %s\n' "$(manifest_get "$DG_TMP/hardware" machine)" \
        "$(manifest_get "$DG_TMP/hardware" firmware)" "$(manifest_get "$DG_TMP/hardware" storage_controller)"
    printf 'Destination:  %s/\n' "$DEST_LABEL"
    printf 'Chunks:       %s of up to %s each (%s level %s)\n' "$CHUNK_COUNT" "$(human_bytes "$CHUNK_BYTES")" "$DG_METHOD" "$DG_LEVEL"
    [ "$RESUMING" = 0 ] || printf 'Resuming:     %s of %s chunks are already on the destination\n' "$START" "$CHUNK_COUNT"
    printf 'Type the exact source path to confirm: '
} >&2
CONFIRMATION=
read -r CONFIRMATION || :
[ -t 0 ] || printf '\n' >&2
[ "$CONFIRMATION" = "$SOURCE" ] || die "confirmation did not match; nothing was read"

part_name() {
    printf 'part-%06d' "$1"
}

# --- Check what is being resumed --------------------------------------------

if [ "$RESUMING" = 1 ]; then
    # Drop trailing chunks whose part on the destination is missing or does
    # not match the ledger (a crash can catch a part mid-write).
    while [ "$START" -gt 0 ]; do
        LAST_PART_HASH=$(sed -n "${START}p" "$DG_TMP/chunks" | cut -d ' ' -f 6)
        HAVE=$(dest_sh "sha256sum <$(part_name $((START - 1))) 2>/dev/null || :" </dev/null | cut -d ' ' -f 1) || HAVE=
        [ "$HAVE" != "$LAST_PART_HASH" ] || break
        warn "chunk $((START - 1)) on the destination is missing or damaged; capturing it again"
        START=$((START - 1))
        head -n "$START" "$DG_TMP/chunks" >"$DG_TMP/chunks.new"
        mv -f "$DG_TMP/chunks.new" "$DG_TMP/chunks"
    done
    # Is this the same disk, unchanged? Read the last captured chunk again.
    if [ "$START" -gt 0 ]; then
        info "Checking that $SOURCE still matches the unfinished capture..."
        read -r _ CHECK_OFF CHECK_LEN _ CHECK_RAW _ <<EOF
$(sed -n "${START}p" "$DG_TMP/chunks")
EOF
        NOW=$(dd if="$SOURCE" bs=1M skip="$CHECK_OFF" count="$CHECK_LEN" iflag=skip_bytes,count_bytes,fullblock 2>/dev/null |
            sha256sum | cut -d ' ' -f 1)
        [ "$NOW" = "$CHECK_RAW" ] ||
            die "$SOURCE does not match the unfinished capture in $DEST_LABEL (a different disk, or it changed since); use a new folder"
    fi
    info "Resuming at chunk $START of $CHUNK_COUNT."
fi

# --- Prepare the destination ------------------------------------------------

if [ "$RESUMING" = 0 ]; then
    STARTED_UTC=$(utc_now)
    {
        printf '# Project Doppelganger capture session, written when the capture started.\n'
        printf 'format=%s\n' "$DG_MANIFEST_FORMAT"
        printf 'tool_version=%s\n' "$DG_VERSION"
        printf 'started_utc=%s\n' "$STARTED_UTC"
        printf 'source=%s\n' "$SOURCE"
        printf 'source_kind=%s\n' "$SOURCE_KIND"
        printf 'source_bytes=%s\n' "$SOURCE_BYTES"
        printf 'source_model=%s\n' "$SOURCE_MODEL"
        printf 'chunk_bytes=%s\n' "$CHUNK_BYTES"
        printf 'chunk_count=%s\n' "$CHUNK_COUNT"
        printf 'compression=%s\n' "$DG_METHOD"
        printf 'compression_level=%s\n' "$DG_LEVEL"
    } >"$DG_TMP/session"
    run_in "$DEST_PARENT" "mkdir -p $Q_NAME" </dev/null || die "cannot create $DEST_LABEL"
    dest_sh "cat >session.tmp && mv -f session.tmp session && : >chunks" <"$DG_TMP/session" ||
        die "cannot write to $DEST_LABEL"
fi
# The hardware facts come from the run that started the capture.
dest_sh "if [ -f hardware ]; then cat >/dev/null; else cat >hardware.tmp && mv -f hardware.tmp hardware; fi" \
    <"$DG_TMP/hardware" || die "cannot write to $DEST_LABEL"
# Bring the destination in line with the ledger: keep its first START lines,
# and remove partial parts and any part after them.
dest_sh "head -n $START chunks >chunks.tmp 2>/dev/null; mv -f chunks.tmp chunks &&
    ls -1 | awk -v keep=$START 'index(\$0, \"part-\") == 1 {
        if (\$0 ~ /^part-[0-9][0-9][0-9][0-9][0-9][0-9]\$/ && substr(\$0, 6) + 0 < keep) next
        print }' | while IFS= read -r f; do rm -f \"./\$f\"; done" </dev/null ||
    die "could not tidy $DEST_LABEL"

# --- Capture ----------------------------------------------------------------
#
# For each chunk:
#
#   dd (one chunk) -> tee -+-> compressor -> write_chunk -> part-NNNNNN.tmp
#                          +-> sha256sum     (raw hash, here)     (hashed there)
#                          +-> wc -c         (exact byte count)
#
# then rename the part into place and append its line to the ledger. A chunk
# is in the ledger only once its part is complete and both hashes are known,
# so the ledger is always a safe point to resume from. write_chunk
# (lib/write_chunk.sh) runs in the capture folder, here or on the SSH server.
# See the FIFO notes in lib/common.sh: each stage opens its FIFOs before any
# regular file, so a failing stage unwinds the pipeline instead of hanging it.

WRITE_CHUNK=$(cat "$(dirname -- "$0")/lib/write_chunk.sh")
RAW=$DG_TMP/raw
ZIN=$DG_TMP/zin
ZOUT=$DG_TMP/zout
HASH_FIFO=$DG_TMP/hash
COUNT_FIFO=$DG_TMP/count
mkfifo "$RAW" "$ZIN" "$ZOUT" "$HASH_FIFO" "$COUNT_FIFO"

STARTED=$(date +%s)
START_BYTES=$((START * CHUNK_BYTES))
[ "$START_BYTES" -le "$SOURCE_BYTES" ] || START_BYTES=$SOURCE_BYTES
DONE=$START
DONE_BYTES=$START_BYTES

# write_status STATE CHUNKS_DONE BYTES_DONE: the status file a dashboard reads.
write_status() {
    _elapsed=$(($(date +%s) - STARTED))
    _rate=0
    [ "$_elapsed" -le 0 ] || _rate=$((($3 - START_BYTES) / _elapsed))
    _eta=unknown
    [ "$_rate" -le 0 ] || _eta=$(((SOURCE_BYTES - $3) / _rate))
    {
        printf 'state=%s\n' "$1"
        printf 'chunks_done=%s\n' "$2"
        printf 'chunks_total=%s\n' "$CHUNK_COUNT"
        printf 'bytes_done=%s\n' "$3"
        printf 'bytes_total=%s\n' "$SOURCE_BYTES"
        printf 'percent=%s\n' "$(awk -v d="$3" -v t="$SOURCE_BYTES" 'BEGIN { printf("%.1f", t > 0 ? 100 * d / t : 100) }')"
        printf 'rate_bytes_per_second=%s\n' "$_rate"
        printf 'eta_seconds=%s\n' "$_eta"
        printf 'updated_utc=%s\n' "$(utc_now)"
    } >"$DG_TMP/status"
}

progress_line() {
    [ "${DG_PROGRESS:-1}" = 1 ] && [ "${DG_QUIET:-0}" != 1 ] || return 0
    awk -v d="$DONE_BYTES" -v t="$SOURCE_BYTES" -v s="$((DONE_BYTES - START_BYTES))" \
        -v e="$(($(date +%s) - STARTED))" -v c="$DONE" -v n="$CHUNK_COUNT" '
        function h(b,   i, u) {
            split("B KiB MiB GiB TiB", u, " "); i = 1
            while (b >= 1024 && i < 5) { b /= 1024; i++ }
            return sprintf(i == 1 ? "%d %s" : "%.1f %s", b, u[i])
        }
        function dur(x) {
            x = int(x)
            if (x >= 3600) return sprintf("%dh%02dm", x / 3600, x % 3600 / 60)
            return sprintf("%dm%02ds", x / 60, x % 60)
        }
        BEGIN {
            r = e > 0 ? s / e : 0
            line = sprintf("capture: chunk %d of %d, %s of %s (%.1f%%)", c, n, h(d), h(t), t > 0 ? 100 * d / t : 100)
            if (r > 0) line = line sprintf(", %s/s", h(r))
            if (r > 0 && d < t) line = line ", ETA " dur((t - d) / r)
            print line
        }' >&2
}

mark_interrupted() {
    write_status interrupted "$DONE" "$DONE_BYTES"
    dest_sh "rm -f part-*.tmp; cat >status.tmp && mv -f status.tmp status" <"$DG_TMP/status" 2>/dev/null || :
    printf '%s: capture stopped with %s of %s chunks done; run the same command again to resume\n' \
        "$DG_PROG" "$DONE" "$CHUNK_COUNT" >&2
}
DG_ON_FAIL=mark_interrupted

write_status running "$DONE" "$DONE_BYTES"
dest_sh "cat >status.tmp && mv -f status.tmp status" <"$DG_TMP/status" || die "cannot write to $DEST_LABEL"
[ "$RESUMING" = 1 ] || info "Capturing $SOURCE..."

capture_chunk() {
    _idx=$1
    _off=$((_idx * CHUNK_BYTES))
    _len=$CHUNK_BYTES
    [ $((_off + _len)) -le "$SOURCE_BYTES" ] || _len=$((SOURCE_BYTES - _off))
    _part=$(part_name "$_idx")
    DG_FAILED=

    # The writer is started as a simple command, not through dest_sh: a
    # backgrounded function would keep a forked copy of this shell around.
    _cmd=$(in_dir_cmd "$DEST" "exec sh -c $(sq "$WRITE_CHUNK") write_chunk $_part")
    if [ -n "$REMOTE_HOST" ]; then
        # shellcheck disable=SC2086 # SSH_CMD may carry options
        $SSH_CMD "$REMOTE_HOST" "sh -c $(sq "$_cmd")" <"$ZOUT" >"$DG_TMP/chunk.result" &
    else
        sh -c "$_cmd" <"$ZOUT" >"$DG_TMP/chunk.result" &
    fi
    _pid_write=$!
    # shellcheck disable=SC2086 # DG_COMPRESS is a plain word list
    $DG_COMPRESS <"$ZIN" >"$ZOUT" &
    _pid_compress=$!
    sha256sum <"$HASH_FIFO" >"$DG_TMP/chunk.sha256" &
    _pid_hash=$!
    wc -c <"$COUNT_FIFO" >"$DG_TMP/chunk.bytes" &
    _pid_count=$!
    tee "$HASH_FIFO" "$COUNT_FIFO" <"$RAW" >"$ZIN" &
    _pid_tee=$!
    dd if="$SOURCE" bs=1M skip="$_off" count="$_len" iflag=skip_bytes,count_bytes,fullblock \
        >"$RAW" 2>"$DG_TMP/dd.err" &
    _pid_dd=$!
    DG_PIDS="$_pid_write $_pid_compress $_pid_hash $_pid_count $_pid_tee $_pid_dd"

    dg_start_progress "$_pid_dd" rchar "$SOURCE_BYTES" capture "$_off"
    dg_wait dd "$_pid_dd"
    dg_wait tee "$_pid_tee"
    dg_wait sha256sum "$_pid_hash"
    dg_wait wc "$_pid_count"
    dg_wait "$DG_METHOD" "$_pid_compress"
    dg_wait write "$_pid_write"
    dg_stop_monitor
    DG_PIDS=

    if [ -n "$DG_FAILED" ]; then
        sed 's/^/  dd: /' "$DG_TMP/dd.err" >&2
        die "chunk $_idx failed in:$DG_FAILED"
    fi
    _raw_sha=$(cut -d ' ' -f 1 <"$DG_TMP/chunk.sha256")
    _raw_bytes=$(awk '{ print $1 }' "$DG_TMP/chunk.bytes")
    [ "$_raw_bytes" = "$_len" ] || die "read $_raw_bytes bytes for chunk $_idx but expected $_len; $SOURCE may have shrunk"
    read -r _part_sha _part_bytes <"$DG_TMP/chunk.result" || :
    case ${_part_sha:-}:${_part_bytes:-} in
        *[!0-9a-f:]* | :* | *:) die "the destination did not report a hash for chunk $_idx" ;;
    esac
    [ ${#_part_sha} -eq 64 ] && [ ${#_raw_sha} -eq 64 ] || die "bad hash for chunk $_idx"

    _line="$_idx $_off $_len $_part_bytes $_raw_sha $_part_sha"
    write_status running $((_idx + 1)) $((_off + _len))
    dest_sh "mv -f $_part.tmp $_part && echo '$_line' >>chunks && cat >status.tmp && mv -f status.tmp status" \
        <"$DG_TMP/status" || die "could not record chunk $_idx on the destination"
    printf '%s\n' "$_line" >>"$DG_TMP/chunks"
    DONE=$((_idx + 1))
    DONE_BYTES=$((_off + _len))
    progress_line
}

IDX=$START
while [ "$IDX" -lt "$CHUNK_COUNT" ]; do
    capture_chunk "$IDX"
    IDX=$((IDX + 1))
done
ELAPSED=$(($(date +%s) - STARTED))

# --- Finish: part list, then the manifest -----------------------------------

COMPRESSED_BYTES=$(awk '{ n += $4 } END { printf("%.0f\n", n) }' "$DG_TMP/chunks")
CONTENT_DIGEST=$(awk '{ print $5 }' "$DG_TMP/chunks" | sha256sum | cut -d ' ' -f 1)
awk '{ printf("%s  part-%06d\n", $6, $1) }' "$DG_TMP/chunks" >"$DG_TMP/parts.sha256"
{
    printf '# Project Doppelganger capture manifest. Written last: a capture folder\n'
    printf '# with this file is complete. content_digest is the SHA-256 of the\n'
    printf "# ledger's raw SHA-256 column, one hash per line, in chunk order.\n"
    printf 'format=%s\n' "$DG_MANIFEST_FORMAT"
    printf 'tool_version=%s\n' "$DG_VERSION"
    printf 'started_utc=%s\n' "$STARTED_UTC"
    printf 'finished_utc=%s\n' "$(utc_now)"
    printf 'last_session_seconds=%s\n' "$ELAPSED"
    printf 'resumed=%s\n' "$([ "$RESUMING" = 1 ] && echo yes || echo no)"
    printf 'source=%s\n' "$SOURCE"
    printf 'source_kind=%s\n' "$SOURCE_KIND"
    printf 'source_model=%s\n' "$SOURCE_MODEL"
    printf 'image_bytes=%s\n' "$SOURCE_BYTES"
    printf 'chunk_bytes=%s\n' "$CHUNK_BYTES"
    printf 'chunk_count=%s\n' "$CHUNK_COUNT"
    printf 'compression=%s\n' "$DG_METHOD"
    printf 'compression_level=%s\n' "$DG_LEVEL"
    printf 'compressed_bytes=%s\n' "$COMPRESSED_BYTES"
    printf 'content_digest=%s\n' "$CONTENT_DIGEST"
    printf 'chunks_file=chunks\n'
    printf 'parts_file=parts.sha256\n'
    printf 'hardware_file=hardware\n'
} >"$DG_TMP/manifest"

dest_sh "cat >parts.sha256.tmp && mv -f parts.sha256.tmp parts.sha256" <"$DG_TMP/parts.sha256" ||
    die "could not write the part list"
dest_sh "cat >manifest.tmp && mv -f manifest.tmp manifest" <"$DG_TMP/manifest" ||
    die "could not write the manifest"
DG_ON_FAIL=
write_status complete "$CHUNK_COUNT" "$SOURCE_BYTES"
dest_sh "cat >status.tmp && mv -f status.tmp status" <"$DG_TMP/status" || warn "could not update the status file"

RATIO=$(awk -v c="$COMPRESSED_BYTES" -v i="$SOURCE_BYTES" 'BEGIN { printf("%.1f", i > 0 ? 100 * c / i : 0) }')
RATE=$(awk -v b="$((SOURCE_BYTES - START_BYTES))" -v s="$ELAPSED" 'BEGIN { print (s > 0 ? int(b / s) : 0) }')
printf 'Capture complete.\n'
printf '  Image:     %s in %s chunks\n' "$(human_bytes "$SOURCE_BYTES")" "$CHUNK_COUNT"
printf '  Digest:    %s\n' "$CONTENT_DIGEST"
printf '  Stored:    %s compressed (%s%% of the original)\n' "$(human_bytes "$COMPRESSED_BYTES")" "$RATIO"
if [ "$ELAPSED" -gt 0 ]; then
    printf '  This run:  %s (%s/s)' "$(human_duration "$ELAPSED")" "$(human_bytes "$RATE")"
else
    printf '  This run:  <1s'
fi
[ "$RESUMING" = 0 ] || printf ', resumed at chunk %s' "$START"
printf '\n'
printf '  Folder:    %s/\n' "$DEST_LABEL"
