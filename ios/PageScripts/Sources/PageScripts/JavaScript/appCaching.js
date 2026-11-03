// Turns off Teams' precaching and caching of hosted apps (Calendar,
// OneDrive, Copilot, ...) through Teams' own settings.
//
// Teams keeps hosted apps as hidden cached iframes: Calendar is precached at
// startup (ECS core.enableAppPreCaching with
// extensibility.appPrecachingOptInAppList), and every opened hosted app stays
// cached after it is left. Each is a whole web app in the same web content
// process, which iOS kills at its 2 GB limit, ending any call with it. See
// "Memory budget" in ios/README.md.
//
// Teams' settings service merges a localStorage provider ("tmp.settings",
// { namespace: { key: value } }) over ECS, overrides and policy, and creates
// it in production builds. Writing the keys there before Teams starts makes
// Teams load a hosted app when it is opened and unload it when it is left,
// using its own non-cached code path. Other keys in tmp.settings are kept.
(() => {
  const host = location.hostname;
  if (!(host === "teams.cloud.microsoft" || host === "teams.microsoft.com" ||
        host.endsWith(".teams.microsoft.com"))) return;

  const KEY = "tmp.settings";
  const OVERRIDES = {
    core: { enableAppPreCaching: false },
    extensibility: { enableAppCachingNS: false, enableAppCachinginMainContentNS: false },
  };

  try {
    let settings = {};
    try {
      const stored = JSON.parse(localStorage.getItem(KEY) || "{}");
      if (stored && typeof stored === "object" && !Array.isArray(stored)) settings = stored;
    } catch { /* unreadable: replaced below */ }
    let changed = false;
    for (const [namespace, values] of Object.entries(OVERRIDES)) {
      const current = settings[namespace] && typeof settings[namespace] === "object" ? settings[namespace] : {};
      for (const [key, value] of Object.entries(values)) {
        if (current[key] !== value) { current[key] = value; changed = true; }
      }
      settings[namespace] = current;
    }
    if (changed) {
      localStorage.setItem(KEY, JSON.stringify(settings));
      console.info("[APPCACHE] Teams app caching and precaching turned off");
    }
  } catch {
    console.warn("[APPCACHE] Could not write Teams settings");
  }
})();
