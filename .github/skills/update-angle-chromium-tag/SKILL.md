---
name: update-angle-chromium-tag
description: >
  Bump the pinned upstream `chromium/NNNN` ANGLE branch used by the
  angle-windows, angle-apple, and angle-android fork repos, verify every
  checked-in patch still applies cleanly against the new commit, fix any
  patch that fails, and (optionally) do a real local build to confirm.
  Use when asked to "update the chromium tag", "bump ANGLE to chromium/NNNN",
  or "check patches still apply" for any of these repos.
argument-hint: [new chromium/NNNN tag] [repo name(s), default: all]
---

# Update ANGLE chromium/NNNN tag across fork repos

## Background

Repos live as siblings under `Celestia/angle/`:
- `angle` — a working checkout of upstream `github.com/google/angle` (or
  chromium's angle mirror), used as the scratch tree to test patch
  application and do real builds. Not itself one of the "fork" repos.
- `angle-windows`, `angle-apple`, `angle-android` — each pins a specific
  `chromium/NNNN` branch/commit of upstream ANGLE and carries a small set of
  `*.patch` files (unified diffs) plus a `build.sh`/`build.cmd` that clones
  upstream at that pin, applies the patches in a fixed order, and builds.

When upstream advances to a new `chromium/NNNN` branch, the patches may no
longer apply cleanly (line-number drift, or upstream already made an
equivalent/conflicting change) and must be fixed by hand, then re-verified.

## Step-by-step (repeat per repo that needs the bump)

### 1. Find where the tag is pinned and bump it

- `angle-windows/.github/workflows/angle-build.yml`: `ANGLE_COMMIT: chromium/NNNN` (env var consumed by `build.cmd`).
- `angle-apple/build.sh`: `git checkout chromium/NNNN` (near the top, after cloning ANGLE).
- `angle-android/build.sh`: `ANGLE_COMMIT=$(git ls-remote ... refs/heads/chromium/NNNN | awk '{print $1}')` (default fallback branch name baked into the script) — also check `publish_maven.sh` for a `chromium/NNNN` URL used in the generated POM license link.

Update all occurrences for the repo(s) in scope.

### 1a. Keep the CI Xcode version in one place (angle-apple)

`angle-apple`'s Xcode version for the `xcode-27`-style self-hosted runners is
defined **once**, as the repo variable `vars.XCODE_VERSION` (Settings →
Secrets and variables → Actions → Variables), e.g. `27.0`:

```bash
gh variable set XCODE_VERSION --body "27.0" --repo celestiamobile/angle-apple
```

Both `.github/workflows/build-template.yml` (its `xcode-version` input,
passed in by `xcframework.yml`'s `build-all` job) and
`.github/workflows/xcframework.yml`'s `generate-xcframework` job read
`${{ vars.XCODE_VERSION }}` and run
`sudo xcode-select -s /Applications/Xcode_${{ vars.XCODE_VERSION }}.app` —
do not hardcode the version as a literal in more than one place, and do not
use third-party actions like `maxim-lobanov/setup-xcode` here: that action
does its own strict version-list matching against Xcode.app bundles it
detects by its own naming convention (e.g. it saw `Xcode_27_beta_6.app` and
refused to match a requested `'27.0'`), which fails even when the runner's
actual `/Applications/Xcode_27.0.app` path (set up out-of-band on the
self-hosted runner image) works fine with plain `xcode-select`.
Note: `jobs.<job_id>.with` (used when calling a reusable workflow) only has
access to the `vars`/`inputs`/`github`/`needs`/`strategy`/`matrix` contexts —
**not** `env` — so a workflow-level `env:` block cannot be used to share this
value with a reusable workflow call; the repo variable (`vars`) is the only
context available in both places.

### 2. Set up a scratch tree to test patch application

Use the sibling `angle` checkout as the scratch tree (do NOT test inside the
fork repos themselves — the patches there are meant to apply to a *fresh*
ANGLE checkout, not to `angle-windows`/`angle-apple`/`angle-android`).

```bash
cd Celestia/angle/angle
git fetch origin chromium/NNNN
git checkout chromium/NNNN   # or: git checkout -B chromium/NNNN origin/chromium/NNNN
```

For patches that target the nested `//build` checkout (angle-apple's
`chromium.build.*.patch` files apply inside `angle/build`, a separate
`DEPS`-checked-out repo), `cd build` before applying those.

**Always start from a fully clean tree** before testing a patch sequence:

```bash
git checkout -- .
git clean -fd <dirs-patches-might-add-files-to>   # e.g. extensions/, src/libANGLE/renderer/metal/shaders/
```

⚠️ **Do NOT run `git checkout -- . && git clean -fd` blindly** if there is
*any* uncommitted work-in-progress fix that hasn't been folded into a patch
file yet — this permanently destroys it. Always `git status --short` /
`git diff` first and make sure everything of value is either committed,
stashed (`git stash -u`, not plain `git stash` — plain stash leaves new
untracked files behind), or already captured in a patch file.

### 3. Apply each repo's patches in their documented order and watch for failures

Read the patch list + order straight out of the repo's own build script
(don't assume — order matters and changes over time):

- `angle-apple/build.sh`: `angle.apple.patch` → `variable_rasterization_rate_map.patch` → `angle.visionos.patch` → `angle.metal.patch` → (cd `build/`) → `chromium.build.apple.patch` → `chromium.build.visionos.patch`.
- `angle-windows/build.cmd` + `build.patch`: single `angle.patch` against ANGLE, `build.patch` against the nested `//build` checkout.
- `angle-android`: no `*.patch` files currently — bump-only.

Apply with plain `git apply --ignore-whitespace --whitespace=nowarn`
(fuzzy context matching). **Never use `git apply -3`** (three-way merge) for
this kind of verification/CI use — it can silently produce a bad merge
instead of failing when line-offsets are large; it has caused real CI
corruption in this project before. If `-3` is present in a repo's
`build.sh`/`build.cmd`, that's a bug — remove it.

```bash
git apply ../angle-apple/angle.apple.patch --ignore-whitespace --whitespace=nowarn && echo 1ok && \
git apply ../angle-apple/variable_rasterization_rate_map.patch --ignore-whitespace --whitespace=nowarn && echo 2ok && \
... # etc, one invocation per patch, chained with && so it stops at the first failure
```

### 4. Fix any patch that fails to apply

For each failing hunk:
1. Read the rejected hunk's context lines vs. the current file content at
   roughly that location — usually it's just line-number drift (fine, `git
   apply`'s fuzz handles it) or the *content* of a context line genuinely
   changed upstream (breaks fuzzy matching regardless of offset).
2. Regenerate that hunk from a tree that has **only the patches that come
   before it in the apply order** already applied (never a tree with a
   *later* patch's changes mixed in — that causes cross-contamination
   between patch files, e.g. accidentally folding one patch's insertion
   into another patch's file). Prefer editing the unified diff hunk by hand
   (safer, avoids re-diffing unrelated whitespace) over regenerating the
   whole file diff when only a line or two changed.
3. If two patches touch overlapping regions of the *same* file (has
   happened for `config/compiler/BUILD.gn` between `chromium.build.apple.patch`
   and `chromium.build.visionos.patch` in angle-apple), trim each hunk's
   context lines so the two hunks' context windows don't overlap the line(s)
   the other patch is modifying — a hunk's default 3-line context can be
   safely shortened (adjust the `@@ -a,b +c,d @@` counts accordingly) to
   avoid this.
4. **Unified diff gotcha**: a context line that is fully blank must still
   have a single leading space character; a truly empty line is invalid and
   causes `git apply` to error on a *later*, unrelated hunk ("patch fragment
   without header").
5. Re-run the full apply sequence from a clean tree (step 2+3) to confirm.

### 5. (Optional but recommended) Do a real local build to confirm

For angle-apple, after all patches apply:

```bash
cd Celestia/angle/angle
cp ../angle-apple/<Config>.args.gn out/<outdir>/args.gn
# NOTE: checked-in args.gn templates use "Xcode.app" as a placeholder that
# CI substitutes for the pinned Xcode version. Locally this only works if
# your default Xcode.app matches; if you have a separate beta Xcode with a
# newer SDK, point clang_base_path AND the sysroot at the same Xcode install
# (mixing toolchain vs. SDK versions across Xcode installs causes
# "-Werror,-Wunknown-attributes" build failures from SDK headers the older
# clang doesn't understand). Never commit a local Xcode-beta override into
# the checked-in args.gn templates.
export PATH="$PWD/../depot_tools:$PATH"
gn gen out/<outdir>
autoninja -C out/<outdir>
```

Common real (not just patch-apply) breakage seen across chromium bumps and
their fixes — check whether these are already covered before re-solving
them:
- New/renamed warning flags unsupported by Apple clang (e.g.
  `-Wno-stringop-overread` is GCC-only) — guard with `!is_apple` in
  `build/config/compiler/BUILD.gn`.
- Apple's `ar` (vs `llvm-ar`) doesn't support `-D` or `@responsefile`
  expansion — the `alink` tool in `build/toolchain/apple/toolchain.gni` must
  use `${prefix}ar` + `{{inputs}}` directly for the non-libtool branch.
  `rspfile` should stay scoped to the libtool-only branch.
- Xcode's toolchain doesn't ship `lld` — host toolchain in
  `build/toolchain/mac/BUILD.gn` needs `use_lld = false` or `-fuse-ld=lld`
  linker errors occur for host tools built during cross builds.
- `angle_enable_perfetto` defaults to `true` once
  `angle_perfetto_cpp_dir`/`build_overrides/angle.gni` picks up perfetto
  support upstream — set `angle_enable_perfetto = false` in every
  `*.args.gn` template unless perfetto tracing is actually wanted (large
  extra dependency/build time).
- Autogenerated array sizes (e.g. `g_stringEnumTable` in
  `gl_enum_utils_autogen.cpp`, patched by
  `variable_rasterization_rate_map.patch`) can silently mismatch if upstream
  refactors to `constexpr std::array<...>` (no longer auto-sized) — bump the
  literal size in the patch to match the new enum count.
- Removed/renamed gn args (e.g. `angle_enable_d3d9` no longer exists) should
  simply be dropped from the `*.args.gn` templates — `gn gen` only warns
  ("Build argument has no effect"), it doesn't fail, so these are easy to
  miss; grep for stale args across all templates when bumping.

### 6. Fold every fix into the actual patch files, never leave it only in the live build tree

The live `angle`/`angle/build` scratch trees are disposable — any fix that
isn't captured in a `*.patch` file (or, for CI/toolchain-only fixes, in the
fork repo's own tracked files like `build.sh`/`*.args.gn`/workflow YAML) will
be silently lost and must be rediscovered next time. After each fix, leave
the scratch tree in a clean or fully-reproducible state (either fully
re-verify + wipe, or explicitly note what's left uncommitted and why).

### 7. Commit and push (only when explicitly asked)

Do not commit/push automatically — this user reviews and explicitly asks
for "commit and push" as a separate step once satisfied with the fixes.
