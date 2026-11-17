#pragma once

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <memory>
#include <vector>

// The caller keeps input buffers alive until render returns. The returned buffer
// is retained (+1) and must be released after the encoder has taken ownership.
class GPUCanvas {
public:
    GPUCanvas(NSArray *panels, NSArray *bands);
    ~GPUCanvas();
    CVPixelBufferRef render(const std::vector<CVPixelBufferRef>& frames, int frameIndex);
    NSDictionary *stats() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
