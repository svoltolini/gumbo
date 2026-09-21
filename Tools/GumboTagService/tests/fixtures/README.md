# Test audio

The three `tone` files are generated 440 Hz sine waves lasting approximately 0.15 seconds. They contain no recordings from a music library. They are distributed under the same GPL-2.0-or-later license as this helper.

Generated with FFmpeg 7.1 (from the temporary imageio-ffmpeg 0.6.0 development tool), using `-f lavfi -i sine=frequency=440:duration=0.15`, then MP3/libmp3lame, FLAC/flac, or M4A/AAC at 64 kbps. Title, artist and comment tags let tests check unrelated metadata preservation. FFmpeg is not a runtime dependency and is not included in the service image.
