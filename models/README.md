# Models

NormaCAD AI использует две локальные модели:

- `qwen2.5-coder:7b` — текст, код и содержимое файлов;
- `qwen2.5vl:7b` — изображения и технические чертежи.

Большие model blobs опубликованы в GitHub Release `models-v1`. Они разбиты
на части меньше лимита GitHub Release и восстанавливаются установщиком с
обязательной проверкой SHA-256:

```powershell
.\models\install-local-ai.ps1
```

Установщик не обращается к облачному AI API. После установки inference
выполняется локально через Ollama.

Альтернативная установка напрямую из Ollama Registry:

```powershell
.\models\ollama-pull.ps1
```

Для создания нового model release из уже установленного Ollama:

```powershell
.\tools\package-ollama-models.ps1
gh release create models-v1 .\release-assets\* `
  --repo PetrSaf-RU/normacad-ai-local `
  --title "NormaCAD AI local models"
```

Проверка GPU:

```powershell
ollama ps
```

В колонке `PROCESSOR` желательно видеть `100% GPU`.
