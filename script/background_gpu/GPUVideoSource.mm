#import "GPUVideoSource.hpp"
#import "GPUDeinterlacer.hpp"
#import "GPUProResDecoder.hpp"
#import <VideoToolbox/VideoToolbox.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/videotoolbox.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
}
#include <cmath>
#include <sstream>
#include <stdexcept>
#include <string>

namespace {
constexpr AVRational kFrameTime = {1001, 30000};
std::string avError(int code) {
    char text[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(code, text, sizeof(text));
    return text;
}
void checked(int code, const std::string &operation) {
    if (code < 0) throw std::runtime_error(operation + ": " + avError(code));
}
CMVideoCodecType nativeCodec(AVCodecID codec, uint32_t tag) {
    switch (codec) {
        case AV_CODEC_ID_PRORES:
            // FFmpeg codec_tag is a little-endian fourcc; CoreMedia uses BE.
            return tag ? ((tag & 255) << 24) | ((tag & 0xff00) << 8) |
                         ((tag & 0xff0000) >> 8) | ((tag >> 24) & 255)
                       : kCMVideoCodecType_AppleProRes422HQ;
        case AV_CODEC_ID_MPEG2VIDEO: return kCMVideoCodecType_MPEG2Video;
        case AV_CODEC_ID_H264: return kCMVideoCodecType_H264;
        case AV_CODEC_ID_HEVC: return kCMVideoCodecType_HEVC;
        default: return 0;
    }
}
}

struct GPUSource::Impl {
    NSDictionary *__strong panel;
    NSArray *__strong segments;
    NSMutableArray *__strong segmentStats;
    NSMutableDictionary *__strong currentStats;
    AVFormatContext *format = nullptr;
    AVCodecContext *decoder = nullptr;
    AVBufferRef *device = nullptr;
    AVBufferRef *uploadFrames = nullptr;
    SwsContext *packer = nullptr;
    std::unique_ptr<GPUDeinterlacer> deinterlacer;
    std::unique_ptr<GPUProResDecoder> proResDecoder;
    AVPacket *packet = nullptr;
    AVFrame *decoded = nullptr;
    AVFrame *lastInput = nullptr;
    AVFrame *previous = nullptr;
    AVFrame *current = nullptr;
    AVFrame *following = nullptr;
    size_t segmentIndex = 0;
    int streamIndex = -1;
    int64_t targetTimestamp = 0;
    int64_t wanted = 0, fed = 0, delivered = 0;
    int64_t totalReturned = 0, hardwareFrames = 0, cpuFrames = 0;
    int64_t interlacedFrames = 0, progressiveFrames = 0, topFirstFrames = 0;
    int64_t discardedFrames = 0, clonedFrames = 0;
    bool open = false, useHardware = false, hardwareSupported = false;
    bool nativeProRes = false;
    bool demuxEOF = false, decoderFlushed = false;
    bool trimmingSeekPreroll = false;
    std::string path, hardwareError;

    explicit Impl(NSDictionary *value) : panel([value copy]),
        segments([value[@"segments"] copy]), segmentStats([NSMutableArray array]) {
        if (![segments isKindOfClass:[NSArray class]] || !segments.count)
            throw std::runtime_error("GPU panel has no source segments");
        checked(av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                                       nullptr, nullptr, 0), "Create VT source device");
        packet = av_packet_alloc();
        decoded = av_frame_alloc();
        if (!packet || !decoded) throw std::runtime_error("Allocate source decode buffers");
    }
    ~Impl() {
        closeSegment();
        av_packet_free(&packet);
        av_frame_free(&decoded);
        av_buffer_unref(&device);
    }
    std::string context(const char *text) const {
        return "Comp " + std::to_string([panel[@"comp"] intValue]) + ": " + text + " (" + path + ")";
    }
    void closeSegment() {
        if (proResDecoder && currentStats) [currentStats addEntriesFromDictionary:proResDecoder->stats()];
        av_frame_free(&previous);
        av_frame_free(&current);
        av_frame_free(&following);
        av_frame_free(&lastInput);
        av_buffer_unref(&uploadFrames);
        sws_freeContext(packer);
        packer = nullptr;
        avcodec_free_context(&decoder);
        proResDecoder.reset();
        avformat_close_input(&format);
        if (packet) av_packet_unref(packet);
        if (decoded) av_frame_unref(decoded);
        open = false;
    }
    static AVPixelFormat chooseFormat(AVCodecContext *codec, const AVPixelFormat *formats) {
        Impl *self = static_cast<Impl *>(codec->opaque);
        for (const AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; ++p) {
            if (*p != AV_PIX_FMT_VIDEOTOOLBOX) continue;
            AVBufferRef *frames = nullptr;
            int ret = avcodec_get_hw_frames_parameters(codec, self->device,
                                                       AV_PIX_FMT_VIDEOTOOLBOX, &frames);
            if (ret >= 0) {
                auto *hw = reinterpret_cast<AVHWFramesContext *>(frames->data);
                hw->sw_format = AV_PIX_FMT_NV12;
                hw->initial_pool_size = 8;
                static_cast<AVVTFramesContext *>(hw->hwctx)->color_range = AVCOL_RANGE_MPEG;
                ret = av_hwframe_ctx_init(frames);
            }
            if (ret >= 0) {
                av_buffer_unref(&codec->hw_frames_ctx);
                codec->hw_frames_ctx = frames;
                return AV_PIX_FMT_VIDEOTOOLBOX;
            }
            av_buffer_unref(&frames);
            self->hardwareError = avError(ret);
            return AV_PIX_FMT_NONE;
        }
        self->hardwareError = "Decoder did not offer VideoToolbox frames";
        return AV_PIX_FMT_NONE;
    }
    void openSegment() {
        NSDictionary *segment = segments[segmentIndex];
        NSString *sourcePath = segment[@"path"];
        if (![sourcePath isKindOfClass:[NSString class]])
            throw std::runtime_error("GPU source segment has no path");
        path = sourcePath.fileSystemRepresentation;
        wanted = [segment[@"frames"] longLongValue];
        double sourceIn = [segment[@"source_in_seconds"] doubleValue];
        if (wanted < 1 || !std::isfinite(sourceIn) || sourceIn < 0)
            throw std::runtime_error(context("Invalid source segment budget"));
        fed = delivered = 0;
        demuxEOF = decoderFlushed = false;
        hardwareError.clear();
        checked(avformat_open_input(&format, path.c_str(), nullptr, nullptr), context("Open source"));
        checked(avformat_find_stream_info(format, nullptr), context("Inspect source"));
        streamIndex = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
        checked(streamIndex, context("Find video stream"));
        AVStream *stream = format->streams[streamIndex];
        AVRational rate = av_guess_frame_rate(format, stream, nullptr);
        if (rate.num > 0 && std::abs(av_q2d(rate) - av_q2d(av_inv_q(kFrameTime))) > .005)
            throw std::runtime_error(context("Source frame rate differs from template"));
        nativeProRes = stream->codecpar->codec_id == AV_CODEC_ID_PRORES;
        CMVideoCodecType type = nativeCodec(stream->codecpar->codec_id, stream->codecpar->codec_tag);
        if (nativeProRes) {
            // Direct ownership exposes the actual decoder session and makes
            // hardware a requirement, rather than FFmpeg's ProRes preference.
            proResDecoder = std::make_unique<GPUProResDecoder>(type, stream->codecpar->width,
                stream->codecpar->height, stream->codecpar->field_order);
        }
        hardwareSupported = type && VTIsHardwareDecodeSupported(type);
        useHardware = nativeProRes || hardwareSupported;
        if (nativeProRes) {
            uploadFrames = av_hwframe_ctx_alloc(device);
            if (!uploadFrames) throw std::runtime_error(context("Allocate native ProRes surface context"));
            auto *hw = reinterpret_cast<AVHWFramesContext *>(uploadFrames->data);
            hw->format = AV_PIX_FMT_VIDEOTOOLBOX;
            hw->sw_format = AV_PIX_FMT_NV12;
            hw->width = stream->codecpar->width;
            hw->height = stream->codecpar->height;
            static_cast<AVVTFramesContext *>(hw->hwctx)->color_range = AVCOL_RANGE_MPEG;
            checked(av_hwframe_ctx_init(uploadFrames), context("Initialize native ProRes surface context"));
        } else {
            const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
            if (!codec) throw std::runtime_error(context("No source decoder"));
            decoder = avcodec_alloc_context3(codec);
            if (!decoder) throw std::runtime_error(context("Allocate source decoder"));
            checked(avcodec_parameters_to_context(decoder, stream->codecpar), context("Copy decoder parameters"));
            decoder->pkt_timebase = stream->time_base;
            decoder->thread_count = 1;
            if (useHardware) {
                decoder->opaque = this;
                decoder->get_format = chooseFormat;
                decoder->hw_device_ctx = av_buffer_ref(device);
                if (!decoder->hw_device_ctx) throw std::runtime_error(context("Retain VT decoder device"));
            }
            checked(avcodec_open2(decoder, codec, nullptr), context("Open source decoder"));
        }
        int64_t start = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
        int64_t sourceFrame = std::llround(sourceIn / av_q2d(kFrameTime));
        targetTimestamp = start + av_rescale_q(sourceFrame, kFrameTime, stream->time_base);
        trimmingSeekPreroll = sourceFrame > 0;
        if (sourceFrame > 0) {
            checked(av_seek_frame(format, streamIndex, targetTimestamp, AVSEEK_FLAG_BACKWARD),
                    context("Seek source"));
            if (decoder) avcodec_flush_buffers(decoder);
        }
        currentStats = [@{@"path": sourcePath, @"source_in_seconds": @(sourceIn),
                           @"planned_frames": @(wanted), @"returned_frames": @0,
                           @"hardware_decode_supported": @(hardwareSupported),
                           @"decoder": nativeProRes ? @"native_videotoolbox_prores_hardware_required" :
                                        (useHardware ? @"videotoolbox_hardware_capable" : @"libavcodec_cpu"),
                           @"decoder_threads": @1,
                           @"reported_hardware_decoder": [NSNull null],
                           @"hardware_backend_query_attempted": @NO,
                           @"codec": @(avcodec_get_name(stream->codecpar->codec_id)),
                           @"cpu_nv12_pack_frames": @0, @"interlaced_input_frames": @0,
                           @"progressive_input_frames": @0, @"cloned_final_frames": @0} mutableCopy];
        [segmentStats addObject:currentStats];
        open = true;
    }
    static void releaseNativePixel(void *opaque, uint8_t *) {
        CVPixelBufferRelease(static_cast<CVPixelBufferRef>(opaque));
    }
    bool decodeNativeProRes() {
        for (;;) {
            av_frame_unref(decoded);
            av_packet_unref(packet);
            int ret = av_read_frame(format, packet);
            if (ret == AVERROR_EOF) return false;
            checked(ret, context("Read ProRes packet"));
            if (packet->stream_index != streamIndex) continue;
            if (packet->flags & AV_PKT_FLAG_CORRUPT)
                throw std::runtime_error(context("Demuxer marked a ProRes packet corrupt"));
            if (trimmingSeekPreroll) {
                if (packet->pts == AV_NOPTS_VALUE)
                    throw std::runtime_error(context("ProRes seek packet has no timestamp"));
                if (packet->pts + 1 < targetTimestamp) { ++discardedFrames; continue; }
                trimmingSeekPreroll = false;
            }
            GPUProResFrame frame = proResDecoder->decode(packet->data, packet->size, fed);
            AVBufferRef *owner = av_buffer_create(reinterpret_cast<uint8_t *>(frame.pixel), 1,
                                                  releaseNativePixel, frame.pixel, 0);
            if (!owner) {
                CVPixelBufferRelease(frame.pixel);
                throw std::runtime_error(context("Retain native ProRes output surface"));
            }
            decoded->buf[0] = owner;
            decoded->data[3] = reinterpret_cast<uint8_t *>(frame.pixel);
            decoded->format = AV_PIX_FMT_VIDEOTOOLBOX;
            decoded->width = static_cast<int>(CVPixelBufferGetWidth(frame.pixel));
            decoded->height = static_cast<int>(CVPixelBufferGetHeight(frame.pixel));
            decoded->pts = decoded->best_effort_timestamp = packet->pts;
            decoded->hw_frames_ctx = av_buffer_ref(uploadFrames);
            if (!decoded->hw_frames_ctx) throw std::runtime_error(context("Retain native ProRes surface context"));
            if (frame.interlaced) decoded->flags |= AV_FRAME_FLAG_INTERLACED;
            if (frame.topFieldFirst) decoded->flags |= AV_FRAME_FLAG_TOP_FIELD_FIRST;
            if (![currentStats[@"hardware_backend_query_attempted"] boolValue])
                [currentStats addEntriesFromDictionary:proResDecoder->stats()];
            av_packet_unref(packet);
            return true;
        }
    }
    bool decodeNext() {
        if (nativeProRes) return decodeNativeProRes();
        for (;;) {
            av_frame_unref(decoded);
            int ret = avcodec_receive_frame(decoder, decoded);
            if (ret == 0) {
                int64_t pts = decoded->best_effort_timestamp;
                if (trimmingSeekPreroll) {
                    if (pts == AV_NOPTS_VALUE)
                        throw std::runtime_error(context("Seek preroll frame has no presentation timestamp"));
                    // One tick of tolerance avoids rejecting a rounded exact-frame seek.
                    if (pts + 1 < targetTimestamp) {
                        ++discardedFrames;
                        continue;
                    }
                    trimmingSeekPreroll = false;
                }
                if (decoded->decode_error_flags || (decoded->flags & AV_FRAME_FLAG_CORRUPT))
                    throw std::runtime_error(context("Source decoder marked a planned frame corrupt"));
                return true;
            }
            if (ret == AVERROR_EOF) return false;
            if (ret != AVERROR(EAGAIN))
                throw std::runtime_error(context("Decode source") + ": " + avError(ret) +
                                         (hardwareError.empty() ? "" : "; " + hardwareError));
            if (demuxEOF) {
                if (decoderFlushed) throw std::runtime_error(context("Decoder stalled after EOF"));
                checked(avcodec_send_packet(decoder, nullptr), context("Flush decoder"));
                decoderFlushed = true;
                continue;
            }
            for (;;) {
                av_packet_unref(packet);
                ret = av_read_frame(format, packet);
                if (ret == AVERROR_EOF) {
                    demuxEOF = true;
                    break;
                }
                checked(ret, context("Read source packet"));
                if (packet->stream_index != streamIndex) continue;
                ret = avcodec_send_packet(decoder, packet);
                av_packet_unref(packet);
                checked(ret, context("Send source packet"));
                break;
            }
        }
    }
    AVFrame *hardwareFrame() {
        AVFrame *result = av_frame_alloc();
        if (!result) throw std::runtime_error(context("Allocate GPU input frame"));
        try {
            if (decoded->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                checked(av_frame_ref(result, decoded), context("Retain decoded GPU frame"));
                ++hardwareFrames;
                if (![currentStats[@"hardware_backend_query_attempted"] boolValue]) {
                    currentStats[@"hardware_backend_query_attempted"] = @YES;
                    AVVideotoolboxContext *vt = static_cast<AVVideotoolboxContext *>(decoder->hwaccel_context);
                    if (vt && vt->session) {
                        CFTypeRef property = nullptr;
                        OSStatus status = VTSessionCopyProperty(vt->session,
                            kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                            kCFAllocatorDefault, &property);
                        currentStats[@"hardware_backend_query_status"] = @(status);
                        if (status == noErr && property && CFGetTypeID(property) == CFBooleanGetTypeID())
                            currentStats[@"reported_hardware_decoder"] = @(CFBooleanGetValue(static_cast<CFBooleanRef>(property)));
                        if (property) CFRelease(property);
                    } else {
                        currentStats[@"hardware_backend_query_limit"] = @"Public FFmpeg hwaccel_context does not expose internal VT session";
                    }
                }
            } else {
                if (useHardware) throw std::runtime_error(context("Hardware decoder returned CPU frame"));
                if (!uploadFrames) {
                    uploadFrames = av_hwframe_ctx_alloc(device);
                    if (!uploadFrames) throw std::runtime_error(context("Allocate VT upload pool"));
                    auto *hw = reinterpret_cast<AVHWFramesContext *>(uploadFrames->data);
                    hw->format = AV_PIX_FMT_VIDEOTOOLBOX;
                    hw->sw_format = AV_PIX_FMT_NV12;
                    hw->width = decoded->width;
                    hw->height = decoded->height;
                    hw->initial_pool_size = 8;
                    static_cast<AVVTFramesContext *>(hw->hwctx)->color_range = AVCOL_RANGE_MPEG;
                    checked(av_hwframe_ctx_init(uploadFrames), context("Initialize VT upload pool"));
                }
                AVFrame *packed = av_frame_alloc();
                if (!packed) throw std::runtime_error(context("Allocate CPU NV12 frame"));
                try {
                    packed->format = AV_PIX_FMT_NV12;
                    packed->width = decoded->width;
                    packed->height = decoded->height;
                    checked(av_frame_get_buffer(packed, 32), context("Allocate CPU NV12 storage"));
                    packer = sws_getCachedContext(packer, decoded->width, decoded->height,
                                                 static_cast<AVPixelFormat>(decoded->format),
                                                 decoded->width, decoded->height, AV_PIX_FMT_NV12,
                                                 SWS_BILINEAR, nullptr, nullptr, nullptr);
                    if (!packer) throw std::runtime_error(context("Configure same-size NV12 packing"));
                    int lines = sws_scale(packer, decoded->data, decoded->linesize, 0,
                                          decoded->height, packed->data, packed->linesize);
                    if (lines != decoded->height)
                        throw std::runtime_error(context("Incomplete same-size NV12 packing"));
                    checked(av_hwframe_get_buffer(uploadFrames, result, 0), context("Allocate VT input surface"));
                    checked(av_hwframe_transfer_data(result, packed, 0), context("Upload CPU-decoded NV12 surface"));
                    checked(av_frame_copy_props(result, decoded), context("Preserve decoded frame flags"));
                } catch (...) { av_frame_free(&packed); throw; }
                av_frame_free(&packed);
                ++cpuFrames;
                currentStats[@"cpu_nv12_pack_frames"] = @([currentStats[@"cpu_nv12_pack_frames"] longLongValue] + 1);
            }
            if (!result->hw_frames_ctx || !result->data[3])
                throw std::runtime_error(context("VT input surface lacks hardware ownership"));
            CVPixelBufferRef pixel = reinterpret_cast<CVPixelBufferRef>(result->data[3]);
            if (CVPixelBufferGetPixelFormatType(pixel) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                throw std::runtime_error(context("Decoder did not produce requested limited-range NV12"));
            if (!CVPixelBufferGetIOSurface(pixel))
                throw std::runtime_error(context("VT input is not IOSurface-backed"));
            if (result->flags & AV_FRAME_FLAG_INTERLACED) {
                ++interlacedFrames;
                if (result->flags & AV_FRAME_FLAG_TOP_FIELD_FIRST) ++topFirstFrames;
                currentStats[@"interlaced_input_frames"] = @([currentStats[@"interlaced_input_frames"] longLongValue] + 1);
            } else {
                ++progressiveFrames;
                currentStats[@"progressive_input_frames"] = @([currentStats[@"progressive_input_frames"] longLongValue] + 1);
            }
            // Match the existing renderer's explicit Rec.709 limited tagging.
            result->color_range = AVCOL_RANGE_MPEG;
            result->colorspace = AVCOL_SPC_BT709;
            result->color_primaries = AVCOL_PRI_BT709;
            result->color_trc = AVCOL_TRC_BT709;
            result->sample_aspect_ratio = AVRational{1, 1};
            result->pts = fed;
            result->time_base = kFrameTime;
            return result;
        } catch (...) { av_frame_free(&result); throw; }
    }
    AVFrame *plannedInput() {
        AVFrame *frame = nullptr;
        if (decodeNext()) {
            frame = hardwareFrame();
        } else if (lastInput && fed == wanted - 1) {
            frame = av_frame_clone(lastInput);
            if (!frame) throw std::runtime_error(context("Clone inclusive final source frame"));
            frame->pts = fed;
            ++clonedFrames;
            currentStats[@"cloned_final_frames"] = @1;
        } else {
            throw std::runtime_error(context("Source is materially shorter than planned cut") +
                                     "; received " + std::to_string(fed) +
                                     " of " + std::to_string(wanted) + " frames");
        }
        av_frame_free(&lastInput);
        lastInput = av_frame_clone(frame);
        if (!lastInput) { av_frame_free(&frame); throw std::runtime_error(context("Retain final cut frame")); }
        ++fed;
        return frame;
    }
    CVPixelBufferRef next() {
        while (segmentIndex < segments.count) {
            if (!open) openSegment();
            if (delivered == wanted) {
                closeSegment();
                ++segmentIndex;
                continue;
            }
            if (!current) {
                current = plannedInput();
                previous = av_frame_clone(current);
                if (!previous) throw std::runtime_error(context("Prime temporal deinterlace window"));
            }
            if (!following) {
                following = fed < wanted ? plannedInput() : av_frame_clone(current);
                if (!following) throw std::runtime_error(context("Complete temporal deinterlace window"));
            }
            CVPixelBufferRef pixel = reinterpret_cast<CVPixelBufferRef>(current->data[3]);
            CVPixelBufferRef result;
            if (current->flags & AV_FRAME_FLAG_INTERLACED) {
                if (!deinterlacer) deinterlacer = std::make_unique<GPUDeinterlacer>();
                result = deinterlacer->render(reinterpret_cast<CVPixelBufferRef>(previous->data[3]),
                                             pixel,
                                             reinterpret_cast<CVPixelBufferRef>(following->data[3]),
                                             (current->flags & AV_FRAME_FLAG_TOP_FIELD_FIRST) != 0);
            } else {
                result = CVPixelBufferRetain(pixel);
            }
            av_frame_free(&previous);
            previous = current;
            current = following;
            following = nullptr;
            ++delivered;
            ++totalReturned;
            currentStats[@"returned_frames"] = @(delivered);
            return result;
        }
        return nullptr;
    }
    NSDictionary *stats() const {
        if (proResDecoder && currentStats) [currentStats addEntriesFromDictionary:proResDecoder->stats()];
        return @{@"comp": panel[@"comp"] ?: @0, @"returned_frames": @(totalReturned),
                 @"videotoolbox_decoded_frames": @(hardwareFrames), @"cpu_decoded_nv12_packed_frames": @(cpuFrames),
                 @"interlaced_input_frames": @(interlacedFrames), @"progressive_input_frames": @(progressiveFrames),
                 @"top_field_first_input_frames": @(topFirstFrames), @"discarded_seek_preroll_frames": @(discardedFrames),
                 @"cloned_final_frames": @(clonedFrames),
                 @"deinterlace": @"Native Metal YADIF: send_frame, source parity, interlaced only",
                 @"cpu_packing": @"Same-size pixel-layout/chroma conversion only; no CPU scaling or compositing",
                 @"source_frame_cache": @NO, @"decoder_threads": @1,
                 @"hardware_decode_attribution": @"Native ProRes sessions require hardware and query the active backend; other VT codecs retain capability-only attribution when FFmpeg keeps its session private",
                 @"deinterlacer": deinterlacer ? deinterlacer->stats() : @{},
                 @"segments": [segmentStats copy]};
    }
};

GPUSource::GPUSource(NSDictionary *panel) : impl(std::make_unique<Impl>(panel)) {}
GPUSource::~GPUSource() = default;
CVPixelBufferRef GPUSource::next() { return impl->next(); }
NSDictionary *GPUSource::stats() const { return impl->stats(); }
