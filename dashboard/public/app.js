'use strict';

const STATUSES = ['Open', 'In Progress', 'Resolved', 'Closed'];
let STATE = null;
let CURRENT_FILTER = 'all';
let OPEN_TICKET_ID = null;

const $  = (sel, el = document) => el.querySelector(sel);
const $$ = (sel, el = document) => [...el.querySelectorAll(sel)];

async function api(path, method = 'GET', body) {
  const opts = { method, headers: { 'Content-Type': 'application/json' } };
  if (body) opts.body = JSON.stringify(body);
  const res = await fetch(path, opts);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`);
  return data;
}

function initials(name) {
  return (name || '?').split(/\s+/).slice(0, 2).map(w => w[0] || '').join('').toUpperCase();
}
function timeAgo(iso) {
  const s = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return 'just now';
  const m = Math.floor(s / 60); if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60); if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}
const esc = (s) => (s ?? '').toString().replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const statusClass = (s) => 's-' + s.replace(/\s+/g, '');

function toast(msg) {
  const t = $('#toast');
  t.textContent = msg; t.hidden = false;
  clearTimeout(toast._t);
  toast._t = setTimeout(() => { t.hidden = true; }, 2600);
}

/* ------------------------------ rendering ------------------------------ */

function applyConfig(cfg) {
  $('#brandCompany').textContent = cfg.companyName;
  $('#brandMark').textContent = initials(cfg.companyName);
  document.title = `${cfg.companyName} — IT Service Desk`;
  $$('#tierToggle .seg').forEach(b => b.classList.toggle('active', b.dataset.tier === cfg.tier));
  $$('#modeToggle .seg').forEach(b => b.classList.toggle('active', b.dataset.mode === cfg.mode));
  $('#modeHint').textContent = cfg.mode === 'Live' ? 'the live Entra tenant' : 'the mock tenant';
  const sel = $('#companySelect');
  if (sel.options.length !== STATE.companies.length) {
    sel.innerHTML = STATE.companies.map(c => `<option value="${c.key}">${esc(c.name)}</option>`).join('');
  }
  sel.value = cfg.company;
}

function applyStats(stats) {
  for (const key of ['total', 'open', 'inProgress', 'resolved', 'closed']) {
    const el = $(`[data-count="${key}"]`);
    if (el) el.textContent = stats[key];
  }
}

function ticketCard(t) {
  const preview = t.body.length > 160 ? t.body.slice(0, 160) + '…' : t.body;
  return `
    <article class="ticket pl-${t.priority}" data-id="${t.id}">
      <div class="ticket-top">
        <span class="ticket-number">${esc(t.number)}</span>
        <span class="badge badge-${t.priority}">${t.priority}</span>
        <span class="badge badge-status ${statusClass(t.status)}">${t.status}</span>
        ${t.tier === 'Paid' ? '<span class="badge badge-tier">Paid</span>' : ''}
        <span class="badge badge-cat">${esc(t.category)}</span>
      </div>
      <div class="ticket-subject">${esc(t.subject)}</div>
      <div class="ticket-preview">${esc(preview)}</div>
      <div class="ticket-foot">
        <span class="ticket-req"><span class="avatar">${initials(t.requester.name)}</span>${esc(t.requester.name)} · ${esc(t.requester.department)}</span>
        <span>${timeAgo(t.createdAt)}</span>
      </div>
    </article>`;
}

function render() {
  applyConfig(STATE.config);
  applyStats(STATE.stats);

  const filtered = CURRENT_FILTER === 'all'
    ? STATE.tickets
    : STATE.tickets.filter(t => t.status === CURRENT_FILTER);

  $('#queueTitle').textContent = CURRENT_FILTER === 'all' ? 'All tickets' : `${CURRENT_FILTER} tickets`;
  $('#queueMeta').textContent = `${filtered.length} ticket${filtered.length === 1 ? '' : 's'}`;

  const list = $('#ticketList');
  const empty = $('#emptyState');
  if (filtered.length === 0) {
    list.innerHTML = ''; empty.hidden = false;
  } else {
    empty.hidden = true;
    list.innerHTML = filtered.map(ticketCard).join('');
  }

  $$('#statusFilters .filter').forEach(b => b.classList.toggle('active', b.dataset.status === CURRENT_FILTER));

  if (OPEN_TICKET_ID) {
    const t = STATE.tickets.find(x => x.id === OPEN_TICKET_ID);
    if (t) renderDrawer(t); else closeDrawer();
  }
}

/* ------------------------------ drawer ------------------------------ */

function renderDrawer(t) {
  $('#dNumber').textContent = t.number;
  $('#dSubject').textContent = t.subject;
  $('#dBadges').innerHTML = `
    <span class="badge badge-${t.priority}">${t.priority} priority</span>
    <span class="badge badge-status ${statusClass(t.status)}">${t.status}</span>
    <span class="badge badge-cat">${esc(t.category)}</span>
    ${t.tier === 'Paid' ? '<span class="badge badge-tier">Paid feature</span>' : ''}`;

  $('#dRequester').innerHTML = `
    <span class="avatar">${initials(t.requester.name)}</span>
    <div>
      <div class="dr-name">${esc(t.requester.name)}</div>
      <div class="dr-meta">${esc(t.requester.title)} · ${esc(t.requester.department)} · ${esc(t.requester.office)}</div>
      <div class="dr-meta">${esc(t.requester.upn)}</div>
    </div>`;

  $('#dBody').textContent = t.body;

  const affected = t.affectedUser ? `Affected account: <code>${esc(t.affectedUser.upn)}</code><br/>` : '';
  $('#dTech').innerHTML = `
    <strong>Behind the scenes</strong><br/>
    ${affected}
    What happened: ${esc(t.actionDetail)}<br/>
    <em>Suggested fix:</em> ${esc(t.resolutionHint)}`;

  renderStatusSteps(t);
  renderResolution(t);
  $('#drawer').hidden = false;
}

function renderStatusSteps(t) {
  const idx = STATUSES.indexOf(t.status);
  const wrap = $('#dStatusSteps');
  wrap.innerHTML = STATUSES.map((s, i) => {
    let cls = 'step';
    if (i < idx) cls += ' done';
    else if (i === idx) cls += ' current';
    // The next status is actionable (Closed is handled by the form below).
    const isNext = i === idx + 1 && s !== 'Closed';
    if (isNext) cls += ' actionable';
    const label = isNext ? `Move to<br/><small>${s}</small>` : s;
    return `<div class="${cls}" ${isNext ? `data-advance="${s}"` : ''}>${label}</div>`;
  }).join('');
}

function renderResolution(t) {
  const wrap = $('#dResolutionWrap');
  const view = $('#dResolutionView');
  const form = $('#closeForm');
  const canClose = t.status === 'Resolved' || t.status === 'Closed';

  if (t.resolution) {
    wrap.hidden = false; view.hidden = false; form.hidden = true;
    view.innerHTML = `
      ${t.resolution.rootCause ? `<h4>Root cause</h4><p>${esc(t.resolution.rootCause)}</p>` : ''}
      <h4>What was done</h4><p>${esc(t.resolution.actionsTaken)}</p>
      <div class="dr-meta">Closed by ${esc(t.resolution.closedBy)} · ${new Date(t.resolution.closedAt).toLocaleString()}</div>`;
  } else if (canClose) {
    wrap.hidden = false; view.hidden = true; form.hidden = false;
  } else {
    wrap.hidden = true;
  }
}

function closeDrawer() { OPEN_TICKET_ID = null; $('#drawer').hidden = true; }

/* ------------------------------ actions ------------------------------ */

async function refresh() { STATE = await api('/api/state'); render(); }

async function checkForTickets() {
  const btn = $('#checkBtn');
  btn.disabled = true;
  $('.btn-spinner', btn).hidden = false;
  $('.btn-text', btn).textContent = 'Running incidents…';
  try {
    const res = await api('/api/tickets/check', 'POST');
    STATE = res.state; render();
    toast(`${res.created.length} new ticket${res.created.length === 1 ? '' : 's'} filed`);
  } catch (e) {
    toast(e.message);
  } finally {
    btn.disabled = false;
    $('.btn-spinner', btn).hidden = true;
    $('.btn-text', btn).textContent = 'Check for new tickets';
  }
}

async function advanceStatus(ticket, status) {
  try {
    await api(`/api/tickets/${ticket.id}`, 'PATCH', { status });
    await refresh();
    toast(`${ticket.number} → ${status}`);
  } catch (e) { toast(e.message); }
}

async function closeTicket(ticket, resolution) {
  try {
    await api(`/api/tickets/${ticket.id}`, 'PATCH', { status: 'Closed', resolution });
    await refresh();
    toast(`${ticket.number} closed`);
  } catch (e) { toast(e.message); }
}

async function setConfig(patch) {
  try { STATE = await api('/api/config', 'POST', patch); render(); }
  catch (e) { toast(e.message); }
}

/* ------------------------------ events ------------------------------ */

document.addEventListener('click', (e) => {
  const card = e.target.closest('.ticket');
  if (card) { OPEN_TICKET_ID = card.dataset.id; renderDrawer(STATE.tickets.find(t => t.id === OPEN_TICKET_ID)); return; }

  if (e.target.closest('[data-close]')) { closeDrawer(); return; }

  const advance = e.target.closest('[data-advance]');
  if (advance) {
    const t = STATE.tickets.find(x => x.id === OPEN_TICKET_ID);
    if (t) advanceStatus(t, advance.dataset.advance);
    return;
  }

  const filter = e.target.closest('.filter');
  if (filter) { CURRENT_FILTER = filter.dataset.status; render(); return; }

  const tier = e.target.closest('[data-tier]');
  if (tier) { setConfig({ tier: tier.dataset.tier }); return; }

  const mode = e.target.closest('[data-mode]');
  if (mode) {
    if (mode.dataset.mode === 'Live') {
      if (!confirm('Live mode runs REAL actions (disable/delete/reset) against your seeded Entra tenant. Continue?')) return;
    }
    setConfig({ mode: mode.dataset.mode });
    return;
  }
});

$('#checkBtn').addEventListener('click', checkForTickets);
$('#companySelect').addEventListener('change', (e) => setConfig({ company: e.target.value }));
$('#resetBtn').addEventListener('click', async () => {
  if (!confirm('Clear all tickets from the queue? (Does not touch Entra.)')) return;
  STATE = await api('/api/reset', 'POST'); OPEN_TICKET_ID = null; render(); toast('Queue cleared');
});

$('#closeForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const t = STATE.tickets.find(x => x.id === OPEN_TICKET_ID);
  if (!t) return;
  const fd = new FormData(e.target);
  const actionsTaken = (fd.get('actionsTaken') || '').toString().trim();
  if (!actionsTaken) { toast('Please document what you did before closing.'); return; }
  closeTicket(t, {
    rootCause: (fd.get('rootCause') || '').toString().trim(),
    actionsTaken,
    closedBy: (fd.get('closedBy') || '').toString().trim() || 'Service Desk',
  });
  e.target.reset();
});

document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeDrawer(); });

refresh().catch(e => toast('Could not load: ' + e.message));
