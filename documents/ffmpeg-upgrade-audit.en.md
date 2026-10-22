# SGPlayer: FFmpeg 7.0.1 → 9.0.2 migration audit

English | [简体中文](ffmpeg-upgrade-audit.md)

> Historical pre-upgrade audit. Statements about the “current” code below refer to the audited baseline, not the updated working tree. See the [9.0.2 migration guide](ffmpeg-9.0.2-migration.en.md) for implementation and current verification results.

Audit date: 2026-10-22. Project baseline: `d0c7ab85776fdb60979c60611a4b8085a6ef9a59`.

## Conclusion

**Migration is feasible while retaining the playback architecture, but changing only the version number is insufficient.** Two blockers were reproduced: the removed `--disable-postproc` configure option and two accesses to the removed `AVFrame.pkt_size` field in `SGFrame.m`. Existing channel-layout ownership, video memory release and hardware-device initialization problems should also be fixed; successful compilation alone does not establish correct playback.

The audit selected official stable release **9.0.2**, rather than master. At audit time, the live official download page reported release date 2026-09-18 and branch date 2026-06-26. The audit relied on the live page and release sources rather than potentially stale search indexes. [Official release page](https://ffmpeg.org/download.html#release_9.0).

At this audit stage, no player code, build version or production dependency was changed. Full static-library builds, linking, physical-device playback and oldest-system testing had not been completed. This historical audit does not establish that the upgrade was complete.

## 1. Baseline and evidence limits

| Item | Audited repository | Migration requirement |
|---|---|---|
| FFmpeg | `build.sh:8` selects `7.0.1` | Pin official `n9.0.2` and a source revision/checksum |
| Source | `scripts/init-ffmpeg.sh:21–22` uses the `libobjc/FFmpeg` fork | Compare the actual old revision with official `n7.0.1` before switching source or porting patches |
| OpenSSL | `OpenSSL_1_1_1w` | Decide TLS backend/update strategy separately; a successful TLS build is not an HTTPS regression test |
| Platforms | iOS/tvOS arm64; macOS arm64/x86_64 | Reconcile architecture lists and Xcode product configuration |
| Simulators | iOS/tvOS simulator lists are commented out | Build separately and package device/simulator variants with XCFrameworks if required |
| Minimum OS | iOS/tvOS 13.0, macOS 10.15 | Correct arm64 macOS deployment requirements; test minimum systems with appropriate devices/OS versions |
| Existing binaries | No dependency outputs in `build/` in the audited checkout | Script declarations cannot establish what an existing app actually links |
| Automation | No project test target/suite found | Establish migration-specific tests and representative media baselines |

The complete fork diff was not obtained, so this audit does not claim equivalence with official 7.0.1. Preserve old revisions, configure output, libraries and representative playback results for comparison and rollback.

## 2. Verification performed

Using Xcode 27.1 (27A9275), the audit downloaded and inspected official `ffmpeg-9.0.2.tar.xz`. Its SHA-256 was:

```text
8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
```

This records the downloaded content; it does not establish official signature verification.

1. Running the project's original `scripts/module.sh` options against complete 9.0.2 sources reproduced `Unknown option "--disable-postproc"`.
2. In a temporary audit environment only, removing that option and adding `--disable-asm --disable-autodetect --disable-everything` produced configuration headers for syntax checks. This did **not** test real decoders, hardware acceleration, TLS, assembly or a complete production build.
3. After excluding comments, 57 called FFmpeg functions had declarations in the new public headers. Seventeen Objective-C implementation files were checked with 9.0.2 headers using `clang -fsyntax-only -fobjc-arc -fblocks`. Each of six targets—macOS arm64/x86_64 and arm64 iOS/tvOS device/simulator—passed **16/17 files**: 96 of 102 checks passed. All failures were `pkt_size` accesses at lines 113 and 140 of `SGFrame.m`.
4. The compiler accepted `-fembed-bitcode` for macOS/iOS arm64, so it was not classified as a reproduced blocker. It remained a modernization item.

See [audit evidence](ffmpeg-upgrade-audit-evidence.json). Only direct FFmpeg consumers were syntax-checked; no complete SGPlayer/demo build was claimed. Cross-platform checks shared minimally generated macOS configuration headers, suitable only for interface checks, not independent platform configuration or linking.

## 3. Required migration changes

### P1: Remove the invalid postproc option

Location: `scripts/module.sh:41`.

FFmpeg 9.0.2 rejects `--disable-postproc`, stopping the original configuration before compilation. After removal, run the complete production configuration; minimal configuration success does not validate external dependencies. [9.0.2 configure](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/configure).

### P1: Replace AVFrame.pkt_size

Location: `SGPlayer/Classes/Core/SGData/SGFrame.m:113,140`.

The field was deprecated in 7.0.1 and is absent in 9.0.2. A field rename or unconditional zero is insufficient. First define `SGFrame.size` semantics:

- For decoded memory usage, count retained software buffers/planes without double-counting shared allocations, and define a hardware pixel-buffer estimate.
- For compressed packet bytes, evaluate metadata propagation via `AV_CODEC_FLAG_COPY_OPAQUE` and `AVPacket.opaque_ref`. Packet/frame relationships may be many-to-many.

Document frame memory separately from compressed queue bytes to avoid unintended buffering changes. `SGFrameOutput.m:376–388` uses a 15 MiB capacity threshold for packet-reading backpressure; trace notification and capacity effects.

Sources: [7.0.1 frame.h](https://github.com/FFmpeg/FFmpeg/blob/n7.0.1/libavutil/frame.h), [9.0.2 frame.h](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavutil/frame.h).

### P1: Reliably switch source and configuration

Locations: `scripts/init-ffmpeg.sh`, `scripts/do-compile-ffmpeg.sh:270–283`, `scripts/compile-ffmpeg.sh`.

The old build reuses configuration whenever `config.h` exists. Version, SDK, compiler flags, TLS or architecture changes can therefore retain stale configuration. Use version/platform/architecture-specific output directories and configuration fingerprints containing source revision, SDK, toolchain and arguments.

Start migration builds in a new output directory. Verify matching headers/libraries and rebuild all libav*, libsw* libraries and consumers without mixing old ABIs. Avoid forced checkout/clean operations in old directories containing local patches.

## 4. Existing problems to fix during migration

These are not newly introduced by 9.0.2 and are not all detectable with syntax checks.

### P1: Shallow AVChannelLayout ownership

Locations: `SGAudioDescriptor.m:21,42`, `SGAudioFrame.m:37`, and the default internal `channelLayout` setter.

`AV_CHANNEL_ORDER_CUSTOM` owns a dynamic map. Direct assignment shares that map across descriptors/frames. Pooling a frame through `av_frame_unref()` can leave a dangling descriptor pointer; assigning the layout to another frame can cause double-free.

Use independent owned layouts: `av_channel_layout_copy()` with failure checks for initialization, copies, setters and new frames; `av_channel_layout_uninit()` at destruction. For self-assignment, copy to a temporary before replacement. Keep channel counts consistent and explicitly reject or handle invalid/unknown layouts.

The temporary structures in `SGSWResample.m:44–45` borrow layouts for a read-only call; not every structure assignment is an ownership bug. The relevant questions are lifetime and whether the API copies data. [Official layout API](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavutil/channel_layout.h).

### P1: Invalid release of individual YUV planes

Location: `SGVideoFrame.m:39–60`.

`av_image_alloc()` allocates one block with planes pointing into its interior. The old code wraps each plane in a separate default-free `AVBufferRef`, recording only a row's width as size. Releasing frames can free interior addresses, and buffer ranges are incorrect.

Use `av_frame_get_buffer()`, or one owner for the entire allocation with appropriate data/linesize pointers. Return allocation errors instead of dereferencing null buffers. [Allocation contract](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavutil/imgutils.h).

### P1: Uninitialized VideoToolbox device and unreliable fallback

Location: `SGCodecContext.m:152–183`.

The old code calls `av_hwdevice_ctx_alloc()` and assigns the result without `av_hwdevice_ctx_init()`. Use `av_hwdevice_ctx_create()`, or explicit allocation/initialization with error checks. Handle existing references when `get_format` runs repeatedly.

Returning `fmt[0]` after hardware selection fails may choose hardware again. Explicitly select a supported software format accepted by scaling/rendering, or return `AV_PIX_FMT_NONE`. Keep FFmpeg's automatic frame-pool management before considering the commented custom frames context. [Hardware context contract](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavutil/hwcontext.h).

### P2: Channel and plane bounds

Locations: `SGFrame.h:13`, `SGAudioFrame.m:39–47,123–126`, `SGSWResample.m:63–80`, `SGAudioDecoder.m:211`.

The player uses eight fixed planes and `frame->data` instead of full `extended_data`. Planar audio over eight channels risks out-of-bounds access or dropped planes. Either enforce an explicit channel limit at entry or migrate the entire path to dynamic planes and `extended_data`; changing allocation alone is insufficient.

Check failures and size overflow from `swr_get_out_samples()`, `av_buffer_realloc()` and related functions before passing negative sizes or null pointers to read/write paths.

### P2: Decoder results, invalid timestamps and obsolete options

Locations: `SGCodecContext.m:80–98,132–135`, `SGFrame.m:116–118`, `SGAudioFrame.m:87–89`, `SGAudioDecoder.m:199`.

- Retain send/receive. On send EAGAIN, drain output before retrying the original packet. Do not discard every negative return as an empty result. Existing code normally drains output, so this finding alone does not establish routine packet loss; verify failure paths and EOF drain.
- `best_effort_timestamp` and `pkt_dts` remain available, but check `AV_NOPTS_VALUE` before CMTime conversion. Define zero-duration fallback, especially for variable-frame-rate video and audio tails.
- `refcounted_frames` is absent from the new decoder option table. Discarding unconsumed options hides invalid settings. Remove the internal option; if retaining the public property were considered, its compatibility semantics would need explicit definition. Report unrecognized options during debugging.

Sources: [Decoder state machine](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/avcodec.h), [option table](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/options_table.h). The later implementation removes the public property; this paragraph records the earlier audit recommendation.

## 5. Interfaces and behavior that can remain

| Module | Existing usage | 9.0.2 audit result |
|---|---|---|
| Demuxing | `avformat_open_input/find_stream_info/read_frame/seek_file/close_input`, `stream->codecpar` | Syntax passed; network/seek regression still required |
| Decoding | `const AVCodec *`, `avcodec_parameters_to_context`, send/receive/flush/free | No need for legacy decode APIs; complete error-state handling |
| Layouts | `ch_layout`, default/compare, `swr_alloc_set_opts2` | Already modern APIs; fix copying/lifetimes |
| Resampling | `swr_init/convert/get_delay/get_out_samples/free` | Syntax passed; numerically test samples, delay and tails |
| Scaling | `sws_getCachedContext/sws_scale/freeContext` | Syntax passed; no mandatory SwsContext redesign |
| Frames/packets | alloc/ref/unref/free, `frame->duration`, `pkt_dts` | Still available; replace `pkt_size` |
| VideoToolbox output | `AV_PIX_FMT_VIDEOTOOLBOX`, CVPixelBuffer in `frame->data[3]` | Official implementation retains this representation; hold the AVFrame reference for lifetime |
| Logs/dictionaries/time | `av_log_*`, `av_dict_*`, `av_rescale*` | Syntax passed |

The audit found no interface evidence requiring a Metal or AudioToolbox architecture rewrite. New decoders do not automatically add render formats, HDR mapping or hardware support. Check HEVC Main10/P010 output, conversion and color rendering separately.

## 6. Build and TLS decisions

1. When using the official repository, use `n9.0.2` instead of the fork's `7.0.1` tag convention, after auditing fork patches. Do not assume equivalent tags/patches.
2. Reconcile architecture lists across FFmpeg/OpenSSL initialization and compilation scripts. Device/simulator arm64 cannot share a fat archive; lipo each platform variant separately, then package XCFrameworks.
3. Old CPU-dispatched `avconfig.h/ffversion.h/config.h` do not distinguish device/simulator. Give each slice matching independent headers.
4. FFmpeg 9.0.2 still probes OpenSSL >=1.1.1, so OpenSSL 3 is not an established compilation requirement. Retaining an old TLS library and selecting a maintained TLS strategy are separate decisions. GPL/nonfree are disabled; recheck the final combination if license flags change.
5. Old scripts explicitly enable OpenSSL only when `libssl.a` exists; automatic backend detection may otherwise vary. Record the actual backend and independently test HTTPS, TLS HLS and RTMPS rather than inferring support from a file.
6. Review `-fembed-bitcode`, fixed `make -j12` and disabled Intel assembly as modernization/performance items, not all as confirmed failures. Measure architecture performance and minimum-OS compatibility.

Source: [9.0.2 configure/OpenSSL checks](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/configure).

## 7. Suggested execution order and acceptance gates

1. Preserve the actual 7.0.1 fork revision, patches, libraries, configuration and representative media baseline for rollback.
2. Integrate official 9.0.2 in a separate version directory; fix postproc/configuration caching; build required platforms/slices and verify matching versions.
3. Replace `pkt_size`, repair layout ownership/video allocation, define accounting semantics and complete failure paths.
4. Repair hardware initialization/fallback, decoder errors, invalid timestamps and channel bounds.
5. Compile, link, run and compare all targets/demos before switching the default dependency. Keep TLS changes independently comparable.

| Acceptance group | Minimum coverage | Passing criteria |
|---|---|---|
| Build | Three platforms, required simulators, dual-architecture macOS, Debug/Release | Clean consistent builds, no old ABI mixing, demo links |
| Software video | H.264 B-frames, HEVC, YUV420P/NV12, odd dimensions, variable frame rate, screenshots | Reasonable frame/duration comparisons, no invalid frees or corruption |
| Hardware | H.264/HEVC/Main10, fallback, resolution changes | Record actual hardware use; no crash/reference growth during rebuild/fallback |
| Audio | AAC/MP3/FLAC; mono/stereo/5.1/7.1/custom; oversized layouts | Correct channel order, independent copies after source reuse, explicit oversized-input handling |
| Resampling/speed | 44.1↔48 kHz, planar↔packed, 0.5/1/2x, EOF | Samples/durations match delay/rounding policy without lost tails or drift |
| Containers/time | MP4/MKV/TS, missing PTS/DTS, nonzero start, EOF/seek/repeated seek | Valid synchronized time and decoding after seek |
| Network | HTTP/HTTPS/HLS, RTSP, RTMP/RTMPS, disconnect/reconnect/cancel | Explicit backend/options, effective timeouts/cancellation, no indefinite opening/reading |
| Memory/stress | Pools, layout copies, repeated open/close, track switching, long playback | No bounds/UAF/invalid-free findings; stable memory |
| Minimum OS | Oldest supported and current iOS/tvOS/macOS | Start/play on actual systems without missing symbols or incompatible formats |

The proposed release gate was fixing both reproduced blockers, testing P1 ownership/hardware repairs and passing production builds with representative playback. The historical audit established a manageable migration scope, not satisfaction of every acceptance gate. Current passed checks and remaining gaps are recorded separately in the [test record](ffmpeg-9.0.2-testing.en.md).
