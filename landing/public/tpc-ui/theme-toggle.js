/* TPC theme toggle (vanilla). Mirrors @the-portland-company/ui applyThemeChoice:
   writes BOTH the tpc_theme and legacy politogy_theme cookies (shared domain on allowlisted
   parents, host-only elsewhere), localStorage, and the resolved class on <html>.
   Any element with [data-tpc-theme-toggle] cycles light -> dark -> system. */
(function () {
  var VALID = ['light', 'dark', 'system']
  var ALLOW = ['.theportlandcompany.com', '.politogyvrm.com', '.agentswarmapp.com']
  var YEAR = 60 * 60 * 24 * 365
  function domain() {
    var h = location.hostname.toLowerCase()
    for (var i = 0; i < ALLOW.length; i++) { var b = ALLOW[i].slice(1); if (h === b || h.slice(-ALLOW[i].length) === ALLOW[i]) return ALLOW[i] }
    return null
  }
  function readCookie(n) { var m = document.cookie.match(new RegExp('(?:^|;\\s*)' + n + '=([^;]+)')); return m ? decodeURIComponent(m[1]) : null }
  function writeCookie(n, v) {
    var d = domain()
    document.cookie = n + '=' + encodeURIComponent(v) + '; Path=/; Max-Age=' + YEAR + '; SameSite=Lax' + (d ? '; Domain=' + d : '') + (location.protocol === 'https:' ? '; Secure' : '')
  }
  function get() {
    var v = readCookie('tpc_theme') || readCookie('politogy_theme')
    if (!v) { try { v = localStorage.getItem('tpc_theme') } catch (e) {} }
    return VALID.indexOf(v) === -1 ? 'system' : v
  }
  function resolve(p) { return p === 'system' ? (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light') : p }
  function set(p) {
    if (VALID.indexOf(p) === -1) p = 'system'
    writeCookie('tpc_theme', p)
    writeCookie('politogy_theme', p)
    try { localStorage.setItem('tpc_theme', p) } catch (e) {}
    var r = resolve(p), d = document.documentElement
    d.classList.toggle('dark', r === 'dark')
    d.classList.toggle('light', p === 'light')
    try { d.style.colorScheme = r } catch (e) {}
    label()
    try { window.dispatchEvent(new CustomEvent('tpc-theme', { detail: { preference: p, resolved: r } })) } catch (e) {}
  }
  function next() { var p = get(); return p === 'light' ? 'dark' : p === 'dark' ? 'system' : 'light' }
  function label() {
    var p = get()
    var els = document.querySelectorAll('[data-tpc-theme-toggle]')
    for (var i = 0; i < els.length; i++) {
      var name = p === 'system' ? 'Auto' : p === 'dark' ? 'Dark' : 'Light'
      var t = els[i].querySelector('[data-tpc-theme-label]')
      if (t) t.textContent = name
      // aria-label starts with the visible text (WCAG 2.5.3 label-in-name).
      els[i].setAttribute('aria-label', (t ? name + ' theme' : 'Theme: ' + name) + ', switch to ' + next())
      els[i].setAttribute('data-theme-pref', p)
    }
  }
  window.tpcTheme = { get: get, set: set, next: next, resolve: resolve }
  document.addEventListener('click', function (e) {
    var b = e.target.closest && e.target.closest('[data-tpc-theme-toggle]')
    if (!b) return
    e.preventDefault()
    set(next())
  })
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', label)
  else label()
})()
