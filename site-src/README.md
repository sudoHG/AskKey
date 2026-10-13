# Website source and deployment

`site/` is the website at https://askkey.sudohg.com, served as is: static HTML, CSS, a small script and assets. The only bundled code is the "How it works" film; its source and build are in [`how/`](how/README.md).

## Deploying

The site is a Cloudflare Pages project named `askkey` (Direct Upload), with the custom domain `askkey.sudohg.com`. Nothing deploys automatically: after a change to `site/` is merged into `main`, the maintainer (or an agent with the maintainer's approval) deploys that commit from a clean checkout:

```sh
npx wrangler pages deploy site --project-name askkey --branch main \
  --commit-hash "$(git rev-parse HEAD)" --commit-message "$(git log -1 --format=%s)"
```

Wrangler reads a Cloudflare API token with Pages write access from `CLOUDFLARE_API_TOKEN` and the account from `CLOUDFLARE_ACCOUNT_ID`. Never put the token in a file, an argument or a log.

Before deploying, run `npm run stamp` in `how/` if any CSS or JS changed, so pages never pair with a cached old file, and check both pages in a browser.

## Search and sharing

`site/robots.txt` points crawlers to `site/sitemap.xml`; update its `lastmod` dates when the pages change. `site/_headers` sets Cloudflare Pages response headers: the `askkey.pages.dev` mirror is marked `noindex`, hashed stylesheets, scripts and fonts are cached for a year, and pictures for a week. Each page carries its canonical URL, `hreflang` alternates, Open Graph and X card tags with its own share image (`site/assets/og-*.jpg`), and `SoftwareApplication` structured data.
