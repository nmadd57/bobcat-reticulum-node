# Vendored upstream code

`vendor/sx1302_hal/` is a verbatim copy of Semtech's SX1302 HAL and gateway
utilities, version 2.1.0, copied into this repository so builds do not depend
on a git submodule or network access to upstream.

- Upstream: `https://github.com/Lora-net/sx1302_hal.git`
- Copied from commit `4b42025d1751e04632c0b04160e0d29dbbb222a5` (v2.1.0).
- License: Revised BSD, see `sx1302_hal/LICENSE.TXT`.

## Policy

Keep this tree identical to upstream. To update it, replace the directory with
a fresh checkout of the new upstream tag and record the commit above.
Project-specific changes belong in patch files under `../patches/`. The HAL
build script applies those patches to a build copy rather than editing this
tree in place.
