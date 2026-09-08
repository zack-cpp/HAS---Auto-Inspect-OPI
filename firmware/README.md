# Firmware notes

Hardware-specific firmware, device-tree, and out-of-tree driver notes for the Orange Pi / TV-box hosts used by this project live here.

## ZTE B860H Wi-Fi

- [Automated installer](../setup/setup-b860h-wifi.sh)
- [RTL8189FS recovery and installation runbook](./b860h-rtl8189fs-wifi.md)
- [Fleet implementation guide](./b860h-rtl8189fs-deployment.md)
- [Linux 6.12 cfg80211 compatibility patch](./patches/rtl8189fs-linux-6.12-monitor-channel.patch)
- [B860H Wi-Fi power GPIO device-tree patch](./patches/meson-gxl-s905x-b860h-wifi-power-gpio.patch)
- [Boot-time module list](./rtl8189fs.modules)

The driver module is kernel-specific. Do not copy `8189fs.ko` between kernel versions; rebuild it against the target kernel headers by following the runbook.
