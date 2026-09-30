const refreshablePaths = new Set(["/run", "/call"]);
// має збігатися з видами подій у src/bdo_translate/pipeline; перевірка · команда з P09 2.5 Verify.
const refreshEvents = ["transition", "call", "judge_degenerate", "session_started", "step_started", "step_finished", "failure", "session_finished"];
const minRefreshInterval = 1000;
let lastRefresh = 0;
let refreshTimer = 0;
let refreshInFlight = false;
let refreshPending = false;
let refreshPendingImmediate = false;
let lastMissingTargetRefresh = 0;
let eventStreamOpen = false;
// Стан фільтра вердиктів і пошуку живе тут, бо перемальовка знімка раз на
// секунду його скидала б; після морфу застосовується повторно.
let verdictFilter = "all";
let verdictSearch = "";

function setLiveStatus(open) {
  const liveLabel = document.getElementById("nav-live");
  const liveDot = document.getElementById("nav-live-dot");
  if (liveLabel) liveLabel.textContent = open ? "оновлюється наживо" : "оновлюється при відкритті";
  if (liveDot) liveDot.className = open ? "dot live" : "dot poll";
}

function updateClocks() {
  const now = Date.now();
  for (const element of document.querySelectorAll("[data-since]")) {
    const started = Date.parse(element.dataset.since || "");
    if (!Number.isFinite(started)) continue;
    const seconds = Math.max(0, Math.floor((now - started) / 1000));
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const remainder = seconds % 60;
    const pad = value => String(value).padStart(2, "0");
    element.textContent = hours > 0
      ? `${hours}:${pad(minutes)}:${pad(remainder)}`
      : `${pad(Math.floor(seconds / 60))}:${pad(remainder)}`;
  }
}

function initializeStartForm() {
  const form = document.getElementById("start-form");
  if (!form) return;
  const dry = document.getElementById("start-dry");
  const dryButton = document.getElementById("btn-run_start_dry");
  const writeButton = document.getElementById("btn-run_start");
  const modeInput = document.getElementById("start-mode");
  const rows = document.getElementById("start-rows");
  const rowsSlider = document.getElementById("start-rows-slider");
  const batches = document.getElementById("start-batches");
  const translateAll = document.getElementById("start-all");
  const summary = document.getElementById("start-summary");
  const preview = document.getElementById("start-preview");
  const patchInput = document.getElementById("start-patch");
  const modelSelect = document.getElementById("start-model");
  const modelForm = document.getElementById("model-choice-form");
  if (!dry || !dryButton || !writeButton || !modeInput || !rows || !rowsSlider ||
      !batches || !translateAll || !summary || !preview || !patchInput) return;
  const category = document.getElementById("start-category");
  const missingHead = document.getElementById("start-missing-head");
  const queueNote = document.getElementById("start-queue-note");
  const scope = document.getElementById("start-scope");
  const corpus = document.getElementById("start-corpus");
  const corpusRows = document.getElementById("start-corpus-rows");
  const authorChoice = document.getElementById("start-author-choice");
  const authorRadios = Array.from(form.querySelectorAll('input[name="machine_author"]'));
  const versionChoice = document.getElementById("start-author-version");
  const versionInput = document.getElementById("start-client-version");
  const countsEnabled = category instanceof HTMLSelectElement;
  let patchCountsRequest = 0;
  let categoryCountsRequest = 0;
  let corpusCountsRequest = 0;
  let corpusSelected = null;
  let corpusSelectedLabel = "";

  function selectedPatch() {
    return document.querySelector(".start-patch-row.is-selected");
  }

  function corpusModeSelected() {
    return document.querySelector(".start-mode-card.is-selected")?.dataset.scope === "corpus";
  }

  function patchMissing(row) {
    const cell = row && row.cells.length > 4 ? row.cells[4] : null;
    const valueNode = cell?.querySelector(".start-missing-value");
    const source = valueNode ? valueNode.textContent : cell ? cell.textContent : "";
    const text = source.trim().replaceAll(" ", "");
    if (!text || text === "—") return null;
    const value = Number(text);
    return Number.isFinite(value) ? value : null;
  }

  function setCellMissing(cell, text) {
    const valueNode = cell.querySelector(".start-missing-value");
    if (valueNode) valueNode.textContent = text;
    else cell.textContent = text;
  }

  function setCellWaitingHidden(cell, hidden) {
    const waitingNode = cell.querySelector(".start-missing-waiting");
    if (waitingNode) waitingNode.hidden = hidden;
  }

  function patchBaseMissing(row) {
    const raw = row && row.cells.length > 4 ? row.cells[4].dataset.base || "" : "";
    if (raw === "") return null;
    const value = Number(raw);
    return Number.isFinite(value) ? value : null;
  }

  function formatMissing(value) {
    return value === null
      ? "—"
      : value.toLocaleString("uk-UA").replaceAll("\u00A0", " ");
  }

  function categoryCaption() {
    if (!countsEnabled) return "";
    const option = category.selectedOptions[0];
    if (!option || !option.value) return "";
    const group = option.dataset.group || "";
    const label = option.dataset.label || option.textContent;
    return `${group} ${label}`.trim();
  }

  function sortCategoryOptions(counts) {
    for (const group of category.querySelectorAll("optgroup")) {
      const options = Array.from(group.querySelectorAll("option"));
      options.sort((a, b) => {
        const left = Number.isFinite(counts[a.value]) ? counts[a.value] : -1;
        const right = Number.isFinite(counts[b.value]) ? counts[b.value] : -1;
        return right - left;
      });
      group.append(...options);
    }
  }

  async function loadPatchCounts() {
    if (!countsEnabled) return;
    const row = selectedPatch();
    const snapshot = row?.dataset.snapshot || "";
    if (!snapshot) return;
    const requestId = ++patchCountsRequest;
    const options = Array.from(category.options).filter(option => option.value);
    const allOption = Array.from(category.options).find(option => !option.value);
    for (const option of options) {
      option.textContent = `${option.dataset.label || option.value} · …`;
    }
    if (allOption) {
      allOption.textContent = `${allOption.dataset.label || "усі"} · ${formatMissing(patchBaseMissing(row))}`;
    }
    let counts = null;
    try {
      const response = await fetch("/start/counts.json?patch=" + encodeURIComponent(snapshot));
      if (response.ok) counts = await response.json();
    } catch {
      counts = null;
    }
    if (requestId !== patchCountsRequest) return;
    if (!counts) counts = {};
    // У корпусному режимі категорію обирають у таблиці корпусу, тож лічильники
    // вибраного патча не мають права вимикати опції селектора.
    const corpus = corpusModeSelected();
    for (const option of options) {
      const label = option.dataset.label || option.value;
      const value = Number.isFinite(counts[option.value]) ? counts[option.value] : null;
      option.textContent = value === null ? `${label} · —` : `${label} · ${formatMissing(value)}`;
      option.disabled = !corpus && value === 0 && !option.selected;
    }
    sortCategoryOptions(counts);
    update();
  }

  async function loadCategoryCounts() {
    if (!countsEnabled) return;
    const value = category.value;
    const requestId = ++categoryCountsRequest;
    const cells = Array.from(document.querySelectorAll("td.start-missing"));
    if (!value) {
      for (const cell of cells) {
        const base = patchBaseMissing(cell.closest("tr"));
        setCellMissing(cell, formatMissing(base));
        setCellWaitingHidden(cell, false);
        cell.classList.toggle("start-missing-positive", base !== null && base > 0);
      }
      if (missingHead) missingHead.textContent = "БЕЗ ШІ-ШАРУ";
      update();
      return;
    }
    const option = category.selectedOptions[0];
    const label = option?.dataset.label || option?.textContent || value;
    const group = option?.dataset.group || "";
    if (missingHead) missingHead.textContent = `БЕЗ ШІ-ШАРУ · ${group} ${label}`;
    for (const cell of cells) {
      setCellMissing(cell, "…");
      setCellWaitingHidden(cell, true);
    }
    update();
    let counts = null;
    try {
      const response = await fetch("/start/counts.json?category=" + encodeURIComponent(value));
      if (response.ok) counts = await response.json();
    } catch {
      counts = null;
    }
    if (requestId !== categoryCountsRequest) return;
    if (!counts) counts = {};
    for (const cell of cells) {
      const snapshot = cell.closest("tr")?.dataset.snapshot || "";
      const count = Number.isFinite(counts[snapshot]) ? counts[snapshot] : null;
      setCellMissing(cell, formatMissing(count));
      setCellWaitingHidden(cell, true);
      cell.classList.toggle("start-missing-positive", count !== null && count > 0);
    }
    update();
  }

  function currentAuthor() {
    const checked = authorRadios.find(input => input.checked);
    return checked ? checked.value : "";
  }

  function currentVersion() {
    return versionChoice && versionChoice.checked && versionInput ? versionInput.value.trim() : "";
  }

  function setCorpusStatus(text) {
    if (!corpusRows) return;
    corpusRows.replaceChildren();
    const row = document.createElement("tr");
    row.id = "start-corpus-status";
    const cell = document.createElement("td");
    cell.colSpan = 2;
    cell.textContent = text;
    row.append(cell);
    corpusRows.append(row);
  }

  function corpusRow(value, label, count) {
    const row = document.createElement("tr");
    row.className = "start-corpus-row";
    row.dataset.category = value;
    row.dataset.count = String(count);
    const name = document.createElement("td");
    name.textContent = label;
    const amount = document.createElement("td");
    amount.textContent = formatMissing(count);
    row.append(name, amount);
    return row;
  }

  function corpusGroup(label) {
    const row = document.createElement("tr");
    row.className = "start-corpus-group";
    const cell = document.createElement("td");
    cell.colSpan = 2;
    cell.textContent = label;
    row.append(cell);
    return row;
  }

  function setCategoryValue(value) {
    if (!(category instanceof HTMLSelectElement)) return;
    const option = Array.from(category.options).find(item => item.value === value);
    if (option) option.disabled = false;
    category.value = value;
  }

  function selectCorpusRow(value) {
    if (!corpusRows) return;
    setCategoryValue(value);
    let selected = null;
    for (const row of corpusRows.querySelectorAll("tr.start-corpus-row")) {
      const hit = row.dataset.category === value;
      row.classList.toggle("is-selected", hit);
      if (hit) selected = row;
    }
    if (!selected) {
      selected = corpusRows.querySelector('tr.start-corpus-row[data-category=""]');
      if (selected) selected.classList.add("is-selected");
    }
    const raw = selected?.dataset.count || "";
    corpusSelected = raw === "" ? null : Number(raw);
    corpusSelectedLabel = selected ? selected.cells[0].textContent : "";
  }

  function renderCorpus(payload) {
    if (!corpusRows) return;
    const counts = payload && typeof payload.counts === "object" && payload.counts ? payload.counts : {};
    const totalRaw = Number(payload?.total);
    const total = Number.isFinite(totalRaw) ? totalRaw : 0;
    const domains = [];
    const types = [];
    for (const [key, raw] of Object.entries(counts)) {
      const count = Number(raw);
      if (!Number.isFinite(count) || count === 0) continue;
      if (key.startsWith("domain:")) domains.push([key.slice("domain:".length), count]);
      else if (key.startsWith("semantic_type:")) types.push([key.slice("semantic_type:".length), count]);
    }
    domains.sort((left, right) => right[1] - left[1]);
    types.sort((left, right) => right[1] - left[1]);
    corpusRows.replaceChildren();
    corpusRows.append(corpusRow("", "усі", total));
    if (domains.length) {
      corpusRows.append(corpusGroup("домен"));
      for (const [name, count] of domains) {
        corpusRows.append(corpusRow(`domain:${name}`, `домен · ${name}`, count));
      }
    }
    if (types.length) {
      corpusRows.append(corpusGroup("тип"));
      for (const [name, count] of types) {
        corpusRows.append(corpusRow(`semantic_type:${name}`, `тип · ${name}`, count));
      }
    }
    selectCorpusRow(category instanceof HTMLSelectElement ? category.value : "");
  }

  async function loadCorpusCounts() {
    if (!corpusRows) return;
    const mode = modeInput.value;
    const author = currentAuthor();
    const requestId = ++corpusCountsRequest;
    corpusSelected = null;
    corpusSelectedLabel = "";
    setCorpusStatus("беру категорії корпусу з API · перший раз близько 10 с, далі з кешу");
    update();
    const params = new URLSearchParams({ mode });
    if (author) params.set("machine_author", author);
    const version = currentVersion();
    if (version) params.set("machine_client_version_lt", version);
    let payload = null;
    try {
      const response = await fetch("/start/corpus.json?" + params.toString());
      payload = await response.json();
    } catch {
      payload = null;
    }
    if (requestId !== corpusCountsRequest) return;
    if (!payload || payload.error) {
      corpusSelected = null;
      corpusSelectedLabel = "";
      setCorpusStatus(payload?.error?.message || "не вдалося порахувати категорії корпусу");
      update();
      return;
    }
    renderCorpus(payload);
    update();
  }

  function update() {
    const row = selectedPatch();
    const missing = patchMissing(row);
    const rowCount = Number(rows.value) || Number(rows.min);
    rowsSlider.value = String(rowCount);
    const mode = modeInput.value;
    const modeInputChoice = Array.from(
      document.querySelectorAll(".start-mode-card input[name=\"mode-choice\"]"),
    ).find(input => input.value === mode);
    const modeCard = modeInputChoice?.closest(".start-mode-card");
    const queueMode = modeCard?.dataset.source === "proposals";
    const patchMode = mode === "patch";
    const corpusMode = modeCard?.dataset.scope === "corpus";
    const authorChoiceMode = corpusMode && modeCard?.dataset.authorChoice === "true";
    const queueTotalRaw = queueNote?.dataset.queueTotal || "";
    const queueCap = queueTotalRaw === "" ? null : Number(queueTotalRaw);
    if (authorChoice) authorChoice.hidden = !authorChoiceMode;
    for (const input of authorRadios) input.disabled = !authorChoiceMode;
    if (versionInput) {
      versionInput.disabled = !authorChoiceMode || !(versionChoice && versionChoice.checked);
    }
    const versionNote = corpusMode && currentVersion()
      ? ` · перекладені програмою до версії ${currentVersion()}`
      : "";
    if (!patchMode && !corpusMode && scope) {
      // Категорія й патч діють лише в режимі «патч»: інші режими беруть активний патч без категорії.
      if (category instanceof HTMLSelectElement && category.value !== "") {
        category.value = "";
        category.dispatchEvent(new Event("change"));
        return;
      }
      const activeRow = document.querySelector('.start-patch-row[data-active="true"]');
      if (patchInput.value !== "active" && activeRow instanceof HTMLElement) {
        activeRow.click();
        return;
      }
    }
    if (!patchMode && !corpusMode && !queueMode && translateAll.checked) {
      translateAll.checked = false;
      translateAll.dispatchEvent(new Event("change"));
      return;
    }
    if (translateAll.checked) {
      const total = queueMode ? queueCap : corpusMode ? corpusSelected : missing;
      if (total !== null && Number.isFinite(total)) {
        batches.value = String(Math.max(1, Math.ceil(total / rowCount)));
      }
    }
    batches.disabled = translateAll.checked;
    translateAll.disabled = queueMode
      ? queueCap === null
      : corpusMode
        ? corpusSelected === null
        : !patchMode || missing === null;
    const modeName = modeCard?.querySelector("strong")?.textContent || mode;
    const patchNumber = row?.cells[1]?.textContent.trim() || "—";
    const count = Number(batches.value) || 1;
    const summaryPatch = row?.dataset.active === "true"
      ? `в активному патчі ${patchNumber}`
      : `у патчі ${patchNumber}`;
    const categoryName = categoryCaption();
    const missingCell = row && row.cells.length > 4 ? row.cells[4] : null;
    const missingValueNode = missingCell?.querySelector(".start-missing-value");
    const cellText = (missingValueNode ? missingValueNode.textContent : missingCell ? missingCell.textContent : "").trim();
    if (queueNote) {
      queueNote.hidden = patchMode || corpusMode;
      const total = queueCap === null ? "" : formatMissing(queueCap);
      queueNote.textContent = queueMode
        ? `режим бере чергу до людини від найстаріших${total ? ` · чекають ${total}` : ""}`
        : "режим бере рядки активного патча; категорію й патч обирають лише в режимі «патч»";
    }
    if (scope) scope.hidden = !patchMode;
    if (corpus) corpus.hidden = !corpusMode;
    if (queueMode) {
      summary.textContent = queueCap === null
        ? "черга до людини недоступна; кількість не повернута API."
        : `у черзі до людини чекають ${formatMissing(queueCap)} · це приблизно ${Math.ceil(queueCap / rowCount)} пачок по ${rowCount}`;
    } else if (corpusMode) {
      summary.textContent = corpusSelected === null
        ? "рахую категорії корпусу…"
        : `весь корпус · ${corpusSelectedLabel || "усі"}${versionNote} · ${formatMissing(corpusSelected)} рядків · це приблизно ${Math.ceil(corpusSelected / rowCount)} пачок по ${rowCount} · числа щойно з API`;
    } else if (!patchMode) {
      summary.textContent = `активний патч ${patchNumber} · скільки рядків візьме режим «${modeName}», API не рахує; кількість пачок задай вручну.`;
    } else if (cellText === "…") {
      summary.textContent = "рахую рядки без ШІ-шару для категорії…";
    } else if (missing === null) {
      summary.textContent = "Доступна інформація з вибраного патча; кількість без ШІ-шару не повернута API.";
    } else {
      const categorySuffix = categoryName ? ` · ${categoryName}` : "";
      summary.textContent = `${summaryPatch}${categorySuffix} лишилось ${missing.toLocaleString('uk-UA').replaceAll('\xa0', ' ')} рядків без ШІ-шару · це приблизно ${Math.ceil(missing / rowCount)} пачок по ${rowCount} · числа щойно з API`;
    }
    const target = modeCard?.querySelector(".start-mode-target")?.textContent.replace("→ ", "")
      || "серверний канал";
    const last = `«почати прогін» — ${target}; «тестовий прогін» нічого не записує.`;
    preview.replaceChildren();
    const lines = [
      queueMode
        ? `Виберу пачку з черги до людини · ${rowCount} рядків · режим «${modeName}».`
        : corpusMode
          ? `Виберу пачку з усього корпусу · ${corpusSelectedLabel || "усі"}${versionNote} · ${rowCount} рядків · режим «${modeName}».`
          : `Виберу пачку з ${!patchMode || row?.dataset.active === "true" ? "активного " : ""}патча ${patchNumber} · ${rowCount} рядків · режим «${modeName}».`,
      `Проганяю ${count} ${count === 1 ? "пачку" : "пачок"} через увесь конвеєр: терміни → переклад → перевірка якості → ремонт дефектів → суддя → ${target}.`,
      last,
    ];
    for (const text of lines) {
      const item = document.createElement("li");
      item.textContent = text;
      preview.append(item);
    }
  }

  document.querySelectorAll('.start-mode-card input[name="mode-choice"]').forEach(input => {
    input.addEventListener("change", () => {
      modeInput.value = input.value;
      document.querySelectorAll(".start-mode-card").forEach(card => {
        card.classList.toggle("is-selected", card.contains(input));
      });
      update();
      if (input.closest(".start-mode-card")?.dataset.scope === "corpus") loadCorpusCounts();
      else loadPatchCounts();
    });
  });
  document.querySelectorAll(".start-patch-row").forEach(row => {
    row.addEventListener("click", () => {
      document.querySelectorAll(".start-patch-row").forEach(item => {
        item.classList.toggle("is-selected", item === row);
        item.setAttribute("aria-selected", item === row ? "true" : "false");
      });
      patchInput.value = row.dataset.patch || "active";
      update();
      loadPatchCounts();
    });
  });
  if (corpusRows) {
    corpusRows.addEventListener("click", event => {
      const target = event.target.closest("tr.start-corpus-row");
      if (!target) return;
      selectCorpusRow(target.dataset.category || "");
      update();
    });
  }
  for (const input of authorRadios) {
    input.addEventListener("change", () => {
      if (!input.checked) return;
      update();
      if (document.querySelector('.start-mode-card.is-selected')?.dataset.scope === "corpus") {
        loadCorpusCounts();
      }
    });
  }
  if (versionInput) {
    versionInput.addEventListener("change", () => {
      if (versionInput.disabled) return;
      update();
      if (document.querySelector('.start-mode-card.is-selected')?.dataset.scope === "corpus") {
        loadCorpusCounts();
      }
    });
  }
  rows.addEventListener("input", update);
  rowsSlider.addEventListener("input", () => {
    rows.value = rowsSlider.value;
    update();
  });
  let manualBatchCount = batches.value;
  batches.addEventListener("input", () => {
    if (!translateAll.checked) manualBatchCount = batches.value;
    update();
  });
  translateAll.addEventListener("change", () => {
    if (translateAll.checked) manualBatchCount = batches.value;
    else batches.value = manualBatchCount;
    update();
  });
  if (countsEnabled) {
    category.addEventListener("change", () => {
      loadCategoryCounts();
    });
    loadPatchCounts();
    if (category.value) loadCategoryCounts();
  }
  if (modelSelect && modelForm) {
    modelSelect.addEventListener("change", () => {
      const [provider, model] = modelSelect.value.split("::", 2);
      document.getElementById("start-model-provider").value = provider || "";
      document.getElementById("start-model-value").value = model || "";
      modelForm.requestSubmit();
    });
  }
  form.addEventListener("submit", event => {
    dry.value = event.submitter === dryButton ? "true" : "false";
    update();
    batches.disabled = false;
    writeButton.disabled = true;
    dryButton.disabled = true;
    if (event.submitter) event.submitter.textContent = "запускаю…";
  });
  update();
  if (document.querySelector('.start-mode-card.is-selected')?.dataset.scope === "corpus") {
    loadCorpusCounts();
  }
}

function initializeReview() {
  const list = document.getElementById("review-list");
  const loading = document.getElementById("review-loading");
  const search = document.getElementById("review-search");
  const limit = document.getElementById("review-limit");
  const refresh = document.getElementById("review-refresh");
  const checkboxes = list ? Array.from(list.querySelectorAll("[data-review-select]")) : [];
  const bulkForms = Array.from(document.querySelectorAll(".review-bulk-form"));
  const textareas = list ? Array.from(list.querySelectorAll("textarea.grow")) : [];

  function resizeTextarea(textarea) {
    textarea.style.height = "auto";
    textarea.style.height = `${textarea.scrollHeight + 1}px`;
  }
  for (const textarea of textareas) {
    const card = textarea.closest(".review-item");
    const updateMarkupState = () => {
      const text = textarea.value;
      for (const token of card?.querySelectorAll("[data-review-token]") || []) {
        const present = text.includes(token.dataset.reviewToken || "");
        token.classList.toggle("is-present", present);
        token.classList.toggle("is-missing", !present);
        token.querySelector(".review-token-state").textContent = present ? "є" : "бракує";
        token.setAttribute("aria-label", `${token.dataset.reviewToken} · ${present ? "є у перекладі" : "бракує в перекладі"}`);
      }
    };
    textarea.addEventListener("input", () => {
      resizeTextarea(textarea);
      updateMarkupState();
    });
    resizeTextarea(textarea);
    updateMarkupState();
  }
  for (const button of list?.querySelectorAll("[data-copy-hash]") || []) {
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(button.dataset.copyHash || "");
        button.dataset.copyState = "copied";
        const label = button.textContent;
        button.textContent = "скопійовано";
        button.setAttribute("aria-label", "Повний hash скопійовано");
        window.setTimeout(() => {
          button.textContent = label;
          button.setAttribute("aria-label", `Копіювати повний hash ${button.dataset.copyHash.slice(0, 12)}`);
        }, 1600);
      } catch {
        button.dataset.copyState = "clipboard_unavailable";
        button.textContent = "не скопійовано";
        button.setAttribute("aria-label", "Не вдалося скопіювати hash");
      }
    });
  }

  if (loading) loading.hidden = true;
  if (search) {
    search.addEventListener("input", () => {
      const needle = search.value.trim().toLocaleLowerCase();
      for (const card of list?.querySelectorAll("[data-review-search]") || []) {
        card.hidden = needle !== "" && !card.dataset.reviewSearch.includes(needle);
      }
    });
  }
  if (limit) {
    limit.addEventListener("change", () => {
      const order = new URLSearchParams(window.location.search).get("order") === "new" ? "&order=new" : "";
      window.location.assign(`/review?limit=${encodeURIComponent(limit.value)}${order}`);
    });
  }
  if (refresh) {
    refresh.addEventListener("click", () => {
      if (loading) loading.hidden = false;
      refresh.disabled = true;
      window.location.reload();
    });
  }

  function updateBulk() {
    const selected = checkboxes.filter(box => box.checked);
    for (const form of bulkForms) {
      form.classList.toggle("is-visible", selected.length > 0);
      const button = form.querySelector("[data-review-bulk]");
      if (button) button.disabled = selected.length === 0;
    }
  }
  for (const checkbox of checkboxes) checkbox.addEventListener("change", updateBulk);
  for (const form of bulkForms) {
    form.addEventListener("submit", event => {
      const selected = checkboxes.filter(box => box.checked);
      if (selected.length === 0) {
        event.preventDefault();
        updateBulk();
        return;
      }
      const items = selected.map(box => {
        const card = box.closest(".review-item");
        return {
          id: box.value,
          text: card?.querySelector("[data-review-text]")?.value || "",
        };
      });
      const payload = form.querySelector('input[name="items"]');
      if (payload) payload.value = JSON.stringify(items);
    });
  }
  updateBulk();
}

function initializeSessionDelete() {
  document.addEventListener("submit", async event => {
    const form = event.target instanceof HTMLFormElement
      ? event.target.closest(".session-delete-form")
      : null;
    if (!form) return;
    event.preventDefault();
    const button = form.querySelector('button[type="submit"]');
    if (!(button instanceof HTMLButtonElement) || button.disabled) return;
    button.disabled = true;
    const feedback = form.parentElement?.querySelector("[data-session-delete-feedback]")
      || document.getElementById("session-delete-feedback");
    feedback?.replaceChildren();
    try {
      const response = await fetch(form.action, {
        method: form.method,
        body: new FormData(form),
        headers: { Accept: "application/json" },
      });
      const result = await response.json();
      const panel = document.createElement("section");
      panel.className = "panel session-delete-result-notice";
      const message = document.createElement("p");
      if (response.ok && result.ok === true) {
        message.id = "session-delete-result";
        message.textContent = result.message || "Сесію видалено.";
        panel.append(message);
        panel.setAttribute("role", "status");
        panel.setAttribute("aria-live", "polite");
        const card = form.closest(".session-entry");
        if (card) {
          card.before(panel);
          card.remove();
        } else {
          feedback?.append(panel);
        }
        if (document.querySelectorAll("details.sess").length === 0) {
          const empty = document.createElement("p");
          empty.id = "sessions-empty";
          empty.className = "empty";
          empty.textContent = "Сесій ще немає.";
          document.getElementById("sessions-table")?.append(empty);
        }
        return;
      }
      const error = result.error;
      const code = typeof error?.code === "string" ? `${error.code} · ` : "";
      message.textContent = `${code}${error?.message || "Не вдалося видалити сесію."}`;
      panel.append(message);
      if (typeof error?.hint === "string" && error.hint) {
        const hint = document.createElement("p");
        hint.className = "hint";
        hint.textContent = `що робити: ${error.hint}`;
        panel.append(hint);
      }
      feedback?.append(panel);
    } catch {
      const panel = document.createElement("section");
      panel.className = "panel";
      const message = document.createElement("p");
      message.textContent = "Не вдалося зв’язатися із сервером. Сесію не прибрано зі списку.";
      panel.append(message);
      feedback?.append(panel);
    } finally {
      if (button.isConnected) button.disabled = false;
    }
  });
}

const usageWindowLabels = { rolling: "5 годин", weekly: "тиждень", monthly: "місяць" };
const usageReasonLabels = {
  key_missing: "немає ключа OPENCODE_API_KEY у .env",
  key_rejected: "OpenCode не прийняв ключ",
  usage_unreachable: "OpenCode не відповідає",
  usage_shape_unknown: "OpenCode змінив форму відповіді · цифр не розібрати",
};

function usageResetLabel(value) {
  if (typeof value !== "string") return "час скидання невідомий";
  const resetAt = Date.parse(value);
  if (!Number.isFinite(resetAt)) return "час скидання невідомий";
  const seconds = Math.max(0, Math.floor((resetAt - Date.now()) / 1000));
  if (seconds < 3600) return `скидання за ${Math.max(1, Math.floor(seconds / 60))} хв`;
  if (seconds < 86400) {
    return `скидання за ${Math.floor(seconds / 3600)} год ${Math.floor((seconds % 3600) / 60)} хв`;
  }
  return `скидання ${new Intl.DateTimeFormat("uk-UA", {
    day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit",
  }).format(new Date(resetAt))}`;
}

function usageReason(reason) {
  if (typeof reason !== "string") return "";
  if (reason.startsWith("usage_refused:")) return `OpenCode відмовив: ${reason.slice("usage_refused:".length).trim()}`;
  return usageReasonLabels[reason] || reason;
}

function usageBarClass(window) {
  if (window.status !== "ok") return "is-danger";
  if (typeof window.percent !== "number") return "";
  if (window.percent >= 85) return "is-danger";
  if (window.percent >= 60) return "is-warn";
  return "is-ok";
}

/* Згорнутий бейдж тримає три періоди у сталому порядку місяць → тиждень →
   п’ять годин; порядок вікон в API інший (rolling, weekly, monthly). */
const usageTabWindows = ["monthly", "weekly", "rolling"];
const usageTabShortLabels = { monthly: "міс", weekly: "тиж", rolling: "5г" };

function usageWindowPercents(providerRows) {
  const percents = { monthly: null, weekly: null, rolling: null };
  for (const provider of Array.isArray(providerRows) ? providerRows : []) {
    for (const window of Array.isArray(provider.windows) ? provider.windows : []) {
      if (!(window.id in percents)) continue;
      if (typeof window.percent !== "number") continue;
      const current = percents[window.id];
      percents[window.id] = current === null ? window.percent : Math.max(current, window.percent);
    }
  }
  return percents;
}

function renderLimitsTab(tab, percents) {
  const numbers = usageTabWindows
    .map((id) => percents[id])
    .filter((value) => typeof value === "number");
  const peak = numbers.length === 0 ? null : Math.max(...numbers);
  const described = usageTabWindows.map((id) => {
    const percent = percents[id];
    return `${usageWindowLabels[id] || id} ${typeof percent === "number" ? `${percent}%` : "—"}`;
  }).join(", ");
  tab.replaceChildren();
  const caption = document.createElement("span");
  caption.className = "limits-tab-caption";
  caption.textContent = "ліміти";
  tab.append(caption);
  for (const id of usageTabWindows) {
    const percent = percents[id];
    const row = document.createElement("span");
    row.className = "limits-tab-row";
    const label = document.createElement("span");
    label.className = "limits-tab-label";
    label.textContent = usageTabShortLabels[id] || id;
    const value = document.createElement("strong");
    value.className = "limits-tab-peak";
    value.textContent = typeof percent === "number" ? `${percent}%` : "—";
    row.append(label, value);
    tab.append(row);
  }
  const description = `Ліміти: ${described}`;
  tab.setAttribute("title", description);
  tab.setAttribute("aria-label", description);
  tab.classList.remove("is-ok", "is-warn", "is-danger");
  if (peak !== null) tab.classList.add(peak >= 85 ? "is-danger" : peak >= 60 ? "is-warn" : "is-ok");
}

function renderUsageWidget(container, providerRows, fetchedAt) {
  container.replaceChildren();
  let peak = null;
  if (providerRows.length === 0) {
    const empty = document.createElement("p");
    empty.className = "limits-empty";
    empty.textContent = "Джерел із лімітами не налаштовано.";
    container.append(empty);
  }
  for (const provider of providerRows) {
    const block = document.createElement("section");
    block.className = "limits-provider";
    const title = document.createElement("div");
    title.className = "limits-provider-name";
    title.textContent = provider.label || provider.provider || "джерело";
    block.append(title);
    if (!provider.ok) {
      const reason = document.createElement("p");
      reason.className = "limits-reason";
      reason.textContent = usageReason(provider.reason);
      block.append(reason);
    }
    for (const window of Array.isArray(provider.windows) ? provider.windows : []) {
      const row = document.createElement("div");
      row.className = "limits-row";
      const name = document.createElement("span");
      name.className = "limits-window";
      name.textContent = usageWindowLabels[window.id] || window.id || "вікно";
      const reset = document.createElement("span");
      reset.className = "limits-reset";
      reset.textContent = usageResetLabel(window.resets_at);
      const percent = document.createElement("span");
      percent.className = "limits-pct";
      percent.textContent = typeof window.percent === "number" ? `${window.percent}%` : "—";
      if (typeof window.percent === "number") peak = peak === null ? window.percent : Math.max(peak, window.percent);
      const bar = document.createElement("div");
      bar.className = "limits-bar";
      bar.setAttribute("role", "meter");
      bar.setAttribute("aria-valuemin", "0");
      bar.setAttribute("aria-valuemax", "100");
      if (typeof window.percent === "number") bar.setAttribute("aria-valuenow", String(window.percent));
      else bar.setAttribute("aria-valuetext", "значення невідоме");
      const fill = document.createElement("i");
      fill.className = usageBarClass(window);
      fill.style.width = `${typeof window.percent === "number" ? window.percent : 0}%`;
      bar.append(fill);
      row.append(name, reset, percent, bar);
      block.append(row);
    }
    container.append(block);
  }
  const meta = document.createElement("div");
  meta.className = "limits-meta";
  const time = typeof fetchedAt === "string" ? Date.parse(fetchedAt) : NaN;
  meta.textContent = `оновлено ${Number.isFinite(time)
    ? new Intl.DateTimeFormat("uk-UA", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }).format(new Date(time))
    : "час невідомий"} · оновлюється само раз на хвилину`;
  container.append(meta);
  return peak;
}

function initializeUsageLimits() {
  const drawer = document.getElementById("limits-drawer");
  const tab = document.getElementById("limits-tab");
  const drawerWidget = document.getElementById("limits-drawer-widget");
  const panel = document.getElementById("limits-panel");
  if (!drawer || !tab || !drawerWidget) return;
  const hide = drawer.querySelector("[data-limits-hide]");
  const storageKey = "bdo-limits-open";
  function setOpen(open) {
    drawer.classList.toggle("is-open", open);
    tab.setAttribute("aria-expanded", String(open));
    try {
      window.localStorage.setItem(storageKey, open ? "1" : "0");
    } catch (error) {
      console.error("app.js: limits localStorage", error);
    }
  }
  let stored = null;
  try {
    stored = window.localStorage.getItem(storageKey);
  } catch (error) {
    console.error("app.js: limits localStorage read", error);
  }
  setOpen(stored === "1");
  tab.addEventListener("click", () => setOpen(true));
  hide?.addEventListener("click", () => setOpen(false));

  async function update() {
    try {
      const response = await fetch("/limits.json", { headers: { Accept: "application/json" } });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const result = await response.json();
      const providers = Array.isArray(result.providers) ? result.providers : [];
      renderUsageWidget(drawerWidget, providers, result.fetched_at);
      if (panel) renderUsageWidget(panel, providers, result.fetched_at);
      renderLimitsTab(tab, usageWindowPercents(providers));
    } catch (error) {
      console.error("app.js: limits fetch", error);
      for (const target of [drawerWidget, panel].filter(Boolean)) {
        target.replaceChildren();
        const message = document.createElement("p");
        message.className = "limits-empty";
        message.textContent = "OpenCode не відповідає";
        target.append(message);
      }
    }
  }
  void update();
  window.setInterval(() => void update(), 60000);
}

function initializeModelSecretFields() {
  for (const input of document.querySelectorAll('.source-card input[type="password"]')) {
    input.value = "";
  }
}

const TYPER_DRAIN_MS = 450;
// Нижня межа черги в розрахунку швидкості: без неї хвіст тане експоненційно й
// останні ~100 символів дописуються секундами, коли модель уже пише далі.
const TYPER_MIN_BACKLOG = 90;
const TYPER_STICK_PX = 24;
const typers = new Map();

// Оцінка як у labels.py::estimate_tokens: слово, число, група пробілів або знак · один токен.
function estimateTokens(text) {
  return (text.match(/\s+|[\p{L}\p{N}]+|[^\p{L}\p{N}\s]/gu) || []).length;
}

// Потоковий форматер JSON: по одному символу дає той самий вигляд, що й
// `json.dumps(indent=2)` на сервері, тож після завершення текст не стрибає.
// Текст, що не починається з `{`/`[` (також після ```json), лишається сирим.
class JsonStreamFormatter {
  constructor() {
    this.mode = "undecided";
    this.head = "";
    this.inString = false;
    this.escape = false;
    this.depth = 0;
    this.openPending = false;
  }

  feed(text) {
    let out = "";
    for (const ch of text) out += this.char(ch);
    return out;
  }

  char(ch) {
    if (this.mode === "raw") return ch;
    if (this.mode === "undecided") return this.decide(ch);
    return this.json(ch);
  }

  decide(ch) {
    this.head += ch;
    const trimmed = this.head.trimStart();
    if (!trimmed) return "";
    if (trimmed.startsWith("```")) {
      const newline = trimmed.indexOf("\n");
      if (newline === -1) return "";
      const rest = trimmed.slice(newline + 1).trimStart();
      if (!rest) return "";
      if (rest[0] === "{" || rest[0] === "[") {
        this.mode = "json";
        return this.feed(rest);
      }
    } else if (trimmed[0] === "{" || trimmed[0] === "[") {
      this.mode = "json";
      return this.feed(trimmed);
    } else if ("`".startsWith(trimmed) || "``".startsWith(trimmed)) {
      return "";
    }
    this.mode = "raw";
    return this.head;
  }

  indent() {
    return "\n" + "  ".repeat(Math.max(0, this.depth));
  }

  json(ch) {
    if (this.inString) {
      if (this.escape) this.escape = false;
      else if (ch === "\\") this.escape = true;
      else if (ch === '"') this.inString = false;
      return ch;
    }
    if (ch === " " || ch === "\n" || ch === "\r" || ch === "\t") return "";
    let out = "";
    if (this.openPending) {
      this.openPending = false;
      if (ch === "}" || ch === "]") return ch;
      this.depth += 1;
      out += this.indent();
    }
    if (ch === '"') {
      this.inString = true;
      return out + ch;
    }
    if (ch === "{" || ch === "[") {
      this.openPending = true;
      return out + ch;
    }
    if (ch === "}" || ch === "]") {
      this.depth -= 1;
      return out + this.indent() + ch;
    }
    if (ch === ",") return out + "," + this.indent();
    if (ch === ":") return out + ": ";
    if (ch === "`") return out;
    return out + ch;
  }
}

// Друкарка живого `pre`: тримає чергу символів і видає її дробово за часом,
// щоб текст не зʼявлявся ривками цілими порціями сервера.
class Typer {
  constructor(node) {
    this.node = node;
    this.pending = "";
    this.carry = 0;
    this.lastAt = 0;
    this.handle = 0;
    this.scheduled = false;
    this.alive = true;
    this.blockedBy = undefined;
    const initial = node.textContent === "—" ? "" : node.textContent || "";
    this.raw = initial;
    this.countedAt = 0;
    this.tokensNode = document.getElementById(`${node.id}-tokens`);
    this.formatter = new JsonStreamFormatter();
    this.textNode = document.createTextNode(this.formatter.feed(initial));
    this.caret = document.createElement("span");
    this.caret.className = "caret";
    this.caret.setAttribute("aria-hidden", "true");
    node.replaceChildren(this.textNode, this.caret);
    this.stick = true;
    node.addEventListener("scroll", () => {
      this.stick = node.scrollHeight - node.scrollTop - node.clientHeight <= TYPER_STICK_PX;
    });
  }

  push(text) {
    this.raw += text;
    this.updateTokens(false);
    this.pending += this.formatter.feed(text);
    this.schedule();
  }

  // Пише оцінку токенів у сусідній `<span>`; на потоці · не частіше ніж раз на 250 мс.
  updateTokens(force) {
    if (!this.tokensNode) return;
    const now = Date.now();
    if (!force && now - this.countedAt < 250) return;
    this.countedAt = now;
    this.tokensNode.textContent = estimateTokens(this.raw).toLocaleString("uk-UA");
  }

  schedule() {
    if (!this.alive || this.scheduled) return;
    this.scheduled = true;
    this.queueNext();
  }

  queueNext() {
    if (!this.alive) return;
    this.handle = document.hidden
      ? window.setTimeout(() => this.step(), 50)
      : window.requestAnimationFrame(() => this.step());
  }

  step() {
    this.scheduled = false;
    if (!this.alive) return;
    if (!this.node.isConnected) {
      this.destroy();
      return;
    }
    const now = performance.now();
    const dt = this.lastAt === 0 ? 16 : Math.min(200, now - this.lastAt);
    this.lastAt = now;
    // Відповідь ролі не друкується поверх роздумів: чекає, доки їхня черга
    // спорожніє, як у моделі, що спершу думає, а потім відповідає.
    const blocker = this.blockedBy ? this.blockedBy() : undefined;
    if (blocker && blocker.alive && blocker.pending) {
      this.lastAt = 0;
      this.carry = 0;
      this.scheduled = true;
      this.queueNext();
      return;
    }
    if (this.pending.length > 0) {
      this.carry += Math.max(this.pending.length, TYPER_MIN_BACKLOG) * dt / TYPER_DRAIN_MS;
      const cap = Math.max(4, Math.ceil(this.pending.length / 20));
      const take = Math.min(Math.floor(this.carry), cap, this.pending.length);
      if (take > 0) {
        this.textNode.appendData(this.pending.slice(0, take));
        this.pending = this.pending.slice(take);
        this.carry -= take;
      }
      if (this.stick) this.node.scrollTop = this.node.scrollHeight;
    }
    if (!this.pending) {
      // Черга порожня: чекаємо наступну порцію без кадрів; `push` запланує крок знову.
      this.lastAt = 0;
      this.carry = 0;
      return;
    }
    this.scheduled = true;
    this.queueNext();
  }

  reschedule() {
    if (!this.alive || !this.scheduled) return;
    window.clearTimeout(this.handle);
    window.cancelAnimationFrame(this.handle);
    this.queueNext();
  }

  flush() {
    if (!this.alive) return;
    this.alive = false;
    window.clearTimeout(this.handle);
    window.cancelAnimationFrame(this.handle);
    if (this.pending) {
      this.textNode.appendData(this.pending);
      this.pending = "";
    }
    this.updateTokens(true);
    if (this.caret.isConnected) this.caret.remove();
    typers.delete(this.node.id);
  }

  destroy() {
    this.alive = false;
    window.clearTimeout(this.handle);
    window.cancelAnimationFrame(this.handle);
    typers.delete(this.node.id);
  }
}

function flushTypers() {
  for (const typer of Array.from(typers.values())) typer.flush();
}

function liveTyper(node) {
  let typer = typers.get(node.id);
  if (!typer) {
    typer = new Typer(node);
    if (node.id.endsWith("-content")) {
      const thinkingId = node.id.replace(/-content$/, "-thinking");
      typer.blockedBy = () => typers.get(thinkingId);
    }
    typers.set(node.id, typer);
  }
  return typer;
}

function protectLiveNode(node) {
  if (!(node instanceof Element) || !node.id || !node.id.startsWith("live-")) return false;
  const typer = typers.get(node.id);
  return Boolean(typer && typer.alive && (typer.pending.length > 0 || typer.caret.isConnected));
}

function refreshMissingLiveTarget() {
  const now = Date.now();
  if (now - lastMissingTargetRefresh >= 300) {
    lastMissingTargetRefresh = now;
    refreshPage(true);
  }
}

function appendLiveDelta(event) {
  try {
    const message = JSON.parse(event.data);
    const data = message.data;
    if (!data || typeof data.role !== "string") return;
    if (data.channel === "request") {
      // Запит не друкується: сервер замінює його цілим текстом одразу.
      const requestNode = document.getElementById(`live-${data.role}-request`);
      if (!requestNode) {
        refreshMissingLiveTarget();
        return;
      }
      requestNode.textContent = typeof data.delta === "string" ? data.delta : "—";
      const tokensNode = document.getElementById(`live-${data.role}-request-tokens`);
      if (tokensNode) {
        const requestText = requestNode.textContent === "—" ? "" : requestNode.textContent;
        tokensNode.textContent = estimateTokens(requestText).toLocaleString("uk-UA");
      }
      // Новий запит ролі · новий виклик: старий текст попереднього раунду не тягнемо.
      for (const channel of ["thinking", "content"]) {
        const node = document.getElementById(`live-${data.role}-${channel}`);
        const typer = node ? typers.get(node.id) : undefined;
        if (typer) typer.destroy();
        if (node) node.textContent = "—";
      }
      return;
    }
    if (!["thinking", "content"].includes(data.channel)) return;
    if (typeof data.delta !== "string" || !data.delta) return;
    if (data.channel === "thinking") {
      // Перша непорожня дельта роздумів · значок мозку в заголовку картки світиться.
      const thinkIcon = document.getElementById(`live-${data.role}-think-icon`);
      if (thinkIcon) {
        thinkIcon.classList.remove("no-thinking");
        thinkIcon.classList.add("has-thinking");
        thinkIcon.title = "модель міркувала";
        thinkIcon.setAttribute("aria-label", "модель міркувала");
      }
    }
    const target = document.getElementById(`live-${data.role}-${data.channel}`);
    if (!target) {
      refreshMissingLiveTarget();
      return;
    }
    liveTyper(target).push(data.delta);
  } catch (error) {
    console.error("app.js: appendLiveDelta", error);
    return;
  }
}

document.addEventListener("visibilitychange", () => {
  // Схована вкладка не дає кадрів: переводимо друкарки на `setTimeout` і назад,
  // інакше черга застигає назавжди.
  for (const typer of Array.from(typers.values())) typer.reschedule();
});

function scheduleRefresh() {
  if (!refreshablePaths.has(window.location.pathname)) return;
  refreshPending = true;
  if (refreshTimer) return;
  const delay = Math.max(0, minRefreshInterval - (Date.now() - lastRefresh));
  refreshTimer = window.setTimeout(() => {
    refreshTimer = 0;
    if (!refreshPending) return;
    refreshPending = false;
    refreshPage();
  }, delay);
}

async function refreshPage(immediate = false) {
  if (refreshInFlight) {
    refreshPending = true;
    refreshPendingImmediate ||= immediate;
    return false;
  }
  refreshInFlight = true;
  lastRefresh = Date.now();
  const preserveViewport = window.location.pathname === "/models";
  const scrollX = window.scrollX;
  const scrollY = window.scrollY;
  try {
    const response = await fetch(window.location.href, { headers: { Accept: "text/html" } });
    if (!response.ok) return false;
    const html = await response.text();
    const parsed = new DOMParser().parseFromString(html, "text/html");
    const currentApp = document.querySelector("main#app");
    const nextApp = parsed.querySelector("main#app");
    const currentNavSide = document.querySelector(".nav-side");
    const nextNavSide = parsed.querySelector(".nav-side");
    if (!currentApp || !nextApp || typeof Idiomorph === "undefined") return false;
    Idiomorph.morph(currentApp, nextApp.innerHTML, {
      morphStyle: "innerHTML",
      callbacks: {
        beforeNodeMorphed(node) {
          // Поки друкарка активно тримає живий `pre`, морф не має повертати його
          // до серверного тексту й запускати друк спочатку.
          if (protectLiveNode(node)) return false;
          return true;
        },
        beforeAttributeUpdated(attributeName, node) {
          if (attributeName === "open" && node.tagName === "DETAILS" && node.hasAttribute("open")) {
            return false;
          }
          return true;
        },
      },
    });
    applyCallToggles();
    applyVerdictFilter();
    for (const typer of Array.from(typers.values())) {
      if (!typer.node.isConnected) typer.destroy();
    }
    if (currentNavSide && nextNavSide) {
      Idiomorph.morph(currentNavSide, nextNavSide.innerHTML, { morphStyle: "innerHTML" });
      // Сервер завжди рендерить «при відкритті»; стан потоку знає лише сторінка.
      setLiveStatus(eventStreamOpen);
    }
    if (preserveViewport) window.scrollTo(scrollX, scrollY);
    return true;
  } catch (error) {
    console.error("app.js: refreshPage", error);
    return false;
  } finally {
    refreshInFlight = false;
    if (refreshPendingImmediate) {
      refreshPending = false;
      refreshPendingImmediate = false;
      refreshPage(true);
    } else if (refreshPending) {
      scheduleRefresh();
    }
  }
}

const callChoices = new Map();

// Типово відкрита лише жива картка; вибір читача зберігається, доки роль
// у тому самому стані (`live`), інакше скидається й знову діє типова поведінка.
function callCardOpen(card) {
  const live = card.dataset.live === "1";
  const choice = callChoices.get(card.id);
  if (choice && choice.live !== live) callChoices.delete(card.id);
  const current = callChoices.get(card.id);
  return current ? current.open : live;
}

function applyCallToggles() {
  for (const card of document.querySelectorAll(".role-card")) {
    const work = card.querySelector(".callWork");
    const button = card.querySelector(".openCall");
    if (!work || !button) continue;
    const open = callCardOpen(card);
    if (open) card.dataset.open = "1";
    else delete card.dataset.open;
    work.hidden = !open;
    button.textContent = open ? "згорнути роботу" : "розгорнути роботу";
    button.setAttribute("aria-expanded", String(open));
  }
}

function applyVerdictFilter() {
  const needle = verdictSearch.toLocaleLowerCase();
  for (const row of document.querySelectorAll("#verdicts .vrow")) {
    const kind = row.dataset.v || "none";
    const matchesFilter = verdictFilter === "all" || kind === verdictFilter;
    const matchesSearch = needle === "" || (row.textContent || "").toLocaleLowerCase().includes(needle);
    row.hidden = !(matchesFilter && matchesSearch);
  }
  for (const chip of document.querySelectorAll(".verdict-filter .chip[data-f]")) {
    chip.setAttribute("aria-pressed", String(chip.dataset.f === verdictFilter));
  }
  const search = document.querySelector(".verdict-search");
  if (search && search.value !== verdictSearch) search.value = verdictSearch;
}

function initializeRunScreen() {
  document.addEventListener("click", event => {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) return;
    const openButton = target.closest(".openCall");
    if (openButton) {
      const card = openButton.closest(".role-card");
      if (card) {
        callChoices.set(card.id, { open: !callCardOpen(card), live: card.dataset.live === "1" });
        applyCallToggles();
      }
      return;
    }
    const chip = target.closest(".verdict-filter .chip[data-f]");
    if (chip) {
      verdictFilter = chip.dataset.f || "all";
      applyVerdictFilter();
    }
  });
  document.addEventListener("input", event => {
    const input = event.target;
    if (!(input instanceof HTMLInputElement) || !input.classList.contains("verdict-search")) return;
    verdictSearch = input.value;
    applyVerdictFilter();
  });
  applyCallToggles();
  applyVerdictFilter();
}

function initializeModelActions() {
  document.addEventListener("change", event => {
    const input = event.target;
    if (!(input instanceof HTMLInputElement) && !(input instanceof HTMLSelectElement)) return;
    // Поля ролі можуть лежати поза формою й бути привʼязані атрибутом `form=`,
    // тому власника шукаємо через `input.form`, а не через нащадків у DOM.
    if (!input.form || !input.form.matches(".models-role-form")) return;
    const isRoleSwitch = input instanceof HTMLInputElement && input.type === "checkbox" && input.name === "think";
    const isRoleEffort = input instanceof HTMLSelectElement && input.name === "effort_choice";
    if (!isRoleSwitch && !isRoleEffort) return;
    if (!input.disabled) input.form.requestSubmit();
  });
  document.addEventListener("submit", async event => {
    const form = event.target instanceof HTMLFormElement
      ? event.target.closest(".model-action-form, .models-role-form")
      : null;
    if (!form) return;
    event.preventDefault();
    if (form.dataset.saving === "true") return;
    const button = form.querySelector('button[type="submit"]');
    const isRoleForm = form.matches(".models-role-form");
    // `form.elements` містить і елементи з атрибутом `form=`, які лежать поза
    // розміткою форми; `querySelector` такі не знаходить.
    const roleSwitchElement = isRoleForm ? form.elements.namedItem("think") : null;
    const roleEffortElement = isRoleForm ? form.elements.namedItem("effort_choice") : null;
    const roleSwitch = roleSwitchElement instanceof HTMLInputElement ? roleSwitchElement : null;
    const roleEffort = roleEffortElement instanceof HTMLSelectElement ? roleEffortElement : null;
    const effortWasDisabled = roleEffort instanceof HTMLSelectElement && roleEffort.disabled;
    if ((!roleSwitch && !(button instanceof HTMLButtonElement)) || button?.disabled) return;
    const feedbackId = isRoleForm ? "models-role-feedback" : "model-action-feedback";
    const feedback = document.getElementById(feedbackId);
    const payload = new FormData(form);
    let saved = false;
    form.dataset.saving = "true";
    if (button instanceof HTMLButtonElement) button.disabled = true;
    if (roleSwitch instanceof HTMLInputElement) roleSwitch.disabled = true;
    if (roleEffort instanceof HTMLSelectElement && !roleEffort.disabled) roleEffort.disabled = true;
    if (feedback) {
      feedback.classList.remove("is-error");
      feedback.textContent = isRoleForm ? "зберігається…" : "";
      feedback.hidden = !isRoleForm;
    }
    try {
      const response = await fetch(form.action, {
        method: form.method,
        body: payload,
        headers: { Accept: "application/json" },
      });
      const result = await response.json();
      if (!response.ok || result.ok !== true) {
        const error = result.error;
        const code = typeof error?.code === "string" ? `${error.code} · ` : "";
        const message = typeof error?.message === "string" ? error.message : "Не вдалося змінити модель.";
        const reasonPrefix = typeof error?.code === "string" ? `${error.code}: ` : "";
        throw new Error(`${code}${reasonPrefix && message.startsWith(reasonPrefix) ? message.slice(reasonPrefix.length) : message}`);
      }
      if (roleSwitch instanceof HTMLInputElement) roleSwitch.dataset.saved = String(roleSwitch.checked);
      saved = true;
      if (!await refreshPage(true)) throw new Error("Не вдалося оновити дані екрана.");
      const refreshedFeedback = document.getElementById(feedbackId);
      if (refreshedFeedback) {
        refreshedFeedback.classList.remove("is-error");
        refreshedFeedback.textContent = result.message || "Зміни збережено.";
        refreshedFeedback.hidden = false;
        if (!isRoleForm) refreshedFeedback.focus({ preventScroll: true });
      }
    } catch (error) {
      if (isRoleForm && !saved) {
        if (roleSwitch instanceof HTMLInputElement) {
          roleSwitch.checked = roleSwitch.dataset.saved === "true";
        }
        if (roleEffort instanceof HTMLSelectElement) {
          roleEffort.value = roleEffort.dataset.saved ?? "";
        }
      }
      if (feedback) {
        feedback.classList.add("is-error");
        feedback.textContent = error instanceof Error ? error.message : "Не вдалося змінити модель.";
        feedback.hidden = false;
        if (!isRoleForm) feedback.focus({ preventScroll: true });
      }
    } finally {
      delete form.dataset.saving;
      if (button instanceof HTMLButtonElement && button.isConnected) button.disabled = false;
      if (roleSwitch instanceof HTMLInputElement && roleSwitch.isConnected) roleSwitch.disabled = false;
      if (roleEffort instanceof HTMLSelectElement && roleEffort.isConnected && !effortWasDisabled) roleEffort.disabled = false;
    }
  });
}

if (typeof EventSource !== "undefined") {
  const events = new EventSource("/events");
  events.onopen = () => {
    eventStreamOpen = true;
    setLiveStatus(true);
  };
  events.onerror = () => {
    eventStreamOpen = false;
    setLiveStatus(false);
  };
  for (const name of refreshEvents) events.addEventListener(name, scheduleRefresh);
  events.addEventListener("call_live", appendLiveDelta);
  // Завершення виклику чи кроку: показуємо хвіст черги негайно й прибираємо каретку.
  for (const name of ["call", "step_finished", "failure", "session_finished"]) {
    events.addEventListener(name, flushTypers);
  }
} else {
  setLiveStatus(false);
}

window.setInterval(() => {
  updateClocks();
  if (!eventStreamOpen) scheduleRefresh();
}, 1000);
updateClocks();

function initializePromptDialogs() {
  // Делегований обробник на `document` переживає морф сторінки: кнопки
  // «промпт» і самі `<dialog>` приходять із новою розміткою.
  document.addEventListener("click", event => {
    const trigger = event.target instanceof Element
      ? event.target.closest("[data-prompt-open]")
      : null;
    if (trigger instanceof HTMLElement) {
      const dialogId = trigger.dataset.promptOpen;
      const dialog = dialogId ? document.getElementById(dialogId) : null;
      if (dialog instanceof HTMLDialogElement) {
        dialog.showModal();
        return;
      }
    }
    // Клік по фону нативного вікна приходить із `target` · сам `dialog`.
    if (event.target instanceof HTMLDialogElement) event.target.close();
  });
}

function initializeModelsCatalog() {
  const catalog = document.getElementById("models-catalog");
  if (!catalog || catalog.dataset.complete === "true") return;
  const providers = (catalog.dataset.providers || "").split(",").filter(Boolean);
  if (providers.length === 0) return;
  const refresh = async provider => {
    const status = document.getElementById(`source-status-${provider}`)
      || document.querySelector(`[data-local-status="${provider}"]`);
    if (status) status.textContent = "знімаю каталог…";
    try {
      const response = await fetch(`/models/catalog/${encodeURIComponent(provider)}`);
      if (!response.ok) throw new Error("catalog_request_failed");
      const result = await response.json();
      if (!status) return true;
      const errorLabel = typeof result.error === "string"
        ? ({
          model_unreachable: "модель недоступна",
          provider_key_missing: "немає ключа джерела",
          timeout: "час очікування вичерпано",
        }[result.error] || "не вдалося зняти каталог")
        : "";
      const localName = status.dataset.localLabel || provider;
      status.textContent = status.hasAttribute("data-local-status")
        ? (errorLabel ? `${localName} · недоступна: ${errorLabel}` : `${localName} · ${result.models.length} моделей`)
        : errorLabel || `${result.models.length} моделей`;
      return true;
    } catch {
      if (status) status.textContent = "не вдалося зняти каталог · оновіть сторінку";
      return false;
    }
  };
  Promise.all(providers.map(refresh)).then(results => {
    if (results.every(Boolean)) window.location.reload();
  });
}

initializeModelsCatalog();
initializePromptDialogs();
initializeStartForm();
initializeReview();
initializeSessionDelete();
initializeUsageLimits();
initializeModelSecretFields();
initializeModelActions();
initializeRunScreen();
const diagnosticsMenu = document.getElementById("nav-diag");
if (diagnosticsMenu) {
  document.addEventListener("pointerdown", (event) => {
    if (!diagnosticsMenu.contains(event.target)) diagnosticsMenu.open = false;
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && diagnosticsMenu.open) {
      diagnosticsMenu.open = false;
      diagnosticsMenu.querySelector("summary")?.focus();
    }
  });
}
