# Apple Watch album artwork

Tracked in [#186](https://github.com/svoltolini/gumbo/issues/186).

The Watch player publishes album artwork to the native Now Playing screen alongside the song title and artist. Covers come from images already cached from the user's NAS or music tags. No external artwork service is called. Missing covers use the existing system fallback.

The phone gathers cover URLs for the active profile's Watch catalogue. An isolated actor creates small JPEG thumbnails, stripping original image metadata. Transfers include one image per album, with limits of 64 albums, 192 pixels per image, 24 KB per image and 500 KB overall. No local file URL travels to Watch. Large catalogues use the existing queued file-transfer path instead of exceeding the interactive message limit.

Artwork preparation is canceled and invalidated when the authorization scope changes. The cache includes that scope and the source cover revision. A debounced cover revision signal also updates Watch when the picture changes without changing playlist metadata or extracted colours. The receiving side bounds image data, validates thumbnail dimensions before display and clears artwork on authorization changes. Older catalogue payloads still decode without artwork.

Catalogue snapshots have a monotonic revision within each authorization, so an older transfer cannot overwrite a newer artwork or deletion update. The iPhone saves the latest snapshot revision with the authorization, so the order holds across its relaunches. Thumbnails are cached only in memory, so after a relaunch that keeps the authorization the iPhone sends no catalogue until the first thumbnail batch is ready; the Watch keeps the covers it has meanwhile. Revision and generation time do not affect content deduplication.

Tests cover compatibility, source filtering, transfer budgets, changed covers, out-of-order snapshots, deletion and download races. The website capture uses the native Watch player with sample-library metadata and cover artwork in an isolated simulator. Physical Watch delivery and offline playback remain device acceptance checks; simulator captures do not prove real WatchConnectivity delivery.
