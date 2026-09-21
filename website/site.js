/* Progressive enhancement only: the content and section links work without JavaScript. */
(() => {
  "use strict";
  const menus = [...document.querySelectorAll(".product-menu, .mobile-menu")];
  menus.forEach(menu => {
    const closeMenu = () => { menu.open = false; };
    menu.querySelectorAll("a").forEach(link => {
      link.addEventListener("click", closeMenu);
    });
    menu.addEventListener("toggle", () => {
      if (menu.open) menus.filter(other => other !== menu).forEach(other => { other.open = false; });
    });
    document.addEventListener("keydown", event => {
      if (event.key === "Escape" && menu.open) {
        closeMenu();
        menu.querySelector("summary").focus();
      }
    });
    document.addEventListener("click", event => {
      if (!menu.contains(event.target)) closeMenu();
    });
    menu.addEventListener("focusout", event => {
      if (event.relatedTarget && !menu.contains(event.relatedTarget)) closeMenu();
    });
    window.matchMedia("(max-width: 760px)").addEventListener("change", closeMenu);
  });

  const status = document.getElementById("beta-status");
  const links = document.querySelectorAll("[data-beta-link]");
  if (!status || !links.length) return;
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
