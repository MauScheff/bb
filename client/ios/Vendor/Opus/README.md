# TurboOpus

Turbo vendors the upstream Xiph `libopus` C implementation for app-side realtime voice media.

## Build

```sh
tools/scripts/build_libopus_xcframework.sh
```

The script downloads `opus-1.6.1.tar.gz` from `downloads.xiph.org`, verifies the pinned SHA-256 checksum, builds static `iphoneos` and `iphonesimulator` slices, and writes:

- `Vendor/Opus/TurboOpus.xcframework`
- `Vendor/Opus/LICENSE.opus.txt`

`TurboOpus` includes a small C shim around `opus_encoder_ctl` so Swift can configure encoder controls without calling C variadic macros directly.
