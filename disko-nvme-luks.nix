{ config, lib, pkgs, nixos-raspberrypi, ... }:

let
  stagedSaltDir = "/run/rpi-otp-derived-key/disko-install/salt";
  stagedSalt = "${stagedSaltDir}/luks-key";
  stagedKeyDir = "/run/secrets";
  stagedKey = "${stagedKeyDir}/luks.key";
  installedSalt = "${config.disko.rootMountPoint}/var/lib/rpi-otp-derived-key/salt/luks-key";
  rpiOtpProvision = pkgs.rpi-otp-derived-key-provision or
    nixos-raspberrypi.packages.${pkgs.stdenv.hostPlatform.system}.rpi-otp-derived-key-provision;
in
{
  imports = [
    nixos-raspberrypi.nixosModules.rpi-otp-derived-key
  ];

  services.rpiOtpDerivedKey = {
    enable = true;
    secrets.luks-key = {
      format = "hex";
      path = stagedKey;
      neededForBoot = true;
      before = [ "cryptsetup-pre.target" ];
    };
  };

  # The OTP-derived initrd secret module and NixOS' LUKS initrd module both add
  # cryptsetup-pre.target with these locked inputs; keep the upstream unit list
  # de-duplicated so initrd unit generation can link each unit once.
  boot.initrd.systemd.additionalUpstreamUnits = lib.mkForce [
    "cryptsetup-pre.target"
    "tpm2.target"
    "systemd-tpm2-setup-early.service"
    "systemd-tmpfiles-setup-dev-early.service"
    "systemd-tmpfiles-setup-dev.service"
    "systemd-tmpfiles-setup.service"
    "cryptsetup.target"
    "remote-cryptsetup.target"
    "initrd-udevadm-cleanup-db.service"
    "systemd-udevd-control.socket"
    "systemd-udevd-kernel.socket"
    "systemd-udevd.service"
    "systemd-udev-settle.service"
    "systemd-udev-trigger.service"
    "systemd-vconsole-setup.service"
  ];

  disko.devices = {
    disk = {
      nvme0-luks = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              # label = "FIRMWARE";
              priority = 1;

              type = "0700"; # Microsoft basic data
              attributes = [
                0 # Required Partition
              ];

              size = "1024M";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot/firmware";
                mountOptions = [
                  "noatime"
                  "noauto"
                  "x-systemd.automount"
                  "x-systemd.idle-timeout=1min"
                ];
              };
            };
            swap = {
              size = "2G";
              content = {
                type = "swap";
                randomEncryption = true;
              };
            };
            luks = {
              size = "100%";
              content = {
                type = "luks";
                name = "crypted";
                extraOpenArgs = [ ];
                settings = {
                  keyFile = stagedKey;
                  allowDiscards = true;
                };
                preCreateHook = ''
                  if ${pkgs.cryptsetup}/bin/cryptsetup isLuks "$device" >/dev/null 2>&1; then
                    echo "Refusing to reuse existing LUKS device $device for OTP-derived install key." >&2
                    exit 1
                  fi

                  ${lib.getExe rpiOtpProvision} stage \
                    --format hex \
                    --salt-file "${stagedSalt}" \
                    --out "${stagedKey}"
                '';
                content = {
                  type = "lvm_pv";
                  vg = "pool";
                };
              };
            };
          };
        };
      };
    };
    lvm_vg = {
      pool = {
        type = "lvm_vg";
        lvs = {
          rootfs = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              postMountHook = ''
                ${lib.getExe rpiOtpProvision} install-salt \
                  --salt-file "${stagedSalt}" \
                  --target-file "${installedSalt}" \
                  --cleanup "${stagedSalt}" \
                  --cleanup "${stagedKey}"
              '';
            };
          };
        };
      };
    };
  };
}
