#import "include/BackgroundEngine.h"
#import "GPUVideoSource.hpp"
#import "GPUVideoEncoder.hpp"
#import "GPUCanvas.hpp"
#include "FFmpegHeaders.hpp"
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
}
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <thread>
#include <unistd.h>
#include <vector>

struct fillr_background_context {
    std::atomic<bool> cancelled{false};
    std::mutex operation;
};

namespace {
using Clock = std::chrono::steady_clock;
constexpr int FullFrames = 17982;
constexpr AVRational FrameTime = {1001, 30000};
double seconds(Clock::time_point since) {
    return std::chrono::duration<double>(Clock::now() - since).count();
}
std::runtime_error failure(const std::string &message) { return std::runtime_error(message); }
void checkAV(int status, const char *operation) {
    if (status < 0) {
        char detail[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(status, detail, sizeof(detail));
        throw failure(std::string(operation) + ": " + detail);
    }
}
void cancelled(fillr_background_context *context) {
    if (context->cancelled.load()) throw failure("Background build cancelled");
}
char *json(NSDictionary *object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:&error];
    if (!data) return strdup("{\"status\":\"failed\",\"error\":\"Cannot serialize native report\"}");
    auto result = static_cast<char *>(malloc(data.length + 1));
    if (!result) return nullptr;
    memcpy(result, data.bytes, data.length);
    result[data.length] = 0;
    return result;
}
NSDictionary *dictionary(const char *value, const char *name) {
    if (!value) throw failure(std::string("Missing ") + name);
    NSData *data = [NSData dataWithBytes:value length:strlen(value)];
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class]) throw failure(std::string("Invalid ") + name + " JSON");
    return object;
}
NSString *pathString(const char *value) {
    NSString *path = value ? [[NSString alloc] initWithUTF8String:value] : nil;
    if (!path.length || !path.isAbsolutePath) throw failure("An absolute local file path is required");
    return path;
}
int boundedInteger(NSDictionary *values, NSString *key, int fallback, int lower, int upper) {
    id value = values[key];
    if (!value) return fallback;
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        !std::isfinite([value doubleValue]) || floor([value doubleValue]) != [value doubleValue] ||
        [value doubleValue] < lower || [value doubleValue] > upper)
        throw failure(std::string("Invalid setting: ") + key.UTF8String);
    return [value intValue];
}
bool boolean(NSDictionary *values, NSString *key, bool fallback) {
    id value = values[key];
    if (!value) return fallback;
    if (CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID())
        throw failure(std::string("Invalid boolean setting: ") + key.UTF8String);
    return [value boolValue];
}
NSDictionary *settings(NSDictionary *input) {
    return @{@"hardware_decode": @(boolean(input, @"hardware_decode", true)),
        @"hardware_encode": @(boolean(input, @"hardware_encode", true)),
        @"decoder_threads": @(boundedInteger(input, @"decoder_threads", 1, 1, 16)),
        @"source_queue_frames": @(boundedInteger(input, @"source_queue_frames", 2, 1, 4)),
        @"encoder_inflight_frames": @(boundedInteger(input, @"encoder_inflight_frames", 8, 1, 8)),
        @"benchmark": @(boolean(input, @"benchmark", false))};
}

// Temporary output lives in a private sibling directory. link() publishes a
// verified result atomically and refuses an existing final path, including a
// path created while the render was running.
struct WorkingOutput {
    NSString *__strong directory;
    NSString *__strong temporary;
    NSString *__strong finalPath;
    explicit WorkingOutput(NSString *path) : finalPath([path copy]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) throw failure("Output video already exists");
        NSString *pattern = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@".fillr-background-XXXXXX"];
        std::vector<char> writable(pattern.fileSystemRepresentation, pattern.fileSystemRepresentation + strlen(pattern.fileSystemRepresentation) + 1);
        char *created = mkdtemp(writable.data());
        if (!created) throw failure(std::string("Cannot create background output directory: ") + strerror(errno));
        directory = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:created length:strlen(created)];
        temporary = [directory stringByAppendingPathComponent:@"render.mp4"];
    }
    void publish() {
        if (link(temporary.fileSystemRepresentation, finalPath.fileSystemRepresentation) != 0)
            throw failure(std::string("Cannot save verified background without overwriting: ") + strerror(errno));
    }
    ~WorkingOutput() {
        [[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
    }
};

struct FormatInput {
    AVFormatContext *format = nullptr;
    explicit FormatInput(const char *path, std::atomic<bool> *stop = nullptr) {
        format = avformat_alloc_context();
        if (!format) throw failure("Cannot allocate media input");
        if (stop) format->interrupt_callback = {[](void *opaque) -> int {
            return static_cast<std::atomic<bool> *>(opaque)->load() ? 1 : 0;
        }, stop};
        int result = avformat_open_input(&format, path, nullptr, nullptr);
        if (result < 0) { avformat_close_input(&format); checkAV(result, "Open video"); }
        result = avformat_find_stream_info(format, nullptr);
        if (result < 0) { avformat_close_input(&format); checkAV(result, "Read video metadata"); }
    }
    ~FormatInput() { avformat_close_input(&format); }
};

struct Decoder {
    AVCodecContext *codec = nullptr;
    AVPacket *packet = nullptr;
    AVFrame *frame = nullptr;
    ~Decoder() { avcodec_free_context(&codec); av_packet_free(&packet); av_frame_free(&frame); }
};

NSDictionary *verifyOutput(NSString *path, int expected, fillr_background_context *context) {
    FormatInput input(path.fileSystemRepresentation, &context->cancelled);
    AVFormatContext *format = input.format;
    int streamIndex = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    checkAV(streamIndex, "Find output video stream");
    AVStream *stream = format->streams[streamIndex];
    AVCodecParameters *parameters = stream->codecpar;
    for (unsigned n = 0; n < format->nb_streams; ++n)
        if (format->streams[n]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO)
            throw failure("The background output unexpectedly contains audio");
    AVRational rate = av_guess_frame_rate(format, stream, nullptr);
    if (parameters->codec_id != AV_CODEC_ID_H264 || parameters->width != 1920 || parameters->height != 1080 ||
        parameters->profile != AV_PROFILE_H264_HIGH || parameters->level != 42 ||
        av_cmp_q(rate, av_inv_q(FrameTime)) != 0 ||
        (stream->sample_aspect_ratio.num > 0 && av_cmp_q(stream->sample_aspect_ratio, AVRational{1, 1}) != 0))
        throw failure("Rendered background does not match the Chabot H.264 output format");
    Decoder decoder;
    const AVCodec *codec = avcodec_find_decoder(parameters->codec_id);
    if (!codec) throw failure("The bundled FFmpeg library has no H.264 verification decoder");
    decoder.codec = avcodec_alloc_context3(codec);
    decoder.packet = av_packet_alloc();
    decoder.frame = av_frame_alloc();
    if (!decoder.codec || !decoder.packet || !decoder.frame) throw failure("Cannot allocate output verifier");
    checkAV(avcodec_parameters_to_context(decoder.codec, parameters), "Configure output verifier");
    decoder.codec->thread_count = 2;
    decoder.codec->err_recognition = AV_EF_EXPLODE;
    checkAV(avcodec_open2(decoder.codec, codec, nullptr), "Start output verifier");
    int count = 0;
    auto receive = [&]() {
        for (;;) {
            cancelled(context);
            int result = avcodec_receive_frame(decoder.codec, decoder.frame);
            if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return;
            checkAV(result, "Decode rendered output");
            if (decoder.frame->decode_error_flags || (decoder.frame->flags & (AV_FRAME_FLAG_CORRUPT | AV_FRAME_FLAG_INTERLACED)))
                throw failure("Rendered output contains a corrupt or interlaced frame");
            if (decoder.frame->width != 1920 || decoder.frame->height != 1080 ||
                decoder.frame->color_range != AVCOL_RANGE_MPEG || decoder.frame->color_primaries != AVCOL_PRI_BT709 ||
                decoder.frame->color_trc != AVCOL_TRC_BT709 || decoder.frame->colorspace != AVCOL_SPC_BT709)
                throw failure("Rendered output frame format or Rec.709 colour metadata changed");
            if (++count > expected) throw failure("Rendered output contains too many frames");
            av_frame_unref(decoder.frame);
        }
    };
    for (;;) {
        cancelled(context);
        int result = av_read_frame(format, decoder.packet);
        if (result == AVERROR_EOF) break;
        checkAV(result, "Read rendered output");
        if (decoder.packet->stream_index == streamIndex) {
            if (decoder.packet->flags & AV_PKT_FLAG_CORRUPT) throw failure("Rendered output contains a corrupt packet");
            checkAV(avcodec_send_packet(decoder.codec, decoder.packet), "Feed output verifier");
            receive();
        }
        av_packet_unref(decoder.packet);
    }
    checkAV(avcodec_send_packet(decoder.codec, nullptr), "Drain output verifier");
    receive();
    if (count != expected) throw failure("Rendered output frame count does not match the complete job");
    double expectedDuration = expected * av_q2d(FrameTime);
    if (stream->duration == AV_NOPTS_VALUE || fabs(stream->duration * av_q2d(stream->time_base) - expectedDuration) > .001)
        throw failure("Rendered output duration differs from the complete frame count");
    return @{@"status": @"passed", @"full_decode": @YES, @"frame_count": @(count),
             @"duration_seconds": @(expectedDuration), @"width": @1920, @"height": @1080,
             @"frame_rate": @"30000/1001", @"codec": @"h264", @"silent": @YES,
             @"progressive": @YES, @"colour": @"limited-range Rec.709"};
}

struct PanelWorker {
    NSDictionary *__strong panel;
    NSDictionary *__strong options;
    NSDictionary *__strong statistics;
    fillr_background_context *context;
    const int expected;
    const size_t limit;
    std::atomic<bool> stopped{false};
    std::mutex mutex;
    std::condition_variable ready;
    std::deque<CVPixelBufferRef> frames;
    std::thread thread;
    std::string error;
    bool done = false;
    PanelWorker(NSDictionary *value, NSDictionary *settings, int count, fillr_background_context *owner)
        : panel([value copy]), options([settings copy]), context(owner), expected(count),
          limit([settings[@"source_queue_frames"] unsignedIntegerValue]) {}
    ~PanelWorker() { stop(); join(); for (auto frame : frames) CVPixelBufferRelease(frame); }
    void start() {
        thread = std::thread([this] {
            @autoreleasepool {
                try {
                    @try {
                        GPUSource source(panel, options, &context->cancelled);
                        for (int n = 0; n < expected && !stopped; ++n) {
                            @autoreleasepool {
                                cancelled(context);
                                std::unique_lock<std::mutex> lock(mutex);
                                while (!stopped && !context->cancelled && frames.size() >= limit)
                                    ready.wait_for(lock, std::chrono::milliseconds(100));
                                if (stopped || context->cancelled) break;
                                lock.unlock();
                                CVPixelBufferRef frame = source.next();
                                if (!frame) throw failure("Panel ended before the requested frame count");
                                lock.lock();
                                if (stopped || context->cancelled) { CVPixelBufferRelease(frame); break; }
                                frames.push_back(frame);
                                ready.notify_all();
                            }
                        }
                        statistics = source.stats();
                    } @catch (NSException *exception) {
                        throw failure(std::string("Native source error: ") + (exception.reason.UTF8String ?: "unknown exception"));
                    }
                } catch (const std::exception &exception) {
                    std::lock_guard<std::mutex> lock(mutex);
                    error = exception.what();
                } catch (...) {
                    std::lock_guard<std::mutex> lock(mutex);
                    error = "Unknown native source failure";
                }
                std::lock_guard<std::mutex> lock(mutex);
                done = true;
                ready.notify_all();
            }
        });
    }
    CVPixelBufferRef pop() {
        std::unique_lock<std::mutex> lock(mutex);
        while (frames.empty() && !done && !stopped && !context->cancelled)
            ready.wait_for(lock, std::chrono::milliseconds(100));
        cancelled(context);
        if (!error.empty()) throw failure(error);
        if (frames.empty()) throw failure("Source queue ended before the timeline");
        auto frame = frames.front(); frames.pop_front(); ready.notify_all(); return frame;
    }
    void stop() { { std::lock_guard<std::mutex> lock(mutex); stopped = true; } ready.notify_all(); }
    void join() { if (thread.joinable()) thread.join(); }
};

void validateJob(NSDictionary *job, NSDictionary *options) {
    int frames = boundedInteger(job, @"frames", 0, 1, FullFrames);
    if (frames < 1) throw failure("The Chabot job has no positive frame count");
    if (![options[@"benchmark"] boolValue] && frames != FullFrames)
        throw failure("A complete Chabot background requires exactly 17,982 frames");
    if (![job[@"frame_rate"] isEqual:@"30000/1001"] ||
        ![job[@"panels"] isKindOfClass:NSArray.class] || [job[@"panels"] count] != 15 ||
        ![job[@"bands"] isKindOfClass:NSArray.class] || [job[@"bands"] count] != 2)
        throw failure("Expected the existing Chabot layout: 15 panels, two crawls and 30000/1001 fps");
    for (id panel in job[@"panels"]) {
        if (![panel isKindOfClass:NSDictionary.class] || ![panel[@"segments"] isKindOfClass:NSArray.class] ||
            ![panel[@"segments"] count] || ![panel[@"geometry"] isKindOfClass:NSDictionary.class])
            throw failure("Invalid Chabot panel");
        NSDictionary *geometry = panel[@"geometry"];
        for (NSString *key in @[@"width", @"height", @"visible_width", @"visible_height", @"x", @"y"]) {
            id value = geometry[key];
            if (![value isKindOfClass:NSNumber.class] || !std::isfinite([value doubleValue]) ||
                [value doubleValue] < 0 || [value doubleValue] > 1920)
                throw failure("Invalid Chabot panel geometry");
        }
        if ([geometry[@"width"] intValue] < 1 || [geometry[@"height"] intValue] < 1 ||
            [geometry[@"visible_width"] intValue] < 1 || [geometry[@"visible_height"] intValue] < 1 ||
            [geometry[@"visible_width"] doubleValue] > [geometry[@"width"] doubleValue] ||
            [geometry[@"visible_height"] doubleValue] > [geometry[@"height"] doubleValue] ||
            [geometry[@"x"] doubleValue] + [geometry[@"visible_width"] doubleValue] > 1920 ||
            [geometry[@"y"] doubleValue] + [geometry[@"visible_height"] doubleValue] > 1080)
            throw failure("Chabot panel extends outside the output canvas");
        int total = 0;
        for (id segment in panel[@"segments"]) {
            if (![segment isKindOfClass:NSDictionary.class] || ![segment[@"path"] isKindOfClass:NSString.class] ||
                ![segment[@"path"] isAbsolutePath] || ![segment[@"source_in_seconds"] isKindOfClass:NSNumber.class] ||
                !std::isfinite([segment[@"source_in_seconds"] doubleValue]) || [segment[@"source_in_seconds"] doubleValue] < 0)
                throw failure("Invalid Chabot source segment");
            total += boundedInteger(segment, @"frames", 0, 1, FullFrames);
            if (total > FullFrames) throw failure("Chabot source timeline exceeds ten minutes");
        }
        if (total != frames) throw failure("Every Chabot panel must cover the exact job frame count");
    }
    for (id band in job[@"bands"]) {
        if (![band isKindOfClass:NSDictionary.class] || ![band[@"tile_path"] isKindOfClass:NSString.class] ||
            ![band[@"tile_path"] isAbsolutePath]) throw failure("Invalid Chabot crawl tile");
        for (NSString *key in @[@"height", @"source_height", @"y", @"start_x", @"speed"])
            if (![band[key] isKindOfClass:NSNumber.class] || !std::isfinite([band[key] doubleValue]) ||
                fabs([band[key] doubleValue]) > 100000)
                throw failure("Invalid Chabot crawl geometry or motion");
    }
}

double cpuSeconds(const timeval &time) { return time.tv_sec + time.tv_usec / 1e6; }

// Deterministic, moving interlaced MPEG-2 fallback exercises the same decoder,
// deinterlacer, scaling and 15-panel compositor as real footage.
void makeSample(NSString *path, int frames) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) throw failure("Built-in test footage already exists");
    AVFormatContext *format = nullptr;
    checkAV(avformat_alloc_output_context2(&format, nullptr, "mpeg2video", path.fileSystemRepresentation), "Create test footage container");
    struct OutputCleanup {
        AVFormatContext *value;
        ~OutputCleanup() { if (value) { if (value->pb) avio_closep(&value->pb); avformat_free_context(value); } }
    } cleanup{format};
    Decoder encoder;
    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_MPEG2VIDEO);
    if (!codec) throw failure("Bundled MPEG-2 fixture encoder is missing");
    encoder.codec = avcodec_alloc_context3(codec);
    encoder.packet = av_packet_alloc();
    encoder.frame = av_frame_alloc();
    if (!encoder.codec || !encoder.packet || !encoder.frame) throw failure("Cannot allocate built-in test encoder");
    auto context = encoder.codec;
    context->width = 1920; context->height = 1080;
    context->time_base = FrameTime; context->framerate = av_inv_q(FrameTime);
    context->pix_fmt = AV_PIX_FMT_YUV420P; context->bit_rate = 12000000;
    context->gop_size = 15; context->max_b_frames = 2; context->thread_count = 2;
    context->color_range = AVCOL_RANGE_MPEG; context->color_primaries = AVCOL_PRI_BT709;
    context->color_trc = AVCOL_TRC_BT709; context->colorspace = AVCOL_SPC_BT709;
    context->flags |= AV_CODEC_FLAG_INTERLACED_DCT | AV_CODEC_FLAG_INTERLACED_ME;
    checkAV(avcodec_open2(context, codec, nullptr), "Open built-in MPEG-2 encoder");
    AVStream *stream = avformat_new_stream(format, nullptr);
    if (!stream) throw failure("Cannot create built-in test stream");
    stream->time_base = FrameTime;
    checkAV(avcodec_parameters_from_context(stream->codecpar, context), "Set test stream metadata");
    checkAV(avio_open(&format->pb, path.fileSystemRepresentation, AVIO_FLAG_WRITE), "Open built-in test footage");
    checkAV(avformat_write_header(format, nullptr), "Write built-in test header");
    encoder.frame->width = context->width; encoder.frame->height = context->height;
    encoder.frame->format = context->pix_fmt;
    encoder.frame->flags |= AV_FRAME_FLAG_INTERLACED | AV_FRAME_FLAG_TOP_FIELD_FIRST;
    checkAV(av_frame_get_buffer(encoder.frame, 32), "Allocate built-in test pixels");
    auto drain = [&]() {
        for (;;) {
            int result = avcodec_receive_packet(context, encoder.packet);
            if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return;
            checkAV(result, "Encode built-in test footage");
            encoder.packet->stream_index = stream->index;
            av_packet_rescale_ts(encoder.packet, FrameTime, stream->time_base);
            checkAV(av_interleaved_write_frame(format, encoder.packet), "Write built-in test packet");
            av_packet_unref(encoder.packet);
        }
    };
    for (int n = 0; n < frames; ++n) {
        checkAV(av_frame_make_writable(encoder.frame), "Update built-in test pixels");
        for (int y = 0; y < 1080; ++y) {
            uint8_t *row = encoder.frame->data[0] + y * encoder.frame->linesize[0];
            for (int x = 0; x < 1920; ++x) row[x] = 16 + ((x / 16 + y / 16 + n * 3 + (y % 2)) % 220);
        }
        for (int y = 0; y < 540; ++y) {
            memset(encoder.frame->data[1] + y * encoder.frame->linesize[1], 96 + n % 64, 960);
            memset(encoder.frame->data[2] + y * encoder.frame->linesize[2], 128, 960);
        }
        encoder.frame->pts = n;
        checkAV(avcodec_send_frame(context, encoder.frame), "Feed built-in test encoder");
        drain();
    }
    checkAV(avcodec_send_frame(context, nullptr), "Drain built-in test encoder");
    drain();
    checkAV(av_write_trailer(format), "Finalize built-in test footage");
}

void blackTile(NSString *path, int width, int height) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) throw failure("Built-in crawl tile already exists");
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(nullptr, width, height, 8, width * 4, space, kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(space);
    if (!context) throw failure("Cannot allocate built-in crawl artwork");
    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, nullptr);
    bool success = image && destination;
    if (success) { CGImageDestinationAddImage(destination, image, nullptr); success = CGImageDestinationFinalize(destination); }
    if (destination) CFRelease(destination);
    if (image) CGImageRelease(image);
    if (!success) throw failure("Cannot save built-in crawl artwork");
}
}

extern "C" fillr_background_context *fillr_background_create(void) {
    try { return new fillr_background_context(); } catch (...) { return nullptr; }
}
extern "C" void fillr_background_cancel(fillr_background_context *context) { if (context) context->cancelled = true; }
extern "C" void fillr_background_destroy(fillr_background_context *context) { delete context; }
extern "C" void fillr_background_free_string(char *string) { free(string); }

extern "C" char *fillr_background_render(fillr_background_context *context, const char *jobJSON,
    const char *outputPath, const char *settingsJSON, fillr_background_progress progress, void *user) {
    @autoreleasepool {
        if (!context) return json(@{@"status": @"failed", @"error": @"Missing native render context"});
        std::unique_lock<std::mutex> operation(context->operation, std::try_to_lock);
        if (!operation.owns_lock()) return json(@{@"status": @"failed", @"error": @"This native context already has an active job"});
        NSMutableDictionary *report = [@{@"status": @"preparing", @"pipeline": @"native-metal-ffmpeg-videotoolbox", @"completed_frames": @0} mutableCopy];
        const auto started = Clock::now();
        rusage before{}; getrusage(RUSAGE_SELF, &before);
        std::vector<std::unique_ptr<PanelWorker>> workers;
        std::vector<CVPixelBufferRef> inputs;
        CVPixelBufferRef composed = nullptr;
        try {
            @try {
                cancelled(context);
                NSDictionary *job = dictionary(jobJSON, "job");
                NSDictionary *options = settings(dictionary(settingsJSON, "settings"));
                validateJob(job, options);
                NSString *finalPath = pathString(outputPath);
                WorkingOutput output(finalPath);
                int frames = [job[@"frames"] intValue];
                report[@"expected_frames"] = @(frames);
                report[@"settings"] = options;
                report[@"benchmark"] = options[@"benchmark"];
                GPUCanvas canvas(job[@"panels"], job[@"bands"]);
                GPUEncoder encoder(output.temporary, frames, options, &context->cancelled);
                for (NSDictionary *panel in job[@"panels"]) {
                    workers.emplace_back(std::make_unique<PanelWorker>(panel, options, frames, context));
                    workers.back()->start();
                }
                for (int n = 0; n < frames; ++n) {
                    @autoreleasepool {
                        cancelled(context);
                        for (auto &worker : workers) inputs.push_back(worker->pop());
                        composed = canvas.render(inputs, n);
                        for (auto frame : inputs) CVPixelBufferRelease(frame);
                        inputs.clear();
                        encoder.append(composed, n);
                        CVPixelBufferRelease(composed); composed = nullptr;
                        report[@"completed_frames"] = @(n + 1);
                        if (progress && (n % 15 == 0 || n + 1 == frames)) progress(user, n + 1, frames);
                    }
                }
                for (auto &worker : workers) worker->join();
                NSMutableArray *sources = [NSMutableArray array];
                for (auto &worker : workers) {
                    if (!worker->error.empty()) throw failure(worker->error);
                    if (!worker->frames.empty()) throw failure("Source frames remain after the complete timeline");
                    [sources addObject:worker->statistics ?: @{}];
                }
                encoder.finish();
                report[@"elapsed_seconds"] = @(seconds(started));
                rusage rendered{}; getrusage(RUSAGE_SELF, &rendered);
                report[@"cpu_user_seconds"] = @(cpuSeconds(rendered.ru_utime) - cpuSeconds(before.ru_utime));
                report[@"cpu_system_seconds"] = @(cpuSeconds(rendered.ru_stime) - cpuSeconds(before.ru_stime));
                NSMutableDictionary *encoderReport = [encoder.stats() mutableCopy];
                encoderReport[@"output_path"] = finalPath;
                report[@"encoder"] = encoderReport;
                report[@"canvas"] = canvas.stats();
                report[@"sources"] = sources;
                const auto verificationStarted = Clock::now();
                report[@"verification"] = verifyOutput(output.temporary, frames, context);
                report[@"verification_seconds"] = @(seconds(verificationStarted));
                cancelled(context);
                output.publish();
                report[@"output_path"] = finalPath;
                report[@"status"] = @"complete";
            } @catch (NSException *exception) {
                throw failure(std::string("Native background error: ") + (exception.reason.UTF8String ?: "unknown exception"));
            }
        } catch (const std::exception &exception) {
            report[@"status"] = context->cancelled ? @"cancelled" : @"failed";
            report[@"error"] = @(exception.what());
        } catch (...) {
            report[@"status"] = @"failed"; report[@"error"] = @"Unknown native background failure";
        }
        if (composed) CVPixelBufferRelease(composed);
        for (auto frame : inputs) CVPixelBufferRelease(frame);
        for (auto &worker : workers) worker->stop();
        for (auto &worker : workers) worker->join();
        rusage after{}; getrusage(RUSAGE_SELF, &after);
        report[@"total_elapsed_seconds"] = @(seconds(started));
        if (!report[@"elapsed_seconds"]) report[@"elapsed_seconds"] = report[@"total_elapsed_seconds"];
        if (!report[@"cpu_user_seconds"]) report[@"cpu_user_seconds"] = @(cpuSeconds(after.ru_utime) - cpuSeconds(before.ru_utime));
        if (!report[@"cpu_system_seconds"]) report[@"cpu_system_seconds"] = @(cpuSeconds(after.ru_stime) - cpuSeconds(before.ru_stime));
        report[@"max_rss_bytes"] = @(after.ru_maxrss);
        report[@"cpu_accounting_limit"] = @"App process threads; excludes external hardware codec service processes and includes concurrent app activity";
        report[@"timing_scope"] = @"Native initialization, source decode, Metal composition, H.264 encode and MP4 finalization; output verification is timed separately";
        return json(report);
    }
}

extern "C" char *fillr_background_probe(const char *path) {
    @autoreleasepool {
        try {
            @try {
                NSString *local = pathString(path);
                FormatInput input(local.fileSystemRepresentation);
                AVFormatContext *format = input.format;
                int index = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
                checkAV(index, "Find source video stream");
                AVStream *stream = format->streams[index];
                AVCodecParameters *parameters = stream->codecpar;
                AVRational rate = av_guess_frame_rate(format, stream, nullptr);
                double duration = stream->duration != AV_NOPTS_VALUE ? stream->duration * av_q2d(stream->time_base) :
                    (format->duration != AV_NOPTS_VALUE ? double(format->duration) / AV_TIME_BASE : 0);
                NSString *rateText = [NSString stringWithFormat:@"%d/%d", rate.num, rate.den];
                const char *profile = avcodec_profile_name(parameters->codec_id, parameters->profile);
                const char *field = parameters->field_order == AV_FIELD_PROGRESSIVE ? "progressive" :
                    (parameters->field_order == AV_FIELD_TT || parameters->field_order == AV_FIELD_TB ? "tt" :
                    (parameters->field_order == AV_FIELD_BB || parameters->field_order == AV_FIELD_BT ? "bb" : "unknown"));
                return json(@{@"status": @"complete", @"codec_name": @(avcodec_get_name(parameters->codec_id)),
                    @"profile": profile ? @(profile) : @"unknown", @"width": @(parameters->width), @"height": @(parameters->height),
                    @"frame_rate": rateText, @"r_frame_rate": rateText,
                    @"duration_seconds": @(duration), @"duration": @(duration),
                    @"frame_count": @(stream->nb_frames), @"nb_frames": @(stream->nb_frames),
                    @"field_order": @(field), @"color_range": @(parameters->color_range),
                    @"color_primaries": @(parameters->color_primaries), @"color_transfer": @(parameters->color_trc),
                    @"color_space": @(parameters->color_space), @"ffmpeg_version": @(av_version_info())});
            } @catch (NSException *exception) { throw failure(exception.reason.UTF8String ?: "Native probe exception"); }
        } catch (const std::exception &exception) { return json(@{@"status": @"failed", @"error": @(exception.what())}); }
        catch (...) { return json(@{@"status": @"failed", @"error": @"Unknown native media probe failure"}); }
    }
}

extern "C" char *fillr_background_test_job(const char *directory, int frames) {
    @autoreleasepool {
        try {
            @try {
                NSString *root = pathString(directory);
                if (frames < 1 || frames > 1800) throw failure("Built-in benchmark footage requires 1–1800 frames");
                BOOL isDirectory = NO;
                if (![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory)
                    throw failure("The built-in benchmark directory must already exist");
                NSString *media = [root stringByAppendingPathComponent:@"built-in-interlaced.m2v"];
                NSString *small = [root stringByAppendingPathComponent:@"small-test-tile.png"];
                NSString *big = [root stringByAppendingPathComponent:@"big-test-tile.png"];
                makeSample(media, frames);
                blackTile(small, 4229, 57); blackTile(big, 7603, 102);
                struct Layout { int number; double cx, cy, scale; };
                const Layout layout[] = {{1,479,270,.5},{2,1199,135,.25},{3,1679,135,.25},
                    {4,1199,405,.25},{5,1679,405,.25},{7,1079,607.5,.125},{8,1319,607.5,.125},
                    {9,1559,607.5,.125},{10,1798,606.5,.125},{11,1079,741.5,.125},
                    {12,1319,741.5,.125},{13,1559,741.5,.125},{14,1798,741.5,.125},
                    {15,1199,944,.25},{16,1679,945,.25}};
                NSMutableArray *panels = [NSMutableArray array];
                for (const auto &item : layout) {
                    int width = static_cast<int>(std::lround(1920 * item.scale));
                    int height = static_cast<int>(std::lround(1080 * item.scale));
                    [panels addObject:@{@"comp": @(item.number), @"geometry": @{
                        @"width": @(width), @"height": @(height), @"visible_width": @(width - 20), @"visible_height": @(height - 20),
                        @"x": @(std::nearbyint(item.cx - width / 2.0) + 10), @"y": @(std::nearbyint(item.cy - height / 2.0) + 10)},
                        @"segments": @[@{@"path": media, @"frames": @(frames), @"source_in_seconds": @0}]}];
                }
                return json(@{@"template": @"chabot-v27", @"frame_rate": @"30000/1001", @"frames": @(frames),
                    @"benchmark_source": @"built-in synthetic interlaced MPEG-2; black crawl tiles", @"panels": panels,
                    @"bands": @[@{@"name": @"small", @"tile_path": small, @"source_height": @57, @"height": @14, @"y": @737, @"start_x": @0, @"speed": @0},
                        @{@"name": @"big", @"tile_path": big, @"source_height": @102, @"height": @26, @"y": @915, @"start_x": @0, @"speed": @0}]});
            } @catch (NSException *exception) { throw failure(exception.reason.UTF8String ?: "Native test footage exception"); }
        } catch (const std::exception &exception) { return json(@{@"status": @"failed", @"error": @(exception.what())}); }
        catch (...) { return json(@{@"status": @"failed", @"error": @"Unknown native test footage failure"}); }
    }
}
