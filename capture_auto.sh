#!/bin/sh
# Hands-off capture for the boot stick: start it at boot and it brings up the
# network and Tailscale, finds the machine's internal disk(s), names the
# capture after the machine, counts down (any key cancels), captures with
# capture_to_parts.sh, retries if the network drops, and powers off when done.
# Booting the stick again on the same machine resumes an unfinished capture or,
# if it is finished, does nothing.
#
# Settings come from a config file (see doppelganger.conf.example):
#   sh capture_auto.sh [--config FILE] [--dry-run]
set -eu

. "$(dirname -- "$0")/lib/common.sh"

usage() {
    cat <<EOF
Usage: $DG_PROG [--config FILE] [--dry-run]

Find this machine's internal disk(s) and capture each one to DG_DEST with
capture_to_parts.sh, with no typing: a countdown (any key cancels) replaces
the confirmation. Meant to start automatically when the boot stick boots.

  --config FILE   settings (default: doppelganger.conf next to this script,
                  else /etc/doppelganger.conf)
  --dry-run       show the machine name, the disks and the capture folders,
                  then stop; no network, nothing is read
  -h, --help      show this help

Settings (shell variables in the config file):
  DG_DEST               where captures go: host:/folder over SSH (a host from
                        ~/.ssh/config works) or a local folder (required)
  DG_COUNTDOWN          seconds to wait before starting, any key cancels
                        (default 10; 0 starts at once)
  DG_POWEROFF           1 to power off when everything is captured (default 1)
  DG_TAILSCALE_AUTHKEY  file holding a Tailscale auth key; if set, join the
                        tailnet before capturing
  DG_RETRIES            capture attempts per disk before giving up (default 10)
  DG_RETRY_WAIT         seconds between attempts (default 30)
  DG_CAPTURE_OPTIONS    extra options for capture_to_parts.sh, e.g.
                        "--chunk-size 1G"
EOF
}

CONFIG=
DRY_RUN=0
while [ $# -gt 0 ]; do
    case $1 in
        --config)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            CONFIG=$2
            shift
            ;;
        --dry-run) DRY_RUN=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

HERE=$(cd "$(dirname -- "$0")" && pwd)
if [ -z "$CONFIG" ]; then
    CONFIG=$HERE/doppelganger.conf
    [ -f "$CONFIG" ] || CONFIG=/etc/doppelganger.conf
fi
[ -f "$CONFIG" ] || die "no config file: $CONFIG (copy doppelganger.conf.example)"
# "." looks a bare name up in PATH, not in the current folder.
case $CONFIG in */*) ;; *) CONFIG=./$CONFIG ;; esac
# shellcheck disable=SC1090 # the config is chosen at run time
. "$CONFIG"
DG_DEST=${DG_DEST:-}
DG_COUNTDOWN=${DG_COUNTDOWN:-10}
DG_POWEROFF=${DG_POWEROFF:-1}
DG_TAILSCALE_AUTHKEY=${DG_TAILSCALE_AUTHKEY:-}
DG_RETRIES=${DG_RETRIES:-10}
DG_RETRY_WAIT=${DG_RETRY_WAIT:-30}
DG_CAPTURE_OPTIONS=${DG_CAPTURE_OPTIONS:-}
[ -n "$DG_DEST" ] || die "DG_DEST is not set in $CONFIG"
for _n in "$DG_COUNTDOWN" "$DG_RETRIES" "$DG_RETRY_WAIT"; do
    case $_n in '' | *[!0-9]*) die "DG_COUNTDOWN, DG_RETRIES and DG_RETRY_WAIT must be whole numbers" ;; esac
done
SYS=${DG_SYSFS:-/sys}

# Remote (host:/folder) or local destination, parsed as capture_to_parts.sh does.
REMOTE_HOST=
DEST_DIR=$DG_DEST
case $DG_DEST in
    /* | ./* | ../*) ;;
    *:*)
        case ${DG_DEST%%:*} in
            '' | */*) ;;
            *)
                REMOTE_HOST=${DG_DEST%%:*}
                DEST_DIR=${DG_DEST#*:}
                ;;
        esac
        ;;
esac
DEST_DIR=${DEST_DIR%/}

say() {
    printf '%s\n' "$*" >&2
}

sq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# --- This machine's name ----------------------------------------------------
#
# Model plus a short fingerprint of the firmware's serial numbers and UUID:
# unique and the same on every boot, so booting again resumes the right
# capture, without writing a serial number anywhere.

is_placeholder() {
    case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') in
        '' | none | n/a | na | 0 | default | 'default string' | 'to be filled by o.e.m.' | \
            'system serial number' | 'system product name' | 'system manufacturer' | 'not specified' | \
            'not applicable' | 'chassis serial number' | 'base board serial number' | 123456789 | \
            00000000-0000-0000-0000-000000000000 | ffffffff-ffff-ffff-ffff-ffffffffffff | \
            03000200-0400-0500-0006-000700080009)
            return 0
            ;;
    esac
    return 1
}

# slug TEXT: letters, digits, '.', '_' and '-' only, as a capture folder needs.
slug() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | tr -s '-' | sed 's/^[-.]*//; s/-*$//' | cut -c 1-60
}

machine_name() {
    _dmi=$SYS/class/dmi/id
    _vendor=$(_dg_read_line "$_dmi/sys_vendor")
    _product=$(_dg_read_line "$_dmi/product_name")
    if is_placeholder "$_product"; then
        _vendor=$(_dg_read_line "$_dmi/board_vendor")
        _product=$(_dg_read_line "$_dmi/board_name")
    fi
    is_placeholder "$_vendor" && _vendor=
    is_placeholder "$_product" && _product=
    _vendor=$(printf '%s' "$_vendor" | sed -E 's/,? *(Inc\.?|Corporation|Corp\.?|Co\., *Ltd\.?|Ltd\.?|GmbH|Technology|Computer)$//')
    _model=$(slug "$_vendor $_product")
    _ids=
    for _f in product_serial product_uuid board_serial chassis_serial; do
        _v=$(_dg_read_line "$_dmi/$_f")
        is_placeholder "$_v" || _ids="$_ids|$_f=$_v"
    done
    if [ -z "$_ids" ]; then
        # No usable firmware IDs: fall back to the first wired network card.
        for _nic in "$SYS"/class/net/*; do
            [ -r "$_nic/address" ] && [ ! -d "$_nic/wireless" ] || continue
            case ${_nic##*/} in lo | tailscale* | docker* | veth* | virbr*) continue ;; esac
            _mac=$(_dg_read_line "$_nic/address")
            is_placeholder "$_mac" || [ "$_mac" = 00:00:00:00:00:00 ] || { _ids="mac=$_mac"; break; }
        done
    fi
    if [ -n "$_ids" ]; then
        _id=$(printf '%s' "$_ids" | sha256sum | cut -c 1-8)
    else
        _id=$(date -u +%Y%m%d-%H%M%S)
        say "warning: this machine reports no serial number, UUID or network card; the folder is named by date, so a later boot starts a new capture instead of resuming"
    fi
    printf '%s-%s\n' "${_model:-machine}" "$_id"
}

# --- Its internal disks ------------------------------------------------------

# internal_disks: print the whole disks worth capturing; report what is skipped.
# Skipped: partitions, virtual devices (loop, RAM, device mapper, RAID sets),
# optical drives, removable media, anything on USB (the stick itself, USB
# drives) and any disk with a mounted partition or active swap.
internal_disks() {
    for _d in "$SYS"/class/block/*; do
        _name=${_d##*/}
        [ -e "$_d" ] && [ ! -e "$_d/partition" ] || continue
        case $_name in
            loop* | ram* | zram* | dm-* | md* | sr* | fd* | nbd* | mmcblk*boot* | mmcblk*rpmb | nvme*c*n*) continue ;;
        esac
        _size=$(_dg_read_line "$_d/size")
        [ -n "$_size" ] && [ "$_size" != 0 ] || continue
        if [ "$(_dg_read_line "$_d/removable")" = 1 ]; then
            say "  skipping $_name: removable media"
            continue
        fi
        case $(readlink -f "$_d/device" 2>/dev/null || :) in
            */usb[0-9]*)
                say "  skipping $_name: USB (the stick itself or a USB drive)"
                continue
                ;;
        esac
        DG_SYSFS=$SYS dg_block_family "${DG_DEVDIR:-/dev}/$_name" >"$DG_TMP/family"
        _busy=$(dg_family_in_use "$DG_TMP/family")
        if [ -n "$_busy" ]; then
            say "  skipping $_name: in use"
            say "$_busy"
            continue
        fi
        printf '%s\n' "$_name"
    done
}

describe_disk() {
    _bytes=$(($(_dg_read_line "$SYS/class/block/$1/size") * 512))
    _model=$(_dg_read_line "$SYS/class/block/$1/device/model")
    printf '%s  %s%s  (%s)' "$1" "$(human_bytes "$_bytes")" "${_model:+  $_model}" "$(DG_SYSFS=$SYS dg_storage_controller "$1")"
}

# --- Network, Tailscale, the server ------------------------------------------

has_route() {
    ip route 2>/dev/null | grep -q '^default'
}

# network_up: DHCP on every wired port, then Wi-Fi if the stick has a
# wpa_supplicant config. Returns as soon as there is a default route.
network_up() {
    has_route && return 0
    for _nic in "$SYS"/class/net/*; do
        _if=${_nic##*/}
        case $_if in lo | tailscale*) continue ;; esac
        [ ! -d "$_nic/wireless" ] || continue
        ip link set "$_if" up 2>/dev/null || continue
        udhcpc -i "$_if" -q -n -t 4 -T 2 >/dev/null 2>&1 || continue
        has_route && return 0
    done
    if [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
        for _nic in "$SYS"/class/net/*; do
            [ -d "$_nic/wireless" ] || continue
            _if=${_nic##*/}
            ip link set "$_if" up 2>/dev/null || continue
            pgrep -f "wpa_supplicant.*-i *$_if" >/dev/null 2>&1 ||
                wpa_supplicant -B -i "$_if" -c /etc/wpa_supplicant/wpa_supplicant.conf >/dev/null 2>&1 || continue
            udhcpc -i "$_if" -q -n -t 8 -T 3 >/dev/null 2>&1 || continue
            has_route && return 0
        done
    fi
    has_route
}

tailscale_up() {
    [ -n "$DG_TAILSCALE_AUTHKEY" ] || return 0
    command -v tailscale >/dev/null 2>&1 || die "DG_TAILSCALE_AUTHKEY is set but tailscale is not installed"
    [ -r "$DG_TAILSCALE_AUTHKEY" ] || die "cannot read the Tailscale auth key: $DG_TAILSCALE_AUTHKEY"
    if ! tailscale status >/dev/null 2>&1; then
        if ! pgrep tailscaled >/dev/null 2>&1; then
            modprobe tun 2>/dev/null || :
            mkdir -p /run/tailscale
            # In-memory state: every boot joins as a new, ephemeral device.
            tailscaled --state=mem: --socket=/run/tailscale/tailscaled.sock >/var/log/tailscaled.log 2>&1 &
            _i=0
            while [ ! -S /run/tailscale/tailscaled.sock ] && [ $_i -lt 20 ]; do
                sleep 1
                _i=$((_i + 1))
            done
        fi
        _host=$(printf 'doppel-%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr '._' '--' | cut -c 1-63)
        tailscale up --auth-key="file:$DG_TAILSCALE_AUTHKEY" --hostname="$_host" --timeout=60s >/dev/null 2>&1 ||
            return 1
    fi
}

server_ok() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" true </dev/null >/dev/null 2>&1
}

# connect: keep trying until the server answers.
connect() {
    [ -n "$REMOTE_HOST" ] || return 0
    _said=
    while :; do
        # A direct cable has no default route but can still reach the
        # server, so always try the server, whatever the network looks like.
        network_up || :
        if has_route; then tailscale_up || :; fi
        if server_ok; then
            [ -z "$_said" ] || say "Connected."
            return 0
        fi
        if [ -z "$_said" ]; then
            if ! has_route; then
                say "Waiting for a network: plug in an Ethernet cable (or set up Wi-Fi on the stick)..."
            else
                say "Waiting for $REMOTE_HOST to answer over SSH..."
            fi
            _said=1
        fi
        sleep 10
    done
}

# folder_state FOLDER: complete, partial or new.
folder_state() {
    _cmd="if [ -f $(sq "$DEST_DIR/$1/manifest") ]; then echo complete; elif [ -e $(sq "$DEST_DIR/$1") ]; then echo partial; else echo new; fi"
    if [ -n "$REMOTE_HOST" ]; then
        ssh -o BatchMode=yes "$REMOTE_HOST" "sh -c $(sq "$_cmd")" </dev/null
    else
        sh -c "$_cmd"
    fi
}

# --- Countdown ---------------------------------------------------------------

STTY_SAVED=
restore_tty() {
    [ -z "$STTY_SAVED" ] || stty "$STTY_SAVED" 2>/dev/null || :
    STTY_SAVED=
}
DG_ON_EXIT=restore_tty

# countdown SECONDS MESSAGE: succeed when the time runs out, fail if a key is
# pressed. Without a terminal there is nobody to press a key: just wait.
countdown() {
    [ "$1" -gt 0 ] || return 0
    if [ ! -t 0 ]; then
        say "$2 in $1s"
        sleep "$1"
        return 0
    fi
    STTY_SAVED=$(stty -g)
    stty -icanon -echo min 0 time 10
    _left=$1
    while [ "$_left" -gt 0 ]; do
        printf '\r%s in %ds (press any key to cancel) ' "$2" "$_left" >&2
        if [ "$(dd bs=1 count=1 2>/dev/null | wc -c)" -gt 0 ]; then
            restore_tty
            printf '\n' >&2
            return 1
        fi
        _left=$((_left - 1))
    done
    restore_tty
    printf '\n' >&2
    return 0
}

finish_poweroff() {
    [ "$DG_POWEROFF" = 1 ] && [ "$DRY_RUN" = 0 ] || return 0
    if countdown 15 "Powering off"; then
        # Everything is on the destination; nothing on the stick needs a
        # clean shutdown, so flush and switch off at once.
        sync
        poweroff -f
    else
        say "Not powering off."
    fi
}

# --- Main --------------------------------------------------------------------

dg_init
[ "$DRY_RUN" = 1 ] || [ "$(id -u)" = 0 ] || die "run it as root (it reads the raw disk)"

say "Project Doppelganger: hands-off capture"
NAME=$(machine_name)
say "Machine:     $(_dg_read_line "$SYS/class/dmi/id/sys_vendor") $(_dg_read_line "$SYS/class/dmi/id/product_name")  ->  $NAME"
say "Looking for internal disks..."
internal_disks >"$DG_TMP/disks"
COUNT=$(grep -c . "$DG_TMP/disks") || COUNT=0
[ "$COUNT" -gt 0 ] || die "no internal disk found to capture (see the skipped devices above)"

# One disk: the folder is the machine's name. Several: one folder each.
: >"$DG_TMP/plan"
while IFS= read -r disk; do
    folder=$NAME
    [ "$COUNT" -eq 1 ] || folder=$NAME-$disk
    printf '%s %s\n' "$disk" "$folder" >>"$DG_TMP/plan"
done <"$DG_TMP/disks"

if [ "$DRY_RUN" = 1 ]; then
    while read -r disk folder; do
        say "Disk:        $(describe_disk "$disk")"
        say "             -> $DG_DEST/$folder"
    done <"$DG_TMP/plan"
    exit 0
fi

connect

# Skip what is already finished on the destination.
: >"$DG_TMP/todo"
while read -r disk folder; do
    state=$(folder_state "$folder") || die "cannot check $DG_DEST/$folder"
    say "Disk:        $(describe_disk "$disk")"
    case $state in
        complete) say "             -> $DG_DEST/$folder (already captured; skipping)" ;;
        partial)
            say "             -> $DG_DEST/$folder (unfinished; will resume)"
            printf '%s %s\n' "$disk" "$folder" >>"$DG_TMP/todo"
            ;;
        *)
            say "             -> $DG_DEST/$folder"
            printf '%s %s\n' "$disk" "$folder" >>"$DG_TMP/todo"
            ;;
    esac
done <"$DG_TMP/plan"

if [ ! -s "$DG_TMP/todo" ]; then
    say "Everything on this machine is already captured. Nothing to do."
    finish_poweroff
    exit 0
fi

if ! countdown "$DG_COUNTDOWN" "Starting the capture"; then
    say "Cancelled. Nothing was read. Run 'sh $0' to start again."
    exit 1
fi

FAILED=
while read -r disk folder; do
    attempt=1
    while :; do
        say ""
        say "=== $disk -> $DG_DEST/$folder (attempt $attempt of $DG_RETRIES)"
        # The countdown above was the confirmation; pass the device path on.
        # shellcheck disable=SC2086 # DG_CAPTURE_OPTIONS is a word list
        if printf '/dev/%s\n' "$disk" | sh "$HERE/capture_to_parts.sh" $DG_CAPTURE_OPTIONS "/dev/$disk" "$DG_DEST/$folder"; then
            break
        fi
        if [ "$attempt" -ge "$DG_RETRIES" ]; then
            FAILED="$FAILED $disk"
            break
        fi
        say "The capture stopped; trying again in ${DG_RETRY_WAIT}s (it picks up where it left off)..."
        sleep "$DG_RETRY_WAIT"
        connect
        attempt=$((attempt + 1))
    done
done <"$DG_TMP/todo"

say ""
if [ -n "$FAILED" ]; then
    say "NOT FINISHED:$FAILED. Booting the stick again (or running 'sh $0') resumes."
    exit 1
fi
say "All done: every internal disk on this machine is captured."
finish_poweroff
