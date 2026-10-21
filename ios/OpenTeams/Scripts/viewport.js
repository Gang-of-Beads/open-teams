(() => {
  const content = "width=device-width, initial-scale=1, maximum-scale=1, shrink-to-fit=no";
  const apply = () => {
    let meta = document.querySelector('meta[name="viewport"]');
    if (!meta) {
      meta = document.createElement("meta");
      meta.name = "viewport";
      (document.head || document.documentElement).appendChild(meta);
    }
    if (meta.content !== content) meta.content = content;
  };
  apply();
  new MutationObserver(apply).observe(document.head || document.documentElement, {
    subtree: true, childList: true, attributes: true, attributeFilter: ["content"],
  });
})();
