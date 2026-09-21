# Gumbo · gumbo.one

Static HTML/CSS with a small script. No dependencies or build step.

## TestFlight invitation

The external **Gumbo Founding Testers** group’s enrollment settings are managed in App Store Connect. Keep numeric capacity out of public website copy. The invitation is configured once in `index.html`, near the top of `<head>`:

```js
const TESTFLIGHT_PUBLIC_LINK = "https://testflight.apple.com/join/GensWMTh";
```

This one constant controls every beta button through `site.js`. For a replacement group, use its actual `https://testflight.apple.com/join/ALPHANUMERIC` invitation URL. Empty/invalid links lead to the beta section with a coming-soon message. Without JavaScript, a note directly below the header explains that the buttons lead to beta details and JavaScript is needed to open the configured invitation. The section menu still works using native HTML; the header stops being sticky so an open menu cannot cover an anchor destination.

Apple approved all three platform builds for external testing. On 21 September 2026, App Store Connect reported `IN_BETA_TESTING` for iOS, macOS and tvOS build `202609202112`, and the public page offered **View Gumbo Music Beta** and **View in TestFlight**. TestFlight remains the authority for current beta and build availability. See [issue #162](https://github.com/svoltolini/gumbo/issues/162) for the acceptance evidence; this does not replace physical-device/NAS testing.

## Preview and customise

From this folder, run `python3 -m http.server 8000`, then open `http://localhost:8000`.

- **Brand and products:** Gumbo is the text-only umbrella wordmark. Music stays at `/`; Film has a static `/film/` page marked **In development**. The product navigation uses ordinary links with `aria-current="page"`, so it works without JavaScript. Keep product logos, copy, favicons and social cards specific to their product. Add future products as separate pages using the same shell; do not promise unconfirmed features or release dates.
- **Screenshots:** replace each entire decorative mockup `<div>` with `<img class="desktop-preview product-screenshot">` for Mac or `<img class="phone-preview product-screenshot">` for iPhone. Add `src`, descriptive `alt`, and natural `width`/`height`. The visible preview caption has been removed. HTML comments mark both slots; the Mac and iPhone visuals remain illustrative mockups. The figure has an accessible description. `assets/gumbo-watch-playlists.png` is a real 416 × 496 Watch simulator screenshot of Gumbo’s built-in sample playlists, presented inside a CSS Watch frame; do not replace it with an invented interface.
- **Social image:** `assets/gumbo-music-social-v4.png` is the production **1200 × 630** branded card; its editable source is `assets/og-image.svg`. Render that SVG at its natural size after editing. Use a new image filename for future revisions and update both Open Graph and Twitter image URLs together so refreshed previews request the new asset. `assets/og-image.png` is retained as a compatibility copy for older links. `assets/logo.svg` preserves the supplied mark’s paths with its black backing removed. `assets/logo-on-light.svg` uses blue and black for contrast on the silver beta panel.
- **Favicons:** `favicon.svg` uses the transparent Gumbo mark with less surrounding padding for small sizes. `favicon.ico` contains transparent 16, 32 and 48px versions; `apple-touch-icon.png` is an opaque 180 × 180 image on the site’s charcoal background (`#101011`). These Music icons are linked in the Music and privacy HTML heads with absolute production URLs. Film has its own complete set in `film/`, derived from its supplied mark.
- **Preview metadata:** Open Graph and Twitter tags are written directly in the HTML `<head>`, so crawlers receive them without running JavaScript. After deployment, check the raw HTML at `https://gumbo.one/` and fetch the linked images/icons; verify their dimensions and content types. Existing preview services may retain their own caches until they fetch the page again.

Use **Gumbo** and **Gumbo Music** with this exact casing in visible branding. Domain names and technical identifiers stay lowercase. The current beta supports Synology DSM/File Station only; general NAS wording must keep that requirement clear.

The hero and **Devices** section highlight iPhone, iPad, Mac, Apple TV, Apple Watch, CarPlay and AirPlay. Public product labels say **Apple Watch**. Keep setup requirements clear in supporting copy: Watch needs a paired iPhone for setup and playlist sync, CarPlay uses the connected iPhone, and Apple TV streams rather than retaining offline downloads. Do not promise playback handoff or a shared live queue. Minimum versions in the beta section match `project.yml`: iOS/iPadOS 26.1, macOS/tvOS/watchOS 26.0. Recheck these when platform support changes.

The beta's free-year-at-launch offer is supplied by the owner. Keep privacy wording precise: no separate Gumbo account or music upload to a Gumbo cloud library; audio streams/downloads to devices, while iCloud syncs profiles and listening data. Remote streaming needs configured NAS access. The landing summary links to the dedicated app and website policy at `privacy/index.html`, published at `https://gumbo.one/privacy/`. Keep both aligned with the app’s actual data flows. The policy has its own static metadata and is included in the sitemap. During the beta it provides the verified developer-contact route in TestFlight; no unpublished contact email is exposed. App Store privacy fields and declarations are managed separately.

## Navigation and privacy page

The mobile menu uses native `<details>` and `<summary>`, so section links remain available without JavaScript. The script adds dismissal on section selection, outside click, Escape (with focus returned), focus leaving the menu, and switching to desktop width. Check these behaviors with a keyboard and at narrow widths after changing the header.

The standalone `privacy/index.html` and `film/index.html` use relative links to shared styles/assets and the landing page, so it also works on GitHub Pages and Netlify without custom rewrites. Neither contains a beta invitation constant. Film links visitors to Music; the privacy page links back to Music’s beta details. When moving domains, update canonical/social URLs in **all three** HTML files and the sitemap.

### Film artwork and page

`assets/film-logo.svg` preserves the two paths and colours from the supplied Film SVG, removing only its solid backing and adjusting the viewBox for display. Its mark is used only for Film. `assets/gumbo-film-social-v1.svg` and `.png` provide the editable and 1200 × 630 social card, with Film-specific title, description and icons in the HTML head. The page describes the planned film/series product without implying a downloadable build. Music remains the only public beta. The shared website privacy policy covers visits to both pages; a future Film app will need disclosures matched to its actual implementation.

## Vercel (current host)

The **`gumbo`** project in **`svoltolinis-projects`** is connected to **`svoltolini/gumbo`**. Its production branch is **`main`**, root directory is **`website`**, framework preset is **Other**, and output directory is **`.`**. `vercel.json` explicitly disables install and build commands; Vercel serves these static files directly.

Merge website changes into `main` to update production through the Git integration. Check the deployment is **Ready** in Vercel before verifying the public page. For a new import, select the same repository and settings above. [Vercel Git deployment guide](https://vercel.com/docs/git).

The canonical address is `https://gumbo.one`; `www.gumbo.one` is configured in the Vercel project's Domains settings as a **308 redirect to `gumbo.one`**. The redirect belongs to the project settings, so it is not duplicated in `vercel.json`.

Keep GoDaddy's nameservers and set only the website's apex A and `www` CNAME records to the exact values shown by Vercel for this project. Preserve unrelated DNS records. Once DNS is correct, verify trusted HTTPS on the apex, the `www` redirect, and that both addresses reach this page. A Ready deployment alone does not prove the custom domain is live. [Custom-domain guide](https://vercel.com/docs/domains/working-with-domains/add-a-domain), [domain redirects](https://vercel.com/docs/domains/working-with-domains/deploying-and-redirecting).

## Alternative: GitHub Pages

1. Copy `deploy/github-pages.yml.example` to `.github/workflows/website-pages.yml` at the **repository root** and commit it.
2. Select **GitHub Actions** in **Settings → Pages**.
3. Run **Deploy Gumbo website → Run workflow** from your intended branch. It manually publishes `website/`, without building the Apple apps.

For a standalone website repository, put this folder's contents at its root and change the workflow artifact `path` to `.`. [Workflow guide](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

Set `gumbo.one` in Pages, configure registrar DNS, then enable HTTPS. Follow [GitHub's custom-domain guide](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site); `CNAME` alone does not configure the domain.

## Alternative: Netlify

Import the app repository: **base `website`**, **publish `.`**, **no build command**. For a standalone repository, leave base empty. `netlify.toml` sets the publish path. Manual folder upload also works. [Deployment guide](https://docs.netlify.com/start/quickstarts/deploy-from-repository/), [monorepo settings](https://docs.netlify.com/build/configure-builds/monorepos/).

Add `gumbo.one` as primary domain, configure DNS and verify HTTPS using [Netlify's domain guide](https://docs.netlify.com/manage/domains/configure-domains/bring-a-domain-to-netlify/).

File delivery does **not** publish the site, configure DNS or enable public TestFlight access. After deployment, check mobile layout, keyboard navigation, beta buttons and the social image. For another domain, update `index.html` canonical/social URLs, `CNAME`, `robots.txt` and `sitemap.xml`.
