// Vanilla TPC cookie banner for the static product sites. Bundled into consent.js by
// tools/tpc-ui-sync.mjs. All decisions come from @the-portland-company/consent's core:
// region defaults (EU/EEA/UK/CH opt-in, elsewhere opt-out), GPC (always forces marketing off),
// Google Consent Mode v2, reprompt on policy-version bumps/expiry, consent logging, and
// activation of <script type="text/plain" data-consent="analytics|marketing"> tags.
import {
  getConsentState, acceptAll, rejectAll, saveCustom, activateGatedScripts, pushGcmUpdate,
} from '@tpc/consent'

const meta = (n) => document.querySelector(`meta[name="${n}"]`)?.content || null
const opts = {
  site: location.hostname || 'file',
  // Served by the Worker from CF-IPCountry / Sec-GPC; absent on file:// previews.
  countryCode: meta('tpc-country'),
  gpcHeader: meta('tpc-gpc'),
  policyVersions: JSON.parse(meta('tpc-policy-versions') || '{"terms":1,"privacy":1,"cookies":1}'),
}

// Consent Mode v2: everything denied by default, then updated from the resolved state.
pushGcmUpdate({ essential: true, analytics: false, marketing: false }, 'default')
let state = getConsentState(opts)
pushGcmUpdate(state.categories, 'update')

const BTN = 'inline-flex shrink-0 items-center justify-center gap-2 rounded-md text-sm font-medium whitespace-nowrap transition-[color,background-color,border-color,box-shadow,opacity,transform] duration-fast ease-standard outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50 h-9 px-4 py-2 pointer-coarse:h-11'
const PRIMARY = `${BTN} bg-primary text-primary-foreground hover:bg-primary/90`
const OUTLINE = `${BTN} border bg-background shadow-xs hover:bg-accent hover:text-accent-foreground dark:border-input dark:bg-input/30 dark:hover:bg-input/50`

function apply(record) {
  state = getConsentState(opts)
  activateGatedScripts(record ? record.categories : state.categories)
}

function message() {
  if (state.region === 'eu_eea_uk_ch') return 'Nothing beyond essential cookies runs until you accept.'
  if (state.gpc) return 'A Global Privacy Control signal was detected: marketing cookies stay off.'
  return 'You can opt out at any time.'
}

let root = null
function close() { root?.remove(); root = null }

function open(customize) {
  close()
  root = document.createElement('section')
  root.id = 'tpc-consent'
  root.setAttribute('role', 'region')
  root.setAttribute('aria-label', 'Cookie consent')
  root.className = 'fixed inset-x-0 bottom-0 z-50 border-t bg-card text-card-foreground shadow-lg'
  const c = state.categories
  root.innerHTML = `<div class="mx-auto flex max-w-6xl flex-wrap items-center gap-4 px-6 py-4">
    <p class="m-0 min-w-0 flex-[1_1_320px] text-sm">We use cookies for essential site function, and, with your choice, for analytics and marketing. ${message()} <a class="underline underline-offset-4" href="/cookies">Cookie Policy</a></p>
    <fieldset class="m-0 flex flex-wrap gap-4 border-0 p-0 text-sm" ${customize ? '' : 'hidden'}>
      <legend class="sr-only">Cookie categories</legend>
      <label class="inline-flex min-h-11 items-center gap-2"><input type="checkbox" checked disabled class="size-11 accent-primary"> Essential</label>
      <label class="inline-flex min-h-11 items-center gap-2"><input type="checkbox" name="analytics" class="size-11 accent-primary"${c.analytics ? ' checked' : ''}> Analytics</label>
      <label class="inline-flex min-h-11 items-center gap-2"><input type="checkbox" name="marketing" class="size-11 accent-primary"${c.marketing ? ' checked' : ''}${state.gpc ? ' disabled' : ''}> Marketing</label>
    </fieldset>
    <div class="flex flex-wrap gap-2">
      <button type="button" data-act="${customize ? 'save' : 'customize'}" class="${OUTLINE}">${customize ? 'Save choices' : 'Customize'}</button>
      <button type="button" data-act="reject" class="${OUTLINE}">Reject</button>
      <button type="button" data-act="accept" class="${PRIMARY}">Accept</button>
    </div>
  </div>`
  root.addEventListener('click', (e) => {
    const act = e.target.closest?.('[data-act]')?.getAttribute('data-act')
    if (!act) return
    if (act === 'customize') { open(true); root.querySelector('input[name="analytics"]')?.focus(); return }
    const q = (n) => root.querySelector(`input[name="${n}"]`).checked
    const record = act === 'accept' ? acceptAll(opts) : act === 'reject' ? rejectAll(opts) : saveCustom(opts, { analytics: q('analytics'), marketing: q('marketing') })
    apply(record)
    close()
  })
  root.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !state.needsPrompt) close() })
  document.body.appendChild(root)
}

function boot() {
  activateGatedScripts(state.categories)
  if (state.needsPrompt) open(false)
  document.addEventListener('click', (e) => {
    if (!e.target.closest?.('[data-tpc-cookie-settings]')) return
    e.preventDefault()
    open(true)
    root.querySelector('input[name="analytics"]')?.focus()
  })
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot)
else boot()
