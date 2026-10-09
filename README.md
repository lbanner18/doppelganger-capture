# doppelganger-capture

Copy a whole disk, a chunk at a time, into a folder of compressed parts, locally or over SSH, from a tiny Linux boot environment. Every chunk is verified with SHA-256, and a capture that stops part-way (power loss, Ctrl-C, a dropped network) resumes where it left off when you run the same command again.

It is plain POSIX `sh` and runs under BusyBox ash, so it works from a minimal Alpine boot stick. With `capture_auto.sh` it runs hands-off: boot the stick and walk away. The whole pipeline uses well under 32 MiB of memory.

```text
 source disk, read one chunk at a time                 destination folder (local or over SSH)
 ─────────────────────────────────────                 ──────────────────────────────────────
   chunk ─ dd ─ tee ─ zstd ─────────(SSH)──────────►     part-000000, part-000001, ...
                 ├─ sha256sum (raw)                      chunks    (ledger of finished chunks)
                 └─ wc -c                                hardware  status  manifest
```

## Safety

- **Only copy disks you own or have explicit permission to copy.** A disk image contains everything on the disk.
- It only ever **reads** the source disk. Boot the machine from a USB stick so the disk is idle. The script refuses a disk with a mounted partition or active swap, and refuses a destination on the disk being read.
- Nothing is read until you **type the exact device path** to confirm. Check it with `lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS` first.
- Parts are created readable by their owner only (`umask 077`).

## Requirements

- **On the boot stick** (the Linux environment that runs the capture, not the OS installed on the disk being copied, which is never started): `sh`, `dd`, `tee`, `sha256sum`, `wc`, `mkfifo`, `mktemp`, `stat`, and `zstd` (or `gzip`). On Alpine that is BusyBox plus `apk add zstd`. Two more are optional:
  - `coreutils` doubles the speed, because its hashing is faster than BusyBox's
  - `lsblk` shows the disk's partitions before you confirm
- **For SSH destinations:**
  - the client side needs `ssh`, with OpenSSH preferred
  - the server needs only `sh`, `tee`, `sha256sum`, `mkfifo`, `mktemp` and `stat`, and does not need a copy of this repository

## Usage

As root:

```sh
sh capture_to_parts.sh /dev/sdX user@server:/path/to/captures/machine1   # over SSH
sh capture_to_parts.sh /dev/sdX /mnt/usb/machine1                        # to a local folder
```

The destination is a folder, created if needed. Its parent folder must exist. The script shows the disk's size, model and partitions and the machine's firmware and storage controller, then asks you to type the device path before reading anything. Progress is printed with an ETA.

**If it stops, run the same command again.** It reads the ledger on the destination, re-checks the last finished part, and reads the last finished chunk from the disk again to make sure it is the same, unchanged disk. Then it carries on. It refuses to resume onto a different disk or with different settings.

With OpenSSH, every step shares one connection, so there is a single login per capture. Other clients, such as Dropbear (`DG_SSH="dbclient -y"`), log in once per step, so use key authentication. Put SSH options in `~/.ssh/config` rather than `DG_SSH` to keep the shared connection.

Options:

| Option | Meaning |
|---|---|
| `--chunk-size SIZE` | raw bytes per chunk (default `3900M`, so every compressed part fits on FAT32) |
| `--compression NAME` | `auto` (zstd, else gzip), `zstd` or `gzip` |
| `--level N` | compression level (default 1) |
| `--no-progress` | do not print progress |
| `--allow-file` | allow a regular file as the source (re-pack an image file) |
| `--allow-mounted` | capture even if the disk is in use (the copy may be inconsistent) |

Run `sh capture_to_parts.sh --help` for everything.

## Hands-off mode

`capture_auto.sh` wraps the capture so nobody has to type anything. Start it at boot on the stick, and it will:

1. bring up the network: DHCP on every wired port, then Wi-Fi if `/etc/wpa_supplicant/wpa_supplicant.conf` exists. Optionally it joins a Tailscale network with an auth key
2. find the machine's internal disk(s), skipping the boot stick, USB drives, removable and optical media, virtual devices, and any disk with a mounted partition or active swap
3. name the capture after the machine, for example `Dell-OptiPlex-7090-3f9a2c1b`: the model plus a short fingerprint of the firmware's serial numbers and UUID. The name is the same on every boot, but the serial number itself is never written anywhere
4. show what it found and count down (10 seconds by default). **Any key cancels**; otherwise it starts by itself
5. capture each disk with `capture_to_parts.sh`, retrying if the network drops (each retry resumes)
6. power off when everything is captured

Boot the stick again after a power cut and it resumes the unfinished capture. Boot it on a machine that is already captured and it says so and powers off.

Copy `doppelganger.conf.example` to `doppelganger.conf` next to the script and set `DG_DEST` (and SSH access, as above). Then try it without touching anything:

```sh
sh capture_auto.sh --dry-run      # the machine name, the disks it would capture, the folders
```

To start it at boot on Alpine (BusyBox `init`), put it on the first console in `/etc/inittab`, and keep a login prompt on the second:

```
tty1::once:/bin/sh /path/to/capture_auto.sh
tty2::respawn:/sbin/getty 38400 tty2
```

It needs the console so the countdown can see a keypress; without a terminal it just waits out the countdown. Settings, all in the config file:

| Setting | Default | Meaning |
|---|---|---|
| `DG_DEST` | (required) | `host:/folder` over SSH, or a local folder |
| `DG_COUNTDOWN` | `10` | seconds before starting; any key cancels; `0` starts at once |
| `DG_POWEROFF` | `1` | power off when done |
| `DG_TAILSCALE_AUTHKEY` | empty | file with a Tailscale auth key; if set, join the tailnet first (needs `tailscale`) |
| `DG_RETRIES`, `DG_RETRY_WAIT` | `10`, `30` | capture attempts per disk, and seconds between them |
| `DG_CAPTURE_OPTIONS` | empty | extra options for `capture_to_parts.sh`, e.g. `--chunk-size 1G` |

Tested by booting the real Alpine 3.24 ISO in a VM three times with nothing typed. The first boot started by itself, and its power was cut part-way. The second resumed and powered off by itself. The third saw the finished capture and changed nothing. The rebuilt disk was byte-identical to the original.

## What you get

| File | Contents |
|---|---|
| `part-000000`, `part-000001`, ... | one independently compressed chunk each |
| `chunks` | the ledger: `index offset raw_bytes part_bytes raw_sha256 part_sha256`, one line per finished chunk |
| `parts.sha256` | SHA-256 of every part, in standard `sha256sum -c` format |
| `hardware` | machine model, CPU, RAM, BIOS or UEFI, Secure Boot, TPM, storage controller |
| `status` | progress (`state`, `percent`, `eta_seconds`, ...), rewritten after every chunk, for a dashboard |
| `session` | the settings the capture started with |
| `manifest` | written last: its presence means the capture is complete. Its `content_digest` is the SHA-256 of the ledger's `raw_sha256` column |

## Checking and rebuilding the disk image

Standard tools are enough. In the capture folder:

```sh
sha256sum -c parts.sha256                    # every part arrived intact
zstd -dc part-* > disk.img                   # rebuild the raw disk image (gzip -dc for gzip captures)
```

Each part is a complete compressed stream, so decompressing them in order gives the original disk byte for byte. To check one rebuilt chunk against the ledger, use the chunk's offset and size from `chunks`:

```sh
dd if=disk.img bs=1M skip=OFFSET count=RAW_BYTES iflag=skip_bytes,count_bytes | sha256sum   # compare with raw_sha256
```

The raw image can then be converted for a hypervisor, for example `qemu-img convert -f raw -O qcow2 disk.img disk.qcow2`.

## License

MIT. See [LICENSE](LICENSE).
