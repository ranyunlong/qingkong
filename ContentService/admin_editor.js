(() => {
  "use strict";

  const allowedTags = new Set(["P", "BR", "H2", "H3", "BLOCKQUOTE", "UL", "OL", "LI", "STRONG", "B", "EM", "I", "U", "S", "STRIKE", "A", "IMG"]);
  const discardedTags = new Set(["SCRIPT", "STYLE", "IFRAME", "OBJECT", "EMBED", "SVG", "MATH", "TEMPLATE", "NOSCRIPT", "VIDEO", "AUDIO", "SOURCE", "TRACK", "LINK", "META", "INPUT", "BUTTON", "SELECT", "TEXTAREA"]);
  const blockTags = new Set(["P", "DIV", "H1", "H2", "H3", "H4", "H5", "H6", "BLOCKQUOTE", "UL", "OL", "LI", "SECTION", "ARTICLE"]);

  function httpsURL(value) {
    try {
      const url = new URL(String(value).trim());
      return url.protocol === "https:" && !url.username && !url.password ? url.href : "";
    } catch (_) {
      return "";
    }
  }

  function imageURL(value) {
    const address = httpsURL(value);
    if (!address) return "";
    try { return /\.svgz?$/i.test(decodeURIComponent(new URL(address).pathname)) ? "" : address; }
    catch (_) { return ""; }
  }

  function cleanHTML(value) {
    const template = document.createElement("template");
    template.innerHTML = value;
    const result = document.createElement("div");
    function append(source, target) {
      for (const node of source.childNodes) {
        if (node.nodeType === Node.TEXT_NODE) {
          target.append(document.createTextNode(node.textContent));
          continue;
        }
        if (node.nodeType !== Node.ELEMENT_NODE || discardedTags.has(node.tagName)) continue;
        if (!allowedTags.has(node.tagName)) {
          if (blockTags.has(node.tagName) && !Array.from(node.children).some(child => blockTags.has(child.tagName))) {
            const paragraph = document.createElement("p");
            append(node, paragraph);
            target.append(paragraph);
          } else {
            append(node, target);
          }
          continue;
        }
        const element = document.createElement(node.tagName.toLowerCase());
        if (node.tagName === "A") {
          const href = httpsURL(node.getAttribute("href") || "");
          if (!href) {
            append(node, target);
            continue;
          }
          element.setAttribute("href", href);
          element.setAttribute("rel", "noopener noreferrer");
        }
        if (node.tagName === "IMG") {
          const src = imageURL(node.getAttribute("src") || "");
          if (!src) continue;
          element.setAttribute("src", src);
          element.setAttribute("alt", (node.getAttribute("alt") || "正文图片").slice(0, 300));
          for (const attribute of ["width", "height"]) {
            const value = node.getAttribute(attribute) || "";
            if (/^[1-9]\d{0,4}$/.test(value) && Number(value) <= 10000) element.setAttribute(attribute, value);
          }
        }
        append(node, element);
        target.append(element);
      }
    }
    append(template.content, result);
    return result.innerHTML;
  }

  function plainText(html) {
    const template = document.createElement("template");
    template.innerHTML = html;
    function read(node) {
      if (node.nodeType === Node.TEXT_NODE) return node.textContent;
      if (node.nodeType === Node.ELEMENT_NODE && node.tagName === "BR") return "\n";
      if (node.nodeType === Node.ELEMENT_NODE && node.tagName === "IMG") return "\n" + (node.getAttribute("alt") || "正文图片") + "\n";
      const text = Array.from(node.childNodes, read).join("");
      return node.nodeType === Node.ELEMENT_NODE && blockTags.has(node.tagName) ? text + "\n\n" : text;
    }
    return read(template.content).replace(/\u00a0/g, " ").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  }

  function setupRichEditor(form) {
    const editor = form.querySelector("[data-rich-editor]");
    const surface = form.querySelector("[data-editor-surface]");
    const body = form.elements.namedItem("body");
    const bodyHTML = form.elements.namedItem("bodyHTML");
    if (!editor || !surface || !body || !bodyHTML || typeof document.execCommand !== "function") return;

    let savedRange = null;
    let uploading = false;
    const commands = Array.from(editor.querySelectorAll("[data-editor-command]"));
    const message = document.createElement("p");
    message.className = "editor-help";
    message.setAttribute("role", "status");
    message.setAttribute("aria-live", "polite");
    editor.after(message);
    function sync() {
      const html = cleanHTML(surface.innerHTML);
      bodyHTML.value = html;
      body.value = plainText(html);
    }
    function rememberSelection() {
      const selection = window.getSelection();
      if (selection && selection.rangeCount && surface.contains(selection.anchorNode) && surface.contains(selection.focusNode)) {
        savedRange = selection.getRangeAt(0).cloneRange();
      }
    }
    function restoreSelection() {
      surface.focus();
      const selection = window.getSelection();
      if (savedRange && surface.contains(savedRange.commonAncestorContainer)) {
        selection.removeAllRanges();
        selection.addRange(savedRange);
      }
    }
    function updateToolbar() {
      const selection = window.getSelection();
      if (!selection || !selection.rangeCount || !surface.contains(selection.anchorNode)) return;
      for (const button of commands) {
        const command = button.dataset.editorCommand;
        if (command === "createLink") continue;
        try {
          const active = command === "formatBlock"
            ? String(document.queryCommandValue("formatBlock")).toLowerCase().replace(/[<>]/g, "") === button.dataset.commandValue
            : document.queryCommandState(command);
          button.setAttribute("aria-pressed", String(Boolean(active)));
        } catch (_) {
          button.setAttribute("aria-pressed", "false");
        }
      }
    }
    const supportedCommands = new Set(["bold", "italic", "underline", "strikeThrough", "insertUnorderedList", "insertOrderedList", "formatBlock", "createLink"]);
    for (const button of commands) {
      button.type = "button";
      button.addEventListener("mousedown", event => event.preventDefault());
      button.addEventListener("click", () => {
        const command = button.dataset.editorCommand;
        if (!supportedCommands.has(command)) return;
        let value = null;
        if (command === "formatBlock") {
          value = button.dataset.commandValue;
          if (!["p", "h2", "h3", "blockquote"].includes(value)) return;
        }
        if (command === "createLink") {
          const entered = window.prompt("请输入 HTTPS 链接地址");
          if (entered === null) return;
          value = httpsURL(entered);
          if (!value) {
            message.textContent = "链接需使用有效的 HTTPS 地址。";
            return;
          }
        }
        restoreSelection();
        document.execCommand("styleWithCSS", false, false);
        document.execCommand(command, false, value);
        rememberSelection();
        updateToolbar();
        sync();
        message.textContent = "";
      });
    }
    const imageURLButton = editor.querySelector("[data-editor-image-url]");
    const imageUploadButton = editor.querySelector("[data-editor-image-upload]");
    const imageFile = editor.querySelector("[data-editor-image-file]");
    function insertImage(url, description, dimensions = {}) {
      if (surface.querySelectorAll("img").length >= 30) throw new Error("每篇正文最多添加 30 张图片。");
      restoreSelection();
      const image = document.createElement("img");
      image.src = url;
      image.alt = (description || "正文图片").slice(0, 300);
      for (const attribute of ["width", "height"]) {
        const value = dimensions[attribute];
        if (Number.isInteger(value) && value > 0 && value <= 10000) image.setAttribute(attribute, String(value));
      }
      document.execCommand("insertHTML", false, image.outerHTML + "<p><br></p>");
      sync();
      rememberSelection();
    }
    if (imageURLButton) {
      imageURLButton.addEventListener("mousedown", event => { event.preventDefault(); rememberSelection(); });
      imageURLButton.addEventListener("click", () => {
        const entered = window.prompt("请输入 HTTPS 图片链接");
        if (entered === null) return;
        const url = imageURL(entered);
        if (!url) { message.textContent = "图片链接需使用有效的 HTTPS 地址。"; return; }
        const description = window.prompt("图片说明（可选，用于无法显示图片时）", "正文图片");
        if (description === null) return;
        try { insertImage(url, description); message.textContent = "图片已插入，可继续编辑正文。"; }
        catch (error) { message.textContent = error.message; }
      });
    }
    async function uploadImage(file) {
      if (uploading) { message.textContent = "图片正在上传，请稍候。"; return; }
      if (!file || !["image/jpeg", "image/png", "image/webp"].includes(file.type)) {
        message.textContent = "请选择 JPG、PNG 或 WebP 图片。"; return;
      }
      if (!file.size || file.size > 10 * 1024 * 1024) { message.textContent = "图片大小需在 10 MiB 以内。"; return; }
      if (surface.querySelectorAll("img").length >= 30) { message.textContent = "每篇正文最多添加 30 张图片。"; return; }
      const csrf = form.elements.namedItem("csrf");
      if (!csrf) { message.textContent = "登录信息已失效，请刷新页面后重试。"; return; }
      const insertionRange = savedRange && savedRange.cloneRange();
      const controller = new AbortController();
      const timer = window.setTimeout(() => controller.abort(), 60000);
      uploading = true;
      if (imageUploadButton) { imageUploadButton.disabled = true; imageUploadButton.setAttribute("aria-busy", "true"); }
      message.textContent = "正在上传图片……";
      try {
        const response = await fetch("/admin/api/images", {
          method: "POST", credentials: "same-origin",
          headers: { "Content-Type": file.type, "Accept": "application/json", "X-CSRF-Token": csrf.value },
          body: file, signal: controller.signal
        });
        let result;
        try { result = await response.json(); } catch (_) { throw new Error("无法读取上传结果，请稍后重试。"); }
        if (!result || typeof result !== "object" || Array.isArray(result)) throw new Error("无法读取上传结果，请稍后重试。");
        if (!response.ok) throw new Error(typeof result.error === "string" ? result.error : "图片上传失败，请重试。");
        const url = imageURL(result.url);
        if (!url) throw new Error("上传结果缺少有效的图片地址，请重试。");
        savedRange = insertionRange;
        insertImage(url, "正文图片", result);
        message.textContent = "图片已上传并插入，保存草稿后保留在正文中。";
      } catch (error) {
        message.textContent = error.name === "AbortError" ? "图片上传超时，请重试。" : (error.message || "图片上传失败，请重试。");
      } finally {
        window.clearTimeout(timer);
        uploading = false;
        if (imageUploadButton) { imageUploadButton.disabled = false; imageUploadButton.removeAttribute("aria-busy"); }
        if (imageFile) imageFile.value = "";
      }
    }
    if (imageUploadButton && imageFile) {
      imageUploadButton.addEventListener("mousedown", event => { event.preventDefault(); rememberSelection(); });
      imageUploadButton.addEventListener("click", () => imageFile.click());
      imageFile.addEventListener("change", () => { if (imageFile.files[0]) uploadImage(imageFile.files[0]); });
    }
    surface.addEventListener("paste", event => {
      const clipboard = event.clipboardData;
      event.preventDefault();
      if (!clipboard) {
        message.textContent = "暂时无法读取粘贴内容，请重试或手动输入正文。";
        return;
      }
      const image = Array.from(clipboard.files).find(file => file.type.startsWith("image/"));
      if (image) { rememberSelection(); uploadImage(image); return; }
      const html = clipboard.getData("text/html");
      if (html) {
        document.execCommand("insertHTML", false, cleanHTML(html));
      } else {
        document.execCommand("insertText", false, clipboard.getData("text/plain"));
      }
      sync();
      rememberSelection();
      message.textContent = "已粘贴正文和 HTTPS 图片，外部样式不会保留。";
    });
    surface.addEventListener("drop", event => {
      event.preventDefault();
      message.textContent = "请使用“上传图片”添加本地图片，或粘贴正文。";
    });
    surface.addEventListener("input", () => { sync(); rememberSelection(); updateToolbar(); });
    surface.addEventListener("keyup", () => { rememberSelection(); updateToolbar(); });
    surface.addEventListener("mouseup", () => { rememberSelection(); updateToolbar(); });
    surface.addEventListener("blur", sync);
    document.addEventListener("selectionchange", () => { rememberSelection(); updateToolbar(); });
    form.addEventListener("submit", event => {
      if (uploading || surface.querySelectorAll("img").length > 30) {
        event.preventDefault();
        message.textContent = uploading ? "请等待图片上传完成后再保存。" : "每篇正文最多添加 30 张图片，请移除多余图片。";
      }
      sync();
    });
    surface.innerHTML = cleanHTML(surface.innerHTML);
    surface.setAttribute("role", "textbox");
    surface.setAttribute("aria-multiline", "true");
    editor.hidden = false;
    const fallback = form.querySelector("[data-plain-fallback]");
    if (fallback) fallback.hidden = true;
    sync();
  }

  function setupReferences(form) {
    const list = form.querySelector("[data-reference-list]");
    const add = form.querySelector("[data-add-reference]");
    if (!list || !add) return;
    function rows() { return Array.from(list.querySelectorAll("[data-reference-row]")); }
    function update() { add.disabled = rows().length >= 30; }
    function newRow() {
      const row = document.createElement("div");
      row.className = "reference-row";
      row.dataset.referenceRow = "";
      for (const [name, title, type] of [["referenceTitle", "来源标题", "text"], ["referenceURL", "HTTPS 链接", "url"]]) {
        const label = document.createElement("label");
        const caption = document.createElement("span");
        caption.className = "field-label";
        caption.textContent = title;
        const input = document.createElement("input");
        input.name = name;
        input.type = type;
        input.maxLength = name === "referenceTitle" ? 300 : 2000;
        if (type === "url") { input.placeholder = "https://"; input.inputMode = "url"; }
        label.append(caption, input);
        row.append(label);
      }
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "button quiet button-icon";
      remove.dataset.removeReference = "";
      remove.textContent = "移除";
      remove.setAttribute("aria-label", "移除此条参考来源");
      row.append(remove);
      return row;
    }
    add.type = "button";
    add.addEventListener("click", () => {
      if (rows().length >= 30) return;
      const row = newRow();
      list.append(row);
      update();
      row.querySelector("input").focus();
    });
    list.addEventListener("click", event => {
      const button = event.target.closest("[data-remove-reference]");
      if (!button || !list.contains(button)) return;
      const row = button.closest("[data-reference-row]");
      if (!row) return;
      if (rows().length === 1) {
        row.querySelectorAll("input").forEach(input => { input.value = ""; });
        row.querySelector("input").focus();
      } else {
        const next = row.nextElementSibling || row.previousElementSibling;
        row.remove();
        if (next) next.querySelector("input").focus();
      }
      update();
    });
    if (!rows().length) list.append(newRow());
    list.querySelectorAll("[data-remove-reference]").forEach(button => { button.type = "button"; });
    update();
  }

  function setupMedia(form) {
    const inspect = form.querySelector("[data-inspect-media]");
    const status = form.querySelector("[data-media-status]");
    const audioURL = form.elements.namedItem("audioURL");
    const albumID = form.elements.namedItem("albumID");
    const csrf = form.elements.namedItem("csrf");
    if (!inspect || !status || !audioURL || !albumID || !csrf) return;
    const names = ["title", "summary", "durationSeconds", "fileVersion", "byteSize", "sha256", "owner", "source", "license", "expiresAt"];
    const dirty = new Set();
    const lastAuto = new Map();
    let controller = null;
    let generation = 0;
    let attemptedKey = "";
    let pendingKey = "";
    let lastFilledURL = "";
    inspect.type = "button";
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");
    for (const name of names) {
      const field = form.elements.namedItem(name);
      if (!field) continue;
      const edited = () => { dirty.add(name); };
      field.addEventListener("input", edited);
      field.addEventListener("change", edited);
    }
    function cancel() {
      generation += 1;
      if (controller) controller.abort();
      controller = null;
      pendingKey = "";
      inspect.disabled = false;
      inspect.removeAttribute("aria-busy");
    }
    function fill(name, value) {
      const field = form.elements.namedItem(name);
      if (!field || dirty.has(name) || value === undefined || value === null || value === "") return false;
      if (typeof value !== "string" && typeof value !== "number") return false;
      if (typeof value === "number" && !Number.isFinite(value)) return false;
      const fileFact = ["durationSeconds", "fileVersion", "byteSize", "sha256"].includes(name);
      if (!fileFact && field.value.trim() && field.value !== lastAuto.get(name)) return false;
      field.value = String(value);
      lastAuto.set(name, field.value);
      return true;
    }
    async function run(manual = false) {
      if (!albumID.value) {
        if (manual) status.textContent = "请先选择所属专辑，再读取音频信息。";
        return;
      }
      const url = httpsURL(audioURL.value);
      if (!url) {
        if (manual || audioURL.value.trim()) status.textContent = "请先填写有效的 HTTPS 音频地址。";
        return;
      }
      const key = albumID.value + "\n" + url;
      if (pendingKey === key || (!manual && attemptedKey === key)) return;
      cancel();
      const current = generation;
      const requestController = new AbortController();
      controller = requestController;
      pendingKey = key;
      attemptedKey = key;
      inspect.disabled = true;
      inspect.setAttribute("aria-busy", "true");
      status.textContent = "正在读取音频信息并校验文件，请稍候……";
      let timedOut = false;
      const timer = window.setTimeout(() => { timedOut = true; requestController.abort(); }, 65000);
      try {
        const response = await fetch("/admin/api/media/inspect", {
          method: "POST",
          credentials: "same-origin",
          headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": csrf.value },
          body: JSON.stringify({ url }),
          signal: requestController.signal
        });
        let metadata;
        try { metadata = await response.json(); } catch (_) { throw new Error("服务返回的内容无法读取，请稍后重试。"); }
        if (!response.ok) {
          const reason = metadata && (metadata.error || metadata.message);
          throw new Error(typeof reason === "string" ? reason : "音频信息读取失败，请检查地址后重试。");
        }
        if (current !== generation || albumID.value + "\n" + httpsURL(audioURL.value) !== key) return;
        if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) throw new Error("音频信息格式无效，请稍后重试。");
        let filled = 0;
        for (const name of names.slice(0, 6)) filled += Number(fill(name, metadata[name]));
        const copyright = metadata.copyright && typeof metadata.copyright === "object" ? metadata.copyright : metadata;
        for (const name of names.slice(6)) filled += Number(fill(name, copyright[name]));
        lastFilledURL = url;
        const missingRights = ["owner", "source", "license"].some(name => {
          const field = form.elements.namedItem(name);
          return field && !field.value.trim();
        });
        status.textContent = (filled ? "读取完成，已填写 " + filled + " 项信息；已有内容和手动修改已保留。" : "读取完成；已有内容和手动修改已保留。")
          + (missingRights ? "音频标签未提供完整版权信息，请自行补充权利人、来源和许可；永久授权的有效期可留空。" : "请核对版权信息及授权范围后保存。")
          + "识别结果均可继续编辑。";
      } catch (error) {
        if (current !== generation) return;
        status.textContent = timedOut ? "读取超过 65 秒，请稍后点击“读取音频信息”重试。" : error.name === "AbortError" ? "本次读取已取消。" : (error.message || "音频信息读取失败，请稍后重试。");
      } finally {
        window.clearTimeout(timer);
        if (current === generation) {
          controller = null;
          pendingKey = "";
          inspect.disabled = false;
          inspect.removeAttribute("aria-busy");
        }
      }
    }
    inspect.addEventListener("click", () => { run(true); });
    audioURL.addEventListener("input", () => {
      if (controller) { cancel(); status.textContent = "音频地址已更改，离开输入框后将重新读取。"; }
      if (lastFilledURL && httpsURL(audioURL.value) !== lastFilledURL) {
        for (const [name, value] of lastAuto) {
          const field = form.elements.namedItem(name);
          if (field && !dirty.has(name) && field.value === value) field.value = "";
        }
        lastAuto.clear();
        lastFilledURL = "";
        attemptedKey = "";
        status.textContent = "音频地址已更改，原先自动读取的信息已清除；离开输入框后将重新读取。";
      }
    });
    audioURL.addEventListener("change", () => { run(); });
    audioURL.addEventListener("blur", () => { run(); });
    albumID.addEventListener("change", () => { cancel(); if (audioURL.value.trim()) run(); });
    form.addEventListener("submit", cancel);
  }

  function initialize() {
    document.querySelectorAll("form[data-content-editor]").forEach(form => { setupRichEditor(form); setupReferences(form); });
    document.querySelectorAll("form[data-media-editor]").forEach(setupMedia);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initialize, { once: true });
  else initialize();
})();
