# Gumbo artwork sources

These files preserve the artwork supplied on September 20, 2026. `Gumbo.svg` is the editable vector master; `AppIcon.icon` is the supplied Icon Composer source. The original `appstore.png`, `playstore.png` and `TV-banner.png` exports are retained unchanged. They are design inputs, not additional bundled app resources.

Phone, tablet, Mac and Watch use the supplied matching raster sizes in their platform asset catalogs. Their unused alpha channels are removed for distribution; the supplied originals are retained here or in the local input backup. The two asset catalogs keep platform-specific slot metadata.

Apple TV uses the vector artwork centered to match the supplied 1920×1080 banner, then uniformly scaled and padded to each required size. No paths, colours or artwork proportions are changed. Its front layer contains the supplied mark on a transparent canvas; the back layer is solid black. Top Shelf exports flatten the same mark onto black.

`source-sha256.json` records the preserved input hashes. See GitHub issue #121 for integration and signed-device acceptance status.
