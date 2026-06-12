using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;
using UglyToad.PdfPig;

sealed class StandardsService
{
    private const int ChunkSize = 2_400;
    private const int ChunkOverlap = 260;
    private const int ContextMaxChars = 6_500;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly string _root;
    private readonly string _inbox;
    private readonly string _catalog;
    private readonly string _dbPath;
    private bool _ready;

    public StandardsService(IWebHostEnvironment environment)
    {
        _root = Path.Combine(environment.ContentRootPath, "standards");
        _inbox = Path.Combine(_root, "inbox");
        _catalog = Path.Combine(_root, "catalog");
        _dbPath = Path.Combine(_root, "db", "normacad_standards.sqlite");
    }

    public async Task<StandardsStatusDto> GetStatusAsync()
    {
        await EnsureReadyAsync();
        await using var connection = OpenConnection();
        var catalogCount = await ScalarLongAsync(connection, "SELECT COUNT(*) FROM standards");
        var fullTextCount = await ScalarLongAsync(connection, "SELECT COUNT(*) FROM standards WHERE has_full_text = 1");
        var chunkCount = await ScalarLongAsync(connection, "SELECT COUNT(*) FROM standards_fts");
        return new StandardsStatusDto(_dbPath, _inbox, catalogCount, fullTextCount, chunkCount);
    }

    public async Task<StandardsImportResultDto> ImportAsync(string? path = null)
    {
        await EnsureReadyAsync();
        var importPath = string.IsNullOrWhiteSpace(path) ? _inbox : Environment.ExpandEnvironmentVariables(path.Trim().Trim('"', '\''));
        if (!Path.IsPathRooted(importPath))
        {
            importPath = Path.GetFullPath(Path.Combine(_inbox, importPath));
        }

        if (!Directory.Exists(importPath) && !File.Exists(importPath))
        {
            return new StandardsImportResultDto(importPath, 0, 0, 0, [$"Путь не найден: {importPath}"]);
        }

        var files = File.Exists(importPath)
            ? [importPath]
            : Directory.EnumerateFiles(importPath, "*", SearchOption.AllDirectories)
                .Where(IsSupportedDocument)
                .ToArray();

        var imported = 0;
        var skipped = 0;
        var errors = new List<string>();

        foreach (var file in files)
        {
            try
            {
                var changed = await ImportFileAsync(file);
                if (changed) imported++;
                else skipped++;
            }
            catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or SqliteException)
            {
                errors.Add($"{Path.GetFileName(file)}: {error.Message}");
            }
        }

        return new StandardsImportResultDto(importPath, files.Length, imported, skipped, errors);
    }

    public async Task<string> BuildContextAsync(string prompt, IReadOnlyCollection<FileInfoModel> files)
    {
        await EnsureReadyAsync();
        var query = BuildSearchQuery(prompt, files);
        var hits = await SearchAsync(query, 7);
        if (hits.Count == 0)
        {
            return "";
        }

        var builder = new StringBuilder();
        builder.AppendLine("Релевантные фрагменты локальной базы ГОСТ/ЕСКД. Используй только как справочник; если пункта нет в базе, прямо так и скажи.");
        for (var i = 0; i < hits.Count; i++)
        {
            var hit = hits[i];
            var text = hit.Text.Length > 1_100 ? hit.Text[..1_100].TrimEnd() + "..." : hit.Text;
            builder.AppendLine();
            builder.AppendLine($"[{i + 1}] {hit.Code} — {hit.Title}");
            builder.AppendLine($"Источник: {hit.Source}");
            builder.AppendLine(text);
            if (builder.Length > ContextMaxChars)
            {
                break;
            }
        }

        return builder.ToString();
    }

    public async Task<List<StandardSearchHitDto>> SearchAsync(string query, int limit = 8)
    {
        await EnsureReadyAsync();
        var matchQuery = ToFtsQuery(query);
        if (string.IsNullOrWhiteSpace(matchQuery))
        {
            return [];
        }

        await using var connection = OpenConnection();
        try
        {
            await using var command = connection.CreateCommand();
            command.CommandText = """
                SELECT standard_id, chunk_index, code, title, text, bm25(standards_fts) AS score
                FROM standards_fts
                WHERE standards_fts MATCH $query
                ORDER BY score
                LIMIT $limit
                """;
            command.Parameters.AddWithValue("$query", matchQuery);
            command.Parameters.AddWithValue("$limit", limit);
            return await ReadHitsAsync(command, connection);
        }
        catch (SqliteException)
        {
            return await SearchLikeAsync(connection, query, limit);
        }
    }

    private async Task EnsureReadyAsync()
    {
        if (_ready)
        {
            return;
        }

        await _gate.WaitAsync();
        try
        {
            if (_ready)
            {
                return;
            }

            Directory.CreateDirectory(_inbox);
            Directory.CreateDirectory(_catalog);
            Directory.CreateDirectory(Path.GetDirectoryName(_dbPath)!);

            await using var connection = OpenConnection();
            await ExecuteAsync(connection, """
                CREATE TABLE IF NOT EXISTS standards (
                    id TEXT PRIMARY KEY,
                    code TEXT NOT NULL,
                    title TEXT NOT NULL,
                    source_path TEXT,
                    source_url TEXT,
                    content_hash TEXT,
                    has_full_text INTEGER NOT NULL DEFAULT 0,
                    imported_at TEXT NOT NULL
                );
                """);
            await EnsureColumnAsync(connection, "standards", "status", "TEXT NOT NULL DEFAULT 'unknown'");
            await EnsureColumnAsync(connection, "standards", "source_kind", "TEXT NOT NULL DEFAULT 'unknown'");
            await EnsureColumnAsync(connection, "standards", "verified_at", "TEXT");
            await EnsureColumnAsync(connection, "standards", "scope", "TEXT");
            await EnsureColumnAsync(connection, "standards", "keywords", "TEXT");
            await ExecuteAsync(connection, """
                CREATE VIRTUAL TABLE IF NOT EXISTS standards_fts USING fts5(
                    standard_id UNINDEXED,
                    chunk_index UNINDEXED,
                    code,
                    title,
                    text,
                    tokenize = 'unicode61'
                );
                """);

            await SeedCatalogAsync(connection);
            _ready = true;
        }
        finally
        {
            _gate.Release();
        }
    }

    private SqliteConnection OpenConnection()
    {
        var connection = new SqliteConnection($"Data Source={_dbPath}");
        connection.Open();
        return connection;
    }

    private async Task SeedCatalogAsync(SqliteConnection connection)
    {
        var manifest = Path.Combine(_catalog, "eskd_manifest.csv");
        if (!File.Exists(manifest))
        {
            return;
        }

        var lines = await File.ReadAllLinesAsync(manifest, Encoding.UTF8);
        foreach (var line in lines.Skip(1))
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            var cells = SplitCsv(line);
            if (cells.Count < 2)
            {
                continue;
            }

            var code = cells[0].Trim();
            var title = cells[1].Trim();
            var url = cells.Count > 2 ? cells[2].Trim() : "";
            var status = cells.Count > 3 ? cells[3].Trim() : "unknown";
            var scope = cells.Count > 4 ? cells[4].Trim() : "";
            var keywords = cells.Count > 5 ? cells[5].Trim() : "";
            var verifiedAt = cells.Count > 6 ? cells[6].Trim() : "";
            if (string.IsNullOrWhiteSpace(code) || string.IsNullOrWhiteSpace(title))
            {
                continue;
            }

            var id = "catalog:" + Sha256Text(code.ToUpperInvariant());
            await using var command = connection.CreateCommand();
            command.CommandText = """
                INSERT INTO standards (
                    id, code, title, source_path, source_url, content_hash,
                    has_full_text, imported_at, status, source_kind,
                    verified_at, scope, keywords
                )
                VALUES (
                    $id, $code, $title, NULL, $url, '', 0, $imported_at,
                    $status, 'rosstandart_catalog', $verified_at, $scope, $keywords
                )
                ON CONFLICT(id) DO UPDATE SET
                    code = excluded.code,
                    title = excluded.title,
                    source_url = excluded.source_url,
                    status = excluded.status,
                    source_kind = excluded.source_kind,
                    verified_at = excluded.verified_at,
                    scope = excluded.scope,
                    keywords = excluded.keywords
                """;
            command.Parameters.AddWithValue("$id", id);
            command.Parameters.AddWithValue("$code", code);
            command.Parameters.AddWithValue("$title", title);
            command.Parameters.AddWithValue("$url", string.IsNullOrWhiteSpace(url) ? DBNull.Value : url);
            command.Parameters.AddWithValue("$status", string.IsNullOrWhiteSpace(status) ? "unknown" : status);
            command.Parameters.AddWithValue("$scope", string.IsNullOrWhiteSpace(scope) ? DBNull.Value : scope);
            command.Parameters.AddWithValue("$keywords", string.IsNullOrWhiteSpace(keywords) ? DBNull.Value : keywords);
            command.Parameters.AddWithValue("$verified_at", string.IsNullOrWhiteSpace(verifiedAt) ? DBNull.Value : verifiedAt);
            command.Parameters.AddWithValue("$imported_at", DateTimeOffset.UtcNow.ToString("O"));
            await command.ExecuteNonQueryAsync();

            await using var deleteMetadata = connection.CreateCommand();
            deleteMetadata.CommandText = "DELETE FROM standards_fts WHERE standard_id = $id AND chunk_index = -1";
            deleteMetadata.Parameters.AddWithValue("$id", id);
            await deleteMetadata.ExecuteNonQueryAsync();

            var metadataText = $"""
                Официальная карточка Росстандарта. Статус: {status}.
                Область применения: {scope}
                Ключевые слова: {keywords}
                Полный текст в локальную базу не импортирован. Номера пунктов и конкретные нормативные требования по этой записи подтверждать нельзя.
                """;
            await using var insertMetadata = connection.CreateCommand();
            insertMetadata.CommandText = """
                INSERT INTO standards_fts (standard_id, chunk_index, code, title, text)
                VALUES ($id, -1, $code, $title, $text)
                """;
            insertMetadata.Parameters.AddWithValue("$id", id);
            insertMetadata.Parameters.AddWithValue("$code", code);
            insertMetadata.Parameters.AddWithValue("$title", title);
            insertMetadata.Parameters.AddWithValue("$text", metadataText);
            await insertMetadata.ExecuteNonQueryAsync();
        }
    }

    private static async Task EnsureColumnAsync(
        SqliteConnection connection,
        string table,
        string column,
        string definition)
    {
        await using var check = connection.CreateCommand();
        check.CommandText = $"PRAGMA table_info({table})";
        await using var reader = await check.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            if (string.Equals(reader.GetString(1), column, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
        }

        await reader.CloseAsync();
        await ExecuteAsync(connection, $"ALTER TABLE {table} ADD COLUMN {column} {definition}");
    }

    private async Task<bool> ImportFileAsync(string file)
    {
        var hash = await Sha256FileAsync(file);
        var id = "file:" + Sha256Text(Path.GetFullPath(file).ToUpperInvariant());

        await using var connection = OpenConnection();
        await using (var existing = connection.CreateCommand())
        {
            existing.CommandText = "SELECT content_hash FROM standards WHERE id = $id AND has_full_text = 1";
            existing.Parameters.AddWithValue("$id", id);
            var oldHash = await existing.ExecuteScalarAsync() as string;
            if (oldHash == hash)
            {
                return false;
            }
        }

        var extracted = await ExtractTextAsync(file);
        if (string.IsNullOrWhiteSpace(extracted.Text))
        {
            throw new InvalidDataException("не удалось извлечь текст");
        }

        var (code, title) = InferCodeAndTitle(file, extracted.Text);
        await using var transaction = await connection.BeginTransactionAsync();
        await using (var delete = connection.CreateCommand())
        {
            delete.Transaction = (SqliteTransaction)transaction;
            delete.CommandText = "DELETE FROM standards_fts WHERE standard_id = $id";
            delete.Parameters.AddWithValue("$id", id);
            await delete.ExecuteNonQueryAsync();
        }

        await using (var upsert = connection.CreateCommand())
        {
            upsert.Transaction = (SqliteTransaction)transaction;
            upsert.CommandText = """
                INSERT INTO standards (id, code, title, source_path, source_url, content_hash, has_full_text, imported_at)
                VALUES ($id, $code, $title, $path, NULL, $hash, 1, $imported_at)
                ON CONFLICT(id) DO UPDATE SET
                    code = excluded.code,
                    title = excluded.title,
                    source_path = excluded.source_path,
                    content_hash = excluded.content_hash,
                    has_full_text = 1,
                    imported_at = excluded.imported_at
                """;
            upsert.Parameters.AddWithValue("$id", id);
            upsert.Parameters.AddWithValue("$code", code);
            upsert.Parameters.AddWithValue("$title", title);
            upsert.Parameters.AddWithValue("$path", file);
            upsert.Parameters.AddWithValue("$hash", hash);
            upsert.Parameters.AddWithValue("$imported_at", DateTimeOffset.UtcNow.ToString("O"));
            await upsert.ExecuteNonQueryAsync();
        }

        var chunks = Chunk(extracted.Text);
        for (var i = 0; i < chunks.Count; i++)
        {
            await using var insertChunk = connection.CreateCommand();
            insertChunk.Transaction = (SqliteTransaction)transaction;
            insertChunk.CommandText = """
                INSERT INTO standards_fts (standard_id, chunk_index, code, title, text)
                VALUES ($id, $chunk, $code, $title, $text)
                """;
            insertChunk.Parameters.AddWithValue("$id", id);
            insertChunk.Parameters.AddWithValue("$chunk", i);
            insertChunk.Parameters.AddWithValue("$code", code);
            insertChunk.Parameters.AddWithValue("$title", title);
            insertChunk.Parameters.AddWithValue("$text", chunks[i]);
            await insertChunk.ExecuteNonQueryAsync();
        }

        await transaction.CommitAsync();
        return true;
    }

    private static async Task<ExtractedText> ExtractTextAsync(string path)
    {
        var extension = Path.GetExtension(path).ToLowerInvariant();
        return extension switch
        {
            ".pdf" => new ExtractedText(ExtractPdfText(path), "pdf"),
            ".docx" => new ExtractedText(ExtractDocxText(path), "docx"),
            ".html" or ".htm" => new ExtractedText(StripHtml(await File.ReadAllTextAsync(path)), "html"),
            ".txt" or ".md" or ".csv" or ".dxf" or ".xml" or ".json" => new ExtractedText(await File.ReadAllTextAsync(path, DetectEncoding(path)), extension.TrimStart('.')),
            ".cdw" or ".frw" or ".spw" or ".m3d" or ".a3d" or ".dwg" => new ExtractedText(ExtractBinaryStrings(await File.ReadAllBytesAsync(path)), "binary-probe"),
            _ => new ExtractedText("", "unsupported")
        };
    }

    private static Encoding DetectEncoding(string path)
    {
        using var stream = File.OpenRead(path);
        Span<byte> bom = stackalloc byte[4];
        var read = stream.Read(bom);
        if (read >= 3 && bom[0] == 0xEF && bom[1] == 0xBB && bom[2] == 0xBF) return Encoding.UTF8;
        if (read >= 2 && bom[0] == 0xFF && bom[1] == 0xFE) return Encoding.Unicode;
        if (read >= 2 && bom[0] == 0xFE && bom[1] == 0xFF) return Encoding.BigEndianUnicode;
        return Encoding.UTF8;
    }

    private static string ExtractPdfText(string path)
    {
        var builder = new StringBuilder();
        using var document = PdfDocument.Open(path);
        foreach (var page in document.GetPages())
        {
            builder.AppendLine($"[стр. {page.Number}]");
            builder.AppendLine(page.Text);
            builder.AppendLine();
        }

        return CleanText(builder.ToString());
    }

    private static string ExtractDocxText(string path)
    {
        using var archive = ZipFile.OpenRead(path);
        var entry = archive.GetEntry("word/document.xml");
        if (entry is null)
        {
            return "";
        }

        using var stream = entry.Open();
        using var reader = new StreamReader(stream, Encoding.UTF8);
        var xml = reader.ReadToEnd()
            .Replace("</w:p>", "\n", StringComparison.OrdinalIgnoreCase)
            .Replace("<w:tab/>", "\t", StringComparison.OrdinalIgnoreCase);
        return CleanText(WebUtility.HtmlDecode(Regex.Replace(xml, "<[^>]+>", " ")));
    }

    private static string StripHtml(string html)
    {
        var withoutScripts = Regex.Replace(html, "<(script|style)[\\s\\S]*?</\\1>", " ", RegexOptions.IgnoreCase);
        return CleanText(WebUtility.HtmlDecode(Regex.Replace(withoutScripts, "<[^>]+>", " ")));
    }

    private static string ExtractBinaryStrings(byte[] bytes)
    {
        var builder = new StringBuilder();
        var ascii = Regex.Matches(Encoding.Latin1.GetString(bytes), @"[\p{L}\p{N}\s.,:;№°+\-_/\\()]{5,}");
        foreach (Match match in ascii.Take(1_500))
        {
            var value = CleanText(match.Value);
            if (value.Length >= 5)
            {
                builder.AppendLine(value);
            }
        }

        if (bytes.Length >= 2)
        {
            var unicode = Regex.Matches(Encoding.Unicode.GetString(bytes), @"[\p{L}\p{N}\s.,:;№°+\-_/\\()]{5,}");
            foreach (Match match in unicode.Take(1_500))
            {
                var value = CleanText(match.Value);
                if (value.Length >= 5)
                {
                    builder.AppendLine(value);
                }
            }
        }

        return CleanText(builder.ToString());
    }

    private static (string Code, string Title) InferCodeAndTitle(string path, string text)
    {
        var filename = Path.GetFileNameWithoutExtension(path).Replace('_', ' ');
        var joined = filename + "\n" + text[..Math.Min(text.Length, 2_000)];
        var match = Regex.Match(joined, @"ГОСТ\s*Р?\s*\d+(?:\.\d+)*(?:-\d{2,4})?", RegexOptions.IgnoreCase);
        var code = match.Success ? Regex.Replace(match.Value, "\\s+", " ").Trim().ToUpperInvariant() : filename;
        var title = filename;
        var firstTextLine = text.Split('\n').Select(line => line.Trim()).FirstOrDefault(line => line.Length is > 12 and < 180);
        if (!string.IsNullOrWhiteSpace(firstTextLine) && !firstTextLine.Contains("ГОСТ", StringComparison.OrdinalIgnoreCase))
        {
            title = firstTextLine;
        }

        return (code, title);
    }

    private static List<string> Chunk(string text)
    {
        text = CleanText(text);
        var result = new List<string>();
        for (var start = 0; start < text.Length; start += Math.Max(1, ChunkSize - ChunkOverlap))
        {
            var length = Math.Min(ChunkSize, text.Length - start);
            if (length < 180 && result.Count > 0)
            {
                break;
            }

            result.Add(text.Substring(start, length).Trim());
        }

        return result;
    }

    private static string BuildSearchQuery(string prompt, IReadOnlyCollection<FileInfoModel> files)
    {
        var builder = new StringBuilder();
        builder.AppendLine(prompt);
        builder.AppendLine("ЕСКД ГОСТ чертеж размеры предельные отклонения шероховатость линии шрифт масштаб форматы основная надпись технические требования КОМПАС-3D");
        foreach (var file in files)
        {
            builder.AppendLine(file.Name);
            if (!string.IsNullOrWhiteSpace(file.OcrText))
            {
                builder.AppendLine(file.OcrText[..Math.Min(file.OcrText.Length, 1_800)]);
            }
            else if (!string.IsNullOrWhiteSpace(file.Text))
            {
                builder.AppendLine(file.Text[..Math.Min(file.Text.Length, 1_800)]);
            }
        }

        return builder.ToString();
    }

    private static string ToFtsQuery(string query)
    {
        var words = Regex.Matches(query.ToLowerInvariant(), @"[\p{L}\p{N}]{3,}")
            .Select(match => match.Value)
            .Where(value => !StopWords.Contains(value))
            .Distinct()
            .Take(18)
            .Select(value => "\"" + value.Replace("\"", "\"\"") + "\"")
            .ToArray();

        return string.Join(" OR ", words);
    }

    private async Task<List<StandardSearchHitDto>> SearchLikeAsync(SqliteConnection connection, string query, int limit)
    {
        var term = Regex.Matches(query, @"[\p{L}\p{N}]{4,}")
            .Select(match => match.Value)
            .FirstOrDefault() ?? "ГОСТ";
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT standard_id, chunk_index, code, title, text, 0.0 AS score
            FROM standards_fts
            WHERE text LIKE $query OR title LIKE $query OR code LIKE $query
            LIMIT $limit
            """;
        command.Parameters.AddWithValue("$query", "%" + term + "%");
        command.Parameters.AddWithValue("$limit", limit);
        return await ReadHitsAsync(command, connection);
    }

    private static async Task<List<StandardSearchHitDto>> ReadHitsAsync(SqliteCommand command, SqliteConnection connection)
    {
        var hits = new List<StandardSearchHitDto>();
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var standardId = reader.GetString(0);
            var source = await GetSourceAsync(connection, standardId);
            hits.Add(new StandardSearchHitDto(
                standardId,
                reader.GetInt32(1),
                reader.GetString(2),
                reader.GetString(3),
                reader.GetString(4),
                source,
                reader.GetDouble(5)
            ));
        }

        return hits;
    }

    private static async Task<string> GetSourceAsync(SqliteConnection connection, string standardId)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT COALESCE(source_path, source_url, '') FROM standards WHERE id = $id";
        command.Parameters.AddWithValue("$id", standardId);
        return (await command.ExecuteScalarAsync()) as string ?? "";
    }

    private static async Task ExecuteAsync(SqliteConnection connection, string sql)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        await command.ExecuteNonQueryAsync();
    }

    private static async Task<long> ScalarLongAsync(SqliteConnection connection, string sql)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        var value = await command.ExecuteScalarAsync();
        return Convert.ToInt64(value);
    }

    private static bool IsSupportedDocument(string file)
    {
        var extension = Path.GetExtension(file).ToLowerInvariant();
        return SupportedExtensions.Contains(extension);
    }

    private static async Task<string> Sha256FileAsync(string path)
    {
        await using var stream = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(stream);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static string Sha256Text(string text)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static string CleanText(string text)
    {
        text = text.Replace('\0', ' ');
        text = Regex.Replace(text, "[ \\t\\r\\f\\v]+", " ");
        text = Regex.Replace(text, "\\n\\s+", "\n");
        text = Regex.Replace(text, "\\n{3,}", "\n\n");
        return text.Trim();
    }

    private static List<string> SplitCsv(string line)
    {
        var result = new List<string>();
        var builder = new StringBuilder();
        var quoted = false;
        for (var i = 0; i < line.Length; i++)
        {
            var ch = line[i];
            if (ch == '"')
            {
                if (quoted && i + 1 < line.Length && line[i + 1] == '"')
                {
                    builder.Append('"');
                    i++;
                }
                else
                {
                    quoted = !quoted;
                }
                continue;
            }

            if (ch == ',' && !quoted)
            {
                result.Add(builder.ToString());
                builder.Clear();
                continue;
            }

            builder.Append(ch);
        }

        result.Add(builder.ToString());
        return result;
    }

    private static readonly HashSet<string> SupportedExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".pdf", ".txt", ".md", ".html", ".htm", ".docx", ".csv", ".dxf", ".xml", ".json",
        ".cdw", ".frw", ".spw", ".m3d", ".a3d", ".dwg"
    };

    private static readonly HashSet<string> StopWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "для", "или", "при", "что", "это", "как", "все", "без", "под", "над", "the", "and", "with", "this", "that"
    };
}

sealed record ExtractedText(string Text, string Kind);

sealed record StandardsStatusDto(
    [property: JsonPropertyName("db_path")] string DbPath,
    [property: JsonPropertyName("inbox_path")] string InboxPath,
    [property: JsonPropertyName("catalog_records")] long CatalogRecords,
    [property: JsonPropertyName("full_text_records")] long FullTextRecords,
    [property: JsonPropertyName("chunks")] long Chunks
);

sealed record StandardsImportResultDto(
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("scanned")] int Scanned,
    [property: JsonPropertyName("imported")] int Imported,
    [property: JsonPropertyName("skipped")] int Skipped,
    [property: JsonPropertyName("errors")] List<string> Errors
);

sealed record StandardSearchHitDto(
    [property: JsonPropertyName("standard_id")] string StandardId,
    [property: JsonPropertyName("chunk_index")] int ChunkIndex,
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("title")] string Title,
    [property: JsonPropertyName("text")] string Text,
    [property: JsonPropertyName("source")] string Source,
    [property: JsonPropertyName("score")] double Score
);
