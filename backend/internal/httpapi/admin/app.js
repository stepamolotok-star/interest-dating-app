'use strict';
// Страница модератора. Все данные пользователей выводятся только через textContent —
// без innerHTML, чтобы текст жалобы или анкеты не мог стать кодом.

const REASONS = {
  threat: 'Угрозы', harassment: 'Преследование', stalking: 'Слежка', minor: 'Похоже на несовершеннолетнего',
  fake: 'Фейк', spam: 'Спам или реклама', paid_services: 'Платные услуги', explicit: 'Непристойное', other: 'Другое',
};
const RESOLUTIONS = { dismiss: 'Отклонена', warn: 'Предупреждение', suspend: 'Временная блокировка', ban: 'Блокировка навсегда' };
const ACTIONS = { ...RESOLUTIONS, unban: 'Разблокирован', hold: 'Скрыт до проверки', release: 'Возвращён в ленту' };

const store = {
  get token() { try { return sessionStorage.getItem('mod_token') || ''; } catch { return ''; } },
  get name() { try { return sessionStorage.getItem('mod_name') || ''; } catch { return ''; } },
  save(token, name) { try { sessionStorage.setItem('mod_token', token); sessionStorage.setItem('mod_name', name); } catch { /* приватный режим */ } },
  clear() { try { sessionStorage.clear(); } catch { /* ничего */ } },
};
let memToken = '', memName = '';
const token = () => store.token || memToken;
const modName = () => store.name || memName;

const $ = (id) => document.getElementById(id);
function el(tag, props = {}, ...children) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === 'class') n.className = v;
    else if (k === 'text') n.textContent = v;
    else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
    else if (v !== undefined && v !== null && v !== false) n.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat(3)) if (c != null && c !== false) n.append(c);
  return n;
}

async function api(path, opts = {}) {
  const res = await fetch('/admin/api' + path, {
    method: opts.method || 'GET',
    headers: {
      Authorization: 'Bearer ' + token(),
      'X-Moderator': encodeURIComponent(modName()),
      ...(opts.body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  if (res.status === 401) { logout('Ключ не подошёл'); throw new Error('unauthorized'); }
  if (res.status === 204) return null;
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || 'Ошибка ' + res.status);
  return data;
}

const fmt = new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
const fmtDate = (s) => (s ? fmt.format(new Date(s)) : '');
function ago(s) {
  const min = Math.round((Date.now() - new Date(s)) / 60000);
  if (min < 1) return 'только что';
  if (min < 60) return min + ' мин назад';
  const h = Math.round(min / 60);
  if (h < 24) return h + ' ч назад';
  return fmtDate(s);
}

let status = 'open';
let current = null;

function statusTags(p) {
  const out = [];
  if (p.banned_at) out.push(el('span', { class: 'tag urgent', text: 'Заблокирован навсегда' }));
  else if (p.suspended_until && new Date(p.suspended_until) > new Date()) out.push(el('span', { class: 'tag urgent', text: 'Заблокирован до ' + fmtDate(p.suspended_until) }));
  if (p.on_hold) out.push(el('span', { class: 'tag hold', text: 'Скрыт до проверки' }));
  return out;
}

async function loadStats() {
  const s = await api('/stats');
  const box = $('stats');
  box.replaceChildren(
    el('span', { class: 'stat' + (s.urgent ? ' hot' : '') }, 'Срочных: ', el('b', { text: String(s.urgent) })),
    el('span', { class: 'stat' }, 'Открытых: ', el('b', { text: String(s.open) })),
    el('span', { class: 'stat' }, 'Скрыто до проверки: ', el('b', { text: String(s.on_hold) })),
    el('span', { class: 'stat' }, 'Заблокировано: ', el('b', { text: String(s.banned + s.suspended) })),
  );
}

async function loadList() {
  const { items } = await api('/reports?status=' + status);
  const list = $('list');
  list.replaceChildren(...items.map((r) => {
    const li = el('li', {
      class: 'item', tabindex: '0', role: 'button', 'aria-current': current === r.id ? 'true' : 'false',
      onclick: () => open(r.id),
      onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(r.id); } },
    },
    el('div', { class: 'row' },
      el('span', { class: 'name', text: `${r.target.name}, ${r.target.age}` }),
      el('span', { class: 'time', text: ago(r.created_at) })),
    el('div', {},
      el('span', { class: 'tag' + (r.urgent ? ' urgent' : ''), text: REASONS[r.reason] || r.reason }),
      r.target_reporters > 1 ? el('span', { class: 'tag urgent', text: `жалуются ${r.target_reporters} чел.` }) : null,
      r.resolution ? el('span', { class: 'tag ok', text: RESOLUTIONS[r.resolution] || r.resolution }) : null,
      ...statusTags(r.target)));
    return li;
  }));
  $('empty').hidden = items.length > 0;
}

async function refresh() {
  try { await Promise.all([loadStats(), loadList()]); } catch (e) { if (e.message !== 'unauthorized') console.error(e); }
}

async function open(id) {
  current = id;
  document.querySelectorAll('.item').forEach((n) => n.setAttribute('aria-current', 'false'));
  const box = $('detail');
  box.replaceChildren(el('p', { class: 'muted center', text: 'Загрузка…' }));
  let d;
  try { d = await api('/reports/' + id); } catch (e) { box.replaceChildren(el('p', { class: 'error', text: e.message })); return; }
  const t = d.target;
  const closed = d.status === 'resolved' || d.status === 'rejected';
  const blocked = t.banned_at || (t.suspended_until && new Date(t.suspended_until) > new Date());

  const msgs = d.messages.length
    ? el('div', { class: 'chat' }, d.messages.map((m) => el('div', { class: 'msg ' + m.sender },
        m.body, el('small', { text: (m.sender === 'target' ? t.name : d.reporter.name) + ' · ' + fmtDate(m.created_at) }))))
    : el('p', { class: 'muted', text: 'Переписки нет: жалоба из ленты или «Рядом».' });

  const note = el('textarea', { id: 'note', maxlength: '1000', placeholder: 'Текст предупреждения или причина блокировки (необязательно)' });
  const days = el('select', { id: 'days', 'aria-label': 'Срок блокировки' },
    [1, 3, 7, 30, 90].map((n) => el('option', { value: String(n), text: n + ' ' + (n === 1 ? 'день' : n < 5 ? 'дня' : 'дней') })));
  days.value = '7';
  const err = el('p', { class: 'error', role: 'alert' });

  async function act(action) {
    if (action === 'ban' && !window.confirm(`Заблокировать ${t.name} навсегда? Номер больше нельзя будет зарегистрировать.`)) return;
    box.querySelectorAll('button').forEach((b) => { b.disabled = true; });
    try {
      await api(`/reports/${id}/resolve`, { method: 'POST', body: { action, days: Number(days.value), note: note.value } });
      await refresh();
      await open(id);
    } catch (e) {
      err.textContent = e.message;
      box.querySelectorAll('button').forEach((b) => { b.disabled = false; });
    }
  }
  async function unban() {
    try {
      await api(`/users/${t.id}/unban`, { method: 'POST', body: { note: note.value } });
      await refresh();
      await open(id);
    } catch (e) { err.textContent = e.message; }
  }

  const parts = [
    el('h2', { text: `${t.name}, ${t.age}` }),
    el('p', { class: 'muted', text: `${t.city || 'город не указан'} · в приложении с ${fmtDate(t.registered_at)}` }),
    el('div', {}, statusTags(t)),
    el('h3', { text: 'Жалоба' }),
    el('p', {},
      el('span', { class: 'tag' + (d.urgent ? ' urgent' : ''), text: REASONS[d.reason] || d.reason }),
      ' от ', el('b', { text: d.reporter.name }), ' · ', fmtDate(d.created_at)),
    d.comment ? el('div', { class: 'comment', text: d.comment }) : el('p', { class: 'muted', text: 'Без комментария' }),
    el('h3', { text: 'Анкета' }),
    el('div', { class: 'profile' },
      el('p', { text: t.about || 'О себе не заполнено' }),
      (t.prompts || []).map((p) => el('div', { class: 'prompt' }, el('div', { class: 'q', text: p.question }), el('div', { text: p.answer })))),
    el('h3', { text: 'Переписка с тем, кто пожаловался' }),
    msgs,
    d.other_reports.length ? [
      el('h3', { text: `Другие жалобы на этого человека (${d.other_reports.length})` }),
      el('ul', { class: 'history' }, d.other_reports.map((o) => el('li', {},
        `${fmtDate(o.created_at)} — ${REASONS[o.reason] || o.reason}`,
        o.comment ? ` — «${o.comment}»` : '',
        o.resolution ? ` (${RESOLUTIONS[o.resolution] || o.resolution})` : ''))),
    ] : null,
    d.history.length ? [
      el('h3', { text: 'Прошлые решения' }),
      el('ul', { class: 'history' }, d.history.map((a) => el('li', {},
        `${fmtDate(a.created_at)} — ${ACTIONS[a.action] || a.action}`,
        a.until ? ` до ${fmtDate(a.until)}` : '', ` (${a.moderator})`, a.note ? ` — ${a.note}` : ''))),
    ] : null,
    el('h3', { text: 'Решение' }),
    closed
      ? el('p', { class: 'resolved', text: `${RESOLUTIONS[d.resolution] || d.status} · ${d.moderator || ''} · ${fmtDate(d.resolved_at)}` })
      : [
          el('label', { for: 'note', text: 'Комментарий' }), note,
          el('div', { class: 'actions' },
            el('button', { type: 'button', onclick: () => act('dismiss'), text: 'Отклонить жалобу' }),
            el('button', { type: 'button', onclick: () => act('warn'), text: 'Предупредить' }),
            days,
            el('button', { type: 'button', class: 'danger', onclick: () => act('suspend'), text: 'Заблокировать на срок' }),
            el('button', { type: 'button', class: 'danger', onclick: () => act('ban'), text: 'Навсегда' })),
        ],
    blocked ? el('div', { class: 'actions' }, el('button', { type: 'button', onclick: unban, text: 'Разблокировать' })) : null,
    err,
  ];
  box.replaceChildren(...parts.flat(3).filter((x) => x != null && x !== false));
  loadList().catch(() => {});
}

function logout(message) {
  store.clear(); memToken = ''; memName = '';
  $('app').hidden = true;
  $('login').hidden = false;
  $('login-error').textContent = message || '';
}

function start() {
  $('login').hidden = true;
  $('app').hidden = false;
  $('who').textContent = modName();
  refresh();
}

document.addEventListener('DOMContentLoaded', () => {
  $('login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    memToken = $('login-token').value.trim();
    memName = $('login-name').value.trim();
    store.save(memToken, memName);
    try { await api('/stats'); start(); } catch (err) { if (err.message !== 'unauthorized') $('login-error').textContent = err.message; }
  });
  $('logout').addEventListener('click', () => logout());
  $('refresh').addEventListener('click', refresh);
  document.querySelectorAll('[role="tab"]').forEach((b) => b.addEventListener('click', () => {
    status = b.dataset.status;
    document.querySelectorAll('[role="tab"]').forEach((x) => x.setAttribute('aria-selected', String(x === b)));
    refresh();
  }));
  if (token()) start(); else logout();
  setInterval(() => { if (!$('app').hidden) loadStats().catch(() => {}); }, 60000);
});
