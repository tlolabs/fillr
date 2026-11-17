/*
 * Metal YADIF adaptation based on FFmpeg's vf_yadif_videotoolbox.metal.
 * Original algorithm/Metal shader copyright:
 *   Copyright (C) 2018 Philip Langdale <philipl@overt.org>
 *                 2020 Aman Karmani <aman@tmm1.net>
 *                 2020 Stefan Dyulgerov <stefan.dyulgerov@gmail.com>
 * Adaptation: explicit bounded NV12 reads, first-field/send-frame mode only,
 * ARC-owned Metal commands, and one completed command buffer for both planes.
 *
 * This file is free software: you can redistribute it and/or modify it under
 * the GNU Lesser General Public License, version 2.1 or (at your option) later.
 * This file is distributed WITHOUT ANY WARRANTY; without even the implied
 * warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * License: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html
 * Upstream: https://github.com/FFmpeg/FFmpeg/blob/master/libavfilter/metal/vf_yadif_videotoolbox.metal
 */
#import "GPUDeinterlacer.hpp"
#import <Metal/Metal.h>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
NSString *const shader = @R"METAL(
#include <metal_stdlib>
using namespace metal;
struct Settings { uint parity; uint channels; };
float at(texture2d<float, access::read> image, int2 p, uint channel) {
    int2 limit = int2(image.get_width(), image.get_height()) - 1;
    return image.read(uint2(clamp(p, int2(0), limit)))[channel];
}
float estimate(texture2d<float, access::read> past,
               texture2d<float, access::read> now,
               texture2d<float, access::read> future, int2 p, uint channel) {
    // Directional spatial predictor; test nested diagonals in YADIF order.
    float above = at(now,p+int2(0,-1),channel), below = at(now,p+int2(0,1),channel);
    float prediction = (above + below) * 0.5;
    float best = abs(at(now,p+int2(-1,-1),channel)-at(now,p+int2(-1,1),channel)) +
                 abs(above-below) +
                 abs(at(now,p+int2(1,-1),channel)-at(now,p+int2(1,1),channel));
    for (int direction = -1; direction <= 1; direction += 2) {
        float score = 0;
        for (int x = -1; x <= 1; ++x)
            score += abs(at(now,p+int2(x+direction,-1),channel)-
                         at(now,p+int2(x-direction,1),channel));
        if (score < best) {
            prediction = (at(now,p+int2(direction,-1),channel)+
                          at(now,p+int2(-direction,1),channel))*0.5;
            best = score;
            float diagonalScore = 0;
            for (int x = -1; x <= 1; ++x)
                diagonalScore += abs(at(now,p+int2(x+direction*2,-1),channel)-
                                     at(now,p+int2(x-direction*2,1),channel));
            if (diagonalScore < best) {
                prediction = (at(now,p+int2(direction*2,-1),channel)+
                              at(now,p+int2(-direction*2,1),channel))*0.5;
                best = diagonalScore;
            }
        }
    }
    // First output field: temporal center uses the previous/current pair.
    float center = (at(past,p,channel)+at(now,p,channel))*0.5;
    float temporalDifference = abs(at(past,p,channel)-at(now,p,channel));
    float previousDifference = (abs(at(past,p+int2(0,-1),channel)-above)+
                                abs(at(past,p+int2(0,1),channel)-below))*0.5;
    float nextDifference = (abs(at(future,p+int2(0,-1),channel)-above)+
                            abs(at(future,p+int2(0,1),channel)-below))*0.5;
    float allowance = max(temporalDifference,max(previousDifference,nextDifference));
    float farAbove = (at(past,p+int2(0,-2),channel)+at(now,p+int2(0,-2),channel))*0.5;
    float farBelow = (at(past,p+int2(0,2),channel)+at(now,p+int2(0,2),channel))*0.5;
    float high = max(max(center-below,center-above),min(farAbove-above,farBelow-below));
    float low = min(min(center-below,center-above),max(farAbove-above,farBelow-below));
    allowance = max(allowance,max(low,-high));
    return clamp(prediction,center-allowance,center+allowance);
}
kernel void yadif(texture2d<float, access::read> previous [[texture(0)]],
                  texture2d<float, access::read> current [[texture(1)]],
                  texture2d<float, access::read> following [[texture(2)]],
                  texture2d<float, access::write> destination [[texture(3)]],
                  constant Settings &settings [[buffer(0)]],
                  uint2 position [[thread_position_in_grid]]) {
    if (position.x>=destination.get_width() || position.y>=destination.get_height()) return;
    float4 value = current.read(position);
    if ((position.y & 1) != settings.parity) {
        for (uint channel=0; channel<settings.channels; ++channel)
            value[channel] = estimate(previous,current,following,int2(position),channel);
    }
    destination.write(value,position);
}
)METAL";

struct SharedPipeline {
    id<MTLDevice> __strong device;
    id<MTLComputePipelineState> __strong pipeline;
    SharedPipeline() {
        device = MTLCreateSystemDefaultDevice();
        if (!device) throw std::runtime_error("No Metal device for YADIF");
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:shader options:nil error:&error];
        if (!library) throw std::runtime_error(std::string("Compile Metal YADIF: ") + error.localizedDescription.UTF8String);
        id<MTLFunction> function = [library newFunctionWithName:@"yadif"];
        pipeline = [device newComputePipelineStateWithFunction:function error:&error];
        if (!pipeline) throw std::runtime_error(std::string("Create Metal YADIF pipeline: ") + error.localizedDescription.UTF8String);
    }
};
SharedPipeline &sharedPipeline() { static SharedPipeline value; return value; }
struct Settings { uint32_t parity, channels; };
}

struct GPUDeinterlacer::Impl {
    id<MTLDevice> __strong device;
    id<MTLComputePipelineState> __strong pipeline;
    id<MTLCommandQueue> __strong queue;
    CVMetalTextureCacheRef cache = nullptr;
    CVPixelBufferPoolRef pool = nullptr;
    size_t width = 0, height = 0;
    int64_t frames = 0;
    Impl() {
        SharedPipeline &shared = sharedPipeline();
        device = shared.device;
        pipeline = shared.pipeline;
        queue = [device newCommandQueue];
        if (!queue || CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &cache) != kCVReturnSuccess)
            throw std::runtime_error("Create Metal YADIF queue/texture cache");
    }
    ~Impl() {
        if (cache) CFRelease(cache);
        if (pool) CVPixelBufferPoolRelease(pool);
    }
    void configure(size_t w, size_t h) {
        if (pool && width == w && height == h) return;
        if (pool) { CVPixelBufferPoolRelease(pool); pool = nullptr; }
        width = w; height = h;
        NSDictionary *attributes = @{
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (__bridge NSString *)kCVPixelBufferWidthKey: @(w),
            (__bridge NSString *)kCVPixelBufferHeightKey: @(h),
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES};
        if (CVPixelBufferPoolCreate(nullptr, nullptr, (__bridge CFDictionaryRef)attributes, &pool) != kCVReturnSuccess)
            throw std::runtime_error("Create Metal-compatible YADIF output pool");
    }
    CVPixelBufferRef render(CVPixelBufferRef previous, CVPixelBufferRef current,
                            CVPixelBufferRef following, bool topFieldFirst) {
        configure(CVPixelBufferGetWidth(current), CVPixelBufferGetHeight(current));
        CVPixelBufferRef destination = nullptr;
        if (CVPixelBufferPoolCreatePixelBuffer(nullptr, pool, &destination) != kCVReturnSuccess)
            throw std::runtime_error("Allocate Metal YADIF output surface");
        std::vector<CVMetalTextureRef> textures;
        try {
            id<MTLCommandBuffer> commands = [queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
            if (!commands || !encoder) throw std::runtime_error("Create Metal YADIF commands");
            [encoder setComputePipelineState:pipeline];
            for (size_t plane = 0; plane < 2; ++plane) {
                size_t w = CVPixelBufferGetWidthOfPlane(current, plane);
                size_t h = CVPixelBufferGetHeightOfPlane(current, plane);
                MTLPixelFormat format = plane ? MTLPixelFormatRG8Unorm : MTLPixelFormatR8Unorm;
                CVPixelBufferRef buffers[] = {previous,current,following,destination};
                for (size_t i = 0; i < 4; ++i) {
                    if (CVPixelBufferGetWidthOfPlane(buffers[i], plane) != w ||
                        CVPixelBufferGetHeightOfPlane(buffers[i], plane) != h)
                        throw std::runtime_error("YADIF temporal frame dimensions differ");
                    CVMetalTextureRef texture = nullptr;
                    CVReturn ret = CVMetalTextureCacheCreateTextureFromImage(nullptr, cache, buffers[i],
                        nullptr, format, w, h, plane, &texture);
                    if (ret != kCVReturnSuccess || !texture) {
                        if (texture) CFRelease(texture);
                        throw std::runtime_error("Map NV12 Metal YADIF plane: " + std::to_string(ret));
                    }
                    textures.push_back(texture);
                    [encoder setTexture:CVMetalTextureGetTexture(texture) atIndex:i];
                }
                Settings settings{topFieldFirst ? 0u : 1u, plane ? 2u : 1u};
                [encoder setBytes:&settings length:sizeof(settings) atIndex:0];
                NSUInteger x = pipeline.threadExecutionWidth;
                NSUInteger y = std::min<NSUInteger>(8, pipeline.maxTotalThreadsPerThreadgroup / x);
                [encoder dispatchThreads:MTLSizeMake(w,h,1) threadsPerThreadgroup:MTLSizeMake(x,y,1)];
            }
            [encoder endEncoding];
            [commands commit];
            [commands waitUntilCompleted];
            if (commands.status == MTLCommandBufferStatusError)
                throw std::runtime_error(std::string("Metal YADIF failed: ") + commands.error.localizedDescription.UTF8String);
            for (auto texture : textures) CFRelease(texture);
            textures.clear();
            CVBufferPropagateAttachments(current,destination);
            CVBufferSetAttachment(destination,kCVImageBufferFieldCountKey,(__bridge CFTypeRef)@1,kCVAttachmentMode_ShouldPropagate);
            CVBufferRemoveAttachment(destination,kCVImageBufferFieldDetailKey);
            ++frames;
            return destination;
        } catch (...) {
            for (auto texture : textures) CFRelease(texture);
            CVPixelBufferRelease(destination);
            throw;
        }
    }
};

GPUDeinterlacer::GPUDeinterlacer() : impl(std::make_unique<Impl>()) {}
GPUDeinterlacer::~GPUDeinterlacer() = default;
CVPixelBufferRef GPUDeinterlacer::render(CVPixelBufferRef previous, CVPixelBufferRef current,
                                        CVPixelBufferRef following, bool topFieldFirst) {
    return impl->render(previous,current,following,topFieldFirst);
}
NSDictionary *GPUDeinterlacer::stats() const {
    return @{@"algorithm": @"YADIF first field, directional spatial plus three-frame temporal predictor",
             @"backend": @"native Metal compute", @"frames": @(impl->frames),
             @"planes_per_command_buffer": @2, @"shader_license": @"LGPL-2.1-or-later",
             @"output_iosurface_metal_compatible": @YES};
}
