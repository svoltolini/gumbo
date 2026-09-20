# Gumbo · gumbo.one

Static HTML/CSS with a small script. No dependencies or build step.

## Paste the TestFlight link

In `index.html`, near the top of `<head>`, replace the empty string:

```js
const TESTFLIGHT_PUBLIC_LINK = "";
```

Use your actual `https://testflight.apple.com/join/ALPHANUMERIC` public invitation URL. This one constant controls every beta button through `site.js`. Empty/invalid links lead to the beta section with a coming-soon message. Without JavaScript, visitors can still read the page and beta information.

## Preview and customise

From this folder, run `python3 -m http.server 8000`, then open `http://localhost:8000`.

- **Product copy:** the marked **PRODUCT: GUMBO MUSIC** `<main id="product-music">` contains visible product copy. For a future product, retain the Gumbo header/footer and shared styles; update the product block, separately marked SEO in `<head>`, and social image together.
- **Screenshots:** replace each entire decorative mockup `<div>` with `<img class="desktop-preview product-screenshot">` for Mac or `<img class="phone-preview product-screenshot">` for iPhone. Add `src`, descriptive `alt`, and natural `width`/`height`. Update the preview caption. HTML comments mark both slots; current mockups are not screenshots.
- **Social image:** replace `assets/og-image.png` (**1200 × 630**). Its editable source is `assets/og-image.svg`. `assets/logo.svg` is the supplied logo.

The beta's limited-first-batch/free-year-at-launch offer is supplied by the owner. Keep privacy wording precise: no separate Gumbo account or music upload to a Gumbo cloud library; audio streams/downloads to devices, while iCloud syncs profiles and listening data. Remote streaming needs configured NAS access. This page does not replace the final app privacy policy.

## GitHub Pages

1. Copy `deploy/github-pages.yml.example` to `.github/workflows/website-pages.yml` at the **repository root** and commit it.
2. Select **GitHub Actions** in **Settings → Pages**.
3. Run **Deploy Gumbo website → Run workflow** from your intended branch. It manually publishes `website/`, without building the Apple apps.

For a standalone website repository, put this folder's contents at its root and change the workflow artifact `path` to `.`. [Workflow guide](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

Set `gumbo.one` in Pages, configure registrar DNS, then enable HTTPS. Follow [GitHub's custom-domain guide](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site); `CNAME` alone does not configure the domain.

## Netlify

Import the app repository: **base `website`**, **publish `.`**, **no build command**. For a standalone repository, leave base empty. `netlify.toml` sets the publish path. Manual folder upload also works. [Deployment guide](https://docs.netlify.com/start/quickstarts/deploy-from-repository/), [monorepo settings](https://docs.netlify.com/build/configure-builds/monorepos/).

Add `gumbo.one` as primary domain, configure DNS and verify HTTPS using [Netlify's domain guide](https://docs.netlify.com/manage/domains/configure-domains/bring-a-domain-to-netlify/).

File delivery does **not** publish the site, configure DNS or enable public TestFlight access. After deployment, check mobile layout, keyboard navigation, beta buttons and the social image. For another domain, update `index.html` canonical/social URLs, `CNAME`, `robots.txt` and `sitemap.xml`.
