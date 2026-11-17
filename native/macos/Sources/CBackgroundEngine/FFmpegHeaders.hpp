#pragma once

#if !__has_include(<libavcodec/avcodec.h>)
#error "Native FFmpeg libraries are missing. Run ./script/build_background_ffmpeg_macos.sh before building FILLR."
#endif
