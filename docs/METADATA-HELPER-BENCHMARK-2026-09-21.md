# Metadata helper transfer benchmark — 2026-09-21

The optional helper substantially reduced network payload in a disposable local test. It did **not** reduce elapsed time on this fast loopback setup. These measurements support its transfer-saving design; they are not real-NAS performance or deployment acceptance.

## Method

[`Tools/GumboTagService/benchmark.py`](../Tools/GumboTagService/benchmark.py) generates four copies each of MP3, FLAC and AAC/M4A: 12 files containing 60 seconds of stereo seeded noise, totalling 31,333,464 original bytes. MP3 accounts for 5,766,064 bytes, FLAC for 19,760,204, and M4A for 5,807,196. Every run uses fresh copies and sets the missing genre to Jazz.

The helper route uses the real service's capabilities, stat, durable per-file job submission and final-result polling. The comparison route performs an actual loopback HTTP whole-file GET, stages/edits/verifies it on the simulated client using the same Mutagen engine, then PUTs the complete result. It models transfer cost; it is not the Apple Swift tag writer or Synology API. Both servers bind only to `127.0.0.1` and all music/state is temporary. No NAS, user library, live token or external genre provider is accessed.

The counters measure actual request/response body bytes, excluding HTTP headers and TLS. Polling is every 10 ms, so response count varies. The script verifies encoded audio and unrelated tags against the original for every result in both routes. Fixture generation and final comparison are outside each timed editing interval.

## Measured results

Python 3.9.6, macOS 27.0 arm64, Mutagen 1.47.0, bundled FFmpeg 7.1:

| Run | Helper time | Helper body bytes | Helper requests | Whole-file time | Whole-file body bytes | Whole-file requests | Body reduction |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.223571 s | 14,514 | 39 | 0.151299 s | 62,681,052 | 24 | 99.9768% |
| 2 | 0.246188 s | 14,666 | 40 | 0.150854 s | 62,681,052 | 24 | 99.9766% |
| 3 | 0.265596 s | 15,164 | 41 | 0.148181 s | 62,681,052 | 24 | 99.9758% |

All three runs verified audio and unrelated tags for all 12 files in both routes. Each helper run sent 3,188 request-body bytes. The comparison uploaded 31,347,588 modified-file bytes and downloaded 31,333,464 original-file bytes.

The helper performs durable job bookkeeping and additional polling; on cached local storage that overhead outweighed the negligible loopback transfer time. Slower real network links could benefit from avoiding whole-file transfers, but that is an expectation to measure, not an observed speed claim. Short generated files, one Mac, loopback HTTP and this reference client do not establish performance on NAS hardware, TLS, mobile devices, large libraries, varied codecs, ACLs or concurrent imports. Installation and end-to-end app-to-NAS acceptance remain open in #201.

## Reproduce

From the repository root:

```sh
python3 -m venv /tmp/gumbo-helper-benchmark
/tmp/gumbo-helper-benchmark/bin/pip install --require-hashes -r Tools/GumboTagService/requirements.txt
/tmp/gumbo-helper-benchmark/bin/pip install 'imageio-ffmpeg==0.6.0'
/tmp/gumbo-helper-benchmark/bin/python Tools/GumboTagService/benchmark.py
```

`imageio-ffmpeg` is a development-only fixture generator; it is not added to the helper image or app. Defaults are `--seconds 60 --copies 4 --repetitions 3`; the script bounds custom sizes and accepts no remote server address. The helper and its benchmark remain separately licensed GPL-2.0-or-later as described in [the helper README](../Tools/GumboTagService/README.md).
