#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#include "GPUVideoSource.hpp"
#include "GPUVideoEncoder.hpp"
#include "GPUCanvas.hpp"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <deque>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <thread>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
volatile sig_atomic_t interrupted = 0;
void onSignal(int) { interrupted = 1; }
double seconds(Clock::time_point start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}
void writeJSON(NSDictionary *value, NSString *path) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:&error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:&error])
        throw std::runtime_error(std::string("Write JSON: ") + error.localizedDescription.UTF8String);
}
double cpuSeconds(const timeval &value) { return value.tv_sec + value.tv_usec / 1e6; }

// Each source has a two-frame queue. Pixel-buffer ownership moves from the
// decoder to this queue, then to the compositor; it never caches a whole clip.
struct PanelWorker {
    NSDictionary *__strong panel;
    NSDictionary *__strong statistics;
    int expected;
    std::atomic<bool> stopped{false};
    std::mutex mutex;
    std::condition_variable ready;
    std::deque<CVPixelBufferRef> frames;
    std::thread thread;
    std::string error;
    bool done = false;
    PanelWorker(NSDictionary *value, int count) : panel(value), expected(count) {}
    ~PanelWorker() { stop(); join(); for (auto frame : frames) CVPixelBufferRelease(frame); }
    void start() {
        thread = std::thread([this] {
            @autoreleasepool {
                try {
                    GPUSource source(panel);
                    for (int n = 0; n < expected && !stopped && !interrupted; ++n) {
                        @autoreleasepool {
                            std::unique_lock<std::mutex> lock(mutex);
                            ready.wait(lock, [this] { return stopped || frames.size() < 2; });
                            if (stopped) break;
                            lock.unlock();
                            CVPixelBufferRef frame = source.next();
                            if (!frame) throw std::runtime_error("Panel ended before requested frame count");
                            lock.lock();
                            if (stopped) { CVPixelBufferRelease(frame); break; }
                            frames.push_back(frame);
                            ready.notify_all();
                        }
                    }
                    statistics = source.stats();
                } catch (const std::exception &failure) {
                    std::lock_guard<std::mutex> lock(mutex);
                    error = failure.what();
                }
                std::lock_guard<std::mutex> lock(mutex);
                done = true;
                ready.notify_all();
            }
        });
    }
    CVPixelBufferRef pop() {
        std::unique_lock<std::mutex> lock(mutex);
        while (frames.empty() && !done && !stopped && !interrupted)
            ready.wait_for(lock, std::chrono::milliseconds(100));
        if (interrupted) throw std::runtime_error("Interrupted");
        if (!error.empty()) throw std::runtime_error(error);
        if (frames.empty()) throw std::runtime_error("Source queue ended before timeline");
        auto frame = frames.front(); frames.pop_front(); ready.notify_all(); return frame;
    }
    void stop() {
        { std::lock_guard<std::mutex> lock(mutex); stopped = true; }
        ready.notify_all();
    }
    void join() { if (thread.joinable()) thread.join(); }
};

void saveStill(CVPixelBufferRef pixel, NSString *path) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        throw std::runtime_error("Validation PNG already exists");
    CIContext *context = [CIContext contextWithMTLDevice:MTLCreateSystemDefaultDevice()];
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixel];
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef rendered = [context createCGImage:image fromRect:CGRectMake(0, 0, 1920, 1080)
                                       format:kCIFormatRGBA8 colorSpace:color];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                                CFSTR("public.png"), 1, nullptr);
    bool ok = rendered && dest;
    if (ok) { CGImageDestinationAddImage(dest, rendered, nullptr); ok = CGImageDestinationFinalize(dest); }
    if (dest) CFRelease(dest);
    if (rendered) CGImageRelease(rendered);
    CGColorSpaceRelease(color);
    if (!ok) throw std::runtime_error("Could not write functional validation PNG");
}
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableDictionary *args = [NSMutableDictionary dictionary];
        for (int i = 1; i < argc; i += 2) {
            if (i + 1 >= argc || strncmp(argv[i], "--", 2)) {
                std::cerr << "Usage: --job JSON --output MP4 --progress JSON --report JSON [--validate-frame PNG]\n";
                return 2;
            }
            args[@(argv[i] + 2)] = @(argv[i + 1]);
        }
        NSString *reportPath = args[@"report"];
        if (!args[@"job"] || !reportPath || (!args[@"output"] && !args[@"validate-frame"])) return 2;
        std::signal(SIGINT, onSignal); std::signal(SIGTERM, onSignal);
        const auto started = Clock::now();
        rusage before{}; getrusage(RUSAGE_SELF, &before);
        NSMutableDictionary *report = [@{@"status": @"preparing", @"pipeline": @"metal-native-hybrid",
            @"source_queue_frames_per_panel": @2, @"silent": @YES,
            @"timing_scope": @"Native pipeline initialization, source decoding, GPU filters/composition, hardware encode and MP4 finalization"} mutableCopy];
        std::vector<std::unique_ptr<PanelWorker>> workers;
        std::vector<CVPixelBufferRef> inputs;
        CVPixelBufferRef composed = nullptr;
        int completed = 0;
        try {
            NSError *error = nil;
            NSData *data = [NSData dataWithContentsOfFile:args[@"job"] options:0 error:&error];
            NSDictionary *job = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
            if (!job || ![job isKindOfClass:[NSDictionary class]]) throw std::runtime_error("Could not read GPU job JSON");
            int frames = [job[@"frames"] intValue];
            NSArray *panels = job[@"panels"], *bands = job[@"bands"];
            if (frames < 1 || panels.count != 15 || bands.count != 2 || ![job[@"frame_rate"] isEqual:@"30000/1001"])
                throw std::runtime_error("Unsupported GPU job: expected 15 panels, 2 crawls and 30000/1001 fps");
            bool still = args[@"validate-frame"] != nil;
            if (!still && [[NSFileManager defaultManager] fileExistsAtPath:args[@"output"]])
                throw std::runtime_error("Output video already exists");
            report[@"expected_frames"] = @(frames);
            report[@"functional_still_only"] = @(still);
            GPUCanvas canvas(panels, bands);
            std::unique_ptr<GPUEncoder> encoder;
            if (!still) encoder = std::make_unique<GPUEncoder>(args[@"output"], frames);
            for (NSDictionary *panel in panels) {
                workers.emplace_back(std::make_unique<PanelWorker>(panel, still ? 1 : frames));
                workers.back()->start();
            }
            double lastProgress = -10;
            for (int n = 0; n < (still ? 1 : frames); ++n) {
                for (auto &worker : workers) inputs.push_back(worker->pop());
                composed = canvas.render(inputs, n);
                for (auto frame : inputs) CVPixelBufferRelease(frame);
                inputs.clear();
                if (still) saveStill(composed, args[@"validate-frame"]);
                else encoder->append(composed, n);
                CVPixelBufferRelease(composed); composed = nullptr;
                completed = n + 1;
                double elapsed = seconds(started);
                if (!still && (elapsed - lastProgress >= 5 || completed == frames)) {
                    NSDictionary *progress = @{@"frames": @(completed), @"total_frames": @(frames),
                        @"elapsed_seconds": @(elapsed), @"fps": @(completed / elapsed)};
                    if (args[@"progress"]) writeJSON(progress, args[@"progress"]);
                    std::cout << "GPU frame " << completed << "/" << frames << "  " << completed / elapsed << " fps\n" << std::flush;
                    lastProgress = elapsed;
                }
            }
            for (auto &worker : workers) worker->join();
            NSMutableArray *sources = [NSMutableArray array];
            for (auto &worker : workers) {
                if (!worker->error.empty()) throw std::runtime_error(worker->error);
                if (!worker->frames.empty()) throw std::runtime_error("Unconsumed source frame after timeline");
                [sources addObject:worker->statistics ?: @{}];
            }
            if (encoder) { encoder->finish(); report[@"encoder"] = encoder->stats(); }
            report[@"sources"] = sources;
            report[@"canvas"] = canvas.stats();
            report[@"status"] = still ? @"functional_still_complete" : @"encoded";
        } catch (const std::exception &failure) {
            report[@"status"] = @"failed"; report[@"error"] = @(failure.what());
            std::cerr << failure.what() << "\n";
        }
        if (composed) CVPixelBufferRelease(composed);
        for (auto frame : inputs) CVPixelBufferRelease(frame);
        for (auto &worker : workers) worker->stop();
        for (auto &worker : workers) worker->join();
        rusage after{}; getrusage(RUSAGE_SELF, &after);
        report[@"completed_frames"] = @(completed);
        report[@"elapsed_seconds"] = @(seconds(started));
        report[@"cpu_user_seconds"] = @(cpuSeconds(after.ru_utime) - cpuSeconds(before.ru_utime));
        report[@"cpu_system_seconds"] = @(cpuSeconds(after.ru_stime) - cpuSeconds(before.ru_stime));
        report[@"max_rss_bytes"] = @(after.ru_maxrss);
        report[@"cpu_accounting_limit"] = @"This process and all its threads; excludes external VideoToolbox service CPU";
        try { writeJSON(report, reportPath); }
        catch (const std::exception &failure) { std::cerr << failure.what() << "\n"; return 1; }
        return [report[@"status"] isEqual:@"failed"] ? 1 : 0;
    }
}
