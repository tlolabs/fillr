#pragma once

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#include <cstdint>
#include <memory>

struct GPUProResFrame {
    CVPixelBufferRef pixel; // +1 retained; caller releases or transfers ownership.
    bool interlaced;
    bool topFieldFirst;
};

// One sequential, hardware-required decoder. ProRes packets contain complete
// intra frames; compressed data is copied into a bounded CoreMedia sample and
// its callback completes before decode() returns. No source video is cached.
class GPUProResDecoder {
public:
    GPUProResDecoder(CMVideoCodecType codec, int width, int height, int containerFieldOrder);
    ~GPUProResDecoder();
    GPUProResFrame decode(const uint8_t *data, size_t size, int64_t frameIndex);
    NSDictionary *stats() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
