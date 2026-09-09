/* Double-clic de démonstration. Les styles et l'entrée du site restent inchangés. */
(function () {
  "use strict";

  var gsap = window.gsap;
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

  if (gsap && !reduced.matches) {
    gsap.fromTo("[data-hero-in]",
      { autoAlpha: 0, y: 16, filter: "blur(10px)" },
      { autoAlpha: 1, y: 0, filter: "blur(0px)", duration: 0.9,
        ease: "power3.out", stagger: 0.09, delay: 0.12 }
    );
  }

  var scene = document.querySelector("[data-scene]");
  if (!scene) return;
  var pointer = scene.querySelector("[data-ptr]");
  var file = scene.querySelector("[data-file]");
  var icon = scene.querySelector("[data-file-icon]");
  var win = scene.querySelector("[data-win]");
  var caption = document.querySelector("[data-cap]");
  var toggle = document.querySelector("[data-toggle]");
  if (!pointer || !file || !icon || !win) return;

  var TEXT = {
    fr: {
      idle: "Après extraction du ZIP, double-cliquez sur Libertix.exe.",
      open: "Aperçu de l’écran d’accueil de Libertix 0.3.",
      playing: "Mettre l’animation en pause",
      paused: "Reprendre l’animation",
      ended: "Rejouer l’ouverture"
    },
    en: {
      idle: "Extract the ZIP, then double-click Libertix.exe.",
      open: "Preview of the Libertix 0.3 welcome screen.",
      playing: "Pause the animation",
      paused: "Resume the animation",
      ended: "Replay the opening"
    }
  };
  // Une seule horloge : positions, états et ouverture ne peuvent pas se décaler.
  var TIME = {
    move: 0.32, arrived: 0.96,
    down1: 1.10, up1: 1.18,
    down2: 1.31, up2: 1.39,
    opening: 1.55, opened: 1.79,
    fadePointer: 2.12, pointerGone: 2.28,
    end: 2.45
  };
  // Pointe de l'image 96 × 96, affichée à 24 × 24 : (12, 4) / 4.
  var HOTSPOT = { x: 3, y: 1 };
  var clock = { time: 0 };
  var geometry = null;
  var timeline = null;
  var onScreen = false;
  var wanted = true;
  var ended = false;
  var shown = "";
  var assetsReady = true;

  function language() {
    return document.documentElement.getAttribute("data-lang") === "en" ? "en" : "fr";
  }
  function clamp(value) { return Math.max(0, Math.min(1, value)); }
  function progress(time, start, end) { return clamp((time - start) / (end - start)); }
  function smooth(value) { return value * value * (3 - 2 * value); }
  function easeOut(value) { return 1 - Math.pow(1 - value, 3); }

  function say(key, force) {
    if (key === shown && !force) return;
    shown = key;
    if (caption) caption.textContent = TEXT[language()][key];
  }
  function controls() {
    if (!toggle) return;
    var state = ended ? "ended" : wanted ? "playing" : "paused";
    toggle.dataset.state = state;
    toggle.setAttribute("aria-label", TEXT[language()][state]);
    toggle.setAttribute("title", TEXT[language()][state]);
  }
  function attribute(element, name, value) {
    if (element.getAttribute(name) !== value) element.setAttribute(name, value);
  }

  function measure() {
    var s = scene.getBoundingClientRect();
    var i = icon.getBoundingClientRect();
    var f = file.getBoundingClientRect();
    var width = scene.clientWidth;
    var height = scene.clientHeight;
    if (!width || !height) return;
    var left = s.left + scene.clientLeft;
    var top = s.top + scene.clientTop;
    var target = { x: i.left - left + i.width / 2, y: i.top - top + i.height / 2 };
    geometry = {
      target: target,
      // Trajet court, entièrement dans le cadre : pas de traversée du bureau.
      start: {
        x: Math.min(width - 28, target.x + Math.min(220, width * 0.32)),
        y: Math.min(height - 28, target.y + Math.min(118, height * 0.34))
      },
      file: { left: f.left - left, top: f.top - top,
        right: f.right - left, bottom: f.bottom - top }
    };
    if (timeline) render();
  }

  function render() {
    if (!geometry) return;
    var t = clock.time;
    var step = smooth(progress(t, TIME.move, TIME.arrived));
    var g = geometry;
    var x = g.start.x + (g.target.x - g.start.x) * step;
    var y = g.start.y + (g.target.y - g.start.y) * step;

    // Seule la position change. Ni rotation, ni compression, ni rebond au clic.
    pointer.style.transform = "translate3d(" + (x - HOTSPOT.x).toFixed(3) + "px," +
      (y - HOTSPOT.y).toFixed(3) + "px,0)";
    var pointerAlpha = 1 - progress(t, TIME.fadePointer, TIME.pointerGone);
    pointer.style.opacity = String(pointerAlpha);
    pointer.style.visibility = pointerAlpha > 0 ? "visible" : "hidden";

    var clicked = t >= TIME.down1;
    var down = (t >= TIME.down1 && t < TIME.up1) || (t >= TIME.down2 && t < TIME.up2);
    var hover = !clicked && x >= g.file.left && x <= g.file.right &&
      y >= g.file.top && y <= g.file.bottom;
    attribute(file, "data-sel", clicked ? "1" : "0");
    attribute(file, "data-hover", hover ? "1" : "0");
    attribute(file, "data-pressed", down ? "1" : "0");
    attribute(file, "data-click", t >= TIME.down2 ? "2" : clicked ? "1" : "0");

    var opening = progress(t, TIME.opening, TIME.opened);
    var eased = easeOut(opening);
    win.style.opacity = String(Math.min(1, opening * 2));
    win.style.visibility = opening > 0 ? "visible" : "hidden";
    win.style.transform = "translate(-50%,-50%) translateY(" + (8 * (1 - eased)).toFixed(3) +
      "px) scale(" + (0.975 + 0.025 * eased).toFixed(5) + ")";

    var phase = t < TIME.move ? "idle" : t < TIME.arrived ? "moving" :
      t < TIME.down1 ? "hover" : t < TIME.opening ? "clicking" :
      t < TIME.opened ? "opening" : "open";
    attribute(scene, "data-phase", phase);
    say(t >= TIME.opened ? "open" : "idle");
  }

  function sync() {
    if (!timeline) return;
    var playing = assetsReady && onScreen && !document.hidden && wanted && !ended;
    if (playing) timeline.play();
    else timeline.pause();
    attribute(scene, "data-playback", ended ? "ended" : playing ? "playing" : "paused");
    controls();
  }

  function still() {
    if (timeline) timeline.kill();
    timeline = null;
    pointer.style.opacity = "0";
    pointer.style.visibility = "hidden";
    win.style.opacity = "1";
    win.style.visibility = "visible";
    win.style.transform = "translate(-50%,-50%)";
    ["data-sel", "data-hover", "data-pressed", "data-click"].forEach(function (key) {
      file.removeAttribute(key);
    });
    scene.dataset.phase = "open";
    scene.dataset.playback = "static";
    say("open", true);
    if (toggle) toggle.hidden = true;
  }

  function build() {
    if (!gsap || reduced.matches) { still(); return; }
    if (timeline) timeline.kill();
    timeline = null;
    clock.time = 0;
    wanted = true;
    ended = false;
    measure();
    render();
    if (toggle) toggle.hidden = false;
    timeline = gsap.timeline({
      paused: true,
      onUpdate: render,
      onComplete: function () {
        ended = true;
        wanted = false;
        scene.dataset.playback = "ended";
        controls();
      }
    });
    timeline.to(clock, { time: TIME.end, duration: TIME.end, ease: "none" });
    sync();
  }

  document.addEventListener("libertix:lang", function () {
    say(shown || "open", true);
    controls();
    measure();
  });
  if (toggle) toggle.addEventListener("click", function () {
    if (!timeline) return;
    if (ended) build();
    else { wanted = !wanted; sync(); }
  });

  // L'icône distante et le pointeur peuvent finir de charger après les scripts.
  // Ne pas commencer à cliquer avant leur arrivée, sans bloquer en cas de réseau lent.
  (function waitForImages() {
    var pending = 0;
    scene.querySelectorAll(".file__ico img, .ptr img").forEach(function (image) {
      if (image.complete) return;
      pending += 1;
      var released = false;
      function settled() {
        if (released) return;
        released = true;
        pending -= 1;
        if (pending === 0) { assetsReady = true; sync(); }
      }
      image.addEventListener("load", settled, { once: true });
      image.addEventListener("error", settled, { once: true });
    });
    assetsReady = pending === 0;
    if (!assetsReady) window.setTimeout(function () {
      assetsReady = true;
      sync();
    }, 1500);
  })();

  build();
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      onScreen = entries.some(function (entry) {
        return entry.isIntersecting && entry.intersectionRatio >= 0.20;
      });
      sync();
    }, { threshold: [0, 0.20] }).observe(scene);
  } else {
    onScreen = true;
    sync();
  }
  if ("ResizeObserver" in window) new ResizeObserver(measure).observe(scene);
  else window.addEventListener("resize", measure);
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(measure);
  document.addEventListener("visibilitychange", sync);
  window.addEventListener("pagehide", function () { if (timeline) timeline.pause(); });
  window.addEventListener("pageshow", sync);
  if (reduced.addEventListener) reduced.addEventListener("change", build);
  else if (reduced.addListener) reduced.addListener(build);
})();
