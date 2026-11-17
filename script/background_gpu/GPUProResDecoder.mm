#import "GPUProResDecoder.hpp"
#import <VideoToolbox/VideoToolbox.h>
#include <mutex>
#include <stdexcept>
#include <string>

namespace {
void check(OSStatus status, const char *operation) {
    if (status != noErr)
        throw std::runtime_error(std::string(operation) + ": OSStatus " + std::to_string(status));
}
unsigned be16(const uint8_t *p) { return (unsigned(p[0]) << 8) | p[1]; }
uint32_t be32(const uint8_t *p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}
struct DecodeResult {
    std::mutex mutex;
    CVPixelBufferRef pixel = nullptr;
    OSStatus status = noErr;
    VTDecodeInfoFlags flags = 0;
    int callbacks = 0;
    ~DecodeResult() { if (pixel) CVPixelBufferRelease(pixel); }
};
void outputCallback(void *, void *source, OSStatus status, VTDecodeInfoFlags flags,
                    CVImageBufferRef image, CMTime, CMTime) {
    auto *result = static_cast<DecodeResult *>(source);
    std::lock_guard<std::mutex> lock(result->mutex);
    ++result->callbacks;
    result->status = status;
    result->flags |= flags;
    if (image && !result->pixel) result->pixel = CVPixelBufferRetain(image);
}
}

struct GPUProResDecoder::Impl {
    CMVideoCodecType codec;
    int width, height, containerFieldOrder;
    CMVideoFormatDescriptionRef format = nullptr;
    VTDecompressionSessionRef session = nullptr;
    int configuredFrameType = -1;
    int64_t decodedFrames = 0, interlacedFrames = 0;
    int sessionCount = 0;
    OSStatus fieldModeStatus = noErr;
    bool usingHardware = false;
    NSString *__strong decoderID;

    Impl(CMVideoCodecType type, int w, int h, int order)
        : codec(type), width(w), height(h), containerFieldOrder(order) {
        if (width < 1 || height < 1) throw std::runtime_error("Invalid native ProRes dimensions");
        static std::once_flag registration;
        std::call_once(registration, [] {
            VTRegisterProfessionalVideoWorkflowVideoDecoders();
        });
    }
    ~Impl() { close(); }
    void close() {
        if (session) {
            VTDecompressionSessionWaitForAsynchronousFrames(session);
            VTDecompressionSessionInvalidate(session);
            CFRelease(session);
            session = nullptr;
        }
        if (format) { CFRelease(format); format = nullptr; }
    }
    void initialize(int frameType) {
        if (session && frameType == configuredFrameType) return;
        close();
        NSMutableDictionary *extensions = [@{
            (__bridge NSString *)kCMFormatDescriptionExtension_ColorPrimaries:
                (__bridge NSString *)kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            (__bridge NSString *)kCMFormatDescriptionExtension_TransferFunction:
                (__bridge NSString *)kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            (__bridge NSString *)kCMFormatDescriptionExtension_YCbCrMatrix:
                (__bridge NSString *)kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
            (__bridge NSString *)kCMFormatDescriptionExtension_FieldCount: @(frameType ? 2 : 1)
        } mutableCopy];
        if (frameType)
            extensions[(__bridge NSString *)kCMFormatDescriptionExtension_FieldDetail] =
                (__bridge NSString *)(frameType == 1 ? kCMFormatDescriptionFieldDetail_TemporalTopFirst
                                                     : kCMFormatDescriptionFieldDetail_TemporalBottomFirst);
        check(CMVideoFormatDescriptionCreate(kCFAllocatorDefault, codec, width, height,
                    (__bridge CFDictionaryRef)extensions, &format), "Create native ProRes format description");
        NSDictionary *specification = @{
            (__bridge NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES};
        NSDictionary *attributes = @{
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (__bridge NSString *)kCVPixelBufferWidthKey: @(width),
            (__bridge NSString *)kCVPixelBufferHeightKey: @(height),
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        VTDecompressionOutputCallbackRecord callback = {outputCallback, nullptr};
        check(VTDecompressionSessionCreate(kCFAllocatorDefault, format,
                    (__bridge CFDictionaryRef)specification, (__bridge CFDictionaryRef)attributes,
                    &callback, &session), "Create required-hardware ProRes decoder");
        CFTypeRef property = nullptr;
        OSStatus status = VTSessionCopyProperty(session,
            kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, kCFAllocatorDefault, &property);
        usingHardware = status == noErr && property && CFGetTypeID(property) == CFBooleanGetTypeID() &&
                        CFBooleanGetValue(static_cast<CFBooleanRef>(property));
        if (property) CFRelease(property);
        check(status, "Query active ProRes hardware decoder");
        if (!usingHardware) throw std::runtime_error("Native ProRes decoder did not confirm hardware acceleration");
        property = nullptr;
        if (VTSessionCopyProperty(session, CFSTR("VideoDecoderID"), kCFAllocatorDefault, &property) == noErr && property) {
            if (CFGetTypeID(property) == CFStringGetTypeID()) decoderID = (__bridge NSString *)property;
            CFRelease(property);
        }
        // Request woven source fields when the decoder implements special field
        // handling. ProRes hardware does not implement this optional property on
        // every OS/device; unsupported means normal full-frame decoding, with
        // field structure read from the bitstream for the separate Metal filter.
        fieldModeStatus = VTSessionSetProperty(session, kVTDecompressionPropertyKey_FieldMode,
                                               kVTDecompressionProperty_FieldMode_BothFields);
        if (fieldModeStatus != kVTPropertyNotSupportedErr)
            check(fieldModeStatus, "Request both interlaced ProRes fields");
        configuredFrameType = frameType;
        ++sessionCount;
    }
    GPUProResFrame decode(const uint8_t *data, size_t size, int64_t frameIndex) {
        // ProRes frame header: size + 'icpf', followed by a length-delimited
        // header. Its frame-structure bits identify progressive/TFF/BFF. Parsing
        // these small fields avoids CPU image decoding and preserves per-frame
        // field semantics, including MOV files with an unspecified 'fiel' atom.
        if (!data || size < 28 || data[4] != 'i' || data[5] != 'c' || data[6] != 'p' || data[7] != 'f')
            throw std::runtime_error("Invalid complete ProRes packet header");
        size_t frameBytes = be32(data);
        unsigned headerBytes = be16(data + 8);
        if (frameBytes < 28 || frameBytes > size || headerBytes < 20 || headerBytes > frameBytes - 8)
            throw std::runtime_error("Invalid ProRes frame/header length");
        if (be16(data + 16) != unsigned(width) || be16(data + 18) != unsigned(height))
            throw std::runtime_error("ProRes packet dimensions differ from stream metadata");
        int frameType = (data[20] >> 2) & 3;
        if (frameType == 3) throw std::runtime_error("Unsupported reserved ProRes frame structure");
        initialize(frameType);
        CMBlockBufferRef block = nullptr;
        CMSampleBufferRef sample = nullptr;
        DecodeResult result;
        try {
            check(CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, frameBytes,
                        kCFAllocatorDefault, nullptr, 0, frameBytes, 0, &block), "Allocate compressed ProRes sample");
            check(CMBlockBufferReplaceDataBytes(data, block, 0, frameBytes), "Copy compressed ProRes sample");
            CMSampleTimingInfo timing = {CMTimeMake(1001, 30000), CMTimeMake(frameIndex * 1001, 30000), kCMTimeInvalid};
            check(CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, 1, 1, &timing,
                        1, &frameBytes, &sample), "Create compressed ProRes sample buffer");
            VTDecodeInfoFlags flags = 0;
            OSStatus decodeStatus = VTDecompressionSessionDecodeFrame(session, sample, 0, &result, &flags);
            // Even a decoder which schedules internally must complete before the
            // stack callback context and compressed sample can be released.
            OSStatus waitStatus = VTDecompressionSessionWaitForAsynchronousFrames(session);
            check(decodeStatus, "Decode required-hardware ProRes frame");
            check(waitStatus, "Wait for ProRes frame completion");
            std::lock_guard<std::mutex> lock(result.mutex);
            check(result.status, "ProRes hardware decoder callback");
            if (result.callbacks != 1 || !result.pixel ||
                (result.flags & kVTDecodeInfo_FrameDropped) || (flags & kVTDecodeInfo_FrameDropped))
                throw std::runtime_error("Native ProRes decoder dropped or duplicated a frame");
            if (CVPixelBufferGetWidth(result.pixel) != unsigned(width) ||
                CVPixelBufferGetHeight(result.pixel) != unsigned(height) ||
                CVPixelBufferGetPixelFormatType(result.pixel) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                !CVPixelBufferGetIOSurface(result.pixel))
                throw std::runtime_error("Native ProRes decoder did not return full-resolution IOSurface NV12");
            CFRelease(sample); sample = nullptr;
            CFRelease(block); block = nullptr;
            ++decodedFrames;
            if (frameType) ++interlacedFrames;
            auto pixel = result.pixel;
            result.pixel = nullptr;
            return {pixel, frameType != 0, frameType == 1};
        } catch (...) {
            if (sample) CFRelease(sample);
            if (block) CFRelease(block);
            throw;
        }
    }
    NSDictionary *stats() const {
        return @{@"decoder": @"native_videotoolbox_prores_hardware_required",
                 @"require_hardware_decode": @YES, @"reported_hardware_decoder": @(usingHardware),
                 @"hardware_backend_query_attempted": @YES, @"hardware_backend_query_status": @0,
                 @"decoder_id_reported": decoderID ?: (id)[NSNull null],
                 @"native_decoded_frames": @(decodedFrames), @"native_interlaced_frames": @(interlacedFrames),
                 @"native_decoder_sessions": @(sessionCount), @"container_field_order": @(containerFieldOrder),
                 @"field_mode": fieldModeStatus == noErr ? @"BothFields" : @"Decoder default full frame; optional FieldMode unsupported",
                 @"field_mode_set_status": @(fieldModeStatus),
                 @"field_parity_source": @"Per-frame ProRes bitstream header; no CPU pixel decode",
                 @"output": @"full-resolution limited-range NV12 IOSurface, Metal-compatible",
                 @"software_decode_fallback": @NO};
    }
};

GPUProResDecoder::GPUProResDecoder(CMVideoCodecType codec, int width, int height, int order)
    : impl(std::make_unique<Impl>(codec, width, height, order)) {}
GPUProResDecoder::~GPUProResDecoder() = default;
GPUProResFrame GPUProResDecoder::decode(const uint8_t *data, size_t size, int64_t index) {
    return impl->decode(data, size, index);
}
NSDictionary *GPUProResDecoder::stats() const { return impl->stats(); }
