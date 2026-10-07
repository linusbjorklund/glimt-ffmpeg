# glimt-ffmpeg

Build scripts for the FFmpeg audio decoder extension of
[AndroidX Media3](https://github.com/androidx/media) (ExoPlayer), as used by
Glimt, a media player for Android TV.

Media3 does not publish this extension as a binary, because it has to be
compiled together with FFmpeg. This repository builds it from source in GitHub
Actions and publishes the result as an Android library (AAR) under
[Releases](../../releases). It holds build scripts only: no application code.

## What is in a release

| File | Content |
| --- | --- |
| `media3-ffmpeg-decoder-<version>.aar` | The library |
| `media3-ffmpeg-decoder-<version>.aar.sha256` | Its SHA-256 checksum |
| `BUILD_INFO.txt` | Pinned revisions, toolchain and the exact FFmpeg configure flags of that build |

The version is `<Media3 version>-<build number>`, and the tag is `v<version>`,
for example `v1.11.1-1`.

The AAR holds:

- `classes.jar`: Media3's Java classes in `androidx.media3.decoder.ffmpeg`
  (`FfmpegAudioRenderer`, `FfmpegLibrary` and others), unchanged.
- `jni/<abi>/libffmpegJNI.so` for `armeabi-v7a`, `arm64-v8a`, `x86` and
  `x86_64`: Media3's JNI wrapper, linked with FFmpeg's `libavcodec`, `libavutil`
  and `libswresample`. The libraries are aligned for 16 KB memory pages, which
  64-bit devices can use from Android 15 on.

FFmpeg is built with four audio decoders, plus the AC-3 parser that FFmpeg
selects with them. There are no other decoders, and no encoders, demuxers,
muxers, filters or network code:

| FFmpeg decoder | Formats |
| --- | --- |
| `ac3` | Dolby Digital (AC-3) |
| `eac3` | Dolby Digital Plus (E-AC-3) |
| `dca` | DTS |
| `mp3` | MPEG audio layers I, II and III |

## Pinned versions

[`versions.env`](versions.env) is the source of truth. At the time of writing:

| Input | Revision |
| --- | --- |
| Media3 | tag [`1.11.1`](https://github.com/androidx/media/tree/1.11.1), commit `8c6678b657ede1e7883fc164ef73ed483c7796c3` |
| FFmpeg | branch `release/6.0`, commit [`b4a62c32549b8295691a8e0ff2c9b82188923159`](https://github.com/FFmpeg/FFmpeg/tree/b4a62c32549b8295691a8e0ff2c9b82188923159) |
| Android NDK | r26b (`26.1.10909125`) |
| Android API level | 23 |

The FFmpeg branch and the NDK are the ones the
[README of the Media3 module](https://github.com/androidx/media/blob/1.11.1/libraries/decoder_ffmpeg/README.md)
names for this Media3 version. `BUILD_INFO.txt` of each release says what that
release was built from.

## How it is built

[`build.sh`](build.sh) does everything, and the
[workflow](.github/workflows/build.yml) only calls it:

1. Checks out Media3 and FFmpeg at the pinned commits. FFmpeg comes from
   FFmpeg's own source repository (the build uses its official GitHub mirror).
   No prebuilt FFmpeg is used.
2. Configures and builds FFmpeg as static libraries, once per ABI.
3. Builds Media3's `lib-decoder-ffmpeg` module with Gradle, which compiles the
   JNI wrapper and links it with those static libraries.
4. Checks the result, and writes the checksum and `BUILD_INFO.txt`.

The Media3 and FFmpeg sources are not modified. A Gradle init script
([`media3-ffmpeg.init.gradle`](media3-ffmpeg.init.gradle)) sets the NDK
version, the ABIs and one linker flag for the JNI library
(`-Wl,-z,max-page-size=16384`, for 16 KB pages).

### FFmpeg configure flags

The flags are those of Media3's own
[`build_ffmpeg.sh`](https://github.com/androidx/media/blob/1.11.1/libraries/decoder_ffmpeg/src/main/jni/build_ffmpeg.sh).
For every ABI:

```
--target-os=android
--enable-static
--disable-shared
--disable-doc
--disable-programs
--disable-everything
--disable-avdevice
--disable-avformat
--disable-swscale
--disable-postproc
--disable-avfilter
--disable-symver
--enable-swresample
--extra-ldexeflags=-pie
--disable-v4l2-m2m
--disable-vulkan
--nm=<ndk>/llvm-nm
--ar=<ndk>/llvm-ar
--ranlib=<ndk>/llvm-ranlib
--strip=<ndk>/llvm-strip
--enable-decoder=ac3
--enable-decoder=eac3
--enable-decoder=dca
--enable-decoder=mp3
```

Plus, per ABI (`<ndk>` is the NDK's `toolchains/llvm/prebuilt/linux-x86_64/bin`):

| ABI | Flags |
| --- | --- |
| `armeabi-v7a` | `--libdir=android-libs/armeabi-v7a --arch=arm --cpu=armv7-a --cross-prefix=<ndk>/armv7a-linux-androideabi23- --extra-cflags='-march=armv7-a -mfloat-abi=softfp' --extra-ldflags='-Wl,--fix-cortex-a8'` |
| `arm64-v8a` | `--libdir=android-libs/arm64-v8a --arch=aarch64 --cpu=armv8-a --cross-prefix=<ndk>/aarch64-linux-android23-` |
| `x86` | `--libdir=android-libs/x86 --arch=x86 --cpu=i686 --cross-prefix=<ndk>/i686-linux-android23- --disable-asm` |
| `x86_64` | `--libdir=android-libs/x86_64 --arch=x86_64 --cpu=x86-64 --cross-prefix=<ndk>/x86_64-linux-android23- --disable-asm` |

`--enable-gpl`, `--enable-nonfree` and `--enable-version3` are not used, so
FFmpeg stays under its default licence, LGPL version 2.1 or later. The build
stops if FFmpeg's `configure` reports any other licence, or any codec besides
the four above.

The linker drops FFmpeg's own configuration string from the finished library,
so it cannot be read back from the `.so` files. `BUILD_INFO.txt` holds the flags
as FFmpeg's `configure` recorded them for each ABI.

## Using the library

The AAR needs `androidx.media3:media3-exoplayer` and
`androidx.media3:media3-decoder` next to it, in exactly the Media3 version it
was built from (the part of the version before the dash).

With Gradle, the release assets can be used as a repository. In
`settings.gradle.kts`:

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        exclusiveContent {
            forRepository {
                ivy {
                    name = "glimtFfmpeg"
                    url = uri("https://github.com/linusbjorklund/glimt-ffmpeg/releases/download")
                    patternLayout { artifact("v[revision]/[artifact]-[revision].[ext]") }
                    metadataSources { artifact() }
                }
            }
            filter { includeGroup("io.github.linusbjorklund.glimt") }
        }
    }
}
```

In the module:

```kotlin
dependencies {
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    implementation("androidx.media3:media3-decoder:1.11.1")
    implementation("io.github.linusbjorklund.glimt:media3-ffmpeg-decoder:1.11.1-1@aar")
}
```

The group name is only a label that ties the dependency to this repository in
the build. Media3's own README explains how to
[enable the extension in ExoPlayer](https://github.com/androidx/media/blob/1.11.1/libraries/decoder_ffmpeg/README.md#using-the-module-with-exoplayer).

## Building it yourself

On Linux, with git, make, unzip, a JDK (17 or newer) and an Android SDK that
has its command line tools installed:

```sh
export ANDROID_HOME=/path/to/android/sdk
./build.sh
```

The script installs the pinned NDK and CMake through the SDK manager if they are
missing, and leaves the AAR in `out/`. In GitHub Actions it takes about five
minutes.

To build from other revisions, or with a modified FFmpeg, change
[`versions.env`](versions.env) (and the repository address in `build.sh` if the
source is elsewhere).

In this repository a build is published by pushing a tag: `git tag v1.11.1-2`
and `git push origin v1.11.1-2`. A manual run of the workflow on a branch builds
without publishing.

## Replacing the library in an application

All FFmpeg code in an application that uses this AAR is in one file per ABI:
`lib/<abi>/libffmpegJNI.so` inside the APK. Nothing else is linked with FFmpeg.
To run the application with your own build of FFmpeg:

1. Build the AAR as described above, from the FFmpeg source you want.
2. Take `jni/<abi>/libffmpegJNI.so` out of your AAR (an AAR is a zip file).
3. Put it in place of `lib/<abi>/libffmpegJNI.so` in the APK (also a zip file),
   then align and sign the APK with `zipalign` and `apksigner` from the Android
   SDK build tools, using your own key.
4. Install it. Android does not let an APK signed with another key update an
   installed application, so uninstall the original first.

The library has to stay compatible with the JNI wrapper of the Media3 version in
`BUILD_INFO.txt`, which is what `build.sh` ensures.

## Licences

- **FFmpeg** is licensed under the GNU Lesser General Public License, version
  2.1 or later: see [`COPYING.LGPLv2.1`](COPYING.LGPLv2.1), which is FFmpeg's own
  copy of the licence text. The source is at <https://git.ffmpeg.org/ffmpeg.git>
  (mirror: <https://github.com/FFmpeg/FFmpeg>), and the exact commit of each
  build stands in its `BUILD_INFO.txt`. FFmpeg is a trademark of Fabrice
  Bellard, originator of the FFmpeg project. This repository is not affiliated
  with the FFmpeg project.
- **Media3** (the Java classes and the JNI wrapper) is licensed under the
  Apache License, Version 2.0: see [`LICENSE`](LICENSE). Copyright The Android
  Open Source Project.
- **The scripts in this repository** are licensed under the Apache License,
  Version 2.0: see [`LICENSE`](LICENSE). The FFmpeg configure flags come from
  Media3's `build_ffmpeg.sh`.

Some of the audio formats above may be covered by patents in some countries.
The licences here do not grant patent rights for the formats themselves.
