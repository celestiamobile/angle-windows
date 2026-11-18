Adapted from https://github.com/mmozeiko/build-angle

## Downstream patches

`build.cmd` applies `angle.patch`, then `angle.d3d11-texture-storage.patch`
to ANGLE, and `build.patch` to its nested Chromium `build` checkout.

The separate [D3D11 texture-storage patch](docs/d3d11-texture-storage.md)
avoids redundant staging backups when promoting textures to render targets.
The linked notes cover its upstream issue, safety conditions, regression
tests, and outstanding Windows validation.
