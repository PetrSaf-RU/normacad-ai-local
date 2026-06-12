const form = document.querySelector("#askForm");
const fileInput = document.querySelector("#fileInput");
const dropzone = document.querySelector("#dropzone");
const fileTitle = document.querySelector("#fileTitle");
const fileMeta = document.querySelector("#fileMeta");
const localPathInput = document.querySelector("#localPathInput");
const statusLine = document.querySelector("#statusLine");
const statusText = document.querySelector("#statusText");
const answerText = document.querySelector("#answerText");
const filesList = document.querySelector("#filesList");
const sourcesList = document.querySelector("#sourcesList");
const modelName = document.querySelector("#modelName");
const serverPill = document.querySelector("#serverPill");
const submitButton = document.querySelector(".submit-button");
const taskProgress = document.querySelector("#taskProgress");
const progressFill = document.querySelector("#progressFill");
const progressLabel = document.querySelector("#progressLabel");
const progressValue = document.querySelector("#progressValue");

let idleTimer = null;
let progressTimer = null;
let currentProgress = 0;
const idleDelay = 5 * 60 * 1000;

function getCookie(name) {
    const value = `; ${document.cookie}`;
    const parts = value.split(`; ${name}=`);
    if (parts.length === 2) {
        return parts.pop().split(";").shift();
    }
    return "";
}

function setStatus(mode, text, animated = false) {
    statusLine.className = `status-line ${mode}`;
    statusText.textContent = text;
    statusText.classList.toggle("typing", animated);
}

function resetIdleTimer() {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
        answerText.textContent = "";
        renderFiles([]);
        renderSources([]);
        setStatus("waiting", "Ожидание запроса");
        resetProgress();
        modelName.textContent = "qwen2.5-coder:7b";
    }, idleDelay);
}

function setLoading() {
    answerText.textContent = "";
    renderFiles([]);
    renderSources([]);
    setStatus("loading", "Ожидание ответа", true);
    startProgress();
    submitButton.disabled = true;
}

function setProgress(percent, label, state = "active") {
    currentProgress = Math.max(0, Math.min(100, percent));
    progressFill.style.width = `${currentProgress}%`;
    progressValue.textContent = `${Math.round(currentProgress)}%`;
    progressLabel.textContent = label;
    taskProgress.classList.toggle("is-active", state === "active");
    taskProgress.classList.toggle("is-complete", state === "complete");
    taskProgress.classList.toggle("is-error", state === "error");
}

function resetProgress() {
    clearInterval(progressTimer);
    progressTimer = null;
    setProgress(0, "Готов к запуску", "idle");
}

function progressStage(percent) {
    if (percent < 18) {
        return "Подготовка запроса";
    }
    if (percent < 36) {
        return "Чтение файлов и источников";
    }
    if (percent < 58) {
        return "Отправка в Ollama";
    }
    if (percent < 84) {
        return "Qwen обрабатывает задачу";
    }
    return "Сбор ответа и файлов";
}

function startProgress() {
    clearInterval(progressTimer);
    setProgress(4, "Подготовка запроса", "active");

    progressTimer = setInterval(() => {
        if (currentProgress >= 92) {
            setProgress(92, "Ожидание завершения генерации", "active");
            return;
        }

        const step = Math.max(0.6, (92 - currentProgress) * 0.045);
        const nextProgress = Math.min(92, currentProgress + step);
        setProgress(nextProgress, progressStage(nextProgress), "active");
    }, 650);
}

function finishProgress(success, label) {
    clearInterval(progressTimer);
    progressTimer = null;
    setProgress(success ? 100 : Math.max(currentProgress, 100), label, success ? "complete" : "error");
}

function formatBytes(bytes) {
    if (!bytes) {
        return "0 Б";
    }

    const units = ["Б", "КБ", "МБ", "ГБ"];
    let size = bytes;
    let unitIndex = 0;

    while (size >= 1024 && unitIndex < units.length - 1) {
        size /= 1024;
        unitIndex += 1;
    }

    return `${size.toFixed(size >= 10 || unitIndex === 0 ? 0 : 1)} ${units[unitIndex]}`;
}

function renderFiles(files) {
    filesList.innerHTML = "";

    if (!files || files.length === 0) {
        filesList.innerHTML = '<span class="empty-state">Файлы появятся здесь после генерации</span>';
        return;
    }

    files.forEach((file) => {
        const link = document.createElement("a");
        link.className = "file-link";
        link.href = file.url;
        link.download = file.name;
        link.title = file.name;
        link.innerHTML = `
            <strong>${escapeHtml(file.name)}</strong>
            <span class="file-size">${formatBytes(file.size)}</span>
        `;
        filesList.appendChild(link);
    });
}

function renderSources(sources) {
    sourcesList.innerHTML = "";

    if (!sources || sources.length === 0) {
        sourcesList.innerHTML = '<span class="empty-state">Нет источников</span>';
        return;
    }

    sources.forEach((source) => {
        const item = document.createElement("div");
        item.className = "source-chip";
        const kind = source.kind === "local_path" ? "локальный путь" : "загрузка";
        const media = source.is_image ? " · изображение" : "";
        const vision = source.vision_width && source.vision_height
            ? ` · vision ${source.vision_width}×${source.vision_height}`
            : "";
        const ocr = source.ocr_chars ? ` · OCR ${source.ocr_chars} зн.` : "";
        const suffix = source.truncated ? " · фрагмент" : "";
        item.innerHTML = `
            <strong>${escapeHtml(source.name)}</strong>
            <small>${escapeHtml(kind)} · ${formatBytes(source.size)}${media}${vision}${ocr}${suffix}</small>
        `;
        sourcesList.appendChild(item);
    });
}

function escapeHtml(value) {
    return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#039;");
}

function updateFileLabel() {
    const file = fileInput.files[0];

    if (!file) {
        fileTitle.textContent = "Загрузить файл";
        fileMeta.textContent = "текстовый файл или изображение для OCR";
        return;
    }

    fileTitle.textContent = file.name;
    fileMeta.textContent = formatBytes(file.size);
}

fileInput.addEventListener("change", updateFileLabel);

["dragenter", "dragover"].forEach((eventName) => {
    dropzone.addEventListener(eventName, (event) => {
        event.preventDefault();
        dropzone.classList.add("is-dragging");
    });
});

["dragleave", "drop"].forEach((eventName) => {
    dropzone.addEventListener(eventName, () => {
        dropzone.classList.remove("is-dragging");
    });
});

dropzone.addEventListener("drop", (event) => {
    event.preventDefault();
    if (event.dataTransfer.files.length > 0) {
        fileInput.files = event.dataTransfer.files;
        updateFileLabel();
    }
});

form.addEventListener("submit", async (event) => {
    event.preventDefault();
    clearTimeout(idleTimer);
    setLoading();

    try {
        const formData = new FormData(form);
        const response = await fetch("/api/ask/", {
            method: "POST",
            headers: {
                "X-CSRFToken": getCookie("csrftoken"),
            },
            body: formData,
        });

        let data = {};
        try {
            data = await response.json();
        } catch {
            data = { error: "Сервер вернул ошибку без JSON. Проверьте, что файл считался и Qwen запущен." };
        }

        if (!response.ok) {
            throw new Error(data.error || "Не удалось получить ответ.");
        }

        answerText.textContent = data.answer || "Готово.";
        renderFiles(data.files);
        renderSources(data.sources);
        modelName.textContent = data.model || "qwen2.5-coder:7b";
        serverPill.innerHTML = `<span class="live-dot"></span> Ollama · ${escapeHtml(data.server.replace("http://", ""))}`;
        finishProgress(true, "Задача выполнена");
        setStatus("done", "Ответ получен");
    } catch (error) {
        answerText.textContent = error.message;
        renderFiles([]);
        renderSources([]);
        finishProgress(false, "Задача завершилась ошибкой");
        setStatus("error", "Ошибка");
    } finally {
        submitButton.disabled = false;
        resetIdleTimer();
    }
});

localPathInput.addEventListener("input", () => {
    if (localPathInput.value.trim()) {
        fileMeta.textContent = "будет добавлен локальный путь";
    } else {
        updateFileLabel();
    }
});

resetIdleTimer();
