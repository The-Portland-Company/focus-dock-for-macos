import { extendTheme, cookieStorageManager } from "@chakra-ui/react";

type StorageManager = typeof cookieStorageManager;

// TPC UI bridge: Chakra reads the vendored TPC tokens (public/tpc-ui/tpc-ui.css) through CSS
// variables, so light/dark come from the TPC prepaint + theme toggle, never from hex values.
const v = (name: string) => `var(--${name})`;

export const theme = extendTheme({
  config: { initialColorMode: "system", useSystemColorMode: false, disableTransitionOnChange: false },
  fonts: {
    heading: `-apple-system, BlinkMacSystemFont, "SF Pro Display", "Inter", system-ui, sans-serif`,
    body: `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif`,
  },
  semanticTokens: {
    colors: {
      "chakra-body-bg": v("background"),
      "chakra-body-text": v("foreground"),
      "chakra-border-color": v("border"),
      "chakra-placeholder-color": v("muted-foreground"),
      "chakra-subtle-bg": v("muted"),
      "chakra-subtle-text": v("muted-foreground"),
      bg: v("background"),
      fg: v("foreground"),
      card: v("card"),
      "card-fg": v("card-foreground"),
      muted: v("muted"),
      "muted-fg": v("muted-foreground"),
      border: v("border"),
      primary: v("primary"),
      "primary-fg": v("primary-foreground"),
      accent: v("accent"),
      "accent-fg": v("accent-foreground"),
      ring: v("ring"),
      scrim: v("scrim"),
      "accent-1": v("tpc-accent-1"),
      "accent-4": v("tpc-accent-4"),
    },
  },
  styles: {
    global: {
      body: { bg: "bg", color: "fg" },
      "a:focus-visible, button:focus-visible": { outline: "2px solid var(--ring)", outlineOffset: "2px" },
    },
  },
  components: {
    Button: {
      variants: {
        tpc: {
          bg: "primary",
          color: "primary-fg",
          _hover: { bg: "primary", opacity: 0.9, _disabled: { bg: "primary" } },
          _active: { opacity: 0.85 },
        },
        ghost: { color: "fg", _hover: { bg: "accent", color: "accent-fg" }, _active: { bg: "accent" } },
        outline: { color: "fg", borderColor: "border", _hover: { bg: "accent", color: "accent-fg" } },
      },
    },
    Modal: {
      baseStyle: {
        dialog: { bg: "card", color: "card-fg", borderWidth: "1px", borderColor: "border" },
        overlay: { bg: "scrim" },
      },
    },
    Tag: {
      baseStyle: { container: { bg: "muted", color: "fg" } },
      variants: { subtle: { container: { bg: "muted", color: "fg" } } },
    },
    Badge: {
      variants: { subtle: { bg: "muted", color: "fg" } },
    },
  },
});

type Pref = "light" | "dark" | "system";
const readPref = (): Exclude<Pref, "system"> | undefined => {
  const m = typeof document !== "undefined" ? document.cookie.match(/(?:^|;\s*)(?:tpc_theme|politogy_theme)=([^;]+)/) : null;
  const p = m ? decodeURIComponent(m[1]) : null;
  return p === "light" || p === "dark" ? p : undefined; // undefined = system (initialColorMode)
};

// Chakra's color mode follows the TPC cookie. The toggle writes through window.tpcTheme
// (public/tpc-ui/theme-toggle.js), which sets BOTH tpc_theme and politogy_theme.
export const tpcColorModeManager: StorageManager = {
  type: "cookie",
  ssr: false,
  get: () => readPref(),
  // Writes happen in the toggle via window.tpcTheme.set (both cookies); Chakra only mirrors.
  set: () => {},
};
