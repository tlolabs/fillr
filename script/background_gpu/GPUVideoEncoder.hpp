#pragma once

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <memory>

// Offline H.264/MP4 sink. append() takes its own bounded reference to each
// source pixel buffer, so the caller may release its reference on return.
class GPUEncoder {
public:
    GPUEncoder(NSString *output, int expectedFrames);
    ~GPUEncoder();
    GPUEncoder(const GPUEncoder &) = delete;
    GPUEncoder &operator=(const GPUEncoder &) = delete;
    void append(CVPixelBufferRef image, int frameIndex);
    void finish();
    NSDictionary *stats() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
