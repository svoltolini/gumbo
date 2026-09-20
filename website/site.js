/* Progressive enhancement only: the content and section links work without JavaScript. */
(() => {
  "use strict";
  const status = document.getElementById("beta-status");
  const links = document.querySelectorAll("[data-beta-link]");
  let invitation = null;

  try {
    const configured = typeof TESTFLIGHT_PUBLIC_LINK === "string" ? TESTFLIGHT_PUBLIC_LINK.trim() : "";
    if (configured) {
      const url = new URL(configured);
      if (url.protocol === "https:" && url.hostname === "testflight.apple.com" &&
          !url.username && !url.password && !url.port && /^\/join\/[a-z0-9]+\/?$/i.test(url.pathname)) {
        invitation = url.href;
      }
    }
  } catch { /* An unfinished link keeps the honest, accessible coming-soon state. */ }

  if (invitation) {
    links.forEach(link => {
      link.href = invitation;
      link.setAttribute("aria-describedby", "beta-status");
    });
    return;
  }

  status.textContent = "The public invitation link is coming soon. Please check back here.";
  links.forEach(link => {
    link.setAttribute("aria-describedby", "beta-status");
    link.addEventListener("click", () => {
      // Preserve native #beta navigation, including keyboard use and reduced motion.
      status.textContent = "The public invitation link is coming soon. Please check back here.";
    });
  });
})();
