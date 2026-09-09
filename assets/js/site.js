/* Langues et comportements de la page originale. Aucun module ni build. */
(function () {
  "use strict";

  var root = document.documentElement;
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

  (function language() {
    var button = document.querySelector("[data-lang-toggle]");
    var control = document.querySelector("[data-language-control]");
    var code = document.querySelector("[data-lang-code]");
    var manualChoice = false;
    var TEXT = {
      fr: {
        title: "Libertix — installez Linux depuis Windows",
        description: "Libertix est une application Windows gratuite qui installe Linux Mint ou Zorin OS à côté de votre système actuel. Sans clé USB, et annulable tant que l’installation n’est pas terminée.",
        scene: "Aperçu de Libertix : un double-clic sur Libertix.exe ouvre l’écran d’accueil. La maquette n’est pas interactive.",
        switchTo: "Switch to English",
        locale: "fr_FR"
      },
      en: {
        title: "Libertix — install Linux from Windows",
        description: "Libertix is a free Windows application that installs Linux Mint or Zorin OS alongside your current system. No USB drive, and you can cancel before the installation is complete.",
        scene: "Libertix preview: a double-click on Libertix.exe opens the welcome screen. The mockup is not interactive.",
        switchTo: "Passer en français",
        locale: "en_GB"
      }
    };

    function browserLanguage() {
      var prefs = navigator.languages && navigator.languages.length
        ? navigator.languages : [navigator.language || "en"];
      for (var i = 0; i < prefs.length; i++) {
        var candidate = prefs[i].toLowerCase().split(/[-_]/)[0];
        if (candidate === "fr" || candidate === "en") return candidate;
      }
      return "en";
    }

    function meta(selector, content) {
      var el = document.querySelector(selector);
      if (el) el.setAttribute("content", content);
    }

    function apply(lang, persist) {
      if (lang !== "fr" && lang !== "en") return;
      var text = TEXT[lang];
      root.setAttribute("data-lang", lang);
      root.setAttribute("lang", lang);
      document.title = text.title;
      meta('meta[name="description"]', text.description);
      meta('meta[property="og:title"]', text.title);
      meta('meta[property="og:description"]', text.description);

      var locale = document.querySelector('meta[property="og:locale"]');
      if (!locale) {
        locale = document.createElement("meta");
        locale.setAttribute("property", "og:locale");
        document.head.appendChild(locale);
      }
      locale.setAttribute("content", text.locale);

      var scene = document.querySelector("[data-scene]");
      if (scene) scene.setAttribute("aria-label", text.scene);
      if (code) code.textContent = lang.toUpperCase();
      if (button) {
        button.setAttribute("aria-label", lang.toUpperCase() + " — " + text.switchTo);
        button.setAttribute("title", text.switchTo);
      }
      if (control) control.hidden = false;

      if (persist) {
        manualChoice = true;
        try { localStorage.setItem("libertix.lang", lang); } catch (e) {
          // Navigation privée : le choix reste actif pour cette page.
        }
        // Un lien ?lang=en reste cohérent après un changement manuel.
        try {
          var url = new URL(location.href);
          if (url.searchParams.has("lang")) {
            url.searchParams.set("lang", lang);
            history.replaceState(history.state, "", url.href);
          }
        } catch (e) {}
      }
      document.dispatchEvent(new CustomEvent("libertix:lang", { detail: { lang: lang } }));
    }

    apply(root.getAttribute("data-lang") || browserLanguage(), false);
    if (button) button.addEventListener("click", function () {
      apply(root.getAttribute("data-lang") === "fr" ? "en" : "fr", true);
    });

    window.addEventListener("languagechange", function () {
      if (manualChoice) return;
      try {
        var explicit = new URLSearchParams(location.search).get("lang");
        var saved = localStorage.getItem("libertix.lang");
        if (explicit === "fr" || explicit === "en" || saved === "fr" || saved === "en") return;
      } catch (e) {}
      apply(browserLanguage(), false);
    });
  })();

  (function reveal() {
    var targets = document.querySelectorAll("[data-in]");
    if (!targets.length) return;
    if (reduced.matches || !("IntersectionObserver" in window)) {
      targets.forEach(function (el) { el.classList.add("on"); });
      return;
    }
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("on");
        io.unobserve(entry.target);
      });
    }, { rootMargin: "0px 0px -12% 0px", threshold: 0.1 });
    root.classList.add("js-reveal");
    targets.forEach(function (el) { io.observe(el); });
  })();

  (function stuck() {
    var nav = document.querySelector(".nav");
    if (!nav || !("IntersectionObserver" in window)) return;
    var probe = document.createElement("div");
    probe.setAttribute("aria-hidden", "true");
    probe.style.cssText = "position:absolute;top:0;left:0;width:1px;height:1px";
    document.body.prepend(probe);
    new IntersectionObserver(function (entries) {
      nav.dataset.stuck = entries[0].isIntersecting ? "0" : "1";
    }).observe(probe);
  })();

  var year = document.querySelector("[data-year]");
  if (year) year.textContent = String(new Date().getFullYear());
})();
