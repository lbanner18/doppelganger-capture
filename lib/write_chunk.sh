# shellcheck shell=sh
# Destination side of one capture chunk: write the compressed chunk on stdin to
# PART.tmp, hashing it on the way to disk so it never has to be read back, then
# print "SHA256 BYTES". capture_to_parts.sh renames PART.tmp into place and
# records the chunk in the ledger once it has the source-side hash too.
#
# Runs in the capture folder, locally or on the SSH server.
# capture_to_parts.sh sends this file's text, so the server needs no copy of
# the project; it must stay POSIX sh and use only tee, sha256sum, mkfifo,
# mktemp and stat.
#
# Usage: sh write_chunk.sh PART <compressed-chunk
set -u
part=$1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/doppelganger-chunk.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkfifo "$tmp/hash" || exit 1

sha256sum <"$tmp/hash" >"$tmp/sum" &
hash_pid=$!
# Hold a write end of the FIFO here until tee is done, so sha256sum always
# gets an end-of-file, even if tee dies without ever opening the FIFO. (It is
# opened after sha256sum starts, so sha256sum does not inherit it.)
exec 3<>"$tmp/hash"
# The part is a tee argument, not a redirection: if it cannot be created, tee
# still writes to the hash FIFO and reports the failure in its exit status.
tee_status=0
tee "$tmp/hash" "$part.tmp" >/dev/null 3>&- || tee_status=$?
exec 3>&-
hash_status=0
wait "$hash_pid" || hash_status=$?
if [ "$tee_status" -ne 0 ] || [ "$hash_status" -ne 0 ]; then
    echo "write_chunk: writing $part failed (tee $tee_status, sha256sum $hash_status)" >&2
    exit 1
fi
size=$(stat -c %s "$part.tmp") || exit 1
printf '%s %s\n' "$(cut -d ' ' -f 1 <"$tmp/sum")" "$size"
