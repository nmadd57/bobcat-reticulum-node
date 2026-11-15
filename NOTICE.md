# Third-party components

| Component | Where | License |
|---|---|---|
| `shvelo/sx1302_rns`, a Reticulum interface for SX1302 concentrators. Modified here: RNode framing, a configurable payload limit, tests. | `sx1302_rns/` | MIT (`sx1302_rns/LICENSE`) |
| Semtech `sx1302_hal` v2.1.0, copied unmodified | `sx1302_rns/vendor/sx1302_hal/` | Revised BSD (`LICENSE.TXT` in that directory) |
| Reticulum (`rns`), installed from PyPI at install time | not included | see the `rns` package |
| Community Bobcat Armbian image (`sicXnull/Bobcat-Armbian`), downloaded at image build time | **not included** | see that project; it is never committed here |

Everything else in this repository is MIT licensed (`LICENSE`).

The image built by `image/build-image.sh` is a modified copy of the community
image. Check that project's terms before redistributing it. This repository
publishes the build recipe, not the image.
