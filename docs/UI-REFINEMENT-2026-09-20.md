# Search, sync activity and Gumbo colours

Implementation issues: #126, #127 and #128. Build: 1.0 (202609201513).

## Interaction decisions

- Keep one global Search destination for artists, albums and songs. The phone/iPad field belongs to Search's navigation stack; the shared tab container no longer exposes a field over unrelated pages. Mac keeps its existing global toolbar search, which opens its Search section.
- Keep the phone tab bar and mini-player in place while scrolling. Search retains one list through idle, loading, results and no-results states. Existing results remain visible but disabled while a newer query is being evaluated, avoiding a blank-screen flash or activation of stale results.
- Wait 160 ms after typing before querying an immutable index away from the UI actor. Match case, accent and width variants, accept multiple words across title/artist/album/genre metadata, and rank title matches ahead of metadata-only matches. Bound displayed results to 20 artists, 30 albums and 50 songs.
- Cancel superseded work and validate query, catalogue revision, server and root before publishing. A source/root change cannot present the preceding index as the new source. Profile navigation reset clears the query.
- Rotate the library scan icon for active scanning, including the Mac toolbar and scan details. Reduce Motion keeps a static labelled icon. Idle and failed scan states keep distinct icons and accessible status.
- At accessibility text sizes, search result labels and shared album rows wrap instead of fading away. Song duration moves beneath metadata so it cannot squeeze the title.

## Colour roles

| Role | Light | Dark |
| --- | --- | --- |
| Main canvas | Silver `#D4D5D6` | Black `#000000` |
| Primary filled actions / selected chips | Blue `#0826FF` | Blue `#0826FF` |
| Labels on blue | Silver | Silver |
| Unfilled action text and indicators | Blue | Silver for contrast |
| Main palette text | Black | Silver |

Native cards, glass, secondary labels and error/destructive colours retain their system semantics. Album art and user-selected profile colours remain content. The former cover-tinted canvas is now neutral; smart playlist art, Watch controls, widget placeholders and download activity styling use the Gumbo palette.

## Validation and remaining acceptance

- 427 Release package tests in 25 suites passed, including six new search regressions covering normalization, multi-word metadata, ranking, cancellation, source/root replacement and profile reset.
- All 20 preflight checks passed.
- Signed Release iPhone build (including Watch/widgets), unsigned Release Mac and TV Simulator builds, and Debug iPhone Simulator build passed.
- Static sample-library renders inspected on a 390-point-wide phone and iPad mini; light/dark search, empty search, other tabs and accessibility text checked during implementation. These are rendered-state checks, not gesture automation.
- Physical scrolling, keyboard presentation/dismissal, tab switching while playing, live sync animation, Reduce Motion and real NAS search responsiveness remain acceptance checks in #123. Build success and screenshots do not establish those journeys.

## Reproducing layout fixtures

In a **Debug iOS Simulator** build, launch with `--sample-library --ui-preview`. Optional arguments are `--preview-tab search|playlists|downloads|settings`, `--preview-query <text>` and `--preview-dark`.

The fixture uses ordinary profile admission and sample catalogue data, with CloudKit startup/foreground refresh disabled so account checks cannot replace the preview profile. It does not bypass a PIN or unreadable profile storage. These preview arguments have no effect in device or Release builds. Use a disposable simulator; appearance is a persisted preference there.
