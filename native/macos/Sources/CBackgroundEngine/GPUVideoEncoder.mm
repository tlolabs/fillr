#import "GPUVideoEncoder.hpp"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#include <atomic>
#include <chrono>
#include <map>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>

namespace {
constexpr int Width = 1920;
constexpr int Height = 1080;


std::string text(NSString *value) {
    return value ? std::string(value.UTF8String) : std::string("unspecified error");
}

std::runtime_error statusError(const char *operation, OSStatus status) {
    return std::runtime_error(std::string(operation) + " failed: OSStatus " + std::to_string(status));
}

CMTime frameTime(int index) { return CMTimeMake(static_cast<int64_t>(index) * 1001, 30000); }
}

struct GPUEncoder::Impl {
    NSString *outputPath;
    const int expectedFrames;
    const int inflightLimit;
    const bool requireHardware;
    std::atomic<bool> *cancelled;
    VTCompressionSessionRef session = nullptr;
    AVAssetWriter *writer = nil;
    AVAssetWriterInput *writerInput = nil;
    dispatch_queue_t muxQueue;
    dispatch_semaphore_t inflight;
    mutable std::mutex mutex;
    std::string failure;
    std::map<int, CVPixelBufferRef> heldImages;
    // Only touched by muxQueue; samples own their compressed block buffers.
    std::map<int, CMSampleBufferRef> readySamples;
    int nextMuxIndex = 0;
    std::atomic<int> submitted{0};
    std::atomic<int> callbacks{0};
    std::atomic<int> muxed{0};
    std::atomic<int> dropped{0};
    bool finished = false;
    NSDictionary *requestedProperties;
    NSMutableDictionary *reportedProperties;

    Impl(NSString *path, int frames, NSDictionary *settings, std::atomic<bool> *stop)
        : outputPath([path copy]), expectedFrames(frames),
          inflightLimit([settings[@"encoder_inflight_frames"] intValue]),
          requireHardware([settings[@"hardware_encode"] boolValue]), cancelled(stop) {
        muxQueue = dispatch_queue_create("com.fillr.background-gpu.mp4-mux", DISPATCH_QUEUE_SERIAL);
        inflight = dispatch_semaphore_create(inflightLimit);
        reportedProperties = [NSMutableDictionary dictionary];
    }

    void fail(const std::string &message) {
        std::lock_guard<std::mutex> guard(mutex);
        if (failure.empty()) failure = message;
    }

    std::string error() const {
        std::lock_guard<std::mutex> guard(mutex);
        return failure;
    }

    void check() const {
        if (cancelled->load()) throw std::runtime_error("Background build cancelled");
        const auto message = error();
        if (!message.empty()) throw std::runtime_error(message);
    }

    CVPixelBufferRef takeImage(int index) {
        std::lock_guard<std::mutex> guard(mutex);
        auto found = heldImages.find(index);
        if (found == heldImages.end()) return nullptr;
        auto image = found->second;
        heldImages.erase(found);
        return image;
    }

    void set(CFStringRef key, id value) {
        const auto status = VTSessionSetProperty(session, key, (__bridge CFTypeRef)value);
        if (status != noErr) throw statusError(text((__bridge NSString *)key).c_str(), status);
    }

    id read(CFStringRef key) const {
        CFTypeRef value = nullptr;
        const auto status = VTSessionCopyProperty(session, key, kCFAllocatorDefault, &value);
        if (status != noErr || !value) return nil;
        return CFBridgingRelease(value);
    }

    void updateReportedProperties() {
        if (!session) return;
        for (id key in @[(__bridge NSString *)kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                          (__bridge NSString *)kVTCompressionPropertyKey_EncoderID,
                          (__bridge NSString *)kVTCompressionPropertyKey_ProfileLevel,
                          (__bridge NSString *)kVTCompressionPropertyKey_AverageBitRate,
                          (__bridge NSString *)kVTCompressionPropertyKey_DataRateLimits,
                          (__bridge NSString *)kVTCompressionPropertyKey_ExpectedFrameRate,
                          (__bridge NSString *)kVTCompressionPropertyKey_MaxFrameDelayCount]) {
            id value = read((__bridge CFStringRef)key);
            if (value) reportedProperties[key] = value;
        }
        NSNumber *usingHardware = reportedProperties[(__bridge NSString *)kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder];
        if (![usingHardware isKindOfClass:NSNumber.class])
            throw std::runtime_error("VideoToolbox did not confirm the active encoder backend");
        if (usingHardware.boolValue != requireHardware)
            throw std::runtime_error("VideoToolbox encoder backend differs from the selected hardware setting");
    }

    void initialize() {
        if (expectedFrames <= 0) throw std::invalid_argument("Encoder requires a positive frame count");
        if (!outputPath.length) throw std::invalid_argument("Encoder output path is empty");
        if ([[NSFileManager defaultManager] fileExistsAtPath:outputPath])
            throw std::runtime_error("Refusing to overwrite encoder output: " + text(outputPath));
        NSError *writerError = nil;
        writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:outputPath]
                                          fileType:AVFileTypeMPEG4 error:&writerError];
        if (!writer) throw std::runtime_error("Cannot create MP4 writer: " + text(writerError.localizedDescription));
        writer.shouldOptimizeForNetworkUse = YES;
        writer.movieTimeScale = 30000;
        NSDictionary *specification = @{
            (__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@(requireHardware),
            (__bridge NSString *)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder:@(requireHardware)
        };
        NSDictionary *attributes = @{
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (__bridge NSString *)kCVPixelBufferWidthKey:@(Width),
            (__bridge NSString *)kCVPixelBufferHeightKey:@(Height),
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey:@YES,
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}
        };
        auto status = VTCompressionSessionCreate(kCFAllocatorDefault, Width, Height, kCMVideoCodecType_H264,
            (__bridge CFDictionaryRef)specification, (__bridge CFDictionaryRef)attributes,
            kCFAllocatorDefault, &Impl::outputCallback, this, &session);
        if (status != noErr) throw statusError("Create H.264 compression session", status);
        requestedProperties = @{
            (__bridge NSString *)kVTCompressionPropertyKey_ProfileLevel:(__bridge NSString *)kVTProfileLevel_H264_High_4_2,
            (__bridge NSString *)kVTCompressionPropertyKey_AverageBitRate:@16000000,
            (__bridge NSString *)kVTCompressionPropertyKey_DataRateLimits:@[@2000000, @1],
            (__bridge NSString *)kVTCompressionPropertyKey_ExpectedFrameRate:@(30000.0 / 1001.0),
            (__bridge NSString *)kVTCompressionPropertyKey_RealTime:@NO,
            (__bridge NSString *)kVTCompressionPropertyKey_AllowTemporalCompression:@YES,
            (__bridge NSString *)kVTCompressionPropertyKey_AllowFrameReordering:@NO,
            (__bridge NSString *)kVTCompressionPropertyKey_H264EntropyMode:(__bridge NSString *)kVTH264EntropyMode_CABAC,
            (__bridge NSString *)kVTCompressionPropertyKey_ColorPrimaries:(__bridge NSString *)kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            (__bridge NSString *)kVTCompressionPropertyKey_TransferFunction:(__bridge NSString *)kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            (__bridge NSString *)kVTCompressionPropertyKey_YCbCrMatrix:(__bridge NSString *)kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
            (__bridge NSString *)kVTCompressionPropertyKey_FieldCount:@1,
            (__bridge NSString *)kVTCompressionPropertyKey_PixelAspectRatio:@{
                (__bridge NSString *)kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing:@1,
                (__bridge NSString *)kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing:@1
            }
        };
        for (NSString *key in requestedProperties) set((__bridge CFStringRef)key, requestedProperties[key]);
        status = VTCompressionSessionPrepareToEncodeFrames(session);
        if (status != noErr) throw statusError("Prepare H.264 encoder", status);
        updateReportedProperties();
    }

    void muxOne(CMSampleBufferRef sample, int index) {
        if (CMSampleBufferGetNumSamples(sample) != 1)
            throw std::runtime_error("Expected one compressed video frame per sample buffer");
        if (CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), frameTime(index)) != 0)
            throw std::runtime_error("H.264 encoder changed a frame presentation timestamp");
        if (!writerInput) {
            CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
            if (!format || CMFormatDescriptionGetMediaSubType(format) != kCMVideoCodecType_H264)
                throw std::runtime_error("H.264 encoder did not supply an H.264 format description");
            writerInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo
                                                       outputSettings:nil sourceFormatHint:format];
            writerInput.expectsMediaDataInRealTime = NO;
            writerInput.mediaTimeScale = 30000;
            if (![writer canAddInput:writerInput]) throw std::runtime_error("MP4 writer cannot accept compressed H.264");
            [writer addInput:writerInput];
            if (![writer startWriting])
                throw std::runtime_error("MP4 start failed: " + text(writer.error.localizedDescription));
            [writer startSessionAtSourceTime:kCMTimeZero];
        }
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
        while (!writerInput.readyForMoreMediaData) {
            check();
            if (writer.status == AVAssetWriterStatusFailed || writer.status == AVAssetWriterStatusCancelled)
                throw std::runtime_error("MP4 writer failed: " + text(writer.error.localizedDescription));
            if (std::chrono::steady_clock::now() > deadline)
                throw std::runtime_error("MP4 writer backpressure exceeded 30 seconds");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        CMSampleTimingInfo timing = {frameTime(1), frameTime(index), frameTime(index)};
        CMSampleBufferRef timedSample = nullptr;
        const auto status = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sample, 1, &timing, &timedSample);
        if (status != noErr) throw statusError("Set exact compressed frame timing", status);
        BOOL appended = NO;
        @try { appended = [writerInput appendSampleBuffer:timedSample]; }
        @finally { CFRelease(timedSample); }
        if (!appended) throw std::runtime_error("MP4 append failed: " + text(writer.error.localizedDescription));
        ++muxed;
    }

    void receive(CMSampleBufferRef sample, int index) {
        @autoreleasepool {
            try {
                @try {
                    check();
                    if (readySamples.count(index)) throw std::runtime_error("Duplicate compressed frame index");
                    readySamples[index] = sample; // This method owns the callback's retained sample.
                    sample = nullptr;
                    while (true) {
                        auto found = readySamples.find(nextMuxIndex);
                        if (found == readySamples.end()) break;
                        auto next = found->second;
                        readySamples.erase(found);
                        try {
                            @try { muxOne(next, nextMuxIndex); }
                            @catch (NSException *exception) {
                                throw std::runtime_error("MP4 writer exception: " + text(exception.reason));
                            }
                        }
                        catch (...) { CFRelease(next); dispatch_semaphore_signal(inflight); throw; }
                        CFRelease(next);
                        ++nextMuxIndex;
                        dispatch_semaphore_signal(inflight);
                    }
                } @catch (NSException *exception) {
                    throw std::runtime_error("MP4 writer exception: " + text(exception.reason));
                }
            } catch (const std::exception &exception) {
                fail(exception.what());
                if (sample) { CFRelease(sample); dispatch_semaphore_signal(inflight); }
                for (auto &entry : readySamples) {
                    CFRelease(entry.second);
                    dispatch_semaphore_signal(inflight);
                }
                readySamples.clear();
            }
        }
    }

    static void outputCallback(void *reference, void *frameReference, OSStatus status,
                               VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
        auto self = static_cast<Impl *>(reference);
        const int index = static_cast<int>(reinterpret_cast<uintptr_t>(frameReference)) - 1;
        auto image = self->takeImage(index);
        if (image) CVPixelBufferRelease(image);
        ++self->callbacks;
        if (status != noErr || !sample || (flags & kVTEncodeInfo_FrameDropped)) {
            ++self->dropped;
            self->fail("H.264 encoder failed or dropped frame " + std::to_string(index) +
                       ": OSStatus " + std::to_string(status));
            dispatch_semaphore_signal(self->inflight);
            return;
        }
        CFRetain(sample);
        dispatch_async(self->muxQueue, ^{ self->receive(sample, index); });
    }

    void append(CVPixelBufferRef image, int index) {
        check();
        if (finished || !session) throw std::runtime_error("Encoder is not accepting frames");
        if (!image || CVPixelBufferGetWidth(image) != Width || CVPixelBufferGetHeight(image) != Height ||
            CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            throw std::invalid_argument("Encoder requires 1920x1080 limited-range NV12 pixel buffers");
        if (index != submitted.load() || index >= expectedFrames)
            throw std::invalid_argument("Encoder frames must arrive in exact sequential order");
        // Some Apple H.264 encoders do not implement MaxFrameDelayCount. If
        // our bounded queue fills, force pending frames out before waiting; this
        // prevents an encoder's private lookahead from exhausting every lease.
        if (dispatch_semaphore_wait(inflight, DISPATCH_TIME_NOW)) {
            const auto completionStatus = VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
            if (completionStatus != noErr) throw statusError("Drain bounded H.264 encoder queue", completionStatus);
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
            while (dispatch_semaphore_wait(inflight, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC))) {
                check();
                if (std::chrono::steady_clock::now() > deadline)
                    throw std::runtime_error("H.264 encoder backpressure exceeded 30 seconds");
            }
        }
        try { check(); }
        catch (...) { dispatch_semaphore_signal(inflight); throw; }
        CVPixelBufferRetain(image);
        { std::lock_guard<std::mutex> guard(mutex); heldImages[index] = image; }
        VTEncodeInfoFlags flags = 0;
        const auto status = VTCompressionSessionEncodeFrame(session, image, frameTime(index), frameTime(1),
            nullptr, reinterpret_cast<void *>(static_cast<uintptr_t>(index + 1)), &flags);
        if (status != noErr) {
            if (auto held = takeImage(index)) {
                CVPixelBufferRelease(held);
                dispatch_semaphore_signal(inflight);
            }
            fail("Encode frame " + std::to_string(index) + " failed: OSStatus " + std::to_string(status));
            check();
        }
        ++submitted;
        if (flags & kVTEncodeInfo_FrameDropped) {
            fail("H.264 encoder synchronously dropped frame " + std::to_string(index));
            check();
        }
        check();
    }

    void finish() {
        if (finished) { check(); return; }
        check();
        if (submitted != expectedFrames) throw std::runtime_error("Submitted encoder frame count does not match the job");
        const auto status = VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
        if (status != noErr) throw statusError("Complete H.264 compression", status);
        dispatch_sync(muxQueue, ^{});
        check();
        if (callbacks != expectedFrames || muxed != expectedFrames || dropped != 0)
            throw std::runtime_error("Encoded or muxed frame count does not match the job");
        updateReportedProperties();
        @try {
            [writer endSessionAtSourceTime:frameTime(expectedFrames)];
            [writerInput markAsFinished];
        } @catch (NSException *exception) {
            throw std::runtime_error("MP4 completion exception: " + text(exception.reason));
        }
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        @try { [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }]; }
        @catch (NSException *exception) {
            throw std::runtime_error("MP4 finalization exception: " + text(exception.reason));
        }
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)))
            throw std::runtime_error("MP4 finalization exceeded 60 seconds");
        if (writer.status != AVAssetWriterStatusCompleted)
            throw std::runtime_error("MP4 finalization failed: " + text(writer.error.localizedDescription));
        finished = true;
    }

    NSDictionary *statistics() const {
        const auto message = error();
        id actualHardware = reportedProperties[(__bridge NSString *)kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder];
        id encoderID = reportedProperties[(__bridge NSString *)kVTCompressionPropertyKey_EncoderID];
        return @{
            @"codec":@"H.264", @"container":@"MP4", @"output_path":outputPath,
            @"width":@(Width), @"height":@(Height), @"frame_rate":@"30000/1001",
            @"expected_frames":@(expectedFrames), @"frames_submitted":@(submitted.load()),
            @"frames_encoded":@(callbacks.load()), @"frames_muxed":@(muxed.load()),
            @"frames_dropped":@(dropped.load()), @"audio":@NO,
            @"hardware_encoding_required":@(requireHardware),
            @"requested_hardware":@(requireHardware),
            @"hardware":actualHardware ?: [NSNull null],
            @"using_hardware_encoder_reported":actualHardware ?: [NSNull null],
            @"encoder_id_reported":encoderID ?: [NSNull null],
            @"max_inflight_frames":@(inflightLimit), @"fast_start_mp4":@YES,
            @"drain_encoder_when_inflight_limit_reached":@YES,
            @"requested_properties":requestedProperties ?: @{},
            @"reported_properties":[reportedProperties copy],
            @"status":finished ? @"complete" : (message.empty() ? @"encoding" : @"failed"),
            @"error":message.empty() ? [NSNull null] : [NSString stringWithUTF8String:message.c_str()]
        };
    }

    ~Impl() {
        if (!finished) fail("Encoder shut down before successful completion");
        if (session) {
            // Drain callbacks while this object and its mux queue are alive.
            VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
            VTCompressionSessionInvalidate(session);
            CFRelease(session);
            session = nullptr;
        }
        dispatch_sync(muxQueue, ^{});
        @try {
            if (writer && writer.status != AVAssetWriterStatusCompleted && writer.status != AVAssetWriterStatusCancelled)
                [writer cancelWriting];
        } @catch (NSException *exception) {
            // Destruction is best-effort; append/finish carry the actionable error.
        }
        for (auto &entry : readySamples) CFRelease(entry.second);
        readySamples.clear();
        for (auto &entry : heldImages) CVPixelBufferRelease(entry.second);
        heldImages.clear();
    }
};

GPUEncoder::GPUEncoder(NSString *output, int expectedFrames, NSDictionary *settings, std::atomic<bool> *cancelled)
    : impl(std::make_unique<Impl>(output, expectedFrames, settings, cancelled)) {
    impl->initialize();
}
GPUEncoder::~GPUEncoder() = default;
void GPUEncoder::append(CVPixelBufferRef image, int frameIndex) { impl->append(image, frameIndex); }
void GPUEncoder::finish() { impl->finish(); }
NSDictionary *GPUEncoder::stats() const { return impl->statistics(); }
