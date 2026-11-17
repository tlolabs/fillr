#import "GPUCanvas.hpp"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#include <simd/simd.h>
#include <chrono>
#include <cmath>
#include <stdexcept>
#include <string>
#include <thread>

namespace {
constexpr size_t PanelCount = 15;
constexpr size_t BandCount = 2;
constexpr int OutputWidth = 1920;
constexpr int OutputHeight = 1080;
// Eight buffers may be held by the encoder. The next frame is composed before
// append() drains that queue, so reserve a composing lease plus one spare.
constexpr int OutputPoolLimit = 10;

struct PanelUniform { simd_float4 rect; simd_float4 source; };
struct BandUniform { simd_float4 geometry; simd_float4 tile; };
struct Uniforms {
    PanelUniform panels[PanelCount];
    BandUniform bands[BandCount];
    simd_uint4 frame;
};

std::runtime_error failure(NSString *message) {
    return std::runtime_error(message.UTF8String ?: "GPUCanvas failed");
}

NSString *shaderSource() {
    return @R"METAL(
#include <metal_stdlib>
using namespace metal;
struct Panel { float4 rect; float4 source; };
struct Band { float4 geometry; float4 tile; };
struct Uniforms { Panel panels[15]; Band bands[2]; uint4 frame; };

float cubicWeight(float x) {
    x = abs(x);
    if (x <= 1.0f) return (1.5f*x - 2.5f)*x*x + 1.0f;
    if (x < 2.0f) return ((-0.5f*x + 2.5f)*x - 4.0f)*x + 2.0f;
    return 0.0f;
}

float4 cubicSample(texture2d<float, access::read> image, float2 position) {
    int2 base = int2(floor(position));
    float2 fraction = position - float2(base);
    int2 maximum = int2(image.get_width(), image.get_height()) - 1;
    float4 value = 0.0f;
    for (int y = -1; y <= 2; ++y) {
        float wy = cubicWeight(float(y) - fraction.y);
        for (int x = -1; x <= 2; ++x) {
            float wx = cubicWeight(float(x) - fraction.x);
            uint2 point = uint2(clamp(base + int2(x,y), int2(0), maximum));
            value += image.read(point) * (wx * wy);
        }
    }
    return clamp(value, 0.0f, 1.0f);
}

int panelAt(float2 pixel, constant Uniforms& uniforms) {
    // Later panels win in the same way as overlaying the original composition.
    for (int i = 14; i >= 0; --i) {
        float4 r = uniforms.panels[i].rect;
        if (all(pixel >= r.xy) && all(pixel < r.xy + r.zw)) return i;
    }
    return -1;
}

int bandAt(float2 pixel, constant Uniforms& uniforms) {
    if (pixel.x < 10.0f || pixel.x >= 950.0f) return -1;
    for (int i = 1; i >= 0; --i) {
        Band b = uniforms.bands[i];
        if (b.tile.w > 0.5f && pixel.y >= b.geometry.x &&
            pixel.y < b.geometry.x + b.geometry.y) return i;
    }
    return -1;
}

float2 sourcePosition(float2 pixel, Panel panel) {
    return (pixel - panel.rect.xy + 10.5f) *
           panel.source.zw / panel.source.xy - 0.5f;
}

int copyOffset(int copy, bool big) {
    if (big) return 7600 * copy;
    if (copy == 0) return 0;
    if (copy == 1) return 4220;
    return 4248 * copy;
}

float bannerTexel(texture2d<float, access::read> tile, int2 point, bool big) {
    int width = int(tile.get_width());
    int height = int(tile.get_height());
    // The original banner is black outside its copies. Copies are opaque and
    // applied in increasing order, including the small overlaps at their edges.
    if (point.y < 0 || point.y >= height) return 0.0f;
    for (int copy = big ? 6 : 11; copy >= 0; --copy) {
        int x = point.x - copyOffset(copy, big);
        if (x >= 0 && x < width) return tile.read(uint2(x, point.y)).r;
    }
    return 0.0f;
}

float bannerSample(texture2d<float, access::read> tile, float2 position, bool big, float scaleY) {
    int2 base = int2(floor(position));
    float2 fraction = position - float2(base);
    float value = 0.0f;
    float weight = 0.0f;
    // Clamp the vertical edge just as a crop followed by scale does. Horizontal
    // taps read the reconstructed banner, preserving the copy seam semantics.
    // Widen the reconstruction kernel for the roughly fourfold crawl reduction
    // so thin letters do not alias or shimmer as the quarter-pixel crop moves.
    for (int y = -9; y <= 9; ++y) {
        int py = clamp(base.y + y, 0, int(tile.get_height()) - 1);
        float wy = cubicWeight((float(y) - fraction.y) / scaleY);
        if (wy == 0.0f) continue;
        for (int x = -8; x <= 8; ++x) {
            float w = cubicWeight((float(x)-fraction.x)/4.0f) * wy;
            if (w == 0.0f) continue;
            value += bannerTexel(tile, int2(base.x+x, py), big) * w;
            weight += w;
        }
    }
    return clamp(value / weight, 0.0f, 1.0f);
}

kernel void renderLuma(
    array<texture2d<float, access::read>, 15> sources [[texture(0)]],
    texture2d<float, access::write> output [[texture(30)]],
    texture2d<float, access::read> smallTile [[texture(32)]],
    texture2d<float, access::read> bigTile [[texture(33)]],
    constant Uniforms& uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= 1920 || position.y >= 1080) return;
    float2 pixel = float2(position);
    float value = 16.0f / 255.0f;
    int bandIndex = bandAt(pixel, uniforms);
    if (bandIndex >= 0) {
        Band b = uniforms.bands[bandIndex];
        float2 p = float2(b.geometry.w + (pixel.x - 10.0f + 0.5f)*4.0f - 0.5f,
                         (pixel.y - b.geometry.x + 0.5f)*b.geometry.z/b.geometry.y - 0.5f);
        bool big = b.tile.z > 0.5f;
        float scaleY = b.geometry.z/b.geometry.y;
        float intensity = big ? bannerSample(bigTile, p, true, scaleY) :
                                bannerSample(smallTile, p, false, scaleY);
        value += (219.0f/255.0f) * intensity;
    } else {
        int index = panelAt(pixel, uniforms);
        if (index >= 0) value = cubicSample(sources[index],
                              sourcePosition(pixel, uniforms.panels[index])).r;
    }
    output.write(float4(value, 0.0f, 0.0f, 1.0f), position);
}

kernel void renderChroma(
    array<texture2d<float, access::read>, 15> sources [[texture(15)]],
    texture2d<float, access::write> output [[texture(31)]],
    constant Uniforms& uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= 960 || position.y >= 540) return;
    float2 value = 0.0f;
    for (uint y = 0; y < 2; ++y) {
        for (uint x = 0; x < 2; ++x) {
            float2 pixel = float2(position*2 + uint2(x,y));
            float2 uv = float2(128.0f/255.0f);
            if (bandAt(pixel, uniforms) < 0) {
                int index = panelAt(pixel, uniforms);
                if (index >= 0) {
                    float2 p = sourcePosition(pixel, uniforms.panels[index]);
                    // Center-sited 4:2:0 coordinates, with the four output luma
                    // positions averaged to avoid choosing one edge of a panel.
                    uv = cubicSample(sources[index], p*0.5f - 0.25f).rg;
                }
            }
            value += uv * 0.25f;
        }
    }
    output.write(float4(value, 0.0f, 1.0f), position);
}
)METAL";
}

struct BufferRelease {
    CVPixelBufferRef buffer = nullptr;
    ~BufferRelease() { if (buffer) CVPixelBufferRelease(buffer); }
};
struct TextureReleases {
    std::vector<CVMetalTextureRef> textures;
    ~TextureReleases() { for (CVMetalTextureRef t : textures) CFRelease(t); }
};
}

struct GPUCanvas::Impl {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> lumaPipeline;
    id<MTLComputePipelineState> chromaPipeline;
    MPSImageLanczosScale *panelScale[PanelCount][2];
    id<MTLTexture> scaledPanels[PanelCount][2];
    id<MTLTexture> tiles[BandCount];
    CVMetalTextureCacheRef textureCache = nullptr;
    CVPixelBufferPoolRef pool = nullptr;
    Uniforms uniforms = {};
    double bandStart[BandCount] = {};
    double bandSpeed[BandCount] = {};
    uint64_t submissions = 0;
    double gpuSeconds = 0;
    double renderSeconds = 0;

    ~Impl() {
        if (textureCache) CFRelease(textureCache);
        if (pool) CFRelease(pool);
    }

    id<MTLTexture> map(CVPixelBufferRef buffer, size_t plane, bool output,
                       TextureReleases& keepAlive) {
        CVMetalTextureRef cvTexture = nullptr;
        NSDictionary *attributes = @{(__bridge NSString *)kCVMetalTextureUsage:
            @(output ? MTLTextureUsageShaderWrite : MTLTextureUsageShaderRead)};
        CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, (__bridge CFDictionaryRef)attributes,
            plane == 0 ? MTLPixelFormatR8Unorm : MTLPixelFormatRG8Unorm,
            CVPixelBufferGetWidthOfPlane(buffer, plane),
            CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &cvTexture);
        if (result != kCVReturnSuccess || !cvTexture)
            throw failure([NSString stringWithFormat:
                @"Cannot map %@ NV12 plane %zu to Metal (CoreVideo %d). Input buffers must be IOSurface/Metal-compatible.",
                output ? @"output" : @"input", plane, result]);
        keepAlive.textures.push_back(cvTexture);
        id<MTLTexture> texture = CVMetalTextureGetTexture(cvTexture);
        if (!texture) throw failure(@"CoreVideo returned a null Metal texture");
        return texture;
    }

    CVPixelBufferRef allocateOutput() {
        NSDictionary *aux = @{(__bridge NSString *)kCVPixelBufferPoolAllocationThresholdKey: @(OutputPoolLimit)};
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
        while (true) {
            CVPixelBufferRef result = nullptr;
            CVReturn status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault, pool, (__bridge CFDictionaryRef)aux, &result);
            if (status == kCVReturnSuccess) return result;
            if (status != kCVReturnWouldExceedAllocationThreshold ||
                std::chrono::steady_clock::now() >= deadline)
                throw failure([NSString stringWithFormat:@"Cannot allocate bounded Metal output buffer (CoreVideo %d)", status]);
            CVMetalTextureCacheFlush(textureCache, 0);
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
    }
};

GPUCanvas::GPUCanvas(NSArray *panels, NSArray *bands) : impl(std::make_unique<Impl>()) {
    @autoreleasepool {
        if (panels.count != PanelCount || bands.count > BandCount)
            throw failure(@"GPUCanvas requires exactly 15 panels and at most two crawl bands");
        impl->device = MTLCreateSystemDefaultDevice();
        if (!impl->device) throw failure(@"No Metal GPU is available");
        impl->queue = [impl->device newCommandQueue];
        if (!impl->queue) throw failure(@"Cannot create Metal command queue");
        NSError *error = nil;
        MTLCompileOptions *options = [MTLCompileOptions new];
        if (@available(macOS 15.0, *)) options.mathMode = MTLMathModeFast;
        id<MTLLibrary> library = [impl->device newLibraryWithSource:shaderSource() options:options error:&error];
        if (!library) throw failure([@"Metal compositor compilation failed: " stringByAppendingString:error.localizedDescription ?: @"unknown error"]);
        impl->lumaPipeline = [impl->device newComputePipelineStateWithFunction:[library newFunctionWithName:@"renderLuma"] error:&error];
        if (!impl->lumaPipeline) throw failure([@"Cannot create Metal luma pipeline: " stringByAppendingString:error.localizedDescription ?: @"unknown error"]);
        impl->chromaPipeline = [impl->device newComputePipelineStateWithFunction:[library newFunctionWithName:@"renderChroma"] error:&error];
        if (!impl->chromaPipeline) throw failure([@"Cannot create Metal chroma pipeline: " stringByAppendingString:error.localizedDescription ?: @"unknown error"]);

        CVReturn status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, impl->device, nullptr, &impl->textureCache);
        if (status != kCVReturnSuccess) throw failure(@"Cannot create CoreVideo Metal texture cache");
        NSDictionary *poolAttributes = @{(__bridge NSString *)kCVPixelBufferPoolMinimumBufferCountKey: @3};
        NSDictionary *pixelAttributes = @{
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (__bridge NSString *)kCVPixelBufferWidthKey: @(OutputWidth),
            (__bridge NSString *)kCVPixelBufferHeightKey: @(OutputHeight),
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        status = CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes,
                                        (__bridge CFDictionaryRef)pixelAttributes, &impl->pool);
        if (status != kCVReturnSuccess) throw failure(@"Cannot create Metal NV12 output pool");

        for (size_t i = 0; i < PanelCount; ++i) {
            NSDictionary *geometry = panels[i][@"geometry"];
            float width = [geometry[@"width"] floatValue];
            float height = [geometry[@"height"] floatValue];
            float visibleWidth = [geometry[@"visible_width"] floatValue];
            float visibleHeight = [geometry[@"visible_height"] floatValue];
            if (!(width > 0 && height > 0 && visibleWidth > 0 && visibleHeight > 0))
                throw failure(@"Invalid panel geometry supplied to GPUCanvas");
            impl->uniforms.panels[i].rect = (simd_float4){[geometry[@"x"] floatValue], [geometry[@"y"] floatValue], visibleWidth, visibleHeight};
            impl->uniforms.panels[i].source = (simd_float4){width, height, 0, 0};
            for (size_t plane = 0; plane < 2; ++plane) {
                NSUInteger targetWidth = plane == 0 ? NSUInteger(width) : NSUInteger(std::ceil(width/2));
                NSUInteger targetHeight = plane == 0 ? NSUInteger(height) : NSUInteger(std::ceil(height/2));
                MTLTextureDescriptor *textureDescription = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                    (plane == 0 ? MTLPixelFormatR8Unorm : MTLPixelFormatRG8Unorm)
                    width:targetWidth height:targetHeight mipmapped:NO];
                textureDescription.storageMode = MTLStorageModePrivate;
                textureDescription.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
                impl->scaledPanels[i][plane] = [impl->device newTextureWithDescriptor:textureDescription];
                impl->panelScale[i][plane] = [[MPSImageLanczosScale alloc] initWithDevice:impl->device];
                impl->panelScale[i][plane].edgeMode = MPSImageEdgeModeClamp;
                if (!impl->scaledPanels[i][plane] || !impl->panelScale[i][plane])
                    throw failure(@"Cannot allocate GPU panel scaling resources");
            }
        }

        MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:impl->device];
        NSDictionary *loadOptions = @{MTKTextureLoaderOptionSRGB: @NO,
            MTKTextureLoaderOptionTextureUsage: @(MTLTextureUsageShaderRead),
            MTKTextureLoaderOptionTextureStorageMode: @(MTLStorageModePrivate)};
        // Bind a real tile to both slots even in validation jobs without crawls.
        MTLTextureDescriptor *dummyDescription = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:1 height:1 mipmapped:NO];
        dummyDescription.usage = MTLTextureUsageShaderRead;
        dummyDescription.storageMode = MTLStorageModeShared;
        id<MTLTexture> dummy = [impl->device newTextureWithDescriptor:dummyDescription];
        uint8_t black = 0;
        [dummy replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&black bytesPerRow:1];
        impl->tiles[0] = dummy;
        impl->tiles[1] = dummy;
        bool occupied[BandCount] = {};
        for (NSDictionary *band in bands) {
            NSString *name = band[@"name"];
            size_t i;
            if ([name isEqualToString:@"small"]) i = 0;
            else if ([name isEqualToString:@"big"]) i = 1;
            else throw failure(@"GPUCanvas crawl name must be small or big");
            if (occupied[i]) throw failure(@"Duplicate GPUCanvas crawl band");
            occupied[i] = true;
            NSString *path = band[@"tile_path"];
            if (![path isKindOfClass:NSString.class] || path.length == 0)
                throw failure(@"GPUCanvas requires tile_path; large preassembled banners cannot be loaded as Metal textures");
            id<MTLTexture> tile = [loader newTextureWithContentsOfURL:[NSURL fileURLWithPath:path] options:loadOptions error:&error];
            if (!tile) throw failure([NSString stringWithFormat:@"Cannot load crawl tile %@: %@", path, error.localizedDescription]);
            NSUInteger expectedWidth = i == 0 ? 4229 : 7603;
            NSUInteger expectedHeight = i == 0 ? 57 : 102;
            if (tile.width != expectedWidth || tile.height != expectedHeight)
                throw failure([NSString stringWithFormat:@"Unexpected %@ tile dimensions: %zux%zu", name, tile.width, tile.height]);
            float height = [band[@"height"] floatValue];
            float sourceHeight = [band[@"source_height"] floatValue];
            if (!(height > 0 && sourceHeight == expectedHeight)) throw failure(@"Invalid GPUCanvas crawl height");
            impl->tiles[i] = tile;
            impl->bandStart[i] = [band[@"start_x"] doubleValue];
            impl->bandSpeed[i] = [band[@"speed"] doubleValue];
            impl->uniforms.bands[i].geometry = (simd_float4){[band[@"y"] floatValue], height, sourceHeight, 0};
            impl->uniforms.bands[i].tile = (simd_float4){float(tile.width), float(tile.height), float(i), 1};
        }
    }
}

GPUCanvas::~GPUCanvas() = default;

CVPixelBufferRef GPUCanvas::render(const std::vector<CVPixelBufferRef>& frames, int frameIndex) {
    @autoreleasepool {
        auto begin = std::chrono::steady_clock::now();
        if (frames.size() != PanelCount || frameIndex < 0)
            throw failure(@"GPUCanvas render requires 15 frames and a nonnegative frame index");
        TextureReleases keepAlive;
        keepAlive.textures.reserve(32);
        id<MTLTexture> inputY[PanelCount];
        id<MTLTexture> inputUV[PanelCount];
        for (size_t i = 0; i < PanelCount; ++i) {
            CVPixelBufferRef frame = frames[i];
            if (!frame || CVPixelBufferGetPixelFormatType(frame) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || CVPixelBufferGetPlaneCount(frame) != 2)
                throw failure(@"GPUCanvas inputs must be limited-range NV12 (420v) pixel buffers");
            inputY[i] = impl->map(frame, 0, false, keepAlive);
            inputUV[i] = impl->map(frame, 1, false, keepAlive);
        }
        for (size_t i = 0; i < BandCount; ++i)
            impl->uniforms.bands[i].geometry.w = float(std::round(impl->bandStart[i] + impl->bandSpeed[i] * double(frameIndex) * 1001.0 / 30000.0));
        impl->uniforms.frame = (simd_uint4){uint32_t(frameIndex), 0, 0, 0};

        BufferRelease result{impl->allocateOutput()};
        CVBufferSetAttachment(result.buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(result.buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(result.buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(result.buffer, kCVImageBufferFieldCountKey, (__bridge CFNumberRef)@1, kCVAttachmentMode_ShouldPropagate);
        id<MTLTexture> outputY = impl->map(result.buffer, 0, true, keepAlive);
        id<MTLTexture> outputUV = impl->map(result.buffer, 1, true, keepAlive);
        id<MTLCommandBuffer> command = [impl->queue commandBuffer];
        command.label = @"FILLR GPU background composite";
        if (!command) throw failure(@"Cannot create Metal compositor command buffer");
        for (size_t i = 0; i < PanelCount; ++i) {
            float width = impl->uniforms.panels[i].source.x;
            float height = impl->uniforms.panels[i].source.y;
            // Chroma uses the same geometric scale as luma, including odd panel
            // heights. Its allocated plane rounds up only to hold the last row.
            MPSScaleTransform transform = {
                double(width)/double(inputY[i].width),
                double(height)/double(inputY[i].height), 0, 0};
            impl->panelScale[i][0].scaleTransform = &transform;
            [impl->panelScale[i][0] encodeToCommandBuffer:command sourceTexture:inputY[i]
                                      destinationTexture:impl->scaledPanels[i][0]];
            impl->panelScale[i][1].scaleTransform = &transform;
            [impl->panelScale[i][1] encodeToCommandBuffer:command sourceTexture:inputUV[i]
                                      destinationTexture:impl->scaledPanels[i][1]];
            inputY[i] = impl->scaledPanels[i][0];
            inputUV[i] = impl->scaledPanels[i][1];
            impl->uniforms.panels[i].source.z = width;
            impl->uniforms.panels[i].source.w = height;
        }
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        if (!encoder) throw failure(@"Cannot create Metal compositor compute encoder");
        [encoder setBytes:&impl->uniforms length:sizeof(Uniforms) atIndex:0];
        [encoder setTextures:inputY withRange:NSMakeRange(0, PanelCount)];
        [encoder setTextures:inputUV withRange:NSMakeRange(15, PanelCount)];
        [encoder setTexture:outputY atIndex:30];
        [encoder setTexture:outputUV atIndex:31];
        [encoder setTexture:impl->tiles[0] atIndex:32];
        [encoder setTexture:impl->tiles[1] atIndex:33];
        [encoder setComputePipelineState:impl->lumaPipeline];
        MTLSize group = MTLSizeMake(16, 16, 1);
        [encoder dispatchThreads:MTLSizeMake(OutputWidth, OutputHeight, 1) threadsPerThreadgroup:group];
        [encoder setComputePipelineState:impl->chromaPipeline];
        [encoder dispatchThreads:MTLSizeMake(OutputWidth/2, OutputHeight/2, 1) threadsPerThreadgroup:group];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted)
            throw failure([@"Metal compositor command failed: " stringByAppendingString:command.error.localizedDescription ?: @"unknown error"]);
        ++impl->submissions;
        if (command.GPUEndTime >= command.GPUStartTime)
            impl->gpuSeconds += command.GPUEndTime - command.GPUStartTime;
        impl->renderSeconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
        // CVMetalTexture refs survive through completion. The output is returned
        // retained independently, so VideoToolbox may consume it asynchronously.
        if ((impl->submissions % 120) == 0) CVMetalTextureCacheFlush(impl->textureCache, 0);
        CVPixelBufferRef retained = result.buffer;
        result.buffer = nullptr;
        return retained;
    }
}

NSDictionary *GPUCanvas::stats() const {
    return @{
        @"hardware_device": impl->device.name ?: @"unknown Metal device",
        @"unified_memory": @(impl->device.hasUnifiedMemory),
        @"gpu_submission_count": @(impl->submissions),
        @"gpu_seconds": @(impl->gpuSeconds),
        @"render_wall_seconds": @(impl->renderSeconds),
        @"output_buffer_pool_minimum": @3,
        @"output_buffer_pool_limit": @(OutputPoolLimit),
        @"video_processing": @"Metal Performance Shaders Lanczos antialiased full-panel Y/UV downscale, GPU 10-pixel crop/composition; no RGB video conversion",
        @"crawl_processing": @"Metal GPU reconstructs original opaque tile copies with widened Catmull-Rom antialiasing for scrolling band downscale/crop",
        @"colour": @"NV12 8-bit limited-range Rec.709; center-sited input chroma; progressive; no audio",
        @"resampling_difference": @"MPS Lanczos video and widened Catmull-Rom crawl antialiasing differ from FFmpeg bicubic"
    };
}
