# RTL8189FS precompiled bundle for `6.12.103-ophub`

This directory is a self-contained, offline-installable Wi-Fi bundle for the exact ZTE B860H image recorded in [MANIFEST.txt](./MANIFEST.txt).

It requires:

- ZTE B860H / `zte,b860h`
- ARM64
- Realtek SDIO ID `024C:F179`, or explicit physical verification when the stock DTB leaves SDIO unpowered
- Kernel `6.12.103-ophub` with the exact `/boot/zImage` checksum in the manifest
- The exact stock B860H DTB checksum in the manifest

Copy this entire directory to the target, then run:

```sh
sudo bash install.sh --confirm-hardware --check
sudo bash install.sh --confirm-hardware
sudo reboot
sudo bash install.sh --verify
```

If SDIO already reports `024C:F179`, omit `--confirm-hardware`.

To stage and reboot in one operation:

```sh
sudo bash install.sh --confirm-hardware --reboot
```

Rollback only changes the boot selector back to the preserved configuration; installed artifacts remain harmlessly on disk:

```sh
sudo bash install.sh --rollback --reboot
```

The installer performs no compilation, package installation, or network download.
