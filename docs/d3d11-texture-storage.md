# D3D11 texture-storage promotion

## Status and provenance

- Patch: [`angle.d3d11-texture-storage.patch`](../angle.d3d11-texture-storage.patch).
- Prepared against `chromium/8127`,
  `1f6526a566c27c7c33aa73a78517450a4a2a1714`.
- Upstream report: [Chromium issue 576072317](https://issues.chromium.org/issues/576072317),
  "D3D11: ensureBindFlags redundantly copies old storage back to images since
  17c57c6066ac".
- Regression-introducing change:
  [`17c57c6066ac4cd7f5b09a7e1a0fccf6be3dec97`](https://chromium.googlesource.com/angle/angle/+/17c57c6066ac4cd7f5b09a7e1a0fccf6be3dec97),
  "D3D11: Backup texture storage contents on base level changes".

This is a downstream candidate, not an upstream fix or a measured Celestia
speedup. Clean patch application and formatting have been checked locally.
Windows compilation, D3D11 execution, and performance measurements remain
required; the development host is macOS.

## Why it is needed

`glTexStorage2D` normally creates D3D11 storage without render-target bind
flags unless the application supplies the framebuffer-usage hint. On first
render-target use, `TextureD3D::ensureBindFlags` creates replacement storage
with the additional flags and copies the original storage into it.

The subsequent `setCompleteTexStorage` also asks `releaseTexStorage` to back
up every matching image. This copies the old GPU texture into `Image11`
staging textures. Later image synchronization uploads those backups into
the replacement, duplicating the data transfer already done by
`copyToStorage`.

The original change added necessary data preservation: base-level changes
can destroy storage containing rendering or fast-path uploads that have no
staging copy. Reverting that preservation globally, or restricting it to
textures already marked as render targets, would reintroduce data loss.

Celestia's single-level immutable framebuffer textures exercise the
promotion path, so this issue is relevant even without mipmapped
application textures. The upstream report's large Firefox regression
is evidence for investigating the path, not a Celestia benchmark.

## What the patch changes

After a successful `copyToStorage`, `ensureBindFlags` releases the old
storage with an empty explicit-backup mask **only when all of these match**:

- Internal format.
- Top-level offset and exposed mip count.
- Level-zero width, height, and depth.

The top-level check also protects native mip layouts that include extra
levels for format/block-size constraints. Together with the same texture
type and renderer used for replacement creation, these checks constrain
the fast path to equivalent storage layouts. This matters because D3D11
`CopyResource` returns no success/failure status.

For differing layouts, the original `setCompleteTexStorage` backup path is
unchanged. Base-level-change preservation is also untouched. This patch
does not repair incompatible-resource copies elsewhere in ANGLE.

The empty mask skips only explicit whole-storage backups. Storage
destruction still runs `onDestroy`, including recovery of any associated
`Image11` objects. Pending dirty images are retained, and
`setCompleteTexStorage` still requests image synchronization. Consequently,
some staging copies remain necessary and are intentionally not removed.
Existing observer notifications, bind-flag preservation, error propagation,
and UAV/SRV invalidation remain in place.

The initial GPU-to-GPU storage copy and replacement allocation also remain.
An application-provided `GL_TEXTURE_USAGE_ANGLE =
GL_FRAMEBUFFER_ATTACHMENT_ANGLE` hint can avoid the initial promotion when
supported; this patch does not add that application-side workaround.

## Patch application

`build.cmd` applies the patches in this order:

1. `angle.patch` to the ANGLE checkout.
2. `angle.d3d11-texture-storage.patch` to the ANGLE checkout.
3. `build.patch` to the nested Chromium `build` checkout.

The pre-existing patch files are unchanged. Keep this runtime fix separate
when updating the upstream pin. Use a disposable clean checkout and plain
`git apply`, never `git apply -3`. Check and apply each patch in order;
checking both against an unmodified tree alone does not verify sequencing.

## Windows validation

The patch intentionally contains only the runtime fix in `TextureD3D.cpp`:
one hunk with 13 added lines, including comments and spacing. It adds no
test files or GN changes, minimizing conflicts when updating ANGLE.

In a disposable, dependency-synced Windows ANGLE developer checkout with
both ANGLE patches already applied, build a **desktop** D3D11 debug test
configuration rather than reusing the library-only WinAppSDK output:

```bat
gn gen out/d3d11-storage-tests --args="is_debug=true is_component_build=false angle_build_all=false angle_build_tests=true angle_enable_d3d11=true angle_enable_gl=false angle_enable_vulkan=false angle_enable_wgpu=false angle_enable_null=false angle_enable_perfetto=false use_siso=false"
autoninja -C out/d3d11-storage-tests angle_end2end_tests
out\d3d11-storage-tests\angle_end2end_tests.exe --gtest_filter="*SetBaseLevelPreservesFastPathSubImageData*D3D11*:*D3D11RecoverFromStorageBug*D3D11*"
```

Confirm the selected tests actually run, rather than producing zero
matches or only skips. The existing base-level-preservation and recovery
tests protect the earlier correctness fix, but do not assert that this
optimization removes redundant copies. These Windows commands have
**not** been run on the macOS development host; local source-check
attempts stopped at unavailable Windows platform types and do not count
as a successful build.

Before shipping, also build the normal x64/arm64 packaging targets and
check D3D11 debug-layer output. Use PIX or equivalent copy/resource tracing
to compare first framebuffer use and repeated framebuffer creation; no
steady-state FPS or memory improvement is assumed here.

Check mip contents before and after promotion, including nonzero base
levels, thin/NPOT immutable textures, and RGB8's emulated alpha channel.

## Updating or removing the patch

On a pin update, check whether upstream has fixed issue 576072317 and
whether `copyToStorage`, storage layout metadata, or associated-image
recovery semantics have changed. Re-run the tests above, including the
old preservation tests. Remove this patch and its application line once
an equivalent upstream fix is included; do not silently apply it with a
three-way merge.
