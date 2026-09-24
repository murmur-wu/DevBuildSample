// 待辦清單前端：透過同網域的 /api/<backend>/ 呼叫後端（Worker 代轉），可切換 Node / .NET / PHP。
const STORAGE_KEY = 'devbuildsample.backend';
const BACKENDS = ['node', 'dotnet', 'php'];

const $ = (id) => document.getElementById(id);
const els = {
  status: $('status'),
  error: $('error'),
  items: $('items'),
  empty: $('empty'),
  form: $('add-form'),
  input: $('new-name'),
  apiPath: $('api-path'),
  template: $('item-template'),
  toggles: document.querySelectorAll('[data-backend]'),
};

let backend = loadBackend();

function loadBackend() {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (BACKENDS.includes(saved)) return saved;
  } catch {
    // 無痕模式等情況讀不到 localStorage，用預設值即可
  }
  return 'node';
}

function saveBackend(value) {
  try {
    localStorage.setItem(STORAGE_KEY, value);
  } catch {
    // 存不了就算了，只影響下次開啟時的預設值
  }
}

async function api(path, options = {}) {
  const init = { ...options, headers: { ...options.headers } };
  if (init.body !== undefined) {
    init.headers['content-type'] = 'application/json';
    init.body = JSON.stringify(init.body);
  }
  const res = await fetch(`/api/${backend}${path}`, init);
  if (res.status === 204) return null;
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(data?.error ?? `HTTP ${res.status}`);
  return data;
}

function showError(message) {
  els.error.textContent = message;
  els.error.hidden = !message;
}

function formatTime(iso) {
  return new Date(iso).toLocaleString('zh-TW', { dateStyle: 'short', timeStyle: 'short' });
}

function render(items) {
  els.items.replaceChildren(
    ...items.map((item) => {
      const node = els.template.content.firstElementChild.cloneNode(true);
      const checkbox = node.querySelector('input');
      checkbox.checked = item.done;
      checkbox.addEventListener('change', () => toggleDone(item, checkbox));
      node.querySelector('.name').textContent = item.name;
      node.classList.toggle('done', item.done);
      const time = node.querySelector('.created');
      time.dateTime = item.created_at;
      time.textContent = formatTime(item.created_at);
      node.querySelector('.delete').addEventListener('click', () => remove(item));
      return node;
    }),
  );
  els.empty.hidden = items.length > 0;
}

// 切換後端時先清空畫面、顯示載入中，避免新後端的資料回來前還看到舊後端的內容
function showLoading() {
  els.status.textContent = '連線中…';
  els.status.dataset.state = 'loading';
  els.items.replaceChildren();
  els.empty.hidden = true;
}

async function refresh() {
  showError('');
  els.apiPath.textContent = `/api/${backend}`;
  els.toggles.forEach((btn) => btn.setAttribute('aria-checked', String(btn.dataset.backend === backend)));

  const current = backend;
  try {
    const [health, items] = await Promise.all([api('/health'), api('/items')]);
    if (current !== backend) return; // 等待期間已切換後端，丟棄舊結果
    els.status.textContent = `已連線 · 版本 ${String(health.version).slice(0, 7)} · 資料庫 ${health.db}`;
    els.status.dataset.state = 'ok';
    render(items);
  } catch (err) {
    if (current !== backend) return;
    els.status.textContent = '無法連線到後端';
    els.status.dataset.state = 'error';
    render([]);
    els.empty.hidden = true;
    showError(err.message);
  }
}

async function toggleDone(item, checkbox) {
  checkbox.disabled = true;
  try {
    await api(`/items/${item.id}`, { method: 'PUT', body: { name: item.name, done: checkbox.checked } });
    await refresh();
  } catch (err) {
    checkbox.checked = !checkbox.checked;
    checkbox.disabled = false;
    showError(err.message);
  }
}

async function remove(item) {
  try {
    await api(`/items/${item.id}`, { method: 'DELETE' });
    await refresh();
  } catch (err) {
    showError(err.message);
  }
}

els.form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const name = els.input.value.trim();
  if (!name) return;
  const button = els.form.querySelector('button');
  button.disabled = true;
  try {
    await api('/items', { method: 'POST', body: { name } });
    els.input.value = '';
    await refresh();
  } catch (err) {
    showError(err.message);
  } finally {
    button.disabled = false;
    els.input.focus();
  }
});

els.toggles.forEach((btn) =>
  btn.addEventListener('click', () => {
    if (btn.dataset.backend === backend) return;
    backend = btn.dataset.backend;
    saveBackend(backend);
    showLoading();
    refresh();
  }),
);

showLoading();
refresh();
