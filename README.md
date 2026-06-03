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
    mingw-w64-ucrt-x86_64-meson mingw-w64-ucrt-x86_64-ninja
  ```
  ramiel builds with the GNU/UCRT ABI, so the UCRT64 `.a` link cleanly.
  (`make`/`nasm` drive FFmpeg's autotools build; `meson`/`ninja` build libdav1d.)
- **Linux/macOS:** a C compiler, `make`, `nasm`, `meson`, `ninja`, `pkg-config`
  from your package manager.

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
const ffmpeg = b.dependency("ffmpeg", .{});
ramiel_mod.addSystemIncludePath(ffmpeg.namedLazyPath("include"));
ramiel_mod.addObjectFile(ffmpeg.namedLazyPath("libavformat"));
ramiel_mod.addObjectFile(ffmpeg.namedLazyPath("libavcodec"));
ramiel_mod.addObjectFile(ffmpeg.namedLazyPath("libdav1d"));
ramiel_mod.addObjectFile(ffmpeg.namedLazyPath("libswresample"));
ramiel_mod.addObjectFile(ffmpeg.namedLazyPath("libavutil"));
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
- **Protocols:** file.

AV1 uses **libdav1d** (built from source via meson+ninja, statically linked) —
FFmpeg's built-in `av1` decoder is hardware-only and cannot decode in software.

Edit the `configure` flags in `build.zig` to change the matrix.

## Releasing

`.github/workflows/release.yml` runs on a `v*` tag push: it builds the static
archives on a Windows runner (MSYS2 UCRT64) and a Linux runner, then publishes
per-target tarballs (`ffmpeg-ramiel-<tag>-x86_64-{windows,linux}.tar.gz`) to the
GitHub release.

Bootstrapping prebuilt fetching (one-time per release):

1. Tag and push (`git tag v0.1.0 && git push --tags`); the workflow publishes the
   tarballs.
2. Get each tarball's Zig package hash:
   ```sh
   zig fetch https://github.com/Nikutsuki/ffmpeg-ramiel/releases/download/v0.1.0/ffmpeg-ramiel-v0.1.0-x86_64-windows.tar.gz
   zig fetch https://github.com/Nikutsuki/ffmpeg-ramiel/releases/download/v0.1.0/ffmpeg-ramiel-v0.1.0-x86_64-linux.tar.gz
   ```
3. Paste each printed hash into the matching `prebuilt_x86_64_*` entry in
   `build.zig.zon` (replacing the placeholder), commit.

After that, `zig build` (default `-Dprebuilt=true`) fetches the right tarball
per target with no compilation. The placeholder hashes do not affect source
builds (`-Dprebuilt=false`), which never reference the prebuilt deps.

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
