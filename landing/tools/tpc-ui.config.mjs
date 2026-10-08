// Site-specific settings for tools/tpc-ui-sync.mjs.
export const CONFIG = {
  name: 'Focus Dock',
  origin: 'https://focus-dock.pages.dev',
  out: 'public/tpc-ui',      // vendored + compiled TPC UI, served at /tpc-ui/
  assetBase: '/tpc-ui',
  legalOut: 'public',        // writes public/{terms,privacy,cookies}/index.html
  inject: ['index.html'],    // inline prepaint between <!-- tpc-prepaint --> markers
}
