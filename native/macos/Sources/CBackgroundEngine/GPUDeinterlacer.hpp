#pragma once
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <memory>

// Synchronous GPU YADIF; returns +1 NV12 output after Metal has completed.
// Input buffers may be released when render returns. One instance per worker.
class GPUDeinterlacer {
public:
    GPUDeinterlacer();
    ~GPUDeinterlacer();
    CVPixelBufferRef render(CVPixelBufferRef previous, CVPixelBufferRef current,
                            CVPixelBufferRef following, bool topFieldFirst);
    NSDictionary *stats() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
