#pragma once
#include <atomic>
#include <mutex>

// Shared by synchronous native rendering and download-transcode operations.
struct fillr_background_context {
    std::atomic<bool> cancelled{false};
    std::mutex operation;
};
