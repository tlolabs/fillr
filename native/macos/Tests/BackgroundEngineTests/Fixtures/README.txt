three-frame-two-audio.mpg is a synthetic test fixture: three 32x32 interlaced
MPEG-2 frames at 30000/1001 fps, top field first, with two 48 kHz mono MP2
tracks (440 Hz and 880 Hz sine waves, 5760 decoded samples in each track).
It contains no user footage. It exercises built-in MPEG-2/MP2 decoding,
field-preserving ProRes LT encoding, PCM24 output and complete verification.

Generated once with FFmpeg 9 using testsrc2, two sine filters, -t 0.1,
setfield=tff, mpeg2video -flags +ildct+ilme -field_order tt, and mp2 at 64k.
Tests consume the fixture directly and require no external media tools.

zero-padded-slices.m2v demuxes the same three synthetic frames and appends
three zero bytes after each MPEG-2 slice. The decoded frame hashes are identical
to the original. This covers broadcaster padding rejected by AV_EF_BITSTREAM
despite complete, error-free decoding with CRC/buffer/error-explosion checks.

offset-audio-first.mpg remuxes the same synthetic video and first audio track,
lists audio before video and delays video by 0.000333 seconds. It covers complete
sample preservation and fractional millisecond A/V synchronization with audio
as the reference stream. It also passed before the tolerance robustness change;
it does not reproduce a claimed movie-timescale failure in pinned FFmpeg 9.
