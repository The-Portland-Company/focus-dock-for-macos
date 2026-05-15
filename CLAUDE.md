# Project Instructions

## Deployment

When instructed to "deploy", "publish" or other similar terms assume it means the following steps:

1. Resolve all local wips.
2. Version bump.
3. Git add commit push all local uncommitted code into proper series of commits that correlate with wips.
4. Merge all local and remote branches, unless instructed otherwise.
5. Delete those branches locally and remotely afterward.
6. Delete all local builds, artifacts, caches.
7. Rebuild and relaunch the app fresh.

## Landing page (focus-dock.pages.dev)

The Cloudflare Pages project `focus-dock` on the **The Portland Company**
account (ID `38d9c1cbb51d83ab247e96dd7685974e`) is **not git-connected** —
pushes to GitHub do NOT trigger a deploy. After committing landing-page
changes you must manually publish:

```
cd landing
npm run build
CLOUDFLARE_ACCOUNT_ID=38d9c1cbb51d83ab247e96dd7685974e \
  wrangler pages deploy dist --project-name=focus-dock --branch=main --commit-dirty=true
```

Then verify the deployed bundle hash on https://focus-dock.pages.dev/
matches the freshly built `dist/assets/index-*.js`.
