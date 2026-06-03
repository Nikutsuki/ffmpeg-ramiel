const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const prebuilt = b.option(
        bool,
        "prebuilt",
        "Use precompiled static libraries from the GitHub release instead of building from source (default true on supported targets).",
    ) orelse true;

    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;

    const prebuilt_name: ?[]const u8 = if (prebuilt) blk: {
        if (os == .windows and arch == .x86_64) break :blk "prebuilt_x86_64_windows";
        if (os == .linux and arch == .x86_64) break :blk "prebuilt_x86_64_linux";
        break :blk null;
    } else null;

    if (prebuilt_name) |name| {
        if (b.lazyDependency(name, .{})) |dep| {
            exposePrefix(b, dep.path(""));
        }
        return;
    }

    buildFromSource(b, target);
}

fn exposePrefix(b: *std.Build, prefix: std.Build.LazyPath) void {
    b.addNamedLazyPath("include", prefix.path(b, "include"));
    b.addNamedLazyPath("prefix", prefix);
    inline for (.{ "avcodec", "avformat", "avutil", "swresample", "dav1d" }) |lib| {
        b.addNamedLazyPath("lib" ++ lib, prefix.path(b, "lib/lib" ++ lib ++ ".a"));
    }
    const install = b.addInstallDirectory(.{
        .source_dir = prefix,
        .install_dir = .prefix,
        .install_subdir = "ffmpeg",
    });
    b.getInstallStep().dependOn(&install.step);
}

fn buildFromSource(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const is_windows = target.result.os.tag == .windows;

    const shell = b.option(
        []const u8,
        "shell",
        "POSIX shell used to drive the build (Windows default: MSYS2 bash).",
    ) orelse if (is_windows) "C:/msys64/usr/bin/bash.exe" else "/bin/sh";

    const toolchain_bin = b.option(
        []const u8,
        "toolchain-bin",
        "Directory prepended to PATH so the build finds the toolchain (Windows default: MSYS2 UCRT64).",
    ) orelse if (is_windows) "/c/msys64/ucrt64/bin:/c/msys64/usr/bin" else "";

    const ffmpeg_src = b.lazyDependency("ffmpeg_src", .{}) orelse return;
    const dav1d_src = b.lazyDependency("dav1d_src", .{}) orelse return;

    const run = b.addSystemCommand(&.{ shell, "-c", build_script, "bash" });
    run.setName("ffmpeg+dav1d: lean static build");
    run.setEnvironmentVariable("FFMPEG_TOOLCHAIN_BIN", toolchain_bin);
    run.addDirectoryArg(ffmpeg_src.path(""));
    run.addDirectoryArg(dav1d_src.path(""));
    const prefix = run.addOutputDirectoryArg("ffmpeg");

    exposePrefix(b, prefix);
}

const build_script =
    \\set -e
    \\[ -n "$FFMPEG_TOOLCHAIN_BIN" ] && export PATH="$FFMPEG_TOOLCHAIN_BIN:$PATH"
    \\[ -n "$FFMPEG_TOOLCHAIN_BIN" ] && export MSYSTEM=UCRT64
    \\FFSRC="$1"; DAVSRC="$2"; OUT="$3"
    \\if command -v cygpath >/dev/null 2>&1; then
    \\  FFSRC="$(cygpath -u "$FFSRC")"
    \\  DAVSRC="$(cygpath -u "$DAVSRC")"
    \\  OUT="$(cygpath -u "$OUT")"
    \\  DAVSRC_N="$(cygpath -m "$DAVSRC")"
    \\  OUT_N="$(cygpath -m "$OUT")"
    \\else
    \\  DAVSRC_N="$DAVSRC"
    \\  OUT_N="$OUT"
    \\fi
    \\BUILD="${OUT}.build"
    \\rm -rf "$BUILD"; mkdir -p "$BUILD"
    \\LOG="$BUILD/build.log"
    \\DAVB="$BUILD/dav1d-build"
    \\if command -v cygpath >/dev/null 2>&1; then DAVB_N="$(cygpath -m "$DAVB")"; else DAVB_N="$DAVB"; fi
    \\echo "ffmpeg-ramiel: building dav1d (meson)" >>"$LOG"
    \\if ! meson setup "$DAVB_N" "$DAVSRC_N" --prefix="$OUT_N" --buildtype=release --default-library=static -Denable_tools=false -Denable_tests=false </dev/null >>"$LOG" 2>&1; then
    \\  echo "=== dav1d meson setup failed ===" >&2; tail -n 100 "$LOG" >&2; exit 1
    \\fi
    \\if ! ninja -C "$DAVB_N" install </dev/null >>"$LOG" 2>&1; then
    \\  echo "=== dav1d build failed ===" >&2; tail -n 120 "$LOG" >&2; exit 1
    \\fi
    \\export PKG_CONFIG_PATH="$OUT_N/lib/pkgconfig"
    \\FFB="$BUILD/ffmpeg"
    \\mkdir -p "$FFB"; cp -a "$FFSRC"/. "$FFB"/
    \\cd "$FFB"
    \\echo "ffmpeg-ramiel: configuring ffmpeg" >>"$LOG"
    \\if ! ./configure \
    \\  --prefix="$OUT" \
    \\  --pkg-config-flags=--static \
    \\  --disable-shared --enable-static --enable-pic \
    \\  --disable-programs --disable-doc --disable-debug --disable-autodetect \
    \\  --disable-everything \
    \\  --disable-avdevice --disable-avfilter --disable-swscale --disable-postproc \
    \\  --enable-avcodec --enable-avformat --enable-avutil --enable-swresample \
    \\  --enable-libdav1d \
    \\  --enable-decoder=h264,hevc,vp9,libdav1d,aac,mp3,opus,vorbis,flac,pcm_s16le,pcm_s16be,pcm_f32le \
    \\  --enable-parser=h264,hevc,vp9,av1,aac,opus,vorbis,flac \
    \\  --enable-demuxer=mov,matroska,mp3,ogg,wav,flac,aac \
    \\  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb \
    \\  --enable-protocol=file \
    \\  --disable-network --disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
    \\  --extra-cflags="-ffunction-sections -fdata-sections" \
    \\  </dev/null >>"$LOG" 2>&1; then
    \\  echo "=== ffmpeg configure failed ===" >&2; tail -n 80 "$LOG" >&2
    \\  echo "=== ffbuild/config.log tail ===" >&2; tail -n 60 ffbuild/config.log >&2 2>/dev/null
    \\  exit 1
    \\fi
    \\echo "ffmpeg-ramiel: compiling ffmpeg (make -j)" >>"$LOG"
    \\if ! make -j"$(nproc 2>/dev/null || echo 4)" </dev/null >>"$LOG" 2>&1; then
    \\  echo "=== make failed ===" >&2; tail -n 160 "$LOG" >&2; exit 1
    \\fi
    \\make install </dev/null >>"$LOG" 2>&1
    \\echo "ffmpeg-ramiel: installed lean static ffmpeg + dav1d to $OUT" >>"$LOG"
;
