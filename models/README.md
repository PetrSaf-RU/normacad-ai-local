# Models

Файлы весов Qwen не лежат в репозитории: модель весит несколько гигабайт, а GitHub не подходит для хранения таких артефактов.

Для локального запуска используйте Ollama:

```powershell
.\models\ollama-pull.ps1
```

По умолчанию будут загружены:

- `qwen2.5-coder:7b` — основной текстовый и code/file model
- `qwen2.5vl:7b` — fallback для изображений без OCR

Проверка GPU:

```powershell
ollama ps
```

В колонке `PROCESSOR` желательно видеть `100% GPU`.
