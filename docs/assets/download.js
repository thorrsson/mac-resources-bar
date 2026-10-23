/* The release DMG is universal: Intel and Apple Silicon use the same download. */
(async () => {
  const link = document.getElementById("download-link");
  const status = document.getElementById("download-status");
  const platform = navigator.userAgentData?.platform || navigator.platform || navigator.userAgent;
  const isMac = /mac/i.test(platform) && !(navigator.maxTouchPoints > 1);
  const availability = isMac
    ? "Requires macOS 13+. Supports Intel and Apple Silicon."
    : "ResourcesBar is available only for macOS 13+. Windows, Linux and mobile devices are not supported.";
  status.textContent = availability;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);
  try {
    const response = await fetch("https://api.github.com/repos/thorrsson/mac-resources-bar/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
      signal: controller.signal
    });
    if (!response.ok) {
      throw new Error(`Release lookup failed (${response.status})`);
    }
    const release = await response.json();
    const asset = Array.isArray(release.assets) && release.assets.find(
      (candidate) => /^ResourcesBar-[\d.]+\.dmg$/.test(candidate.name)
    );
    if (!asset) {
      throw new Error("The latest release has no ResourcesBar DMG");
    }
    const url = new URL(asset.browser_download_url);
    if (url.origin !== "https://github.com" ||
        !url.pathname.startsWith("/thorrsson/mac-resources-bar/releases/download/") ||
        !url.pathname.endsWith(`/${asset.name}`)) {
      throw new Error("The release DMG has an unexpected download URL");
    }
    link.href = url.href;
    link.textContent = "Download for macOS (.dmg)";
  } catch (error) {
    console.error("Unable to refresh the ResourcesBar download link:", error);
    status.textContent = `${availability} Could not check the latest release; the link downloads macOS version 1.0.5.`;
  } finally {
    clearTimeout(timeout);
  }
})();
