/* PostHog analytics for the hark.works website only. The Hark app has no
   telemetry; nothing here runs on the user's Mac.

   PostHog collects page views, page leaves with scroll depth, autocaptured
   clicks, heatmaps, dead clicks, web vitals, JavaScript errors and session
   replays (inputs masked). The events below add what autocapture cannot name:
   which install command was copied, which sections were seen, and what the
   demo video and island did. */
(function () {
  var POSTHOG_KEY = '';
  var POSTHOG_HOST = 'https://us.i.posthog.com';
  if (!POSTHOG_KEY) return;

  /* Load posthog-js from PostHog's CDN, then set it up. Every call below
     runs after the library is in place, so no call queue is needed. */
  var lib = document.createElement('script');
  lib.async = true;
  lib.crossOrigin = 'anonymous';
  lib.src = POSTHOG_HOST.replace('.i.posthog.com', '-assets.i.posthog.com') + '/static/array.js';
  lib.onload = setup;
  document.head.appendChild(lib);

  function setup() {
    posthog.init(POSTHOG_KEY, {
      api_host: POSTHOG_HOST,
      defaults: '2025-05-24',
      person_profiles: 'always',
      capture_pageview: true,
      capture_pageleave: true,
      autocapture: { capture_copied_text: true },
      capture_heatmaps: true,
      capture_dead_clicks: true,
      capture_performance: { web_vitals: true },
      capture_exceptions: true,
      enable_recording_console_log: true,
      session_recording: { maskAllInputs: true }
    });

    var media = function (q) { return window.matchMedia && window.matchMedia(q).matches; };
    posthog.register({
      site: 'hark.works',
      page_kind: document.querySelector('meta[name="robots"][content="noindex"]') ? 'not_found' : 'home',
      color_scheme: media('(prefers-color-scheme: dark)') ? 'dark' : 'light',
      reduced_motion: media('(prefers-reduced-motion: reduce)'),
      is_mac: /Mac/.test(navigator.platform || navigator.userAgent)
    });

    function track(event, props) { posthog.capture(event, props || {}); }
    function on(selector, type, fn) {
      document.querySelectorAll(selector).forEach(function (el) { el.addEventListener(type, function (e) { fn(el, e); }); });
    }

    if (document.querySelector('meta[name="robots"][content="noindex"]')) {
      track('page_not_found', { path: location.pathname, referrer: document.referrer });
    }

    /* Install funnel: a copy button, or a manual select-and-copy of the same block. */
    var COMMANDS = {
      'agent-prompt': 'agent_prompt',
      'curl-cmd': 'curl_install',
      'doctor-cmd': 'doctor',
      'settings-cmd': 'open_settings',
      'uninstall-cmd': 'uninstall'
    };
    on('[data-copy]', 'click', function (btn) {
      var id = btn.getAttribute('data-copy');
      track('command_copied', { command: COMMANDS[id] || id, method: 'button' });
    });
    Object.keys(COMMANDS).forEach(function (id) {
      var el = document.getElementById(id);
      if (el) el.addEventListener('copy', function () { track('command_copied', { command: COMMANDS[id], method: 'manual' }); });
    });

    /* Which sections a visitor saw, once each per page view. */
    if ('IntersectionObserver' in window) {
      var seen = {};
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          var id = entry.target.id;
          if (!entry.isIntersecting || seen[id]) return;
          seen[id] = true;
          track('section_viewed', { section: id, seconds_on_page: Math.round(performance.now() / 1000) });
          io.unobserve(entry.target);
        });
      }, { threshold: 0.4 });
      document.querySelectorAll('main section[id]').forEach(function (s) { io.observe(s); });
    }

    /* Links that leave the page or point at the agent docs. */
    on('a[href]', 'click', function (a) {
      var href = a.getAttribute('href');
      if (href.charAt(0) === '#') { track('nav_clicked', { target: href.slice(1), place: a.closest('header') ? 'header' : 'body' }); return; }
      var place = a.closest('header') ? 'header' : a.closest('footer') ? 'footer' : a.closest('.hero') ? 'hero' : a.closest('#install') ? 'install' : 'body';
      track('link_clicked', { href: a.href, text: a.textContent.trim(), place: place });
    });

    /* The demo video and the header island. */
    var video = document.getElementById('demo');
    if (video) {
      on('.vid-toggle', 'click', function () { track('demo_video_toggled', { action: video.paused ? 'play' : 'pause' }); });
      var watched = false;
      video.addEventListener('timeupdate', function () {
        if (!watched && video.currentTime > 5) { watched = true; track('demo_video_watched', { seconds: 5 }); }
      });
    }
    on('.island', 'click', function () { track('island_clicked'); });
  }
})();
