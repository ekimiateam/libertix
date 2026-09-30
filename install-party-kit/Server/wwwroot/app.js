const element = id => document.getElementById(id);
const refreshIntervalMilliseconds = 1000;
const bytesPerMebibyte = 1024 * 1024;
let settingsLoaded = false;

async function request(path, body) {
  const response = await fetch(path, body === undefined ? {} : {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Libertix-Request": "1" },
    body: JSON.stringify(body)
  });
  if (!response.ok) throw new Error(await response.text());
  return response.json();
}

async function refresh() {
  try {
    const state = await request("/api/status");
    renderServer(state);
    renderPool(state.pool);
    renderClients(state.pool.transfers);
    initializeSettings(state.pendingSettings);
  } catch (error) {
    element("error").textContent = `Server unavailable: ${error.message}`;
  } finally {
    setTimeout(refresh, refreshIntervalMilliseconds);
  }
}

function renderServer(state) {
    element("addresses").textContent = state.addresses.join("\n");
    element("channel").textContent = `Active branch: ${state.settings.channel}`;
    element("discovery").textContent = `Discovery: UDP ${state.discoveryPort} (fixed)`;
}

function renderPool(pool) {
    element("phase").textContent = `${pool.phase} — ${pool.files} available files`;
    element("file").textContent = pool.fileName;
    element("progress").value = pool.total ? pool.received / pool.total : 0;
    element("amount").textContent = pool.total
      ? `${(pool.received / bytesPerMebibyte).toFixed(1)} / ${(pool.total / bytesPerMebibyte).toFixed(1)} MiB` : "";
    element("error").textContent = pool.lastError || "";
    element("update").disabled = pool.updating;
}

function renderClients(transfers) {
    const rows = transfers.map(client => {
      const row = document.createElement("tr");
      for (const text of [client.client, client.file, new Date(client.started).toLocaleTimeString()]) {
        const cell = document.createElement("td");
        cell.textContent = text;
        row.append(cell);
      }
      return row;
    });
    element("clients").replaceChildren(...rows);
}

function initializeSettings(settings) {
    if (settingsLoaded) return;
    element("branch").value = settings.channel;
    element("port").value = settings.httpPort;
    element("storage").value = settings.storageDirectory;
    settingsLoaded = true;
}

element("update").addEventListener("click", async () => {
  try { await request("/api/update", {}); }
  catch (error) { element("error").textContent = error.message; }
});
element("settings").addEventListener("submit", async event => {
  event.preventDefault();
  try {
    const result = await request("/api/settings", {
      channel: element("branch").value,
      httpPort: Number(element("port").value),
      storageDirectory: element("storage").value
    });
    element("settings-result").textContent = result.message;
  } catch (error) { element("settings-result").textContent = error.message; }
});
refresh();
