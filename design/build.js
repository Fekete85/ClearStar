// Generates the five ClearStar mockup artboards (.dc.html) + placeholder images.
const fs = require('fs');
const path = require('path');
const OUT = __dirname;

const W = 1600, H = 1280;
const C = {
  title: '#1a1a1d', bg: '#202023', layer: '#27272b', card: '#2d2d32', cardActive: '#2a3434',
  stroke: 'rgba(255,255,255,0.08)', strokeStrong: 'rgba(255,255,255,0.14)',
  text: 'rgba(255,255,255,0.92)', text2: 'rgba(255,255,255,0.60)', text3: 'rgba(255,255,255,0.36)',
  accent: '#3ecfc0', accentSoft: 'rgba(62,207,192,0.16)', accentText: '#0d2a27',
  green: '#6ccb5f', greenSoft: 'rgba(108,203,95,0.16)', amber: '#f2b84b', amberSoft: 'rgba(242,184,75,0.16)',
  view: '#0b0b0e',
};

// ---------- icons (24px stroke) ----------
const I = {
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  layers: '<path d="M12 4 3 9l9 5 9-5z"/><path d="m3 14 9 5 9-5"/>',
  crop: '<path d="M6 2v14a2 2 0 0 0 2 2h14"/><path d="M18 22V8a2 2 0 0 0-2-2H2"/>',
  gradient: '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 12h18M8 3v18M13 3v18"/>',
  sharpen: '<circle cx="12" cy="12" r="9"/><path d="M12 3v18M3 12h18"/><circle cx="12" cy="12" r="3"/>',
  noise: '<circle cx="6" cy="6" r="1"/><circle cx="12" cy="6" r="1"/><circle cx="18" cy="6" r="1"/><circle cx="6" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="18" cy="12" r="1"/><circle cx="6" cy="18" r="1"/><circle cx="12" cy="18" r="1"/><circle cx="18" cy="18" r="1"/>',
  compass: '<circle cx="12" cy="12" r="9"/><path d="m15 9-2 6-4 2 2-6z"/>',
  palette: '<path d="M12 3a9 9 0 1 0 0 18c1.5 0 2-1 1.5-2s0-2 1.5-2h2a3 3 0 0 0 3-3 9 9 0 0 0-8-11z"/><circle cx="8" cy="10" r="1"/><circle cx="12" cy="7" r="1"/><circle cx="16" cy="10" r="1"/>',
  starOff: '<path d="m12 3 2.6 5.4 6 .8-4.3 4.2 1 5.9L12 16.5 6.7 19.3l1-5.9L3.4 9.2l6-.8z"/><path d="M4 4l16 16"/>',
  nebula: '<path d="M4 16a5 5 0 0 1 3-9 6 6 0 0 1 11 1 4 4 0 0 1 1 8H7a3 3 0 0 1-3-3z"/>',
  star: '<path d="m12 3 2.6 5.4 6 .8-4.3 4.2 1 5.9L12 16.5 6.7 19.3l1-5.9L3.4 9.2l6-.8z"/>',
  merge: '<path d="M6 4v6a4 4 0 0 0 4 4h4"/><path d="M18 4v16"/><path d="m15 17 3 3 3-3"/>',
  leaf: '<path d="M5 19c0-8 5-13 14-14-1 9-6 14-14 14z"/><path d="M5 19c4-4 7-7 10-9"/>',
  prism: '<path d="m12 3 9 17H3z"/><path d="M12 3v17"/>',
  contrast: '<circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 1 0 18z" fill="currentColor" stroke="none"/>',
  drop: '<path d="M12 3s6 7 6 11a6 6 0 0 1-12 0c0-4 6-11 6-11z"/>',
  save: '<path d="M5 3h11l3 3v15H5z"/><path d="M8 3v6h7V3"/><path d="M8 21v-7h8v7"/>',
  check: '<path d="m5 12 4 4 10-10"/>',
  chevron: '<path d="m6 9 6 6 6-6"/>',
  eye: '<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
  split: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M12 4v16"/>',
  help: '<circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.4-1 1-1 1.7"/><circle cx="12" cy="17" r=".6"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  minus: '<path d="M5 12h14"/>',
  fit: '<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>',
  upload: '<path d="M12 16V4"/><path d="m7 9 5-5 5 5"/><path d="M4 20h16"/>',
  image: '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="10" r="1.5"/><path d="m21 16-5-5-8 8"/>',
  print: '<path d="M6 9V3h12v6"/><rect x="3" y="9" width="18" height="8" rx="2"/><path d="M6 14h12v7H6z"/>',
  file: '<path d="M6 2h8l5 5v15H6z"/><path d="M14 2v5h5"/>',
  share: '<circle cx="18" cy="5" r="2.5"/><circle cx="6" cy="12" r="2.5"/><circle cx="18" cy="19" r="2.5"/><path d="m8.2 10.8 7.6-4.6M8.2 13.2l7.6 4.6"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>',
  arrow: '<path d="M5 12h14"/><path d="m13 6 6 6-6 6"/>',
};
const icon = (k, size = 18, color = 'currentColor', extra = '') =>
  `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="${color}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" ${extra}>${I[k]}</svg>`;

// ---------- steps ----------
const GROUPS = [
  { name: 'Előkészítés', steps: [
    { n: 1, name: 'Képek betöltése', icon: 'folder' },
    { n: 2, name: 'Képek összeillesztése', sub: 'stackelés', icon: 'layers' },
    { n: 3, name: 'Vágás', icon: 'crop' } ] },
  { name: 'Alapok', steps: [
    { n: 4, name: 'Háttér kiegyenlítése', icon: 'gradient' },
    { n: 5, name: 'Élesítés', sub: 'deconvolution', icon: 'sharpen' },
    { n: 6, name: 'Zajcsökkentés', icon: 'noise' },
    { n: 7, name: 'Égbolt azonosítása', sub: 'plate solving', icon: 'compass' },
    { n: 8, name: 'Színek kalibrálása', icon: 'palette' } ] },
  { name: 'Csillagok', steps: [
    { n: 9, name: 'Csillagok leválasztása', icon: 'starOff' },
    { n: 10, name: 'Ködök, galaxis kiemelése', sub: 'GHS nyújtás', icon: 'nebula' },
    { n: 11, name: 'Csillagok nyújtása', icon: 'star' },
    { n: 12, name: 'Csillagok visszahelyezése', icon: 'merge' } ] },
  { name: 'Finomítás', steps: [
    { n: 13, name: 'Zöld árnyalat eltávolítása', icon: 'leaf' },
    { n: 14, name: 'Színes szegélyek javítása', icon: 'prism' },
    { n: 15, name: 'Kontraszt', icon: 'contrast' },
    { n: 16, name: 'Színtelítettség', icon: 'drop' } ] },
  { name: 'Befejezés', steps: [
    { n: 17, name: 'Mentés', icon: 'save' } ] },
];

// ---------- shared css ----------
const CSS = `
  body { margin: 0; background: ${C.bg}; color: ${C.text}; font-family: "Segoe UI Variable Text", "Segoe UI", system-ui, -apple-system, sans-serif; font-size: 13px; line-height: 1.4; -webkit-font-smoothing: antialiased; }
  a { color: ${C.accent}; text-decoration: none; } a:hover { color: #6fe0d4; }
  * { box-sizing: border-box; }
  .step { display: flex; align-items: center; gap: 10px; height: 36px; padding: 0 12px 0 10px; border-radius: 8px; }
  .step .badge { width: 22px; height: 22px; border-radius: 11px; display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 600; flex-shrink: 0; }
  .step .nm { flex-grow: 1; font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .step .sub { color: ${C.text3}; font-size: 12px; }
  .step .meta { font-size: 11px; color: ${C.text3}; white-space: nowrap; }
  .st-pending .badge { background: rgba(255,255,255,0.06); color: ${C.text3}; }
  .st-pending .nm, .st-pending svg.ic { color: ${C.text3}; }
  .st-done .badge { background: ${C.greenSoft}; color: ${C.green}; }
  .st-done .nm { color: ${C.text2}; } .st-done svg.ic { color: ${C.text2}; }
  .st-skip .badge { background: rgba(255,255,255,0.06); color: ${C.text3}; }
  .st-skip .nm { color: ${C.text3}; text-decoration: line-through; text-decoration-color: rgba(255,255,255,0.25); } .st-skip svg.ic { color: ${C.text3}; }
  .st-stale .badge { background: ${C.amberSoft}; color: ${C.amber}; }
  .st-stale .nm { color: ${C.text2}; } .st-stale svg.ic { color: ${C.text2}; }
  .st-active { background: ${C.accentSoft}; }
  .st-active .badge { background: ${C.accent}; color: ${C.accentText}; }
  .st-active .nm { color: ${C.text}; font-weight: 600; } .st-active svg.ic { color: ${C.accent}; }
  .grp { font-size: 11px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: ${C.text3}; padding: 10px 12px 2px; }
  .card { background: ${C.card}; border: 1px solid ${C.stroke}; border-radius: 10px; }
  .btn { display: inline-flex; align-items: center; justify-content: center; gap: 8px; height: 34px; padding: 0 16px; border-radius: 8px; font-size: 13px; font-weight: 600; border: 1px solid transparent; white-space: nowrap; }
  .btn-primary { background: ${C.accent}; color: ${C.accentText}; }
  .btn-secondary { background: rgba(255,255,255,0.06); color: ${C.text}; border-color: ${C.strokeStrong}; }
  .btn-ghost { background: transparent; color: ${C.text2}; }
  .tool { display: inline-flex; align-items: center; gap: 7px; height: 30px; padding: 0 12px; border-radius: 6px; font-size: 12.5px; color: ${C.text2}; border: 1px solid transparent; }
  .tool-on { background: rgba(255,255,255,0.08); color: ${C.text}; border-color: ${C.strokeStrong}; }
  .zoombtn { width: 30px; height: 30px; display: flex; align-items: center; justify-content: center; color: ${C.text2}; }
  .slider .lbl { display: flex; justify-content: space-between; font-size: 12.5px; margin-bottom: 8px; }
  .slider .track { position: relative; height: 4px; border-radius: 2px; background: rgba(255,255,255,0.12); }
  .slider .fill { position: absolute; left: 0; top: 0; bottom: 0; border-radius: 2px; background: ${C.accent}; }
  .slider .thumb { position: absolute; top: -7px; width: 18px; height: 18px; border-radius: 9px; background: ${C.accent}; border: 3px solid ${C.card}; box-shadow: 0 0 0 1px rgba(0,0,0,0.4); margin-left: -9px; }
  .slider .ticks { display: flex; justify-content: space-between; font-size: 11px; color: ${C.text3}; margin-top: 10px; }
  .toggle { display: flex; align-items: center; justify-content: space-between; font-size: 12.5px; }
  .sw { width: 38px; height: 20px; border-radius: 10px; position: relative; flex-shrink: 0; }
  .sw-on { background: ${C.accent}; } .sw-on .knob { position: absolute; right: 3px; top: 3px; width: 14px; height: 14px; border-radius: 7px; background: ${C.accentText}; }
  .sw-off { background: rgba(255,255,255,0.14); } .sw-off .knob { position: absolute; left: 3px; top: 3px; width: 14px; height: 14px; border-radius: 7px; background: ${C.text2}; }
  .desc { font-size: 12.5px; color: ${C.text2}; margin: 0; }
  .thumb-img { width: 100%; height: 100%; object-fit: cover; display: block; }
`;

// ---------- building blocks ----------
function slider(name, value, pct, ticks) {
  return `<div class="slider">
    <div class="lbl"><span>${name}</span><span style="color: ${C.accent}; font-weight: 600;">${value}</span></div>
    <div class="track"><div class="fill" style="width: ${pct}%;"></div><div class="thumb" style="left: ${pct}%;"></div></div>
    <div class="ticks">${ticks.map(t => `<span>${t}</span>`).join('')}</div>
  </div>`;
}
function toggle(name, on) {
  return `<div class="toggle"><span>${name}</span><div class="sw ${on ? 'sw-on' : 'sw-off'}"><div class="knob"></div></div></div>`;
}
const advanced = () => `<div style="display: flex; align-items: center; justify-content: space-between; font-size: 12.5px; color: ${C.text2}; padding-top: 4px;"><span>Haladó beállítások</span>${icon('chevron', 16, C.text3)}</div>`;
const actions = (primary = 'Alkalmaz', skip = true) =>
  `<div style="display: flex; align-items: center; justify-content: space-between; padding-top: 4px;">
    <div class="btn btn-primary">${primary}</div>${skip ? `<a style="font-size: 12.5px;">Kihagyás</a>` : ''}
  </div>`;

function stepRow(s, state, meta) {
  const cls = { done: 'st-done', active: 'st-active', pending: 'st-pending', skip: 'st-skip', stale: 'st-stale' }[state];
  let badge = String(s.n);
  if (state === 'done') badge = icon('check', 13, C.green, 'stroke-width="2.4"');
  if (state === 'skip') badge = icon('minus', 13, C.text3, 'stroke-width="2.4"');
  if (state === 'stale') badge = '!';
  const metaTxt = meta || (state === 'skip' ? 'Kihagyva' : state === 'stale' ? '<span style="color: ' + C.amber + ';">Frissítés szükséges</span>' : '');
  return `<div class="step ${cls}">
    <div class="badge">${badge}</div>
    ${icon(s.icon, 18, 'currentColor', 'class="ic"')}
    <div class="nm">${s.name}${s.sub ? ` <span class="sub">(${s.sub})</span>` : ''}</div>
    ${metaTxt ? `<div class="meta">${metaTxt}</div>` : ''}
  </div>`;
}

// states: fn(n) -> { state, meta }, body: html for the active step's expanded body
function sidebar({ stateOf, activeBody, doneCount, headline }) {
  let list = '';
  for (const g of GROUPS) {
    list += `<div class="grp">${g.name}</div>`;
    for (const s of g.steps) {
      const st = stateOf(s.n);
      if (st.state === 'active') {
        list += `<div class="card" style="border-color: rgba(62,207,192,0.35); background: ${C.cardActive}; padding: 4px; margin: 2px 0 6px;">
          ${stepRow(s, 'active')}
          <div style="display: flex; flex-direction: column; gap: 16px; padding: 12px 12px 12px;">${activeBody}</div>
        </div>`;
      } else {
        list += stepRow(s, st.state, st.meta);
      }
    }
  }
  const pct = Math.round(doneCount / 17 * 100);
  return `<div style="width: 360px; flex-shrink: 0; background: ${C.layer}; border-right: 1px solid ${C.stroke}; display: flex; flex-direction: column; padding: 16px 12px 12px;">
    <div style="padding: 0 12px 10px;">
      <div style="display: flex; align-items: baseline; justify-content: space-between;">
        <div style="font-size: 15px; font-weight: 600;">Feldolgozás</div>
        <div style="font-size: 12px; color: ${C.text2};">${doneCount} / 17 lépés kész</div>
      </div>
      <div style="height: 4px; border-radius: 2px; background: rgba(255,255,255,0.1); margin-top: 10px;"><div style="height: 4px; border-radius: 2px; background: ${C.accent}; width: ${pct}%;"></div></div>
      ${headline ? `<div style="font-size: 12.5px; color: ${C.accent}; margin-top: 10px;">${headline}</div>` : ''}
    </div>
    <div style="display: flex; flex-direction: column; gap: 0;">${list}</div>
  </div>`;
}

function titlebar() {
  return `<div style="height: 40px; flex-shrink: 0; background: ${C.title}; display: flex; align-items: center; justify-content: space-between; padding: 0 0 0 16px; border-bottom: 1px solid ${C.stroke};">
    <div style="display: flex; align-items: center; gap: 10px;">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none"><path d="m12 2 2.2 6.4L21 9l-5.4 4.2L17.6 20 12 16.2 6.4 20l2-6.8L3 9l6.8-.6z" fill="${C.accent}"/></svg>
      <span style="font-size: 12.5px; font-weight: 600;">ClearStar</span>
      <span style="font-size: 12.5px; color: ${C.text3};">M31 – Andromeda</span>
    </div>
    <div style="display: flex;">
      <div style="width: 46px; height: 40px; display: flex; align-items: center; justify-content: center; color: ${C.text2};"><svg width="10" height="10" viewBox="0 0 10 10" stroke="currentColor"><path d="M0 5h10"/></svg></div>
      <div style="width: 46px; height: 40px; display: flex; align-items: center; justify-content: center; color: ${C.text2};"><svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor"><rect x="0.5" y="0.5" width="9" height="9"/></svg></div>
      <div style="width: 46px; height: 40px; display: flex; align-items: center; justify-content: center; color: ${C.text2};"><svg width="10" height="10" viewBox="0 0 10 10" stroke="currentColor"><path d="M0 0l10 10M10 0 0 10"/></svg></div>
    </div>
  </div>`;
}

function toolbar({ splitOn = false, disabled = false } = {}) {
  const col = disabled ? C.text3 : C.text2;
  return `<div style="height: 48px; flex-shrink: 0; display: flex; align-items: center; justify-content: space-between; padding: 0 16px; border-bottom: 1px solid ${C.stroke};">
    <div style="display: flex; align-items: center; gap: 6px;">
      <div class="tool" style="color: ${col};">${icon('eye', 16)}<span>Eredeti</span><span style="font-size: 11px; color: ${C.text3};">tartsd lenyomva</span></div>
      <div class="tool ${splitOn ? 'tool-on' : ''}" style="${splitOn ? '' : 'color: ' + col + ';'}">${icon('split', 16)}<span>Előtte / utána</span></div>
    </div>
    <div class="tool" style="padding: 0 6px;">${icon('help', 18)}</div>
  </div>`;
}

function zoomPill(zoom = '48%') {
  return `<div style="position: absolute; right: 16px; bottom: 16px; display: flex; align-items: center; background: rgba(32,32,35,0.85); border: 1px solid ${C.strokeStrong}; border-radius: 8px; padding: 2px; backdrop-filter: blur(12px); font-size: 12px;">
    <div class="zoombtn">${icon('minus', 14)}</div>
    <div style="width: 44px; text-align: center; color: ${C.text};">${zoom}</div>
    <div class="zoombtn">${icon('plus', 14)}</div>
    <div style="width: 1px; height: 18px; background: ${C.strokeStrong}; margin: 0 4px;"></div>
    <div class="zoombtn" title="Illesztés">${icon('fit', 14)}</div>
    <div style="padding: 0 10px; color: ${C.text2};">100%</div>
  </div>`;
}
function navigator(img = 'nebula.svg') {
  return `<div style="position: absolute; left: 16px; bottom: 16px; width: 150px; height: 100px; border-radius: 6px; overflow: hidden; border: 1px solid ${C.strokeStrong}; background: #000;">
    <img src="${img}" class="thumb-img">
    <div style="position: absolute; left: 22px; top: 18px; width: 100px; height: 62px; border: 1.5px solid ${C.accent}; border-radius: 2px;"></div>
  </div>`;
}
function statusbar(left, right = '') {
  return `<div style="height: 32px; flex-shrink: 0; display: flex; align-items: center; justify-content: space-between; padding: 0 16px; border-top: 1px solid ${C.stroke}; font-size: 12px; color: ${C.text2};">
    <div>${left}</div><div style="display: flex; align-items: center; gap: 12px;">${right}</div>
  </div>`;
}

function page({ sidebarHtml, toolbarHtml, viewportHtml, statusHtml, overlayHtml = '' }) {
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>${CSS}</style>
</helmet>
<div style="width: ${W}px; height: ${H}px; position: relative; overflow: hidden; display: flex; flex-direction: column; background: ${C.bg};">
  ${titlebar()}
  <div style="display: flex; flex-grow: 1; min-height: 0;">
    ${sidebarHtml}
    <div style="display: flex; flex-direction: column; flex-grow: 1; min-width: 0;">
      ${toolbarHtml}
      <div style="position: relative; flex-grow: 1; background: ${C.view}; overflow: hidden;">${viewportHtml}</div>
      ${statusHtml}
    </div>
  </div>
  ${overlayHtml}
</div>
</x-dc>
</body>
</html>
`;
}

// ---------- placeholder images ----------
function rng(seed) { let s = seed; return () => (s = (s * 1664525 + 1013904223) % 4294967296) / 4294967296; }
function nebulaSvg({ stars = true, w = 1200, h = 800, seed = 11 }) {
  const r = rng(seed);
  let st = '';
  if (stars) {
    for (let i = 0; i < 260; i++) {
      const x = (r() * w).toFixed(0), y = (r() * h).toFixed(0);
      const big = r() < 0.08;
      const rad = big ? (1.6 + r() * 1.8).toFixed(1) : (0.5 + r() * 0.9).toFixed(1);
      const op = (0.5 + r() * 0.5).toFixed(2);
      const col = big ? ['#fff4dc', '#dbe8ff', '#ffd9b0', '#ffffff'][Math.floor(r() * 4)] : '#ffffff';
      st += `<circle cx="${x}" cy="${y}" r="${rad}" fill="${col}" opacity="${op}"/>`;
      if (big) st += `<circle cx="${x}" cy="${y}" r="${(rad * 3).toFixed(1)}" fill="${col}" opacity="0.12"/>`;
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}">
<defs>
  <filter id="n" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency="0.0022 0.0035" numOctaves="5" seed="${seed}"/><feColorMatrix type="matrix" values="0 0 0 0 0.9  0 0 0 0 0.55  0 0 0 0 0.45  0 0 0 1.6 -0.55"/></filter>
  <filter id="n2" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency="0.004 0.006" numOctaves="4" seed="${seed + 5}"/><feColorMatrix type="matrix" values="0 0 0 0 0.35  0 0 0 0 0.55  0 0 0 0 1  0 0 0 1.4 -0.6"/></filter>
  <radialGradient id="core" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#fff1d6" stop-opacity="0.95"/><stop offset="0.12" stop-color="#f0c48a" stop-opacity="0.75"/><stop offset="0.4" stop-color="#8a3d5e" stop-opacity="0.45"/><stop offset="1" stop-color="#0b0b12" stop-opacity="0"/></radialGradient>
  <radialGradient id="mask" cx="50%" cy="50%" r="55%"><stop offset="0" stop-color="#fff"/><stop offset="0.6" stop-color="#fff" stop-opacity="0.7"/><stop offset="1" stop-color="#000"/></radialGradient>
  <mask id="m"><rect width="100%" height="100%" fill="url(#mask)"/></mask>
</defs>
<rect width="100%" height="100%" fill="#07070c"/>
<g mask="url(#m)"><rect width="100%" height="100%" filter="url(#n)" opacity="0.85"/><rect width="100%" height="100%" filter="url(#n2)" opacity="0.6"/></g>
<ellipse cx="${w * 0.52}" cy="${h * 0.48}" rx="${w * 0.36}" ry="${h * 0.24}" fill="url(#core)" transform="rotate(-18 ${w * 0.52} ${h * 0.48})"/>
${st}
</svg>`;
}
function frameSvg(seed) {
  const r = rng(seed); let st = '';
  for (let i = 0; i < 40; i++) st += `<circle cx="${(r() * 160).toFixed(0)}" cy="${(r() * 110).toFixed(0)}" r="${(0.5 + r() * 1.2).toFixed(1)}" fill="#fff" opacity="${(0.4 + r() * 0.6).toFixed(2)}"/>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 110" width="160" height="110"><rect width="160" height="110" fill="#0c0c12"/><ellipse cx="${70 + seed}" cy="55" rx="40" ry="22" fill="#5a3548" opacity="0.5"/>${st}</svg>`;
}
fs.writeFileSync(path.join(OUT, 'nebula.svg'), nebulaSvg({ stars: true }));
fs.writeFileSync(path.join(OUT, 'nebula-starless.svg'), nebulaSvg({ stars: false }));
fs.writeFileSync(path.join(OUT, 'frame.svg'), frameSvg(3));

// ================= A) Induló állapot =================
{
  const body = `
    <p class="desc">Válaszd ki a mappát, ahová a távcsőről vagy fényképezőről a képeidet mentetted. A fény-, sötét- és flat-képeket magunktól szétválogatjuk.</p>
    <div class="btn btn-primary" style="align-self: flex-start;">${icon('folder', 16)}Mappa kiválasztása</div>`;
  const viewport = `
    <div style="position: absolute; inset: 40px; border: 2px dashed rgba(255,255,255,0.14); border-radius: 16px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 14px;">
      <div style="width: 64px; height: 64px; border-radius: 32px; background: rgba(255,255,255,0.05); display: flex; align-items: center; justify-content: center;">${icon('upload', 28, C.text2)}</div>
      <div style="font-size: 18px; font-weight: 600;">Húzd ide a képeidet</div>
      <div style="font-size: 13px; color: ${C.text2};">vagy válassz mappát bal oldalt · FITS, RAW (CR2, NEF, ARW), TIFF</div>
    </div>`;
  const overlay = `
    <div style="position: absolute; inset: 0; background: rgba(8,8,10,0.62); backdrop-filter: blur(6px); display: flex; align-items: center; justify-content: center;">
      <div class="card" style="width: 640px; padding: 36px 40px 32px; background: ${C.layer}; border-color: ${C.strokeStrong}; box-shadow: 0 24px 80px rgba(0,0,0,0.6); display: flex; flex-direction: column; gap: 28px;">
        <div style="display: flex; flex-direction: column; gap: 6px;">
          <div style="font-size: 24px; font-weight: 600;">Üdv a ClearStarban!</div>
          <div style="font-size: 14px; color: ${C.text2};">Három lépésben a nyers képektől a kész asztrofotóig. Végig kézen fogunk, és minden lépésnél elmondjuk, mi történik.</div>
        </div>
        <div style="display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px;">
          ${[['folder', '1', 'Töltsd be a képeidet', 'Egy mappa elég, a többit intézzük.'], ['layers', '2', 'Menj végig a lépéseken', 'Jó alapbeállításokkal, egy kattintással.'], ['save', '3', 'Mentsd el', 'Megosztáshoz, nyomtatáshoz vagy tovább szerkesztéshez.']]
            .map(([ic, n, t, d]) => `<div class="card" style="padding: 18px 16px; display: flex; flex-direction: column; gap: 10px;">
              <div style="display: flex; align-items: center; gap: 10px;"><div style="width: 24px; height: 24px; border-radius: 12px; background: ${C.accent}; color: ${C.accentText}; font-size: 12px; font-weight: 700; display: flex; align-items: center; justify-content: center;">${n}</div>${icon(ic, 18, C.accent)}</div>
              <div style="font-size: 13.5px; font-weight: 600;">${t}</div>
              <div style="font-size: 12px; color: ${C.text2};">${d}</div>
            </div>`).join('')}
        </div>
        <div style="display: flex; align-items: center; justify-content: space-between;">
          <a style="font-size: 12.5px; color: ${C.text3};">Ne mutasd többet</a>
          <div class="btn btn-primary" style="height: 38px; padding: 0 22px;">Kezdjük!${icon('arrow', 16)}</div>
        </div>
      </div>
    </div>`;
  fs.writeFileSync(path.join(OUT, 'Main.dc.html'), page({
    sidebarHtml: sidebar({ stateOf: n => ({ state: n === 1 ? 'active' : 'pending' }), activeBody: body, doneCount: 0 }),
    toolbarHtml: toolbar({ disabled: true }),
    viewportHtml: viewport,
    statusHtml: statusbar('Nincs megnyitott kép'),
    overlayHtml: overlay,
  }));
}

// ================= B) Képek összeillesztése =================
{
  const body = `
    <p class="desc">A sok rövid felvételt egyetlen, sokkal tisztább képpé rakjuk össze. A sötét- és flat-képek a szenzor hibáit tüntetik el.</p>
    ${slider('Illesztés alapossága', 'Kiegyensúlyozott', 50, ['Gyors', 'Kiegyensúlyozott', 'Alapos'])}
    ${toggle('Gyenge képek automatikus kihagyása', true)}
    ${advanced()}
    <div style="display: flex; flex-direction: column; gap: 8px; padding-top: 4px;">
      <div style="display: flex; justify-content: space-between; font-size: 12.5px;"><span>Összeillesztés folyamatban…</span><span style="color: ${C.text2};">14 / 24</span></div>
      <div style="height: 6px; border-radius: 3px; background: rgba(255,255,255,0.1);"><div style="height: 6px; border-radius: 3px; background: ${C.accent}; width: 58%;"></div></div>
      <div style="display: flex; justify-content: space-between; align-items: center;"><span style="font-size: 11.5px; color: ${C.text3};">Még kb. 2 perc</span><a style="font-size: 12.5px; color: ${C.text2};">Megszakítás</a></div>
    </div>`;
  const tab = (name, count, on) => `<div style="display: flex; align-items: center; gap: 8px; height: 36px; padding: 0 14px; border-radius: 8px; font-size: 13px; ${on ? `background: rgba(255,255,255,0.08); color: ${C.text}; font-weight: 600;` : `color: ${C.text2};`}">${name}<span style="font-size: 11.5px; padding: 1px 7px; border-radius: 9px; background: rgba(255,255,255,0.08); color: ${C.text2}; font-weight: 500;">${count}</span></div>`;
  let grid = '';
  for (let i = 0; i < 24; i++) {
    const done = i < 14, cur = i === 14;
    grid += `<div style="position: relative; aspect-ratio: 16 / 11; border-radius: 8px; overflow: hidden; border: 1px solid ${cur ? C.accent : C.stroke}; ${done ? '' : 'opacity: 0.55;'}">
      <img src="frame.svg" class="thumb-img">
      <div style="position: absolute; left: 8px; bottom: 6px; font-size: 11px; color: ${C.text2};">L_${String(i + 1).padStart(3, '0')}.fits</div>
      ${done ? `<div style="position: absolute; right: 6px; top: 6px; width: 18px; height: 18px; border-radius: 9px; background: ${C.green}; display: flex; align-items: center; justify-content: center;">${icon('check', 11, C.accentText, 'stroke-width="3"')}</div>` : ''}
      ${cur ? `<div style="position: absolute; right: 6px; top: 6px; font-size: 10.5px; padding: 2px 7px; border-radius: 9px; background: ${C.accent}; color: ${C.accentText}; font-weight: 600;">Illesztés</div>` : ''}
    </div>`;
  }
  const viewport = `
    <div style="position: absolute; inset: 0; display: flex; flex-direction: column; padding: 20px 24px;">
      <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
        <div style="display: flex; gap: 4px;">${tab('Fény', 24, true)}${tab('Sötét', 12, false)}${tab('Flat', 20, false)}${tab('Bias', 0, false)}</div>
        <div style="font-size: 12.5px; color: ${C.text2};">Összesen 2 óra 24 perc · 6 mp × 24</div>
      </div>
      <div style="display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 12px;">${grid}</div>
    </div>`;
  fs.writeFileSync(path.join(OUT, 'Stackeles.dc.html'), page({
    sidebarHtml: sidebar({ stateOf: n => n === 1 ? { state: 'done', meta: '56 fájl' } : n === 2 ? { state: 'active' } : { state: 'pending' }, activeBody: body, doneCount: 1 }),
    toolbarHtml: toolbar({ disabled: true }),
    viewportHtml: viewport,
    statusHtml: statusbar('24 fénykép · Canon EOS R6 · 6072 × 4048', `<span>Összeillesztés… kb. 2 perc</span><div style="width: 160px; height: 4px; border-radius: 2px; background: rgba(255,255,255,0.1);"><div style="height: 4px; border-radius: 2px; background: ${C.accent}; width: 58%;"></div></div>`),
  }));
}

// ================= C) Háttér kiegyenlítése =================
{
  const body = `
    <p class="desc">A fényszennyezés és a hold egyenetlen, foltos hátteret hagy. Itt ezt simítjuk ki, hogy az ég mindenhol egyformán sötét legyen.</p>
    ${slider('Kiegyenlítés erőssége', 'Közepes', 50, ['Gyenge', 'Közepes', 'Erős'])}
    ${slider('Simítás', 'Finom', 22, ['Finom', 'Közepes', 'Durva'])}
    ${toggle('Mintavételi pontok mutatása', true)}
    ${advanced()}
    ${actions()}`;
  let pts = '';
  const r = rng(21);
  for (let gy = 0; gy < 6; gy++) for (let gx = 0; gx < 9; gx++) {
    const cx = 8 + gx * 10.5, cy = 9 + gy * 16.5;
    const inCore = Math.abs(cx - 52) < 24 && Math.abs(cy - 48) < 20;
    if (inCore && r() < 0.8) continue;
    pts += `<div style="position: absolute; left: ${cx}%; top: ${cy}%; width: 14px; height: 14px; margin: -7px 0 0 -7px; border-radius: 7px; border: 1.5px solid ${C.accent}; background: rgba(62,207,192,0.25);"></div>`;
  }
  const viewport = `
    <div style="position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; padding: 24px;">
      <div style="position: relative; width: 1080px; height: 720px; box-shadow: 0 0 0 1px rgba(255,255,255,0.06);">
        <img src="nebula.svg" class="thumb-img">
        <div style="position: absolute; inset: 0; background: linear-gradient(115deg, rgba(120,90,60,0.28), rgba(0,0,0,0) 55%, rgba(40,60,120,0.18));"></div>
        ${pts}
      </div>
    </div>
    ${navigator()}
    ${zoomPill('48%')}`;
  fs.writeFileSync(path.join(OUT, 'Hatter.dc.html'), page({
    sidebarHtml: sidebar({ stateOf: n => n < 4 ? { state: 'done', meta: n === 2 ? '24 kép' : '' } : n === 4 ? { state: 'active' } : { state: 'pending' }, activeBody: body, doneCount: 3 }),
    toolbarHtml: toolbar(),
    viewportHtml: viewport,
    statusHtml: statusbar('M31_stack.fits · 6072 × 4048 · 32 bit', 'Előnézet kész'),
  }));
}

// ================= D) Csillagok visszahelyezése =================
{
  const body = `
    <p class="desc">A külön kiemelt ködöt és a külön nyújtott csillagokat itt rakjuk újra össze. A csillagok így nem égnek ki, a köd pedig részletgazdag marad.</p>
    ${slider('Csillagok erőssége', 'Természetes', 50, ['Visszafogott', 'Természetes', 'Hangsúlyos'])}
    ${toggle('Csillagok színének megőrzése', true)}
    ${advanced()}
    ${actions()}`;
  const viewport = `
    <div style="position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; padding: 24px;">
      <div style="position: relative; width: 1080px; height: 720px; box-shadow: 0 0 0 1px rgba(255,255,255,0.06); overflow: hidden;">
        <img src="nebula.svg" class="thumb-img">
        <div style="position: absolute; left: 0; top: 0; bottom: 0; width: 46%; overflow: hidden;"><img src="nebula-starless.svg" style="width: 1080px; height: 720px; max-width: none; display: block;"></div>
        <div style="position: absolute; left: 46%; top: 0; bottom: 0; width: 2px; background: #fff; margin-left: -1px; box-shadow: 0 0 8px rgba(0,0,0,0.8);"></div>
        <div style="position: absolute; left: 46%; top: 50%; width: 34px; height: 34px; margin: -17px 0 0 -17px; border-radius: 17px; background: #fff; display: flex; align-items: center; justify-content: center; box-shadow: 0 2px 10px rgba(0,0,0,0.6);"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="${C.title}" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="m9 6-5 6 5 6M15 6l5 6-5 6"/></svg></div>
        <div style="position: absolute; left: 16px; top: 16px; font-size: 12px; font-weight: 600; padding: 4px 10px; border-radius: 6px; background: rgba(0,0,0,0.55); backdrop-filter: blur(8px);">Előtte · csillagok nélkül</div>
        <div style="position: absolute; right: 16px; top: 16px; font-size: 12px; font-weight: 600; padding: 4px 10px; border-radius: 6px; background: rgba(62,207,192,0.9); color: ${C.accentText};">Utána · csillagokkal</div>
      </div>
    </div>
    ${navigator()}
    ${zoomPill('48%')}`;
  fs.writeFileSync(path.join(OUT, 'Csillagok.dc.html'), page({
    sidebarHtml: sidebar({ stateOf: n => n < 12 ? { state: n === 7 ? 'skip' : 'done', meta: n === 2 ? '24 kép' : '' } : n === 12 ? { state: 'active' } : { state: 'pending' }, activeBody: body, doneCount: 11, headline: 'Szép munka! Már csak 5 lépés van hátra.' }),
    toolbarHtml: toolbar({ splitOn: true }),
    viewportHtml: viewport,
    statusHtml: statusbar('M31_stack.fits · 6072 × 4048 · 32 bit', 'Előnézet kész'),
  }));
}

// ================= E) Mentés =================
{
  const body = `
    <p class="desc">Kész a képed! Válaszd ki jobb oldalt, mire szeretnéd használni, a többit beállítjuk.</p>
    <div style="display: flex; flex-direction: column; gap: 6px;">
      <div style="font-size: 12.5px;">Hova mentsük?</div>
      <div style="display: flex; align-items: center; gap: 8px; height: 34px; padding: 0 10px; border-radius: 8px; background: rgba(255,255,255,0.05); border: 1px solid ${C.strokeStrong}; font-size: 12.5px; color: ${C.text2};">${icon('folder', 15)}<span style="flex-grow: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">D:\\Asztro\\2026-09\\M31\\kész</span><a style="font-size: 12px;">Módosítás</a></div>
    </div>
    ${toggle('Feldolgozási lépések mentése a kép mellé', true)}
    ${actions('Mentés', false)}`;
  const fmt = (ic, title, sub, detail, on) => `<div class="card" style="flex: 1 1 0; padding: 22px 20px; display: flex; flex-direction: column; gap: 12px; ${on ? `border-color: ${C.accent}; background: ${C.cardActive}; box-shadow: 0 0 0 1px ${C.accent};` : ''}">
    <div style="display: flex; align-items: center; justify-content: space-between;">${icon(ic, 26, on ? C.accent : C.text2)}<div style="width: 18px; height: 18px; border-radius: 9px; border: 2px solid ${on ? C.accent : C.strokeStrong}; display: flex; align-items: center; justify-content: center;">${on ? `<div style="width: 8px; height: 8px; border-radius: 4px; background: ${C.accent};"></div>` : ''}</div></div>
    <div><div style="font-size: 15px; font-weight: 600;">${title}</div><div style="font-size: 12.5px; color: ${C.accent}; margin-top: 2px;">${sub}</div></div>
    <div style="font-size: 12.5px; color: ${C.text2};">${detail}</div>
  </div>`;
  const viewport = `
    <div style="position: absolute; inset: 0; display: flex; flex-direction: column; padding: 24px 28px; gap: 20px;">
      <div style="display: flex; gap: 16px;">
        ${fmt('share', 'Megosztáshoz', 'JPEG · kb. 4,2 MB', 'Telefonra, közösségi oldalakra, e-mailbe. A legkisebb fájl, mindenhol megnyílik.', true)}
        ${fmt('print', 'Nyomtatáshoz', 'TIFF 16 bit · kb. 140 MB', 'Teljes minőség nagy nyomatokhoz és fotókönyvhöz.', false)}
        ${fmt('file', 'További szerkesztéshez', 'FITS 32 bit · kb. 280 MB', 'Ha más programban (pl. Siril, Photoshop) folytatnád.', false)}
      </div>
      <div style="display: flex; align-items: center; justify-content: space-between; font-size: 12.5px; color: ${C.text2};">
        <div>Fájlnév: <span style="color: ${C.text};">M31_Andromeda_ClearStar.jpg</span></div>
        <div>6072 × 4048 px · sRGB</div>
      </div>
      <div style="position: relative; flex-grow: 1; border-radius: 10px; overflow: hidden; border: 1px solid ${C.stroke};">
        <img src="nebula.svg" class="thumb-img">
      </div>
    </div>`;
  fs.writeFileSync(path.join(OUT, 'Mentes.dc.html'), page({
    sidebarHtml: sidebar({ stateOf: n => n < 17 ? { state: n === 7 || n === 14 ? 'skip' : 'done', meta: n === 2 ? '24 kép' : '' } : { state: 'active' }, activeBody: body, doneCount: 16, headline: 'Ez az utolsó lépés – mindjárt kész!' }),
    toolbarHtml: toolbar(),
    viewportHtml: viewport,
    statusHtml: statusbar('M31_Andromeda_ClearStar.jpg · JPEG · 6072 × 4048', 'Mentésre kész'),
  }));
}

// ---------- canvas layout ----------
const boards = [
  ['Main.dc.html', 'A · Induló állapot'],
  ['Stackeles.dc.html', 'B · Képek összeillesztése'],
  ['Hatter.dc.html', 'C · Háttér kiegyenlítése'],
  ['Csillagok.dc.html', 'D · Csillagok visszahelyezése'],
  ['Mentes.dc.html', 'E · Mentés'],
];
const GAP = 160;
fs.writeFileSync(path.join(OUT, 'canvas.json'), JSON.stringify({
  artboards: boards.map(([file, title], i) => ({ file, title, x: (i % 2) * (W + GAP), y: Math.floor(i / 2) * (H + GAP), w: W, h: H })),
  annotations: [
    { id: 'brief', x: 2 * (W + GAP), y: 2 * (H + GAP), w: 360, text: 'ClearStar – vezetett asztrofotó-feldolgozás kezdőknek.\n\nBal oldalon a 17 lépéses akkordeon: az aktív lépés nyitva, benne a beállításokkal és egy egymondatos magyarázattal. Bármelyik kész lépésre visszaugorva a későbbiek „Frissítés szükséges” jelölést kapnak (borostyán „!”), a kihagyottak áthúzva maradnak.\n\nA képnézet felett: „Eredeti” (lenyomva tartva) és „Előtte / utána” osztott nézet.' },
  ],
  launch: { view: 'canvas' },
}, null, 2));

console.log('written', boards.length, 'artboards +', ['nebula.svg', 'nebula-starless.svg', 'frame.svg'].join(', '));
