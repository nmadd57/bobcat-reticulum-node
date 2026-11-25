# Third-party components

| Component | Where | License |
|---|---|---|
| `shvelo/sx1302_rns`, a Reticulum interface for SX1302 concentrators. Modified here: RNode framing, a configurable payload limit, tests. | `sx1302_rns/` | MIT (`sx1302_rns/LICENSE`) |
| Semtech `sx1302_hal` v2.1.0, copied unmodified | `sx1302_rns/vendor/sx1302_hal/` | Revised BSD (`LICENSE.TXT` in that directory) |
| Reticulum (`rns`), installed from PyPI at install time | not included | see the `rns` package |
| Community Bobcat Armbian image and eMMC flasher (`sicXnull/Bobcat-Armbian`), downloaded at build time | **not included** | see that project; they are never committed here |

Everything else in this repository is MIT licensed (`LICENSE`).

The images built by `image/build-image.sh` and `image/build-flasher.sh` are modified copies of the community
image and flasher. Check that project's terms before redistributing it. This repository
publishes the build recipe, not the image.

## Rockchip loader files (fetched by the web flasher, not stored here)

The web flasher's Maskrom stage downloads `rk3566_ddr_1056MHz_v1.26.bin` and `rk356x_usbplug_v1.17.bin` from
Rockchip's [rkbin](https://github.com/rockchip-linux/rkbin) repository (commit `3e288fe8`), under Rockchip's license in that
repository, which permits use, copying and distribution with the notices kept. Unmodified copies are kept in
[nmadd57/rockchip-loader-mirror](https://github.com/nmadd57/rockchip-loader-mirror), and the full upstream histories in the
forks [nmadd57/rkbin](https://github.com/nmadd57/rkbin) and [nmadd57/rkdeveloptool](https://github.com/nmadd57/rkdeveloptool),
so they stay available if upstream removes them. The page checks a SHA-256 before sending anything to a board.
