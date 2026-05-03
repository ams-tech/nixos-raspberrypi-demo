# nixos-raspberrypi-demo

Demo configurations for the
[nixos-raspberrypi](https://github.com/ams-tech/nixos-raspberrypi) Flake.

## Quick Start: Raspberry Pi 5 LUKS on NVMe

This flow uses the Raspberry Pi 5 installer image from `nixos-raspberrypi`,
then installs this repo's `rpi5-luks` configuration to `/dev/nvme0n1`.

> [!WARNING]
> The install step destroys `/dev/nvme0n1`. The OTP private key step writes
> one-time-programmable Raspberry Pi fuses; run it only when you are sure you
> want to program that board, and keep the generated key material secret.

### Build the RPi 5 installer image

Build on an `aarch64-linux` machine, or on a host configured with an AArch64
remote builder or emulation, using the same `nixos-raspberrypi` ref as
`flake.nix`:

```shell
NIXOS_RPI_FLAKE=github:ams-tech/nixos-raspberrypi/topic/rpi-otp-private-key
nix build "$NIXOS_RPI_FLAKE#installerImages.rpi5"
readlink -f result
```

The `result` symlink points directly to the compressed installer image:

```text
.../nixos-installer-rpi5-kernel.img.zst
```

### Burn the installer image to an SD card

Find the SD card device:

```shell
lsblk -p
```

Replace `/dev/sdX` with the whole SD card device, not a partition such as
`/dev/sdX1`:

```shell
zstdcat result | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

### Boot the installer SD card

Insert the SD card into the Raspberry Pi 5, attach the NVMe drive, connect
Ethernet, and power on. The installer hostname is `nixos-installer`, so SSH is
usually:

```shell
ssh root@nixos-installer.local
```

Use the credentials printed on the installer console if SSH asks for a password.
If you are not using Ethernet, configure Wi-Fi from the console with `iwctl`
first.

### Provision the Raspberry Pi OTP private key

Run these commands on the Raspberry Pi booted from the installer SD card.
Temporary key material is written under `/run` so it disappears on reboot.

First check whether the OTP private key is already programmed:

```shell
NIXOS_RPI_FLAKE=github:ams-tech/nixos-raspberrypi/topic/rpi-otp-private-key
sudo nix run "$NIXOS_RPI_FLAKE#rpi-otp-private-key" -- -c
```

If that succeeds, skip to the install step. If it fails, generate a key and
program it into OTP:

```shell
OTP_KEYDIR="$(mktemp -d /run/rpi-otp-private-key.XXXXXX)"
chmod 0700 "$OTP_KEYDIR"

openssl ecparam -name prime256v1 -genkey -noout -out "$OTP_KEYDIR/private_key.pem"
openssl ec -in "$OTP_KEYDIR/private_key.pem" -text -noout \
  | awk '/priv:/{flag=1; next} /pub:/{flag=0} flag' \
  | tr -d ' \n:' \
  | head -n1 > "$OTP_KEYDIR/d.hex"

sudo nix run "$NIXOS_RPI_FLAKE#rpi-otp-private-key" -- -w "$(cat "$OTP_KEYDIR/d.hex")"
sudo nix run "$NIXOS_RPI_FLAKE#rpi-otp-private-key" -- -c
```

Keep the contents of `$OTP_KEYDIR` secret until the next reboot or until you
remove the directory. The LUKS install derives the disk key from the programmed
OTP key and a salt that is installed at
`/var/lib/rpi-otp-derived-key/salt/luks-key`.

### Install `rpi5-luks` to `nvme0n1`

Still on the installer system, verify that the NVMe disk is the intended target:

```shell
lsblk -p
```

Then install this repo's `rpi5-luks` configuration:

```shell
git clone https://github.com/ams-tech/nixos-raspberrypi-demo.git
cd nixos-raspberrypi-demo
sudo disko-install --flake .#rpi5-luks --disk nvme0-luks /dev/nvme0n1
sudo poweroff
```

Remove the SD card, then power the Raspberry Pi back on to boot from the NVMe
installation.
