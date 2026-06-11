# NormaCAD AI Local C#

Локальный тестовый стенд для проверки совместимости сайта с C# backend, Ollama/Qwen, OCR и базой ГОСТ/ЕСКД.

Проект сделан как ASP.NET Core Minimal API + статичный frontend. Он принимает промт, файл или путь к файлу на компьютере, отправляет задачу локальной модели Qwen через Ollama и возвращает текст ответа плюс сгенерированные файлы.

## Возможности

- C# / ASP.NET Core сайт на `http://127.0.0.1:8000`
- локальная модель через Ollama, без OpenAI API
- загрузка файла через сайт
- чтение файла по локальному пути
- OCR изображений через Tesseract
- progress bar выполнения задачи
- режим `режим философа`
- генерация `.txt`, `.py`, `.json`, `.md`, `.csv` и других текстовых файлов в ответе
- отдельный блок для сгенерированных файлов
- кастомные ошибки вместо голой 500
- SQLite FTS база ГОСТ/ЕСКД для RAG-подсказок
- best-effort поддержка файлов КОМПАС-3D и hook для экспорта через COM API

## Требования

- Windows 10/11
- .NET SDK 10
- Ollama
- Tesseract OCR
- OCR словари `rus.traineddata`, `eng.traineddata`, `osd.traineddata`
- опционально: КОМПАС-3D с COM API для экспорта `.cdw/.frw/.m3d` в PDF

## Установка .NET

## Быстрая установка

Репозиторий включает исходники, OCR-словари и установщик локальных моделей.
Запустите PowerShell:

```powershell
git clone https://github.com/PetrSaf-RU/normacad-ai-local.git
cd normacad-ai-local
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1
.\start.ps1
```

`setup.ps1`:

1. Устанавливает недостающие .NET 10, Ollama и Tesseract через `winget`.
2. Загружает части Qwen из GitHub Release `models-v1`.
3. Проверяет SHA-256 и восстанавливает локальное хранилище Ollama.
4. Собирает C# backend.

Необходимо около 15 ГБ свободного места. После установки сайт и AI работают
локально; облачные API не используются.

Альтернатива без model release:

```powershell
.\setup.ps1 -UseOllamaRegistry
```

В этом режиме модели загружаются командой `ollama pull`.

```powershell
winget install Microsoft.DotNet.SDK.10
```

Проверка:

```powershell
dotnet --info
```

## Установка Ollama и Qwen

Установите Ollama:

```powershell
winget install Ollama.Ollama
```

Загрузите модели:

```powershell
.\models\ollama-pull.ps1
```

По умолчанию используются:

- `qwen2.5-coder:7b` — основной текстовый model
- `qwen2.5vl:7b` — fallback для изображений без OCR

Весовые файлы Qwen опубликованы как разбитые assets в GitHub Release
`models-v1`, поскольку Git не принимает файлы больше 100 МБ. Скрипт
`models/install-local-ai.ps1` собирает их локально. Скрипт
`models/ollama-pull.ps1` остается запасным способом установки.

Для GPU на Windows можно задать переменные окружения перед запуском Ollama:

```powershell
setx OLLAMA_LLM_LIBRARY cuda_v13
setx OLLAMA_FLASH_ATTENTION true
setx OLLAMA_KV_CACHE_TYPE q8_0
setx OLLAMA_MAX_LOADED_MODELS 1
```

Проверка загрузки на GPU:

```powershell
ollama ps
```

В колонке `PROCESSOR` желательно видеть `100% GPU`.

## Tesseract OCR

Установите Tesseract:

```powershell
winget install UB-Mannheim.TesseractOCR
```

Положите OCR словари сюда:

```text
ocr\tessdata
```

Нужные OCR-словари уже включены в репозиторий:

```text
eng.traineddata
rus.traineddata
osd.traineddata
```

Backend сначала ищет словари в `ocr\tessdata` внутри репозитория. Для совместимости с исходной рабочей папкой также поддерживается путь `..\ocr\tessdata`.

## Запуск сайта

```powershell
dotnet restore
dotnet run --urls http://127.0.0.1:8000
```

Откройте:

```text
http://127.0.0.1:8000/
```

Проверка health endpoint:

```powershell
Invoke-WebRequest http://127.0.0.1:8000/api/health -UseBasicParsing
```

## API

`POST /api/ask/` принимает `multipart/form-data`:

- `prompt` — текст запроса
- `file` — загружаемый файл
- `local_path` — путь к файлу на компьютере
- `philosopher_mode` — `1` или `0`

Пример:

```powershell
curl.exe -X POST `
  -F "prompt=Создай файл answer.txt с одной строкой Hello" `
  http://127.0.0.1:8000/api/ask/
```

Ответ:

```json
{
  "model": "qwen2.5-coder:7b",
  "server": "http://127.0.0.1:11434",
  "answer": "Готово.",
  "files": [
    {
      "name": "answer.txt",
      "url": "/media/generated/...",
      "size": 6
    }
  ],
  "sources": [],
  "philosopher_mode": false
}
```

## База ГОСТ/ЕСКД

В проект добавлен локальный RAG-слой на SQLite FTS.

Папки:

- `standards/catalog/eskd_manifest.csv` — стартовый каталог ключевых ЕСКД/СПДС стандартов
- `standards/catalog/download_manifest.csv` — список легальных прямых ссылок для загрузки документов
- `standards/inbox` — сюда кладутся PDF/TXT/DOCX/HTML/DXF с текстами стандартов
- `standards/db/normacad_standards.sqlite` — локальная база, генерируется автоматически

Импорт документов:

```powershell
.\tools\import-standards.ps1
```

Импорт конкретной папки:

```powershell
.\tools\import-standards.ps1 -Path "D:\GOST"
```

Статус базы:

```powershell
Invoke-WebRequest http://127.0.0.1:8000/api/standards/status -UseBasicParsing
```

Если есть легальные прямые ссылки на документы, добавьте их в `standards/catalog/download_manifest.csv`, затем:

```powershell
.\tools\download-standards.ps1
.\tools\import-standards.ps1
```

Важно: репозиторий не содержит полные тексты ГОСТов. Используйте только документы, которые у вас есть право хранить и индексировать.

## КОМПАС-3D

Нативные файлы `.cdw`, `.frw`, `.spw`, `.m3d`, `.a3d` являются закрытыми бинарными форматами. Backend делает best-effort извлечение видимых текстовых строк из бинарника, но для полноценного анализа лучше экспортировать чертеж в PDF/DXF/изображение.

Если установлен КОМПАС-3D с COM API:

```powershell
.\tools\kompas-export.ps1 -SourcePath "D:\drawings\part.cdw"
```

После экспорта PDF можно отправить через сайт или положить в `standards/inbox` для индексации.

## Структура

```text
Program.cs                  ASP.NET Core endpoints, OCR, Ollama bridge
StandardsService.cs          SQLite FTS база ГОСТ/ЕСКД
wwwroot/                     frontend
tools/                       automation scripts
models/                      Ollama model pull script
standards/catalog/           manifests
standards/inbox/             local standards input folder
training-pipeline/            local two-model dataset preparation and review
compat/legacy-ai-json-v2/     schema v2 adapter for older local AI installs
```

## JSON v2 и совместимость со старой локальной ИИ

Актуальный pipeline формирует нормализованные коллекции `reports`, `drawings`,
`entities`, `dimensions`, `issues` и `uncertainties`. Все дочерние записи
связаны через `report_id`, а каждое предполагаемое нарушение требует проверки
человеком.

Старые веса Qwen переобучать не обязательно. Папка
`compat/legacy-ai-json-v2` содержит prompt-шаблон и PowerShell-адаптер, который
вызывает старую Ollama vision-модель и преобразует прежний вложенный ответ в
JSON v2. Инструкции находятся в
`compat/legacy-ai-json-v2/README.md`.

## Публикация на GitHub

```powershell
git init
git add .
git commit -m "Initial NormaCAD AI local C# prototype"
gh auth login
gh repo create normacad-ai-local --public --source . --remote origin --push
```
