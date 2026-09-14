// SPDX-License-Identifier: GPL-3.0-only
// Front-end logic for the WebView2 UI. Talks to the C# host via send().

"use strict";

// Surface every uncaught error to the host log (visible in app.log).
window.addEventListener("error", (e) => {
  try {
    window.chrome?.webview?.postMessage({
      type: "js-error",
      message: `${e.message} @ ${e.filename?.split("/").pop()}:${e.lineno}`,
    });
  } catch { }
});
window.addEventListener("unhandledrejection", (e) => {
  try {
    window.chrome?.webview?.postMessage({
      type: "js-error",
      message: `unhandled rejection: ${e.reason}`,
    });
  } catch { }
});

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => [...document.querySelectorAll(sel)];

// ---------- navigation ----------
$$("nav button").forEach((btn) =>
  btn.addEventListener("click", () => {
    $$("nav button").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    $$(".page").forEach((p) => p.classList.remove("active"));
    $(`#page-${btn.dataset.page}`).classList.add("active");
  })
);

// ---------- log ----------
const logBox = $("#log-box");
function log(text) {
  const line = `[${new Date().toLocaleTimeString("zh-CN", { hour12: false })}] ${text}\n`;
  logBox.textContent += line;
  while ((logBox.textContent.match(/\n/g) || []).length > 300) {
    logBox.textContent = logBox.textContent.slice(logBox.textContent.indexOf("\n") + 1);
  }
  logBox.scrollTop = logBox.scrollHeight;
}

// ---------- state ----------
const state = {
  bound: null,
  voiceReady: false,
  voiceStreaming: false,
  playback: true,
  record: true,
  voiceMode: "toggle",   // voice shortcut is always on; only the mode varies
  voiceTarget: null,
  cableInstalled: false,
  buttons: {},
};

const TARGET_PRESETS = [
  { label: "F2", vks: [0x71] }, { label: "F3", vks: [0x72] }, { label: "F4", vks: [0x73] },
  { label: "F5", vks: [0x74] }, { label: "F6", vks: [0x75] }, { label: "F8", vks: [0x77] }, { label: "F9", vks: [0x78] },
  { label: "Ctrl（左）", vks: [0xA2] }, { label: "Ctrl（右）", vks: [0xA3] },
  { label: "Shift（左）", vks: [0xA0] }, { label: "Shift（右）", vks: [0xA1] },
  { label: "Alt（左）", vks: [0xA4] }, { label: "Alt（右）", vks: [0xA5] },
  { label: "空格", vks: [0x20] }, { label: "Enter", vks: [0x0D] },
];
const BUTTON_TARGET_PRESETS = [
  { label: "方向键 ↑", vks: [0x26] }, { label: "方向键 ↓", vks: [0x28] },
  { label: "方向键 ←", vks: [0x25] }, { label: "方向键 →", vks: [0x27] },
  { label: "Enter", vks: [0x0D] }, { label: "Esc", vks: [0x1B] }, { label: "空格", vks: [0x20] },
  { label: "PageUp", vks: [0x21] }, { label: "PageDown", vks: [0x22] },
  { label: "Ctrl+C", vks: [0xA2, 0x43] }, { label: "Ctrl+V", vks: [0xA2, 0x56] }, { label: "Ctrl+Z", vks: [0xA2, 0x5A] },
  { label: "Ctrl+A", vks: [0xA2, 0x41] }, { label: "Alt+Tab", vks: [0xA4, 0x09] },
  { label: "Win+D", vks: [0x5B, 0x44] }, { label: "F5", vks: [0x74] },
  { label: "音量静音", vks: [0xAD] }, { label: "音量减", vks: [0xAE] }, { label: "音量加", vks: [0xAF] },
  { label: "媒体播放/暂停", vks: [0xB3] },
];

function vksLabel(vks) {
  if (!vks) return "未映射";
  if (typeof vks === "string") return vks;        // backend description strings
  if (!Array.isArray(vks)) return String(vks);
  const names = { 0x08:"Bksp",0x09:"Tab",0x0D:"Enter",0x1B:"Esc",0x20:"Space",0x21:"PgUp",0x22:"PgDn",0x23:"End",0x24:"Home",
    0x25:"←",0x26:"↑",0x27:"→",0x28:"↓",0x2D:"Ins",0x2E:"Del",
    0x5B:"Win(左)",0x5C:"Win(右)",
    0xA0:"Shift(左)",0xA1:"Shift(右)",0xA2:"Ctrl(左)",0xA3:"Ctrl(右)",0xA4:"Alt(左)",0xA5:"Alt(右)",
    0xAD:"静音",0xAE:"音量-",0xAF:"音量+",0xB0:"下一首",0xB1:"上一首",0xB3:"播放" };
  return vks.map((vk) => {
    if (names[vk]) return names[vk];
    if (vk >= 0x30 && vk <= 0x39) return String.fromCharCode(48 + vk - 0x30);
    if (vk >= 0x41 && vk <= 0x5A) return String.fromCharCode(65 + vk - 0x41);
    if (vk >= 0x70 && vk <= 0x7B) return "F" + (vk - 0x6F);
    return "0x" + vk.toString(16);
  }).join("+");
}

// ---------- connection hero ----------
function renderConnection() {
  const icon = $("#hero-icon"), stateEl = $("#conn-state"), detail = $("#conn-detail");
  const voiceBtn = $("#btn-voice"), stopBtn = $("#btn-stop");
  if (state.voiceStreaming) {
    icon.classList.add("connected"); icon.textContent = "🎙";
    stateEl.textContent = "语音进行中";
    detail.textContent = "正在接收遥控器音频…";
    stopBtn.disabled = false;
  } else if (state.voiceReady) {
    icon.classList.add("connected"); icon.textContent = "🎮";
    stateEl.textContent = "遥控器已连接，语音服务就绪";
    detail.textContent = (state.bound ? `${state.bound.name}（${state.bound.address}）\n` : "") + "按住遥控器语音键说话，松开结束。";
    voiceBtn.disabled = true; stopBtn.disabled = false;
  } else if (state.bound) {
    icon.classList.add("connected"); icon.textContent = "🎮";
    stateEl.textContent = "遥控器已绑定";
    detail.textContent = `${state.bound.name}（${state.bound.address}）· 点击「连接语音」开始。`;
    voiceBtn.disabled = false; stopBtn.disabled = true;
  } else {
    icon.classList.remove("connected"); icon.textContent = "🎮";
    stateEl.textContent = "未连接遥控器";
    detail.textContent = "点击「查找遥控器」搜索已配对的 RC003-MS。";
    voiceBtn.disabled = true; stopBtn.disabled = true;
  }
  const pill = $("#stream-pill");
  pill.className = "pill" + (state.voiceStreaming ? " ok" : "");
  $("#stream-text").textContent = state.voiceStreaming ? "正在接收" : state.voiceReady ? "就绪" : "空闲";
  const dot = $("#hdr-dot");
  if (dot) dot.classList.toggle("on", !!(state.voiceReady || state.voiceStreaming || state.bound));
}

// ---------- per-button editor (mapping) ----------
let selectedButton = null;
let capturing = false;

function renderFigure() {
  let mapped = 0;
  $$(".fig-btn").forEach((btn) => {
    const id = btn.dataset.btn;
    if (id === "microphone") return; // 语音键不参与按键映射
    const info = state.buttons[id];
    const has = !!(info && info.target && info.target.length);
    if (has) mapped++;
    btn.classList.toggle("selected", id === selectedButton);
    btn.classList.toggle("has-map", has);
  });
  const sub = $("#map-sub");
  if (sub) {
    sub.textContent = mapped > 0
      ? `已映射 ${mapped} / 12 个按键 · 绿色边框表示已映射。点击示意图上的按键选中，右侧配置目标。`
      : "点击左侧遥控器示意图上的按键选中，右侧配置目标；已映射的按键显示绿色边框。语音键在下方「语音键快捷方式」卡片配置。";
  }
}

$$(".fig-btn").forEach((btn) =>
  btn.addEventListener("click", () => {
    // 语音键不做按键映射：滚动到语音快捷方式卡片。
    if (btn.dataset.btn === "microphone") {
      $("#voice-card")?.scrollIntoView({ behavior: "smooth", block: "start" });
      return;
    }
    selectButton(btn.dataset.btn);
  })
);

function selectButton(id) {
  selectedButton = id;
  capturing = false;
  renderFigure();
  renderEditor();
}

const BUTTON_TITLES = {
  power: "电源", microphone: "语音", up: "上", left: "左", ok: "确认", right: "右",
  down: "下", back: "返回", home: "主页", menu: "菜单",
  volume_up: "音量＋", volume_down: "音量－", tv: "TV",
};
function buttonInfo(id) {
  return state.buttons[id] ?? { title: BUTTON_TITLES[id] ?? id, target: null };
}
function setButtonTarget(id, vks) {
  if (!state.buttons[id]) state.buttons[id] = buttonInfo(id);
  state.buttons[id].target = vks;
}

function renderEditor() {
  const empty = $("#editor-empty"), panel = $("#editor-panel");
  if (!selectedButton) { empty.style.display = "block"; panel.style.display = "none"; return; }
  empty.style.display = "none"; panel.style.display = "block";
  const info = buttonInfo(selectedButton);
  $("#ed-title").textContent = `[${info.title}] 键`;
  const cur = info.target && info.target.length ? vksLabel(info.target) : "未映射";
  $("#ed-current").innerHTML = `当前：<span class="tag">${cur}</span>`;
  $("#ed-captured").textContent = capturing ? "请按组合键…" : (info.target ? cur : "未捕获");
  const box = $("#ed-capture");
  box.classList.toggle("capturing", capturing);
  $("#ed-capture-hint").textContent = capturing
    ? "现在按下组合键（Esc 取消）"
    : "点击这里，然后直接按键盘组合键（如 Ctrl+Shift+Tab）";

  const grid = $("#ed-presets");
  grid.innerHTML = "";
  const mk = (label, vks) => {
    const b = document.createElement("button");
    b.className = "preset-btn";
    b.textContent = label;
    if (info.target && JSON.stringify(info.target) === JSON.stringify(vks)) b.classList.add("active");
    b.addEventListener("click", async () => {
      try {
        await send("set-button-mapping", { button: selectedButton, vks });
        setButtonTarget(selectedButton, vks);
        toast(`${info.title} 已映射到 ${vksLabel(vks)}`);
        renderEditor(); renderFigure();
      } catch (e) { toast("保存失败：" + e.message); }
    });
    return b;
  };
  BUTTON_TARGET_PRESETS.forEach((p) => grid.append(mk(p.label, p.vks)));
  if (info.target && info.target.length
      && !BUTTON_TARGET_PRESETS.some((p) => JSON.stringify(p.vks) === JSON.stringify(info.target)))
    grid.prepend(mk(vksLabel(info.target) + "（当前）", info.target));
}

$("#ed-capture").addEventListener("click", () => {
  capturing = true; renderEditor(); $("#ed-capture").focus();
});
$("#ed-capture").addEventListener("keydown", async (e) => {
  if (!capturing || !selectedButton) return;
  e.preventDefault(); e.stopPropagation();
  if (e.key === "Escape") { capturing = false; renderEditor(); return; }
  // 区分左右修饰键：location 1=左（或非修饰键），2=右。
  // Windows VK：左Shift/Ctrl/Alt = A0/A2/A4，右 = A1/A3/A5。
  const isMod = ["Control", "Shift", "Alt", "Meta"].includes(e.key);
  const modVk = (base, right) => (e.location === 2 ? right : base);
  const mods = [];
  if (e.ctrlKey) mods.push(isMod && e.key === "Control" ? modVk(0xA2, 0xA3) : 0xA2);
  if (e.shiftKey) mods.push(isMod && e.key === "Shift" ? modVk(0xA0, 0xA1) : 0xA0);
  if (e.altKey) mods.push(isMod && e.key === "Alt" ? modVk(0xA4, 0xA5) : 0xA4);
  if (isMod) {
    // 只按了修饰键：输入法软件常把"按住右侧 Ctrl 说话"这类单键当快捷键。
    // 捕获时机 = 该修饰键被松开（keyup），避免按下瞬间就截到一半状态。
    return;
  }
  const keyVk = ({ Enter: 0x0D, Escape: 0x1B, Space: 0x20, Tab: 0x09, Backspace: 0x08,
    ArrowUp: 0x26, ArrowDown: 0x28, ArrowLeft: 0x25, ArrowRight: 0x27,
    Home: 0x24, End: 0x23, PageUp: 0x21, PageDown: 0x22, Insert: 0x2D, Delete: 0x2E })[e.key];
  let main = keyVk ?? e.keyCode;
  if (!main && e.key.length === 1) {
    const code = e.key.toUpperCase().charCodeAt(0);
    main = code; // letters/digits map directly to VK codes
  }
  if (!main) return;
  const vks = [...mods, main];
  try {
    await send("set-button-mapping", { button: selectedButton, vks });
    setButtonTarget(selectedButton, vks);
    capturing = false;
    toast(`已映射到 ${vksLabel(vks)}`);
  } catch (err) { toast("保存失败：" + err.message); }
  renderEditor(); renderFigure();
});
$("#ed-clear").addEventListener("click", async () => {
  if (!selectedButton) return;
  try {
    await send("set-button-mapping", { button: selectedButton, vks: null });
    setButtonTarget(selectedButton, null);
    toast("已清除映射");
  } catch (e) { toast("清除失败：" + e.message); }
  renderEditor(); renderFigure();
});

// ---------- confirm modal ----------
function showConfirm({ title, body, okText = "确认", danger = true, icon = "⚠️" }) {
  return new Promise((resolve) => {
    const back = $("#modal-backdrop");
    $("#modal-icon").textContent = icon;
    $("#modal-title").textContent = title;
    $("#modal-body").innerHTML = body;
    const ok = $("#modal-ok"), cancel = $("#modal-cancel");
    ok.textContent = okText;
    ok.className = danger ? "danger" : "primary";
    back.classList.add("show");
    const cleanup = () => {
      back.classList.remove("show");
      ok.removeEventListener("click", onOk);
      cancel.removeEventListener("click", onCancel);
      back.removeEventListener("click", onBack);
      document.removeEventListener("keydown", onKey);
    };
    const onOk = () => { cleanup(); resolve(true); };
    const onCancel = () => { cleanup(); resolve(false); };
    const onBack = (e) => { if (e.target === back) { cleanup(); resolve(false); } };
    const onKey = (e) => { if (e.key === "Escape") { cleanup(); resolve(false); } };
    ok.addEventListener("click", onOk);
    cancel.addEventListener("click", onCancel);
    back.addEventListener("click", onBack);
    document.addEventListener("keydown", onKey);
  });
}

// ---------- one-click restore defaults (mapping page) ----------
$("#btn-reset-mapping").addEventListener("click", async () => {
  const mapped = Object.values(state.buttons).filter((b) => b && b.target && b.target.length).length;
  const confirmed = await showConfirm({
    title: "恢复默认映射？",
    body: `将清空全部 <b>13</b> 个按键的映射${mapped ? `（当前有 <b>${mapped}</b> 个已映射）` : ""}，`
      + `并把语音快捷键恢复为默认的 <b>F2（点按两下）</b>。<br><br>此操作不可撤销。`,
    okText: "清空并恢复",
    danger: true,
  });
  if (!confirmed) return;
  try {
    const d = await send("reset-mappings");
    if (d) applyInitialState(d);
    else {
      Object.keys(state.buttons).forEach((k) => { state.buttons[k].target = null; });
      renderButtons();
    }
    toast("已恢复默认映射（全部未映射）");
  } catch (e) { toast("恢复失败：" + e.message); }
});

function renderButtons() { renderFigure(); renderEditor(); }

// ---------- voice shortcut ----------
function renderVoiceShortcut() {
  $$(".mode-card").forEach((card) => card.classList.toggle("selected", card.dataset.mode === state.voiceMode));
  const sel = $("#voice-target");
  sel.innerHTML = "";
  TARGET_PRESETS.forEach((p) => sel.append(new Option(p.label, JSON.stringify(p.vks))));
  if (state.voiceTarget) {
    const cur = JSON.stringify(state.voiceTarget);
    if ([...sel.options].some((o) => o.value === cur)) sel.value = cur;
  }
}

$$(".mode-card").forEach((card) =>
  card.addEventListener("click", async () => {
    state.voiceMode = card.dataset.mode;
    renderVoiceShortcut();
    try {
      await send("set-voice-shortcut", {
        mode: state.voiceMode,
        vks: state.voiceTarget || [0x71],
      });
      toast(state.voiceMode === "toggle"
        ? "已设为点按两下模式（Typeless 式）"
        : "已设为按住说话模式（输入法式）");
    } catch (e) { toast("保存失败：" + e.message); }
  })
);
$("#voice-target").addEventListener("change", async (e) => {
  state.voiceTarget = e.target.value ? JSON.parse(e.target.value) : null;
  try {
    await send("set-voice-shortcut", { mode: state.voiceMode, vks: state.voiceTarget });
    toast("快捷键已设为 " + vksLabel(state.voiceTarget));
  } catch (err) { toast("保存失败：" + err.message); }
});

// ---------- voice-mode quick switch ----------
const VOICE_MODE_NAMES = {
  toggle: "点按两下",
  holdtap: "按住说话·自动结束",
  hold: "按住说话·按键式",
};

function renderVoiceCycle() {
  const el = $("#voice-cycle-current");
  if (el) el.textContent = VOICE_MODE_NAMES[state.voiceMode] || state.voiceMode;
}

$("#btn-cycle-voice").addEventListener("click", async () => {
  try {
    const d = await send("cycle-voice-mode");
    if (d?.mode) {
      state.voiceMode = d.mode;
      if (d.target) state.voiceTarget = d.target;
      renderVoiceShortcut();
      renderVoiceCycle();
      toast("已切到「" + (VOICE_MODE_NAMES[d.mode] || d.mode) + "」");
    }
  } catch (e) { toast("切换失败：" + e.message); }
});

// ---------- voice-shortcut key capture ----------
// 输入法软件常把"按住右 Ctrl 说话"这类单侧修饰键当快捷键，所以这里：
//  * 单独按住某个修饰键再松开 = 捕获该修饰键本身（区分左右）；
//  * 按住修饰键再按任意其它键 = 捕获组合键。
let voiceCapturing = false;
let voiceModHeld = null; // { vks: [..] }，按住修饰键期间暂存

function setVoiceCaptured(text) { $("#voice-captured").textContent = text; }

function renderVoiceCapture() {
  const box = $("#voice-capture");
  box.classList.toggle("capturing", voiceCapturing);
  $("#voice-capture-hint").textContent = voiceCapturing
    ? "松开修饰键即捕获它（区分左右）；或按住修饰键再按一个键捕获组合键（Esc 取消）"
    : "或点击这里直接按键捕获：单独按住左/右 Ctrl、Shift、Alt 后松开即捕获该键；组合键则按住修饰键再按一个键";
}

$("#voice-capture").addEventListener("click", () => {
  voiceCapturing = true; voiceModHeld = null;
  renderVoiceCapture(); setVoiceCaptured("请按键…");
  $("#voice-capture").focus();
});

$("#voice-capture").addEventListener("keydown", (e) => {
  if (!voiceCapturing) return;
  e.preventDefault(); e.stopPropagation();
  if (e.key === "Escape") {
    voiceCapturing = false; voiceModHeld = null;
    renderVoiceCapture(); setVoiceCaptured("未捕获");
    return;
  }
  const right = e.location === 2;
  if (e.key === "Control") voiceModHeld = { vks: [right ? 0xA3 : 0xA2] };
  else if (e.key === "Shift") voiceModHeld = { vks: [right ? 0xA1 : 0xA0] };
  else if (e.key === "Alt") voiceModHeld = { vks: [right ? 0xA5 : 0xA4] };
  else if (e.key === "Meta") voiceModHeld = { vks: [right ? 0x5C : 0x5B] };
  else {
    const keyVk = ({ Enter: 0x0D, Space: 0x20, Tab: 0x09, Backspace: 0x08,
      ArrowUp: 0x26, ArrowDown: 0x28, ArrowLeft: 0x25, ArrowRight: 0x27,
      Home: 0x24, End: 0x23, PageUp: 0x21, PageDown: 0x22, Insert: 0x2D, Delete: 0x2E })[e.key];
    let main = keyVk ?? e.keyCode;
    if (!main && e.key.length === 1) main = e.key.toUpperCase().charCodeAt(0);
    if (!main) return;
    const mods = voiceModHeld ? voiceModHeld.vks : [];
    // 组合键里统一用左修饰 VK 表示（右修饰做组合键场景极少且多数软件不区分）
    const vks = [...mods.map((v) => (v >= 0xA1 && v <= 0xA5) ? v - 1 : v), main];
    voiceCapturing = false; voiceModHeld = null;
    applyVoiceTarget(vks);
    return;
  }
  setVoiceCaptured(`已按住 ${vksLabel(voiceModHeld.vks)}…松开即捕获，或继续按其它键组成组合`);
});

$("#voice-capture").addEventListener("keyup", (e) => {
  if (!voiceCapturing || !voiceModHeld) return;
  const modKeys = { Control: true, Shift: true, Alt: true, Meta: true };
  if (modKeys[e.key]) {
    const vks = voiceModHeld.vks;
    voiceCapturing = false; voiceModHeld = null;
    applyVoiceTarget(vks);
  }
});

async function applyVoiceTarget(vks) {
  state.voiceTarget = vks;
  renderVoiceCapture();
  try {
    await send("set-voice-shortcut", { mode: state.voiceMode, vks });
    setVoiceCaptured(vksLabel(vks));
    toast("语音快捷键已设为 " + vksLabel(vks));
  } catch (err) {
    toast("保存失败：" + err.message);
    setVoiceCaptured("未捕获");
  }
}

// ---------- actions ----------
$("#btn-discover").addEventListener("click", async () => {
  $("#conn-state").textContent = "正在查找遥控器…";
  $("#conn-detail").textContent = "正在通过蓝牙查询已连接的 RC003-MS，请保持遥控器开机。";
  try { await send("discover"); } catch (e) { toast(e.message); }
});
$("#btn-voice").addEventListener("click", async () => {
  try {
    await send("connect-voice");
    toast("正在连接语音服务…");
  } catch (e) { toast(e.message); }
});
$("#btn-stop").addEventListener("click", async () => {
  try { await send("stop-voice"); } catch (e) { toast(e.message); }
});
$("#opt-playback").addEventListener("change", async (e) => {
  state.playback = e.target.checked;
  host?.postMessage({ type: "set-playback", enabled: state.playback });
  renderOutputDeviceRow();
  if (state.playback) await loadOutputDevices();
});
$("#opt-record").addEventListener("change", (e) => {
  state.record = e.target.checked;
  host?.postMessage({ type: "set-record", enabled: state.record });
});

// ---------- audio output routing (virtual cable) ----------
function renderOutputDeviceRow() {
  const row = $("#output-device-row");
  if (row) row.style.display = state.playback ? "flex" : "none";
}

async function loadOutputDevices() {
  try {
    const d = await send("list-output-devices");
    if (!d) return;
    state.cableInstalled = !!d.cableInstalled;
    const sel = $("#output-device");
    if (!sel) return;
    sel.innerHTML = "";
    sel.append(new Option("系统默认输出", ""));
    (d.devices || []).forEach((dev) => sel.append(new Option(dev.name, dev.name)));
    if (d.selected) sel.value = d.selected;
    const hint = $("#cable-hint");
    if (hint) {
      hint.innerHTML = state.cableInstalled
        ? "✅ 已检测到虚拟声卡（CABLE）。在语音软件的麦克风里选 <b>CABLE Output</b>，这里把输出选 <b>CABLE Input</b> 即可打通。"
        : "未检测到虚拟声卡。要让语音软件用遥控器的麦克风，请安装 VB-Audio Virtual Cable（见下方按钮）。";
      hint.style.color = state.cableInstalled ? "var(--ok, #0d7a3d)" : "#b35900";
    }
  } catch (e) { /* non-fatal */ }
}

$("#output-device")?.addEventListener("change", async (e) => {
  try {
    await send("set-output-device", { name: e.target.value || null });
    toast(e.target.value ? "回放输出已设为 " + e.target.value : "回放输出已设为系统默认");
  } catch (err) { toast("设置失败：" + err.message); }
});
$("#opt-mapping").addEventListener("change", async (e) => {
  try {
    await send("set-mapping-enabled", { enabled: e.target.checked });
    toast(e.target.checked ? "按键映射已启用" : "按键映射已停用");
  } catch (err) { toast(err.message); }
});
$("#btn-open-folder").addEventListener("click", () => host?.postMessage({ type: "open-folder" }));
$("#btn-pick-folder").addEventListener("click", async () => {
  try {
    const r = await send("pick-folder");
    if (r?.folder) $("#folder-hint").textContent = r.folder;
  } catch (e) { toast(e.message); }
});

// ---------- host events ----------
// Host pushes arrive on chrome.webview (NOT window) in WebView2.
function handleHostEvent(event) {
  const msg = event.data;
  if (!msg?.type) return;
  const d = msg.data;
  switch (msg.type) {
    case "initial-state": {
      // Backend sends {title, target:描述字符串, vks:[...]}; normalize to a
      // {title, target:vks[]} shape so preset highlighting + rendering agree.
      const buttons = {};
      for (const [id, b] of Object.entries(d.buttons || {})) {
        const vks = Array.isArray(b.vks) && b.vks.length
          ? b.vks
          : (Array.isArray(b.target) && b.target.length ? b.target : null);
        buttons[id] = { title: b.title, target: vks };
      }
      Object.assign(state, {
        voiceMode: d.voiceMode,
        voiceTarget: d.voiceTarget,
        buttons,
        bound: d.bound,
      });
      $("#opt-mapping").checked = d.enabled;
      if (typeof d.playback === "boolean") { state.playback = d.playback; $("#opt-playback").checked = d.playback; }
      if (typeof d.record === "boolean") { state.record = d.record; $("#opt-record").checked = d.record; }
      state.cableInstalled = !!d.cableInstalled;
      $("#folder-hint").textContent = d.recordingsFolder;
      renderButtons();
      renderVoiceShortcut();
      renderVoiceCycle();
      renderOutputDeviceRow();
      if (state.playback) loadOutputDevices();
      if (state.voiceTarget) setVoiceCaptured(vksLabel(state.voiceTarget));
      renderConnection();
      break;
    }
    case "voice-mode-changed": {
      // Quick switch (backend-initiated). Keep the whole voice card in sync.
      if (d.mode) {
        state.voiceMode = d.mode;
        if (d.target) state.voiceTarget = d.target;
        renderVoiceShortcut();
        renderVoiceCycle();
      }
      break;
    }
    case "voice-status": {
      state.voiceReady = d.ready;
      state.voiceStreaming = d.streaming;
      $("#stats-hint").textContent = `帧 ${d.frames.toLocaleString()} · 采样 ${d.samples.toLocaleString()}`;
      if (d.message && !d.ready) log(d.message);
      renderConnection();
      break;
    }
    case "level": {
      $("#level-bar").style.width = `${Math.min(100, (d.level || 0) * 100)}%`;
      break;
    }
    case "discovery": {
      log(d.message);
      if (d.count === 1) {
        const c = d.candidates[0];
        state.bound = { name: c.name, address: c.address };
        toast(`已绑定 ${c.name}（${c.address}）`);
      } else if (d.count === 0) {
        toast(d.message);
      }
      renderConnection();
      break;
    }
    case "mapped": {
      // d.target is a backend description string; keep vks arrays intact.
      if (state.buttons[d.button]) state.buttons[d.button].lastDescription = d.target;
      log(`[映射] ${d.title} → ${d.target}`);
      break;
    }
    case "voice-button": {
      log(d.down ? "语音键按下" : "语音键释放");
      break;
    }
    case "log": {
      log(d.text);
      break;
    }
  }
}

// Initial state: the host pushes on load (may race page load and be lost),
// and we also request it; both paths converge on the same handler.
function applyInitialState(d) {
  const evt = { data: { type: "initial-state", data: d } };
  handleHostEvent(evt);
}

(window.chrome?.webview)?.addEventListener("message", handleHostEvent);

send("get-state").then((d) => { if (d) applyInitialState(d); })
  .catch((e) => log("初始化失败：" + e.message));
