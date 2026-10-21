(() => {
  if (window.__openTeamsSessionMaintenance) return;
  const app = document.getElementById("app");
  const root = app?._reactRootContainer?._internalRoot || app?._reactRootContainer;
  const props = root?.current?.updateQueue?.baseState?.element?.props;
  const services = props?.coreServices || props?.children?.props?.coreServices;
  const provider = services?.authenticationService?._coreAuthService?._authProvider;
  if (typeof provider?.acquireToken !== "function" || !services?.correlation) return;
  window.__openTeamsSessionMaintenance = true;
  // Do not return the promise/result to WKWebView: it can contain tokens.
  const timeout = setTimeout(() => { window.__openTeamsSessionMaintenance = false; }, 30000);
  Promise.resolve().then(() => provider.acquireToken("https://graph.microsoft.com", {
    correlation: services.correlation, prompt: "none",
    forceRenew: false, forceRefresh: false, skipCache: false,
  })).catch(() => {
    // MFA, sign-in frequency and revoked sessions still require Teams'
    // normal login flow. Do not retry or attempt to bypass tenant policy.
    console.warn("[SESSION] Silent renewal requires Teams sign-in or is unavailable");
  }).finally(() => {
    clearTimeout(timeout);
    window.__openTeamsSessionMaintenance = false;
  });
})();
