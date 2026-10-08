// Vendors TPC UI into this site so the build stays dependency-free.
// Modeled on tpc-product-marketing-sites/tools/tpc-ui-sync.mjs.
//
//   TPC_UI_DIR=~/Sites/tpc-ui-p1 node tools/tpc-ui-sync.mjs
//
// Outputs (all committed), under CONFIG.out:
//   vendor/theme.css, vendor/brand.css, vendor/animations.css  copies of the TPC UI sources
//   tpc-ui.css       site.css compiled by the Tailwind v4 CLI (tokens + shadcn bridge + utilities)
//   prepaint.js      the TPC ThemeScript body (system default, no flash of wrong theme)
//   consent.js       the TPC cookie banner, bundled from packages/consent's framework-agnostic core
//   legal.json       terms / privacy / cookies docs from packages/legal
// plus static /terms, /privacy, /cookies pages under CONFIG.legalOut, and the prepaint inlined
// between <!-- tpc-prepaint --> markers in each CONFIG.inject file.
// Re-run after changing site.css, consent-entry.js or markup that uses tpc-ui.css classes.
import { readFile, writeFile, copyFile, symlink, lstat, mkdir, unlink } from 'node:fs/promises'
import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'
import path from 'node:path'
import os from 'node:os'
import { CONFIG } from './tpc-ui.config.mjs'

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..')
const ui = path.resolve((process.env.TPC_UI_DIR || path.join(os.homedir(), 'Sites/tpc-ui-p1')).replace(/^~/, os.homedir()))
const out = (p) => path.join(root, CONFIG.out, p)
const require = createRequire(path.join(ui, 'package.json'))
await mkdir(out('vendor'), { recursive: true })

await copyFile(path.join(ui, 'packages/ui/src/theme.css'), out('vendor/theme.css'))
await copyFile(path.join(ui, 'packages/tokens/dist/brand.css'), out('vendor/brand.css'))
await copyFile(path.join(ui, 'packages/motion/dist/animations.css'), out('vendor/animations.css'))

// Prepaint: the exact string <ThemeScript/> renders.
const { themeScript } = require(path.join(ui, 'packages/ui/dist/theme.cjs'))
await writeFile(out('prepaint.js'), themeScript + '\n')
for (const f of CONFIG.inject || []) {
  const p = path.join(root, f)
  const src = await readFile(p, 'utf8')
  const next = src.replace(/<!-- tpc-prepaint -->[\s\S]*?<!-- \/tpc-prepaint -->/, () => `<!-- tpc-prepaint --><script data-theme-prepaint>${themeScript}</script><!-- /tpc-prepaint -->`)
  if (next !== src) await writeFile(p, next)
}

// Legal docs, bundled fallbacks (v1).
const legal = await import(path.join(ui, 'packages/legal/dist/index.js'))
const docs = Object.fromEntries([legal.termsV1, legal.privacyV1, legal.cookiesV1].map((d) => [d.kind, d]))
await writeFile(out('legal.json'), JSON.stringify(docs, null, 2) + '\n')

// Consent: vanilla IIFE from the core (no React).
const esbuild = require('esbuild')
await esbuild.build({
  entryPoints: [out('consent-entry.js')], bundle: true, format: 'iife', minify: true, target: 'es2018',
  outfile: out('consent.js'), alias: { '@tpc/consent': path.join(ui, 'packages/consent/src/index.ts') },
  banner: { js: '/* TPC consent banner, built from @the-portland-company/consent core by tools/tpc-ui-sync.mjs */' },
})

// Static legal pages.
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
const inline = (t) => esc(t)
  .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
  .replace(/\*([^*]+)\*/g, '<em>$1</em>')
  .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a class="text-primary underline underline-offset-4" href="$2">$1</a>')
const md = (src) => {
  const o = []; let list = null
  const flush = () => { if (list) { o.push(`<ul class="my-4 list-disc space-y-2 pl-6">${list.join('')}</ul>`); list = null } }
  for (const block of src.split(/\n{2,}/)) {
    for (const line of block.split('\n')) {
      const h = line.match(/^(#{1,3})\s+(.*)$/)
      if (h) { flush(); const n = h[1].length; o.push(n === 1 ? `<h1 class="mb-6 text-4xl font-bold tracking-tight">${inline(h[2])}</h1>` : `<h${n} class="mt-10 mb-3 ${n === 2 ? 'text-2xl' : 'text-lg'} font-semibold">${inline(h[2])}</h${n}>`); continue }
      const li = line.match(/^\s*[-*]\s+(.*)$/)
      if (li) { (list ||= []).push(`<li>${inline(li[1])}</li>`); continue }
      if (line.trim()) { flush(); o.push(`<p class="my-4 text-muted-foreground">${inline(line)}</p>`) }
    }
    flush()
  }
  return o.join('\n')
}
// Privacy contact address for TPC product sites (overrides the bundled doc's address).
const PRIVACY_CONTACT = 'agency@theportlandcompany.com'
const policyVersions = JSON.stringify({ terms: docs.terms.version, privacy: docs.privacy.version, cookies: docs.cookies.version })
const A = CONFIG.assetBase
export const legalFooter = `<nav class="flex flex-wrap items-center gap-x-6 gap-y-2 text-sm text-muted-foreground" aria-label="Legal">
    <a class="inline-flex min-h-11 items-center hover:text-foreground" href="/terms">Terms</a>
    <a class="inline-flex min-h-11 items-center hover:text-foreground" href="/privacy">Privacy Policy</a>
    <a class="inline-flex min-h-11 items-center hover:text-foreground" href="/cookies">Cookie Policy</a>
    <button type="button" class="inline-flex min-h-11 cursor-pointer items-center hover:text-foreground" data-tpc-cookie-settings>Cookie settings</button>
  </nav>`
for (const kind of ['terms', 'privacy', 'cookies']) {
  const doc = docs[kind]
  let body = md(doc.markdown)
  if (kind === 'privacy') body = body.replace(/contact@theportlandcompany\.com/g, PRIVACY_CONTACT)
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<script data-theme-prepaint>${themeScript}</script>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(doc.title)} | ${esc(CONFIG.name)}</title>
<meta name="description" content="${esc(doc.title)} for ${esc(CONFIG.name)} by The Portland Company.">
<link rel="canonical" href="${CONFIG.origin}/${kind}/">
<meta name="tpc-policy-versions" content="${esc(policyVersions)}">
<link rel="stylesheet" href="${A}/tpc-ui.css">
<script src="${A}/consent.js" defer></script>
<script src="${A}/theme-toggle.js" defer></script>
</head>
<body class="min-h-screen bg-background text-foreground antialiased">
<header class="border-b">
  <div class="mx-auto flex max-w-3xl items-center justify-between gap-4 px-6 py-3">
    <a class="inline-flex min-h-11 items-center font-semibold" href="/">${esc(CONFIG.name)}</a>
    <button type="button" data-tpc-theme-toggle class="inline-flex min-h-11 cursor-pointer items-center rounded-md border px-3 text-sm hover:bg-accent"><span data-tpc-theme-label>Theme</span></button>
  </div>
</header>
<main class="mx-auto max-w-3xl px-6 py-16" data-legal="${kind}" data-version="${doc.version}">
${body}
</main>
<footer class="border-t">
  <div class="mx-auto max-w-3xl px-6 py-6">
  ${legalFooter}
  </div>
</footer>
</body>
</html>
`
  await mkdir(path.join(root, CONFIG.legalOut, kind), { recursive: true })
  await writeFile(path.join(root, CONFIG.legalOut, kind, 'index.html'), html)
}

// Tailwind v4: resolve `tailwindcss` / `tw-animate-css` from the TPC UI install through a
// temporary node_modules symlink next to site.css (removed afterwards so it never ships).
const nm = path.join(root, CONFIG.out, 'node_modules')
let made = false
try { await lstat(nm) } catch { await symlink(path.join(ui, 'node_modules'), nm); made = true }
try {
  execFileSync('npx', ['-y', '@tailwindcss/cli@4.3.3', '-i', out('site.css'), '-o', out('tpc-ui.css'), '--minify'], { cwd: path.join(root, CONFIG.out), stdio: 'inherit' })
} finally { if (made) await unlink(nm) }
console.log('tpc-ui synced from', ui, 'policy versions', policyVersions)
