#pragma once

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <memory>
#include <atomic>

// One sequential panel reader. A returned pixel buffer has +1 ownership and
// remains valid independently of the next call; release after GPU completion.
// Call next()/stats() from one worker only. Separate instances are independent.
class GPUSource {
public:
    GPUSource(NSDictionary *panel, NSDictionary *settings, std::atomic<bool> *cancelled);
    ~GPUSource();
    CVPixelBufferRef next();
    NSDictionary *stats() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
