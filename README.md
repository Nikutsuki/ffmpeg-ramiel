# ffmpeg-ramiel

A lean, **statically-linked** FFmpeg (+ libdav1d for AV1) packaged for the Zig
build system, built for the [ramiel](../ramiel) renderer. By default it fetches
**precompiled** static archives from the GitHub release; with `-Dprebuilt=false`
it builds them from pinned source via FFmpeg's `configure`/`make` and dav1d's
meson/ninja.

Goals:

- **No manual download** — prebuilt archives (or source) come via `build.zig.zon`.
- **No DLLs to copy / no RPATH / no patchelf** — output is static `.a`, linked
  straight into the consumer binary.
- **Small** — `--disable-everything` + selective enable keeps the archives to a
  few MB; the consumer's `--gc-sections` link drops the rest.
- **One command** — `zig build`. No shell scripts to invoke.

## Build

```sh
zig build                  # default: fetch precompiled static archives
zig build -Dprebuilt=false # build from source instead
```

Products are exposed to dependents as named lazy paths and copied under
`zig-out/ffmpeg/` (`include/`, `lib/lib*.a`).

`-Dprebuilt=true` (default) fetches the matching per-target tarball from the
release (currently `x86_64-windows`, `x86_64-linux`); any other target, or
`-Dprebuilt=false`, builds from source. Building from source needs the host
toolchain below; consuming prebuilt needs only Zig.

### Host requirements

`zig build` drives FFmpeg's autotools build, so the **build host** needs a POSIX
shell, `make`, and `nasm` (for x86 SIMD — kept, since decode speed matters):

- **Windows:** [MSYS2](https://www.msys2.org/) with the **UCRT64** toolchain.
  Defaults assume `C:/msys64`. Install deps:
  ```sh
  pacman -S --needed mingw-w64-ucrt-x86_64-gcc make nasm \
    mingw-w64-ucrt-x86_64-meson mingw-w64-ucrt-x86_64-ninja \
    mingw-w64-ucrt-x86_64-pkgconf
  ```
  ramiel builds with the GNU/UCRT ABI, so the UCRT64 `.a` link cleanly.
  (`make`/`nasm` drive FFmpeg's autotools build; `meson`/`ninja` build libdav1d.
  HTTPS uses Windows **Schannel** — no OpenSSL package needed.)
- **Linux:** a C compiler, `make`, `nasm`, `meson`, `ninja`, `pkg-config`,
  plus `libssl-dev` (OpenSSL) for HTTPS, and `libva-dev` / `libdrm-dev` for
  VAAPI. Example: `sudo apt install build-essential nasm meson ninja-build
  pkg-config libssl-dev libva-dev libdrm-dev`
- **macOS:** same core tools; HTTPS uses **Secure Transport** (no extra TLS
  package).

**Works from any shell — no MSYS2 terminal required.** `zig build` may be run
from PowerShell, cmd, or an IDE. The build step internally (a) prepends the
toolchain dir to `PATH` so the unix tools resolve regardless of the launching
shell's `PATH`, and (b) exports `MSYSTEM=UCRT64` so MSYS2's `uname` reports
`MINGW64_NT` — otherwise `configure` aborts with *"Native MSYS builds are
discouraged"*. `make`/`nasm` are also taken from the inherited `PATH` if present
(e.g. ezwinports/Strawberry), so an explicit `pacman` install is optional when
they're already reachable.

Overridable build options:

| Option            | Default (Windows)                     | Purpose                                  |
| ----------------- | ------------------------------------- | ---------------------------------------- |
| `-Dshell=`        | `C:/msys64/usr/bin/bash.exe`          | POSIX shell driving configure+make       |
| `-Dtoolchain-bin=`| `/c/msys64/ucrt64/bin:/c/msys64/usr/bin` | Prepended to `PATH` so `cc`/coreutils resolve |

> Host-only for now: the `configure` build targets the build machine. Cross
> compilation (`--enable-cross-compile`) is not yet wired.

## Consuming from ramiel

`ramiel/build.zig.zon`:

```zig
.dependencies = .{
    .ffmpeg = .{ .path = "../ffmpeg-ramiel" },
    // ...
},
```

`ramiel/build.zig`:

```zig
const ffmpeg_build = @import("ffmpeg");
const ffmpeg = b.dependency("ffmpeg", .{});
ramiel_mod.addSystemIncludePath(ffmpeg.namedLazyPath("include"));
ramiel_mod.addObjectFile(ffmpeg.namedLazyPath("libavformat"));
ramiel_mod.addObjectFile(ffmpeg.namedLazyPath("libavcodec"));
ramiel_mod.addObjectFile(ffmpeg.namedLazyPath("libdav1d"));
ramiel_mod.addObjectFile(ffmpeg.namedLazyPath("libswresample"));
ramiel_mod.addObjectFile(ffmpeg.namedLazyPath("libavutil"));
// HTTPS/network: Schannel (Windows), OpenSSL (Linux), SecureTransport (macOS)
ffmpeg_build.linkSystemDeps(ramiel_mod, target);
```

Exposed named lazy paths: `include`, `prefix`, `libavcodec`, `libavformat`,
`libavutil`, `libswresample`, `libdav1d`.

The consumption interface (named lazy paths) is identical whether the archives
are prebuilt or freshly compiled, so consumers never change.

### ABI

Prebuilt archives assume the consumer links the same ABI they were built with:
**x86_64-windows-gnu (UCRT)** and **x86_64-linux-gnu (glibc)**. ramiel uses the
GNU/UCRT ABI on Windows, so they link cleanly. A target that needs a different
ABI (e.g. windows-msvc, musl) should build from source with `-Dprebuilt=false`.

## Supported codecs (decode-only)

- **Video:** h264, hevc, vp9, av1 (via **libdav1d**, software); + parsers;
  `h264/hevc_mp4toannexb` BSFs.
- **Audio:** aac, mp3, opus, vorbis, flac, pcm.
- **Containers:** mov/mp4, matroska/webm, mp3, ogg, wav, flac, aac.
- **Protocols:** `file`, `http`, `https`, `tls`, `tcp`.
- **TLS:** Schannel (Windows), OpenSSL (Linux), Secure Transport (macOS).

AV1 uses **libdav1d** (built from source via meson+ninja, statically linked) —
FFmpeg's built-in `av1` decoder is hardware-only and cannot decode in software.

Edit the `configure` flags in `build.zig` to change the matrix.

## Releasing

`.github/workflows/release.yml` runs on a `v*` tag push:

1. Builds static archives on Windows (MSYS2 UCRT64) and Linux (`-Dprebuilt=false`).
2. Publishes `ffmpeg-ramiel-<tag>-x86_64-{windows,linux}.tar.gz` to the GitHub release.
3. Computes Zig package hashes and commits an update to `build.zig.zon` on the
   default branch so default `zig build` fetches that tag's prebuilts.

Tag from a commit that already has the desired configure flags:

```sh
git tag v0.1.5
git push origin v0.1.5
```

`.github/workflows/ci.yml` builds from source on push/PR so HTTPS/configure
regressions are caught before tagging.

Manual hash bootstrap (only if the auto-update job is skipped):

```sh
zig fetch https://github.com/Nikutsuki/ffmpeg-ramiel/releases/download/v0.1.5/ffmpeg-ramiel-v0.1.5-x86_64-windows.tar.gz
zig fetch https://github.com/Nikutsuki/ffmpeg-ramiel/releases/download/v0.1.5/ffmpeg-ramiel-v0.1.5-x86_64-linux.tar.gz
```

Prebuilt deps are `lazy`, so `-Dprebuilt=false` never fetches them.

## License

Repository build scripts: MIT (see `LICENSE`). Built/distributed artifacts:
FFmpeg **LGPL v2.1+** (decoders only, no `--enable-gpl`) and dav1d **BSD-2**.
Static-linking LGPL carries the §6 relink obligation — this repo's pinned
versions + configure flags + release archives are the relink recipe. Patent
note for H.264/H.265/AAC. Full detail in `NOTICE`. Never add `--enable-gpl`.

## Pinned versions

FFmpeg **n7.1.1**, dav1d **1.5.1** (see `build.zig.zon`). To bump either:

```sh
zig fetch <archive-url-for-new-tag>
# paste the printed hash + update the url tag in build.zig.zon
```
