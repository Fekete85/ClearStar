/* Cookie consent + Google Analytics 4 for the static blackit.hu sites
 * (csillag, celestial, clearstar). Master copy: blackit repo, server-configs/consent/.
 *
 *   <link rel="stylesheet" href="/consent.css">
 *   <script src="/consent.js" data-ga="G-XXXXXXXXXX" defer></script>
 *   <button type="button" data-consent-open>Süti-beállítások</button>   (anywhere, reopens the banner)
 *
 * Nothing is sent to Google until the visitor accepts: gtag.js itself is only
 * loaded after consent, with Consent Mode v2 defaults set to denied before
 * that. The choice lives in localStorage; the text follows <html lang> (hu/en).
 * The GA cookies are kept on this host only (cookie_domain), so the sites under
 * blackit.hu do not share one _ga cookie.
 */
(function () {
  "use strict";

  var script = document.currentScript;
  var GA_ID = script && script.getAttribute("data-ga");
  if (!GA_ID) { return; }

  var KEY = "blackit-consent-v1";
  var TEXT = {
    hu: {
      title: "Sütik",
      body: "Az oldal látogatottságát a Google Analytics segítségével mérjük. Ehhez sütiket (_ga, _ga_*) " +
            "helyezünk el az eszközödön, az adatokat a Google (Google Ireland Ltd.) kezeli. A mérés csak a " +
            "hozzájárulásoddal indul, és a döntésedet a lap alján a „Süti-beállítások” linkkel bármikor megváltoztathatod.",
      accept: "Elfogadom",
      deny: "Elutasítom"
    },
    en: {
      title: "Cookies",
      body: "We measure visits to this site with Google Analytics. For this we place cookies (_ga, _ga_*) on your " +
            "device, and the data is processed by Google (Google Ireland Ltd.). Measuring only starts with your " +
            "consent, and you can change your choice at any time with the “Cookie settings” link at the bottom of the page.",
      accept: "Accept",
      deny: "Decline"
    }
  };
  var t = TEXT[(document.documentElement.lang || "").slice(0, 2) === "en" ? "en" : "hu"];

  function read() { try { return localStorage.getItem(KEY); } catch (e) { return null; } }
  function write(v) { try { localStorage.setItem(KEY, v); } catch (e) {} }

  window.dataLayer = window.dataLayer || [];
  function gtag() { window.dataLayer.push(arguments); }
  gtag("consent", "default", {
    analytics_storage: "denied",
    ad_storage: "denied",
    ad_user_data: "denied",
    ad_personalization: "denied"
  });

  var loaded = false;
  function startAnalytics() {
    if (loaded) { return; }
    loaded = true;
    gtag("consent", "update", { analytics_storage: "granted" });
    gtag("js", new Date());
    gtag("config", GA_ID, { cookie_domain: location.hostname });
    var s = document.createElement("script");
    s.async = true;
    s.src = "https://www.googletagmanager.com/gtag/js?id=" + encodeURIComponent(GA_ID);
    document.head.appendChild(s);
  }

  function removeGaCookies() {
    document.cookie.split(";").forEach(function (c) {
      var name = c.split("=")[0].trim();
      if (name.indexOf("_ga") !== 0) { return; }
      ["", location.hostname, "." + location.hostname].forEach(function (d) {
        document.cookie = name + "=; Max-Age=0; path=/" + (d ? "; domain=" + d : "");
      });
    });
  }

  var banner = null;
  function build() {
    banner = document.createElement("div");
    banner.className = "bx-consent";
    banner.setAttribute("role", "dialog");
    banner.setAttribute("aria-labelledby", "bx-consent-title");
    banner.hidden = true;

    var h = document.createElement("h2");
    h.id = "bx-consent-title";
    h.textContent = t.title;
    var p = document.createElement("p");
    p.textContent = t.body;

    var actions = document.createElement("div");
    actions.className = "bx-consent-actions";
    var deny = document.createElement("button");
    deny.type = "button";
    deny.textContent = t.deny;
    deny.addEventListener("click", function () { decide("denied"); });
    var accept = document.createElement("button");
    accept.type = "button";
    accept.className = "bx-accept";
    accept.textContent = t.accept;
    accept.addEventListener("click", function () { decide("granted"); });
    actions.appendChild(deny);
    actions.appendChild(accept);

    banner.appendChild(h);
    banner.appendChild(p);
    banner.appendChild(actions);
    document.body.appendChild(banner);
  }

  function show() {
    if (!banner) { build(); }
    banner.hidden = false;
  }

  function decide(value) {
    write(value);
    if (banner) { banner.hidden = true; }
    if (value === "granted") {
      startAnalytics();
    } else {
      if (loaded) { gtag("consent", "update", { analytics_storage: "denied" }); }
      removeGaCookies();
    }
  }

  document.addEventListener("click", function (e) {
    var el = e.target.closest && e.target.closest("[data-consent-open]");
    if (el) { e.preventDefault(); show(); }
  });

  function init() {
    var choice = read();
    if (choice === "granted") { startAnalytics(); }
    else if (choice !== "denied") { show(); }
  }
  if (document.readyState === "loading") { document.addEventListener("DOMContentLoaded", init); }
  else { init(); }
})();
