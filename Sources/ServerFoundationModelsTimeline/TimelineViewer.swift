// The run debugger, embedded: written next to every timeline.json so any
// run — current or archived — opens as an interactive waterfall in a browser
// with zero extra tooling. Placeholders: TIMELINE_LABEL, TIMELINE_DATA.
let timelineViewerTemplate = #"""
<title>R2 run debugger — TIMELINE_LABEL</title>
<style>
:root {
  --surface:#fcfcfb; --surface2:#f3f2ee; --edge:rgba(11,11,11,.12);
  --ink:#0b0b0b; --ink2:#52514e; --ink3:#8a8880;
  --gemini:#2a78d6; --deepseek:#199e70; --fetch:#eda100; --search:#008300; --linkedin:#4a3aa7;
  --phaseA:rgba(42,120,214,.05); --grid:rgba(11,11,11,.08);
  --mark:rgba(11,11,11,.35); --ttft:rgba(11,11,11,.38); --sel:#e34948;
}
@media (prefers-color-scheme: dark) { :root {
  --surface:#1a1a19; --surface2:#232322; --edge:rgba(255,255,255,.14);
  --ink:#ffffff; --ink2:#c3c2b7; --ink3:#8a8880;
  --gemini:#3987e5; --deepseek:#1baf7a; --fetch:#c98500; --search:#3da03d; --linkedin:#9085e9;
  --phaseA:rgba(57,135,229,.09); --grid:rgba(255,255,255,.09);
  --mark:rgba(255,255,255,.4); --ttft:rgba(255,255,255,.45); --sel:#e66767;
} }
:root[data-theme="dark"] {
  --surface:#1a1a19; --surface2:#232322; --edge:rgba(255,255,255,.14);
  --ink:#ffffff; --ink2:#c3c2b7; --ink3:#8a8880;
  --gemini:#3987e5; --deepseek:#1baf7a; --fetch:#c98500; --search:#3da03d; --linkedin:#9085e9;
  --phaseA:rgba(57,135,229,.09); --grid:rgba(255,255,255,.09);
  --mark:rgba(255,255,255,.4); --ttft:rgba(255,255,255,.45); --sel:#e66767;
}
:root[data-theme="light"] {
  --surface:#fcfcfb; --surface2:#f3f2ee; --edge:rgba(11,11,11,.12);
  --ink:#0b0b0b; --ink2:#52514e; --ink3:#8a8880;
  --gemini:#2a78d6; --deepseek:#199e70; --fetch:#eda100; --search:#008300; --linkedin:#4a3aa7;
  --phaseA:rgba(42,120,214,.05); --grid:rgba(11,11,11,.08);
  --mark:rgba(11,11,11,.35); --ttft:rgba(11,11,11,.38); --sel:#e34948;
}
* { box-sizing: border-box; }
body { background:var(--surface); color:var(--ink); margin:0;
  font:14px/1.5 -apple-system,"Segoe UI",system-ui,sans-serif; }
.page { display:grid; grid-template-columns: minmax(0,1fr) 400px; gap:0; min-height:100vh; }
.main { padding:22px 20px 40px 24px; min-width:0; }
h1 { font-size:17px; margin:0 0 2px; letter-spacing:-.01em; }
.stats { color:var(--ink2); font:11.5px ui-monospace,Menlo,monospace; margin:0 0 14px; }
.controls { display:flex; gap:14px; align-items:center; flex-wrap:wrap; margin-bottom:12px;
  font:11.5px ui-monospace,Menlo,monospace; color:var(--ink2); }
.controls button { font:inherit; color:var(--ink2); background:var(--surface2);
  border:1px solid var(--edge); border-radius:5px; padding:2px 9px; cursor:pointer; }
.controls button[data-on="1"] { color:var(--surface); background:var(--ink); border-color:var(--ink); }
.controls label { cursor:pointer; user-select:none; }
.controls input { vertical-align:-2px; margin-right:3px; }
.chartrow { display:flex; border:1px solid var(--edge); border-radius:8px; overflow:hidden; }
.lanecol { flex:0 0 128px; background:var(--surface2); font:600 10.5px ui-monospace,Menlo,monospace;
  color:var(--ink2); position:relative; border-right:1px solid var(--edge); }
.lanecol div { position:absolute; left:10px; right:6px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.plotscroll { flex:1 1 auto; overflow-x:auto; min-width:0; }
svg { display:block; }
.grid { stroke:var(--grid); }
.tick { font:10px ui-monospace,Menlo,monospace; fill:var(--ink3); }
.mark { stroke:var(--mark); stroke-dasharray:2 3; }
.marklabel { font:9.5px ui-monospace,Menlo,monospace; fill:var(--ink2); }
.phase { fill:var(--phaseA); }
.phaselabel { font:600 10px ui-monospace,Menlo,monospace; fill:var(--ink2); letter-spacing:.05em; }
.bar { cursor:pointer; }
.bar.gemini { fill:var(--gemini); } .bar.deepseek { fill:var(--deepseek); }
.bar.fetch { fill:var(--fetch); } .bar.search { fill:var(--search); } .bar.linkedin { fill:var(--linkedin); }
.bar.other { fill:var(--ink3); }
.bar:hover { opacity:.72; }
.bar.hollow { fill-opacity:.16; stroke-width:1.4; }
.bar.gemini.hollow { stroke:var(--gemini); } .bar.deepseek.hollow { stroke:var(--deepseek); }
.bar.selected { stroke:var(--sel) !important; stroke-width:2 !important; }
.ttftseg { fill:var(--ttft); pointer-events:none; }
.legend { display:flex; gap:16px; flex-wrap:wrap; margin:10px 0 4px; font:11px ui-monospace,Menlo,monospace; color:var(--ink2); }
.legend span::before { content:""; display:inline-block; width:10px; height:10px; border-radius:2px; margin-right:5px; vertical-align:-1px; }
.lg-gemini::before { background:var(--gemini); } .lg-deepseek::before { background:var(--deepseek); }
.lg-fetch::before { background:var(--fetch); } .lg-search::before { background:var(--search); }
.lg-linkedin::before { background:var(--linkedin); } .lg-ttft::before { background:var(--ttft); }
.lg-hollow::before { background:transparent; border:1.5px solid var(--gemini); }
h2 { font-size:13px; margin:22px 0 8px; }
table { border-collapse:collapse; font:11.5px ui-monospace,Menlo,monospace; font-variant-numeric:tabular-nums; width:100%; }
td,th { padding:4px 12px 4px 0; text-align:left; border-bottom:1px solid var(--grid); color:var(--ink2); }
th { color:var(--ink3); font-weight:600; letter-spacing:.05em; text-transform:uppercase; font-size:9.5px; }
tbody tr { cursor:pointer; } tbody tr:hover td { color:var(--ink); }
td.num { color:var(--ink); font-weight:600; }
td.what { max-width:420px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.aside { border-left:1px solid var(--edge); background:var(--surface2); padding:20px 18px;
  position:sticky; top:0; height:100vh; overflow-y:auto; }
.aside h3 { font-size:12px; text-transform:uppercase; letter-spacing:.06em; color:var(--ink3); margin:0 0 10px; }
.detail-kind { font:600 13px ui-monospace,Menlo,monospace; margin-bottom:8px; }
.kv { display:grid; grid-template-columns:92px 1fr; gap:3px 10px;
  font:11.5px ui-monospace,Menlo,monospace; color:var(--ink2); margin-bottom:14px; }
.kv b { color:var(--ink); font-weight:600; font-variant-numeric:tabular-nums; }
.io h4 { font-size:10px; text-transform:uppercase; letter-spacing:.06em; color:var(--ink3); margin:12px 0 4px; }
.io pre { background:var(--surface); border:1px solid var(--edge); border-radius:6px; padding:9px 11px;
  font:11px/1.55 ui-monospace,Menlo,monospace; color:var(--ink); white-space:pre-wrap;
  word-break:break-word; margin:0; max-height:230px; overflow-y:auto; }
.hint { color:var(--ink3); font:12px/1.6 ui-monospace,Menlo,monospace; }
#tip { position:fixed; pointer-events:none; background:var(--ink); color:var(--surface);
  font:11px ui-monospace,Menlo,monospace; padding:4px 8px; border-radius:5px; display:none; z-index:9; max-width:420px; }
@media (max-width: 1100px) { .page { grid-template-columns:1fr; } .aside { position:static; height:auto; border-left:none; border-top:1px solid var(--edge); } }
</style>
<div class="page">
<div class="main">
  <h1>R2 run debugger — TIMELINE_LABEL</h1>
  <p class="stats" id="stats"></p>
  <div class="controls">
    <span>zoom</span>
    <button data-zoom="1" data-on="1">1×</button><button data-zoom="2">2×</button>
    <button data-zoom="4">4×</button><button data-zoom="8">8×</button>
    <span style="margin-left:10px">lanes</span>
    <label><input type="checkbox" data-lane="gemini" checked>main model</label>
    <label><input type="checkbox" data-lane="deepseek" checked>distiller</label>
    <label><input type="checkbox" data-lane="fetch" checked>fetch</label>
    <label><input type="checkbox" data-lane="search" checked>search</label>
    <label><input type="checkbox" data-lane="linkedin" checked>linkedin</label>
  </div>
  <div class="chartrow"><div class="lanecol" id="lanecol"></div><div class="plotscroll"><div id="chart"></div></div></div>
  <div class="legend">
    <span class="lg-gemini">main model request</span><span class="lg-deepseek">distiller request</span>
    <span class="lg-fetch">fetchWebpage</span><span class="lg-search">searchWeb</span>
    <span class="lg-linkedin">lookupLinkedIn</span><span class="lg-ttft">lead segment = time to first token</span>
    <span class="lg-hollow">outlined = round answered with tool calls · solid = wrote text</span>
  </div>
  <h2>Longest spans — click to inspect</h2>
  <table id="topspans"><thead><tr><th>dur</th><th>at</th><th>lane</th><th>what</th></tr></thead><tbody></tbody></table>
</div>
<aside class="aside" id="aside">
  <h3>Span detail</h3>
  <p class="hint">Click any span in the waterfall or the table to see its timings, tokens, and full input/output excerpts.</p>
</aside>
</div>
<div id="tip"></div>
<script>
const DATA = TIMELINE_DATA;
{ // the recorder's epoch initializes lazily — shift so the earliest event is t=0
  const starts = [...DATA.requests.map(r => r.start), ...DATA.tools.map(t => t.start), ...DATA.marks.map(m => m.at)];
  const shift = -Math.min(Math.min(...starts), 0);
  DATA.requests.forEach(r => r.start += shift);
  DATA.tools.forEach(t => t.start += shift);
  DATA.marks.forEach(m => m.at += shift);
}

const laneDefs = [
  ["gemini",   "main model",  DATA.requests.filter(r => r.model.includes("gemini")).map(r => reqSpan(r))],
  ["deepseek", "distiller",   DATA.requests.filter(r => r.model.includes("deepseek")).map(r => reqSpan(r))],
  ["fetch",    "fetchWebpage", toolSpans("fetchWebpage")],
  ["search",   "searchWeb",    toolSpans("searchWeb")],
  ["linkedin", "lookupLinkedIn", toolSpans("lookupLinkedInProfile")],
];
function reqSpan(r) {
  // A round whose entire answer was tool calls (new data records them as
  // "→ tool …"; older data left the response empty on a successful round).
  const resp = r.response || "";
  const toolRound = resp.startsWith("→") || (resp === "" && r.ok);
  return { kind:"request", start:r.start, dur:r.total, ttft:r.firstToken, toolRound, d:r };
}
function toolSpans(name) {
  return DATA.tools.filter(t => t.tool === name).map(t => ({ kind:"tool", start:t.start, dur:t.duration, ttft:null, d:t }));
}
const END = Math.max(...laneDefs.flatMap(l => l[2].map(s => s.start + s.dur))) + 2;
const marks = DATA.marks.slice().sort((a,b) => a.at - b.at);

// stats: peak concurrency + volume
const events = DATA.requests.flatMap(r => [[r.start,1],[r.start+r.total,-1]]).sort((a,b)=>a[0]-b[0]||a[1]-b[1]);
let cur=0, peak=0; for (const [,d] of events) { cur+=d; peak=Math.max(peak,cur); }
document.getElementById("stats").textContent =
  `${Math.round(END)}s wall · ${DATA.requests.length} model requests · ${DATA.tools.length} tool runs · peak ${peak} concurrent requests · ` +
  `${Math.round(DATA.requests.reduce((a,r)=>a+r.tokensIn,0)/1000)}k tokens in / ${Math.round(DATA.requests.reduce((a,r)=>a+r.tokensOut,0)/1000)}k out`;

function pack(spans) {
  const rows = [];
  for (const s of spans.slice().sort((a,b)=>a.start-b.start)) {
    let placed = false;
    for (let i=0; i<rows.length; i++) if (s.start >= rows[i] - 0.15) { s.row=i; rows[i]=s.start+Math.max(s.dur,0.6); placed=true; break; }
    if (!placed) { s.row=rows.length; rows.push(s.start+Math.max(s.dur,0.6)); }
  }
  return rows.length;
}

const BARH=9, ROWGAP=3, LANEGAP=16, TOP=46;
let zoom=1, selected=null;
const enabled = Object.fromEntries(laneDefs.map(l=>[l[0],true]));

function fmt(x, digits=1) { return x.toFixed(digits); }
function esc(s) { return s.replace(/&/g,"&amp;").replace(/</g,"&lt;"); }

function render() {
  const pxPerSec = 4.6 * zoom;
  const W = Math.ceil(END * pxPerSec) + 24;
  const active = laneDefs.filter(l => enabled[l[0]]);
  let y = TOP;
  const lanes = [];
  for (const [key, title, spans] of active) {
    const nrows = pack(spans);
    const h = nrows*(BARH+ROWGAP)-ROWGAP;
    lanes.push({key, title, spans, y, h});
    y += h + LANEGAP;
  }
  const H = y + 26;
  const X = sec => sec * pxPerSec + 2;
  let svg = [];
  const pillarsAt = marks.find(m => m.label === "pillars started");
  if (pillarsAt) {
    svg.push(`<rect class="phase" x="${X(0)}" y="${TOP-24}" width="${X(pillarsAt.at)-X(0)}" height="${H-TOP+6}"/>`);
    svg.push(`<text class="phaselabel" x="${X(0)+5}" y="${TOP-28}">identity + plan · 0–${fmt(pillarsAt.at,0)}s</text>`);
    svg.push(`<text class="phaselabel" x="${X(pillarsAt.at)+5}" y="${TOP-28}">pillars in parallel</text>`);
  }
  const step = zoom >= 4 ? 10 : 30;
  for (let sec=0; sec<=END; sec+=step) {
    svg.push(`<line class="grid" x1="${X(sec)}" y1="${TOP-24}" x2="${X(sec)}" y2="${H-20}"/>`);
    svg.push(`<text class="tick" x="${X(sec)}" y="${H-6}" text-anchor="middle">${sec}s</text>`);
  }
  for (const m of marks) if (m.label.endsWith("done")) {
    svg.push(`<line class="mark" x1="${X(m.at)}" y1="${TOP-18}" x2="${X(m.at)}" y2="${H-20}"/>`);
    svg.push(`<text class="marklabel" x="${X(m.at)-3}" y="${TOP-8}" text-anchor="end">${esc(m.label.replace(" done",""))} ✓</text>`);
  }
  const rects = [];
  lanes.forEach((lane, li) => {
    lane.spans.forEach((s, si) => {
      const ry = lane.y + s.row*(BARH+ROWGAP);
      const w = Math.max(s.dur*pxPerSec, 2);
      const id = `${lane.key}:${si}`;
      const sel = selected === id ? " selected" : "";
      const hollow = s.toolRound ? " hollow" : "";
      rects.push(`<rect class="bar ${lane.key}${hollow}${sel}" data-id="${id}" x="${fmt(X(s.start),1)}" y="${ry}" width="${fmt(w,1)}" height="${BARH}" rx="2"/>`);
      if (s.ttft && s.dur > 1) {
        rects.push(`<rect class="ttftseg" x="${fmt(X(s.start),1)}" y="${ry}" width="${fmt(Math.max(s.ttft*pxPerSec,1),1)}" height="${BARH}" rx="2"/>`);
      }
    });
  });
  svg.push(rects.join(""));
  document.getElementById("chart").innerHTML =
    `<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">${svg.join("")}</svg>`;
  const laneCol = lanes.map(l =>
    `<div style="top:${l.y + l.h/2 - 8}px">${l.title}</div>`).join("");
  const lc = document.getElementById("lanecol");
  lc.innerHTML = laneCol; lc.style.height = H + "px";
  attach(lanes);
}

const tip = document.getElementById("tip");
function attach(lanes) {
  const byId = {};
  for (const lane of lanes) lane.spans.forEach((s, si) => byId[`${lane.key}:${si}`] = {lane, s});
  document.querySelectorAll(".bar").forEach(el => {
    const {lane, s} = byId[el.dataset.id];
    el.addEventListener("mousemove", e => {
      const what = s.kind === "request" ? (s.d.prompt || "(no prompt)") : (s.d.input || "");
      const badge = s.kind === "request" ? (s.toolRound ? "⚙ tool-call round · " : "✎ text round · ") : "";
      tip.textContent = `${badge}${fmt(s.dur)}s @ ${fmt(s.start)}s — ${what.slice(0,90)}`;
      tip.style.display = "block";
      tip.style.left = Math.min(e.clientX+12, innerWidth-440)+"px";
      tip.style.top = (e.clientY+14)+"px";
    });
    el.addEventListener("mouseleave", () => tip.style.display = "none");
    el.addEventListener("click", () => { selected = el.dataset.id; render(); show(lane, s); });
  });
}

function show(lane, s) {
  const a = document.getElementById("aside");
  let kv, io;
  if (s.kind === "request") {
    const d = s.d;
    kv = `<div class="kv">
      <span>starts</span><b>${fmt(s.start)}s</b>
      <span>total</span><b>${fmt(d.total)}s</b>
      <span>gate wait</span><b>${fmt(d.gateWait,2)}s</b>
      <span>connect</span><b>${fmt(d.connect,2)}s</b>
      <span>first token</span><b>${fmt(d.firstToken,2)}s</b>
      <span>stream</span><b>${fmt(d.total-d.firstToken,2)}s</b>
      <span>tokens in</span><b>${d.tokensIn.toLocaleString()}</b>
      <span>tokens out</span><b>${d.tokensOut.toLocaleString()}</b>
      <span>status</span><b>${d.ok ? "ok" : "FAILED"}</b>
      <span>answered</span><b>${s.toolRound ? "tool calls" : "text"}</b></div>`;
    io = `<div class="io"><h4>prompt (head)</h4><pre>${esc(d.prompt || "—")}</pre>
      <h4>${s.toolRound ? "tool calls issued" : "response (head)"}</h4><pre>${esc(d.response || (s.toolRound ? "(recorded runs before tool-call capture show the calls in the tool lanes below)" : "—"))}</pre></div>`;
  } else {
    const d = s.d;
    kv = `<div class="kv">
      <span>starts</span><b>${fmt(s.start)}s</b>
      <span>duration</span><b>${fmt(d.duration)}s</b></div>`;
    io = `<div class="io"><h4>arguments</h4><pre>${esc(d.input || "—")}</pre>
      <h4>output (head)</h4><pre>${esc(d.output || "—")}</pre></div>`;
  }
  a.innerHTML = `<h3>Span detail</h3><div class="detail-kind">${lane.title}</div>${kv}${io}`;
}

// longest-spans table
const all = [];
laneDefs.forEach(([key, title, spans]) => spans.forEach((s, si) => all.push({key, title, s, si})));
all.sort((a,b) => b.s.dur - a.s.dur);
document.querySelector("#topspans tbody").innerHTML = all.slice(0,18).map((e,i) => {
  const what = e.s.kind === "request" ? (e.s.d.prompt || "") : (e.s.d.input || "");
  return `<tr data-i="${i}"><td class="num">${fmt(e.s.dur)}s</td><td>${fmt(e.s.start)}s</td><td>${e.title}</td><td class="what">${esc(what.slice(0,110))}</td></tr>`;
}).join("");
document.querySelectorAll("#topspans tbody tr").forEach(tr => {
  tr.addEventListener("click", () => {
    const e = all[+tr.dataset.i];
    selected = `${e.key}:${e.si}`; render();
    show({title: e.title}, e.s);
  });
});

document.querySelectorAll("[data-zoom]").forEach(b => b.addEventListener("click", () => {
  zoom = +b.dataset.zoom;
  document.querySelectorAll("[data-zoom]").forEach(x => x.dataset.on = x === b ? "1" : "0");
  render();
}));
document.querySelectorAll("[data-lane]").forEach(c => c.addEventListener("change", () => {
  enabled[c.dataset.lane] = c.checked; render();
}));
render();
</script>
"""#
