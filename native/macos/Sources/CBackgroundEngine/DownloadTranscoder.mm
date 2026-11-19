#import "include/BackgroundEngine.h"
#include "NativeJobContext.hpp"
#include "FFmpegHeaders.hpp"
#import <Foundation/Foundation.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/samplefmt.h>
#include <libswscale/swscale.h>
}
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {
void checked(int result, const char *operation) {
    if (result >= 0) return;
    char detail[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(result, detail, sizeof(detail));
    throw std::runtime_error(std::string(operation) + ": " + detail);
}
void checkCancellation(fillr_background_context *context) {
    if (context->cancelled.load()) throw std::runtime_error("Download transcode cancelled");
}
char *reportJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if (!data) return strdup("{\"status\":\"failed\",\"error\":\"Cannot serialize transcode report\"}");
    char *result = static_cast<char *>(malloc(data.length + 1));
    if (result) { memcpy(result, data.bytes, data.length); result[data.length] = 0; }
    return result;
}
struct FrameDelete { void operator()(AVFrame *value) const { av_frame_free(&value); } };
struct PacketDelete { void operator()(AVPacket *value) const { av_packet_free(&value); } };
using Frame = std::unique_ptr<AVFrame, FrameDelete>;
using Packet = std::unique_ptr<AVPacket, PacketDelete>;
Frame frame() {
    Frame result(av_frame_alloc());
    if (!result) throw std::bad_alloc();
    return result;
}
Packet packet() {
    Packet result(av_packet_alloc());
    if (!result) throw std::bad_alloc();
    return result;
}
struct Input {
    AVFormatContext *value = nullptr;
    explicit Input(const char *path) {
        checked(avformat_open_input(&value, path, nullptr, nullptr), "Open source media");
        try { checked(avformat_find_stream_info(value, nullptr), "Read source streams"); }
        catch (...) { avformat_close_input(&value); throw; }
    }
    ~Input() { avformat_close_input(&value); }
};
struct Track {
    AVStream *input = nullptr, *output = nullptr;
    AVCodecContext *decoder = nullptr, *encoder = nullptr;
    SwsContext *scaler = nullptr;
    int64_t frames = 0, samples = 0;
    int64_t endTimestamp = AV_NOPTS_VALUE;
    std::vector<int64_t> timestamps;
    std::vector<int> fieldFlags;
    ~Track() { avcodec_free_context(&decoder); avcodec_free_context(&encoder); sws_freeContext(scaler); }
};
void openDecoder(Track &track) {
    const AVCodec *codec = avcodec_find_decoder(track.input->codecpar->codec_id);
    if (!codec) throw std::runtime_error("The built-in transcoder cannot decode a source audio/video codec");
    track.decoder = avcodec_alloc_context3(codec);
    if (!track.decoder) throw std::bad_alloc();
    checked(avcodec_parameters_to_context(track.decoder, track.input->codecpar), "Configure source decoder");
    track.decoder->pkt_timebase = track.input->time_base;
    // Broadcaster MPEG-2 legitimately carries extra zero-filled slice padding.
    // AV_EF_BITSTREAM rejects that padding; CRC/buffer/decode errors remain fatal.
    track.decoder->err_recognition = AV_EF_CRCCHECK | AV_EF_BUFFER | AV_EF_EXPLODE;
    track.decoder->thread_count = 2;
    checked(avcodec_open2(track.decoder, codec, nullptr), "Open source decoder");
}
// Keep the exclusive descriptor open for the entire mux. Custom AVIO avoids
// reopening a path and accidentally truncating a different file after a race.
struct Output {
    AVFormatContext *format = nullptr;
    AVIOContext *io = nullptr;
    int fd = -1;
    std::string path;
    struct stat identity {};
    bool keep = false;
    static int write(void *opaque, const uint8_t *bytes, int count) {
        auto self = static_cast<Output *>(opaque);
        int offset = 0;
        while (offset < count) {
            ssize_t result = ::write(self->fd, bytes + offset, count - offset);
            if (result < 0 && errno == EINTR) continue;
            if (result <= 0) return AVERROR(errno ? errno : EIO);
            offset += static_cast<int>(result);
        }
        return count;
    }
    static int64_t seek(void *opaque, int64_t offset, int whence) {
        auto self = static_cast<Output *>(opaque);
        if (whence == AVSEEK_SIZE) {
            struct stat info {};
            return fstat(self->fd, &info) == 0 ? info.st_size : AVERROR(errno);
        }
        off_t result = lseek(self->fd, offset, whence & ~AVSEEK_FORCE);
        return result < 0 ? AVERROR(errno) : result;
    }
    explicit Output(const char *destination) : path(destination) {
        // Allocation happens before reservation; constructor failure cannot
        // leave a reserved file or native context behind.
        checked(avformat_alloc_output_context2(&format, nullptr, "mov", destination), "Create MOV muxer");
        fd = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (fd < 0) { avformat_free_context(format); format = nullptr; throw std::runtime_error("Cannot create a new provisional output: " + std::string(strerror(errno))); }
        if (fstat(fd, &identity) != 0) { close(fd); unlink(destination); avformat_free_context(format); format = nullptr; throw std::runtime_error("Cannot identify provisional output"); }
        auto buffer = static_cast<uint8_t *>(av_malloc(64 * 1024));
        if (buffer) io = avio_alloc_context(buffer, 64 * 1024, 1, this, nullptr, &Output::write, &Output::seek);
        if (!io) {
            av_free(buffer); close(fd); unlink(destination); avformat_free_context(format); format = nullptr;
            throw std::bad_alloc();
        }
        format->pb = io;
        format->flags |= AVFMT_FLAG_CUSTOM_IO;
        format->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    }
    bool matchesPath() const {
        struct stat current {};
        return lstat(path.c_str(), &current) == 0 && current.st_dev == identity.st_dev && current.st_ino == identity.st_ino;
    }
    ~Output() {
        avformat_free_context(format);
        if (io) { av_freep(&io->buffer); avio_context_free(&io); }
        if (fd >= 0) close(fd);
        if (!keep && matchesPath()) unlink(path.c_str());
    }
};
void prepareEncoder(Track &track, AVFormatContext *destination, AVFormatContext *source) {
    bool video = track.input->codecpar->codec_type == AVMEDIA_TYPE_VIDEO;
    const AVCodec *codec = video ? avcodec_find_encoder_by_name("prores_ks") : avcodec_find_encoder(AV_CODEC_ID_PCM_S24LE);
    if (!codec) throw std::runtime_error("The built-in ProRes LT/PCM encoder is missing");
    track.encoder = avcodec_alloc_context3(codec);
    if (!track.encoder) throw std::bad_alloc();
    AVCodecContext *encoder = track.encoder, *decoder = track.decoder;
    if (video) {
        encoder->width = decoder->width;
        encoder->height = decoder->height;
        if (encoder->width <= 0 || encoder->height <= 0 || encoder->width % 2)
            throw std::runtime_error("Source dimensions are invalid for ProRes 4:2:2");
        encoder->pix_fmt = AV_PIX_FMT_YUV422P10LE;
        encoder->profile = AV_PROFILE_PRORES_LT;
        // prores_ks owns a private profile option in addition to AVCodecContext.
        // Leaving that option automatic selects HQ even when context.profile=LT.
        checked(av_opt_set_int(encoder->priv_data, "profile", AV_PROFILE_PRORES_LT, 0), "Select ProRes LT profile");
        encoder->time_base = track.input->time_base;
        encoder->framerate = av_guess_frame_rate(source, track.input, nullptr);
        if (encoder->framerate.num <= 0 || encoder->framerate.den <= 0 || encoder->time_base.num <= 0 || encoder->time_base.den <= 0)
            throw std::runtime_error("Source has no reliable video timebase or frame rate");
        encoder->sample_aspect_ratio = decoder->sample_aspect_ratio;
        encoder->field_order = decoder->field_order;
        encoder->color_range = decoder->color_range;
        encoder->color_primaries = decoder->color_primaries;
        encoder->color_trc = decoder->color_trc;
        encoder->colorspace = decoder->colorspace;
        encoder->chroma_sample_location = decoder->chroma_sample_location;
        encoder->thread_count = std::min(8u, std::max(1u, NSProcessInfo.processInfo.activeProcessorCount > 1 ? static_cast<unsigned>(NSProcessInfo.processInfo.activeProcessorCount - 1) : 1u));
        if (encoder->field_order != AV_FIELD_UNKNOWN && encoder->field_order != AV_FIELD_PROGRESSIVE)
            encoder->flags |= AV_CODEC_FLAG_INTERLACED_DCT | AV_CODEC_FLAG_INTERLACED_ME;
    } else {
        encoder->sample_fmt = AV_SAMPLE_FMT_S32;
        encoder->sample_rate = decoder->sample_rate;
        if (encoder->sample_rate <= 0 || decoder->ch_layout.nb_channels <= 0)
            throw std::runtime_error("Source audio has no sample rate or channel layout");
        checked(av_channel_layout_copy(&encoder->ch_layout, &decoder->ch_layout), "Copy audio channel layout");
        if (encoder->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) {
            int channels = encoder->ch_layout.nb_channels;
            av_channel_layout_uninit(&encoder->ch_layout);
            av_channel_layout_default(&encoder->ch_layout, channels);
        }
        encoder->time_base = {1, encoder->sample_rate};
        encoder->bits_per_raw_sample = 24;
    }
    if (destination->oformat->flags & AVFMT_GLOBALHEADER) encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    checked(avcodec_open2(encoder, codec, nullptr), "Open transcode encoder");
    track.output = avformat_new_stream(destination, nullptr);
    if (!track.output) throw std::bad_alloc();
    track.output->time_base = encoder->time_base;
    track.output->avg_frame_rate = video ? encoder->framerate : AVRational{0, 1};
    checked(avcodec_parameters_from_context(track.output->codecpar, encoder), "Describe output stream");
    track.output->disposition = track.input->disposition;
    checked(av_dict_copy(&track.output->metadata, track.input->metadata, 0), "Preserve stream metadata");
}
int32_t audioSample(const uint8_t *bytes, AVSampleFormat format) {
    switch (format) {
        case AV_SAMPLE_FMT_U8: return (int32_t(*bytes) - 128) * 16777216;
        case AV_SAMPLE_FMT_S16: { int16_t value; memcpy(&value, bytes, sizeof(value)); return int32_t(value) * 65536; }
        case AV_SAMPLE_FMT_S32: { int32_t value; memcpy(&value, bytes, sizeof(value)); return value; }
        case AV_SAMPLE_FMT_S64: { int64_t value; memcpy(&value, bytes, sizeof(value)); return static_cast<int32_t>(value >> 32); }
        case AV_SAMPLE_FMT_FLT:
        case AV_SAMPLE_FMT_DBL: {
            double value;
            if (format == AV_SAMPLE_FMT_FLT) { float sample; memcpy(&sample, bytes, sizeof(sample)); value = sample; }
            else memcpy(&value, bytes, sizeof(value));
            if (!std::isfinite(value)) throw std::runtime_error("Source audio contains non-finite samples");
            return static_cast<int32_t>(std::clamp(value * 2147483648.0, -2147483648.0, 2147483647.0));
        }
        default: throw std::runtime_error("Unsupported source audio sample representation");
    }
}
Frame convert(Track &track, AVFrame *source) {
    Frame destination = frame();
    bool video = track.encoder->codec_type == AVMEDIA_TYPE_VIDEO;
    checked(av_frame_copy_props(destination.get(), source), "Preserve frame metadata");
    if (video) {
        if (source->width != track.encoder->width || source->height != track.encoder->height)
            throw std::runtime_error("Source video changes dimensions during the download");
        destination->format = track.encoder->pix_fmt;
        destination->width = source->width; destination->height = source->height;
        checked(av_frame_get_buffer(destination.get(), 32), "Allocate ProRes image");
        bool interlaced = source->flags & AV_FRAME_FLAG_INTERLACED;
        const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(static_cast<AVPixelFormat>(source->format));
        if (!description || (interlaced && source->height % (2 << description->log2_chroma_h)))
            throw std::runtime_error("Source field geometry cannot be converted without mixing interlaced fields");
        int conversionHeight = interlaced ? source->height / 2 : source->height;
        track.scaler = sws_getCachedContext(track.scaler, source->width, conversionHeight,
            static_cast<AVPixelFormat>(source->format), source->width, conversionHeight,
            track.encoder->pix_fmt, SWS_BICUBIC, nullptr, nullptr, nullptr);
        if (!track.scaler) throw std::runtime_error("Cannot prepare ProRes pixel conversion");
        // Convert range/transfer metadata without resizing or deinterlacing.
        const int *colors = sws_getCoefficients(source->colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709 : SWS_CS_DEFAULT);
        const int range = source->color_range == AVCOL_RANGE_JPEG ? 1 : 0;
        checked(sws_setColorspaceDetails(track.scaler, colors, range, colors, range, 0, 1 << 16, 1 << 16), "Configure video color conversion");
        // MPEG-2 4:2:0 fields represent different instants. Upsample each field
        // independently so chroma interpolation never mixes those instants.
        for (int field = 0; field < (interlaced ? 2 : 1); ++field) {
            const uint8_t *inputPlanes[4] = {};
            uint8_t *outputPlanes[4] = {};
            int inputStrides[4] = {}, outputStrides[4] = {};
            for (int plane = 0; plane < 4; ++plane) {
                if (source->data[plane]) inputPlanes[plane] = source->data[plane] + field * source->linesize[plane];
                if (destination->data[plane]) outputPlanes[plane] = destination->data[plane] + field * destination->linesize[plane];
                inputStrides[plane] = source->linesize[plane] * (interlaced ? 2 : 1);
                outputStrides[plane] = destination->linesize[plane] * (interlaced ? 2 : 1);
            }
            if (sws_scale(track.scaler, inputPlanes, inputStrides, 0, conversionHeight,
                          outputPlanes, outputStrides) != conversionHeight)
                throw std::runtime_error("ProRes pixel conversion did not produce a complete field/frame");
        }
    } else {
        bool layoutMatches = source->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC
            ? source->ch_layout.nb_channels == track.encoder->ch_layout.nb_channels
            : av_channel_layout_compare(&source->ch_layout, &track.encoder->ch_layout) == 0;
        if (source->sample_rate != track.encoder->sample_rate || !layoutMatches)
            throw std::runtime_error("Source audio changes sample rate or channels during the download");
        destination->format = AV_SAMPLE_FMT_S32;
        destination->sample_rate = source->sample_rate;
        destination->nb_samples = source->nb_samples;
        checked(av_channel_layout_copy(&destination->ch_layout, &track.encoder->ch_layout), "Preserve audio channels");
        checked(av_frame_get_buffer(destination.get(), 0), "Allocate PCM audio");
        AVSampleFormat sourceFormat = static_cast<AVSampleFormat>(source->format);
        AVSampleFormat packed = av_get_packed_sample_fmt(sourceFormat);
        int bytes = av_get_bytes_per_sample(sourceFormat), channels = source->ch_layout.nb_channels;
        if (bytes <= 0) throw std::runtime_error("Invalid source audio sample size");
        bool planar = av_sample_fmt_is_planar(sourceFormat);
        int32_t *samples = reinterpret_cast<int32_t *>(destination->data[0]);
        for (int sample = 0; sample < source->nb_samples; ++sample) {
            for (int channel = 0; channel < channels; ++channel) {
                const uint8_t *value = planar ? source->extended_data[channel] + size_t(sample) * bytes
                    : source->extended_data[0] + (size_t(sample) * channels + channel) * bytes;
                samples[size_t(sample) * channels + channel] = audioSample(value, packed);
            }
        }
    }
    int64_t timestamp = source->best_effort_timestamp;
    if (timestamp == AV_NOPTS_VALUE) timestamp = source->pts;
    destination->duration = av_rescale_q(source->duration, track.input->time_base, track.encoder->time_base);
    if (video && destination->duration <= 0)
        destination->duration = av_rescale_q(1, av_inv_q(track.encoder->framerate), track.encoder->time_base);
    if (timestamp == AV_NOPTS_VALUE) {
        // Raw MPEG-2 elementary streams have no container timestamps, and a
        // demuxer's final delayed picture can lack one. Preserve their known
        // fixed cadence from the preceding frame (or stream start).
        if (!video) throw std::runtime_error("A source audio frame has no presentation timestamp");
        destination->pts = track.endTimestamp != AV_NOPTS_VALUE ? track.endTimestamp
            : track.input->start_time != AV_NOPTS_VALUE
                ? av_rescale_q(track.input->start_time, track.input->time_base, track.encoder->time_base) : 0;
    } else destination->pts = av_rescale_q(timestamp, track.input->time_base, track.encoder->time_base);
    if (!track.timestamps.empty() && destination->pts <= track.timestamps.back())
        throw std::runtime_error("Source presentation timestamps are not strictly increasing");
    track.timestamps.push_back(destination->pts);
    track.fieldFlags.push_back(source->flags & (AV_FRAME_FLAG_INTERLACED | AV_FRAME_FLAG_TOP_FIELD_FIRST));
    track.endTimestamp = destination->pts + (video ? destination->duration : source->nb_samples);
    ++track.frames;
    if (!video) track.samples += source->nb_samples;
    return destination;
}
void drainEncoder(Track &track, AVFormatContext *output, AVFrame *value) {
    checked(avcodec_send_frame(track.encoder, value), "Submit encoder frame");
    Packet compressed = packet();
    while (true) {
        int result = avcodec_receive_packet(track.encoder, compressed.get());
        if (result == AVERROR_EOF || result == AVERROR(EAGAIN)) break;
        checked(result, "Encode ProRes/PCM packet");
        av_packet_rescale_ts(compressed.get(), track.encoder->time_base, track.output->time_base);
        compressed->stream_index = track.output->index;
        checked(av_interleaved_write_frame(output, compressed.get()), "Write transcode packet");
        av_packet_unref(compressed.get());
    }
}
void decodeAndEncode(Track &track, AVPacket *value, AVFormatContext *output, fillr_background_context *context) {
    checked(avcodec_send_packet(track.decoder, value), "Submit source packet");
    Frame decoded = frame();
    while (true) {
        checkCancellation(context);
        int result = avcodec_receive_frame(track.decoder, decoded.get());
        if (result == AVERROR_EOF || result == AVERROR(EAGAIN)) break;
        checked(result, "Fully decode source media");
        if (decoded->decode_error_flags || (decoded->flags & AV_FRAME_FLAG_CORRUPT)) throw std::runtime_error("Source contains a corrupt frame");
        Frame converted = convert(track, decoded.get());
        drainEncoder(track, output, converted.get());
        av_frame_unref(decoded.get());
    }
}
NSDictionary *verify(const char *path, const std::vector<std::unique_ptr<Track>> &sources, fillr_background_context *context) {
    Input input(path);
    if (input.value->nb_streams != sources.size()) throw std::runtime_error("Output audio/video stream count differs from source");
    std::vector<std::unique_ptr<Track>> tracks;
    for (unsigned index = 0; index < input.value->nb_streams; ++index) {
        auto track = std::make_unique<Track>(); track->input = input.value->streams[index];
        AVCodecParameters *parameters = track->input->codecpar;
        const Track &source = *sources[index];
        bool video = source.encoder->codec_type == AVMEDIA_TYPE_VIDEO;
        if (video) {
            if (parameters->codec_id != AV_CODEC_ID_PRORES || parameters->codec_tag != MKTAG('a','p','c','s') ||
                parameters->width != source.encoder->width || parameters->height != source.encoder->height)
                throw std::runtime_error("Output is not ProRes LT at the source dimensions");
        } else {
            bool layoutMatches = av_channel_layout_compare(&parameters->ch_layout, &source.encoder->ch_layout) == 0;
            // MOV commonly omits redundant mono/stereo channel-layout atoms.
            // An omitted layout is acceptable only for the standard layout
            // with the same channel count, never an arbitrary custom order.
            if (parameters->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC && parameters->ch_layout.nb_channels == source.encoder->ch_layout.nb_channels) {
                AVChannelLayout standard {};
                av_channel_layout_default(&standard, parameters->ch_layout.nb_channels);
                layoutMatches = av_channel_layout_compare(&standard, &source.encoder->ch_layout) == 0;
                av_channel_layout_uninit(&standard);
            }
            if (parameters->codec_id != AV_CODEC_ID_PCM_S24LE || parameters->sample_rate != source.encoder->sample_rate || !layoutMatches)
                throw std::runtime_error("Output audio codec, sample rate or channel layout differs from the promised PCM24 format: " +
                std::string(avcodec_get_name(parameters->codec_id)) + " " + std::to_string(parameters->sample_rate) + "Hz " +
                std::to_string(parameters->ch_layout.nb_channels) + " channels, layout " + std::to_string(parameters->ch_layout.order) +
                "; expected " + std::to_string(source.encoder->sample_rate) + "Hz " + std::to_string(source.encoder->ch_layout.nb_channels) +
                " channels, layout " + std::to_string(source.encoder->ch_layout.order));
        }
        openDecoder(*track); tracks.push_back(std::move(track));
    }
    auto receive = [&](Track &track, AVPacket *value) {
        checked(avcodec_send_packet(track.decoder, value), "Verify output packet");
        Frame decoded = frame();
        while (true) {
            checkCancellation(context);
            int result = avcodec_receive_frame(track.decoder, decoded.get());
            if (result == AVERROR_EOF || result == AVERROR(EAGAIN)) break;
            checked(result, "Fully decode ProRes LT output");
            if (decoded->decode_error_flags || (decoded->flags & AV_FRAME_FLAG_CORRUPT)) throw std::runtime_error("Output verification found a corrupt frame");
            ++track.frames; track.samples += decoded->nb_samples;
            int64_t pts = decoded->best_effort_timestamp;
            if (pts == AV_NOPTS_VALUE) throw std::runtime_error("Verified output frame has no timestamp");
            track.timestamps.push_back(pts);
            track.fieldFlags.push_back(decoded->flags & (AV_FRAME_FLAG_INTERLACED | AV_FRAME_FLAG_TOP_FIELD_FIRST));
            track.endTimestamp = pts + (track.decoder->codec_type == AVMEDIA_TYPE_AUDIO
                ? av_rescale_q(decoded->nb_samples, AVRational{1, decoded->sample_rate}, track.input->time_base)
                : decoded->duration);
            av_frame_unref(decoded.get());
        }
    };
    Packet compressed = packet();
    int result;
    while ((result = av_read_frame(input.value, compressed.get())) >= 0) {
        checkCancellation(context);
        if (compressed->flags & AV_PKT_FLAG_CORRUPT) throw std::runtime_error("Output verification found a corrupt packet");
        receive(*tracks.at(compressed->stream_index), compressed.get()); av_packet_unref(compressed.get());
    }
    if (result != AVERROR_EOF) checked(result, "Read complete output");
    NSMutableArray *audio = [NSMutableArray array];
    int64_t videoFrames = 0;
    for (size_t index = 0; index < tracks.size(); ++index) {
        Track &actual = *tracks[index]; const Track &expected = *sources[index];
        receive(actual, nullptr);
        if (expected.encoder->codec_type == AVMEDIA_TYPE_VIDEO) {
            if (actual.frames != expected.frames || actual.frames == 0)
                throw std::runtime_error("Output video frame count differs from the completely decoded source");
            videoFrames = actual.frames;
            for (size_t number = 0; number < actual.timestamps.size(); ++number) {
                if (actual.fieldFlags[number] != expected.fieldFlags[number])
                    throw std::runtime_error("Output changed the source interlace or field order");
                int64_t actualTime = av_rescale_q(actual.timestamps[number] - actual.timestamps.front(), actual.input->time_base, AV_TIME_BASE_Q);
                int64_t expectedTime = av_rescale_q(expected.timestamps[number] - expected.timestamps.front(), expected.encoder->time_base, AV_TIME_BASE_Q);
                if (std::llabs(actualTime - expectedTime) > 2)
                    throw std::runtime_error("Output changed the source video frame timing");
            }
        } else {
            if (actual.samples != expected.samples || actual.samples == 0)
                throw std::runtime_error("Output audio sample count differs from the completely decoded source");
            int64_t actualDuration = av_rescale_q(actual.endTimestamp - actual.timestamps.front(), actual.input->time_base, expected.encoder->time_base);
            int64_t expectedDuration = expected.endTimestamp - expected.timestamps.front();
            if (std::llabs(actualDuration - expectedDuration) > 1)
                throw std::runtime_error("Output changed the source audio duration");
            [audio addObject:@{@"stream":@(index), @"samples":@(actual.samples), @"sample_rate":@(expected.encoder->sample_rate), @"channels":@(expected.encoder->ch_layout.nb_channels)}];
        }
    }
    // Muxers may apply one common start offset. They may not shift audio
    // relative to video; compare each track's first presentation timestamp.
    NSMutableArray *synchronization = [NSMutableArray array];
    for (size_t index = 1; index < tracks.size(); ++index) {
        int64_t actualStart = av_rescale_q(tracks[index]->timestamps.front(), tracks[index]->input->time_base, AV_TIME_BASE_Q)
            - av_rescale_q(tracks[0]->timestamps.front(), tracks[0]->input->time_base, AV_TIME_BASE_Q);
        int64_t expectedStart = av_rescale_q(sources[index]->timestamps.front(), sources[index]->encoder->time_base, AV_TIME_BASE_Q)
            - av_rescale_q(sources[0]->timestamps.front(), sources[0]->encoder->time_base, AV_TIME_BASE_Q);
        // Both timestamps may be rounded to their audio sample clocks. The
        // reference stream can itself be audio when the source lists it first.
        auto samplePeriod = [](const Track &track) -> int64_t {
            return track.encoder->codec_type == AVMEDIA_TYPE_AUDIO
                ? (AV_TIME_BASE + track.encoder->sample_rate - 1) / track.encoder->sample_rate : 0;
        };
        int64_t tolerance = samplePeriod(*sources[index]) + samplePeriod(*sources[0]) + 2;
        if (std::llabs(actualStart - expectedStart) > tolerance)
            throw std::runtime_error("Output changed the source audio/video synchronization");
        [synchronization addObject:@{@"stream":@(index), @"reference_stream":@0,
            @"source_offset_microseconds":@(expectedStart), @"output_offset_microseconds":@(actualStart),
            @"tolerance_microseconds":@(tolerance)}];
    }
    return @{@"full_decode":@YES, @"source_full_decode":@YES, @"frame_count":@(videoFrames), @"audio_tracks":audio,
        @"synchronization":synchronization};
}
}

extern "C" char *fillr_download_transcode(fillr_background_context *context, const char *sourcePath, const char *outputPath) {
    @autoreleasepool {
        if (!context) return reportJSON(@{@"status":@"failed", @"error":@"Missing native transcode context"});
        std::unique_lock<std::mutex> operation(context->operation, std::try_to_lock);
        if (!operation.owns_lock()) return reportJSON(@{@"status":@"failed", @"error":@"Native context already has an active operation"});
        try {
            checkCancellation(context);
            if (!sourcePath || !outputPath || sourcePath[0] != '/' || outputPath[0] != '/')
                throw std::runtime_error("Absolute source and provisional output paths are required");
            struct stat sourceInfo {};
            if (lstat(sourcePath, &sourceInfo) != 0 || !S_ISREG(sourceInfo.st_mode))
                throw std::runtime_error("The completed download must be a regular file");
            Input input(sourcePath);
            std::vector<std::unique_ptr<Track>> tracks;
            std::vector<Track *> mapping(input.value->nb_streams, nullptr);
            unsigned videoCount = 0;
            std::string sourceCodec;
            Output output(outputPath);
            for (unsigned index = 0; index < input.value->nb_streams; ++index) {
                AVStream *stream = input.value->streams[index];
                if (stream->codecpar->codec_type != AVMEDIA_TYPE_VIDEO && stream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
                if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
                    if (++videoCount > 1) throw std::runtime_error("A download must contain exactly one video stream");
                    if (stream->codecpar->codec_id != AV_CODEC_ID_MPEG2VIDEO && stream->codecpar->codec_id != AV_CODEC_ID_PRORES)
                        throw std::runtime_error("Automatic ingest accepts MPEG-2 and ProRes source video");
                    sourceCodec = avcodec_get_name(stream->codecpar->codec_id);
                }
                auto track = std::make_unique<Track>(); track->input = stream;
                openDecoder(*track); prepareEncoder(*track, output.format, input.value);
                mapping[index] = track.get(); tracks.push_back(std::move(track));
            }
            if (videoCount != 1) throw std::runtime_error("The source download has no MPEG-2 or ProRes video stream");
            checked(av_dict_copy(&output.format->metadata, input.value->metadata, 0), "Preserve movie metadata");
            // Pinned FFmpeg chooses a movie timebase from all stream clocks,
            // preserving sub-millisecond A/V offsets in its edit lists.
            checked(avformat_write_header(output.format, nullptr), "Write ProRes LT MOV header");
            Packet compressed = packet();
            int result;
            while ((result = av_read_frame(input.value, compressed.get())) >= 0) {
                checkCancellation(context);
                if (compressed->flags & AV_PKT_FLAG_CORRUPT) throw std::runtime_error("Source download contains a corrupt packet");
                if (mapping.at(compressed->stream_index)) decodeAndEncode(*mapping[compressed->stream_index], compressed.get(), output.format, context);
                av_packet_unref(compressed.get());
            }
            if (result != AVERROR_EOF) checked(result, "Read complete source download");
            for (auto &track : tracks) {
                decodeAndEncode(*track, nullptr, output.format, context);
                if (track->frames == 0) throw std::runtime_error("A source audio/video stream decoded no complete frames");
                drainEncoder(*track, output.format, nullptr);
            }
            checked(av_write_trailer(output.format), "Finalize ProRes LT MOV");
            avio_flush(output.io);
            checked(output.io->error, "Flush ProRes LT output");
            if (fsync(output.fd) != 0) throw std::runtime_error("Cannot synchronize ProRes LT output to disk");
            if (!output.matchesPath()) throw std::runtime_error("Provisional output was replaced during transcoding");
            NSDictionary *verification = verify(outputPath, tracks, context);
            checkCancellation(context);
            struct stat finalSource {};
            if (lstat(sourcePath, &finalSource) != 0 || finalSource.st_dev != sourceInfo.st_dev || finalSource.st_ino != sourceInfo.st_ino ||
                finalSource.st_size != sourceInfo.st_size || finalSource.st_mtimespec.tv_sec != sourceInfo.st_mtimespec.tv_sec ||
                finalSource.st_mtimespec.tv_nsec != sourceInfo.st_mtimespec.tv_nsec)
                throw std::runtime_error("Source download changed during transcoding");
            if (!output.matchesPath()) throw std::runtime_error("Provisional output was replaced during verification");
            output.keep = true;
            return reportJSON(@{@"status":@"complete", @"source_codec":[NSString stringWithUTF8String:sourceCodec.c_str()],
                @"codec":@"prores", @"profile":@"LT", @"encoder":@"prores_ks", @"verification":verification});
        } catch (const std::exception &error) {
            return reportJSON(@{@"status":context->cancelled.load() ? @"cancelled" : @"failed", @"error":[NSString stringWithUTF8String:error.what()] ?: @"Native transcode failed"});
        } catch (...) {
            return reportJSON(@{@"status":@"failed", @"error":@"Unknown native transcode failure"});
        }
    }
}
