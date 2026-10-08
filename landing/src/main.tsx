import React from "react";
import ReactDOM from "react-dom/client";
import { ChakraProvider } from "@chakra-ui/react";
import App from "./App";
import { theme, tpcColorModeManager } from "./theme";

// The TPC prepaint in index.html sets the theme class before first paint; Chakra follows it.
ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <ChakraProvider theme={theme} colorModeManager={tpcColorModeManager}>
      <App />
    </ChakraProvider>
  </React.StrictMode>,
);
