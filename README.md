# nixos-raspberrypi-demo

Demo configurations for the
[nixos-raspberrypi](https://github.com/ams-tech/nixos-raspberrypi) Flake.

## Quick Start: Raspberry Pi 5 Encrypted RootFS

This flow uses the Raspberry Pi 5 installer image from `nixos-raspberrypi`,
then installs this repo's `rpi5-luks` configuration to `/dev/nvme0n1`.

As of writing, the rpi5 is the only variant that includes hardware-accelerated cryptography.  As such, this is the only hardware that can run full disk encryption without a lot of CPU overhead.

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

This will build the image to `.../result/sd-image/nixos-installer-rpi5-kernel.img.zst`

### Burn the installer image to an SD card

Find the SD card device:

```shell
lsblk -p
```

Replace `/dev/sdX` with the whole SD card device, not a partition such as
`/dev/sdX1`:

```shell
zstdcat result/sd-image/nixos-installer-rpi5-kernel.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

This could also be a `/dev/mmcblkX` device (for example, if you're using an RPi's SD card slot)

### Boot the installer SD card

Insert the SD card into the Raspberry Pi 5, attach the NVMe drive, connect
Ethernet, and power on. The installer hostname is `nixos-installer`, so SSH is
usually:

```shell
ssh root@nixos-installer.local
```

Use the credentials printed on the installer console if SSH asks for a password.

### Provision the Raspberry Pi OTP private key

Run these commands on the Raspberry Pi booted from the installer SD card.
Temporary key material is written under `/run`; delete it after programming and
verifying the OTP key.

First check whether the OTP private key is already programmed:

```shell
sudo rpi-otp-private-key -c
```

If that succeeds, skip to the install step. If it fails, generate a key with
OpenSSL and program it into OTP:

```shell
OTP_KEYDIR="$(mktemp -d /run/rpi-otp-private-key.XXXXXX)"
chmod 0700 "$OTP_KEYDIR"

nix run nixpkgs#openssl -- ecparam -name prime256v1 -genkey -noout -out "$OTP_KEYDIR/private_key.pem"
nix run nixpkgs#openssl -- ec -in "$OTP_KEYDIR/private_key.pem" -text -noout \
  | awk '/priv:/{flag=1; next} /pub:/{flag=0} flag' \
  | tr -d ' \n:' \
  | head -n1 > "$OTP_KEYDIR/d.hex"

sudo rpi-otp-private-key -w "$(cat "$OTP_KEYDIR/d.hex")"
sudo rpi-otp-private-key -c

rm -f "$OTP_KEYDIR/private_key.pem" "$OTP_KEYDIR/d.hex"
rmdir "$OTP_KEYDIR"
unset OTP_KEYDIR
```

The LUKS install derives the disk key from the programmed OTP key and a salt
that is installed at `/var/lib/rpi-otp-derived-key/salt/luks-key`.

### Install `rpi5-luks` to `nvme0n1`


```shell
nix develop --command nixos-anywhere --flake .#rpi5-luks root@nixos-installer.local
```

Power off the Raspberrry Pi, remove the SD card, then power the Raspberry Pi back on to boot from the NVMe
installation.
