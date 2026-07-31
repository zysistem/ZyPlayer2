<?php
header("Content-Type: application/json; charset=UTF-8");
header("Access-Control-Allow-Origin: *");

$uri = $_SERVER['REQUEST_URI'];
$imdbId = "";

if (preg_match('/tt\d+/', $uri, $matches)) {
    $imdbId = $matches[0];
} elseif (isset($_GET['imdb'])) {
    $imdbId = $_GET['imdb'];
}

if (empty($imdbId)) {
    echo json_encode([
        "status" => "online",
        "message" => "ZyPlayer Self-Hosted PHP Torrent Server is Running!",
        "usage" => "https://zysistem.net/server/stream/movie/{imdbId}.json"
    ]);
    exit;
}

function httpGet($url) {
    $ch = curl_init();
    curl_setopt($ch, CURLOPT_URL, $url);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
    curl_setopt($ch, CURLOPT_TIMEOUT, 6);
    curl_setopt($ch, CURLOPT_USERAGENT, "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
    $data = curl_exec($ch);
    curl_close($ch);
    return $data;
}

function fetchPirateBay($imdbId) {
    $json = httpGet("https://apibay.org/q.php?q=" . urlencode($imdbId));
    if (!$json) return [];
    
    $data = json_decode($json, true);
    if (!is_array($data)) return [];

    $streams = [];
    foreach ($data as $item) {
        if (!isset($item['info_hash']) || empty($item['info_hash']) || $item['name'] === "No results found") continue;
        
        $sizeMB = round((int)$item['size'] / (1024 * 1024), 1);
        $seeds = (int)$item['seeders'];
        
        $streams[] = [
            "name" => "ZyPlayer\n1080p",
            "title" => $item['name'] . "\n💾 {$sizeMB} MB  👤 {$seeds}  ⚙️ PirateBay",
            "infoHash" => strtolower($item['info_hash']),
            "fileIdx" => 0
        ];
    }
    return $streams;
}

function fetchYTS($imdbId) {
    $urls = [
        "https://yts.mx/api/v2/list_movies.json?query_term=" . urlencode($imdbId),
        "https://yts.lt/api/v2/list_movies.json?query_term=" . urlencode($imdbId),
        "https://yts.rs/api/v2/list_movies.json?query_term=" . urlencode($imdbId)
    ];

    foreach ($urls as $url) {
        $json = httpGet($url);
        if (!$json) continue;

        $data = json_decode($json, true);
        $movie = $data['data']['movies'][0] ?? null;
        if (!$movie || !isset($movie['torrents'])) continue;

        $streams = [];
        foreach ($movie['torrents'] as $t) {
            $streams[] = [
                "name" => "ZyPlayer\n" . $t['quality'],
                "title" => $movie['title'] . " [" . $t['quality'] . " " . strtoupper($t['type']) . "]\n💾 " . $t['size'] . "  👤 " . $t['seeds'] . "  ⚙️ YTS",
                "infoHash" => strtolower($t['hash']),
                "fileIdx" => 0
            ];
        }
        if (!empty($streams)) return $streams;
    }
    return [];
}

function fetchEZTV($imdbId) {
    $numericId = preg_replace('/[^\d]/', '', $imdbId);
    if (empty($numericId)) return [];

    $urls = [
        "https://eztvx.to/api/get-torrents?imdb_id=" . $numericId,
        "https://eztv.re/api/get-torrents?imdb_id=" . $numericId,
        "https://eztv.wf/api/get-torrents?imdb_id=" . $numericId
    ];

    foreach ($urls as $url) {
        $json = httpGet($url);
        if (!$json) continue;

        $data = json_decode($json, true);
        $torrents = $data['torrents'] ?? [];
        if (!is_array($torrents) || empty($torrents)) continue;

        $streams = [];
        foreach (array_slice($torrents, 0, 20) as $item) {
            if (!isset($item['hash']) || empty($item['hash'])) continue;

            $sizeMB = round((int)($item['size_bytes'] ?? 0) / (1024 * 1024), 1);
            $seeds = (int)($item['seeds'] ?? 0);

            $streams[] = [
                "name" => "ZyPlayer\nTV",
                "title" => ($item['title'] ?? 'EZTV') . "\n💾 {$sizeMB} MB  👤 {$seeds}  ⚙️ EZTV",
                "infoHash" => strtolower($item['hash']),
                "fileIdx" => 0
            ];
        }
        if (!empty($streams)) return $streams;
    }
    return [];
}

$yts = fetchYTS($imdbId);
$pb = fetchPirateBay($imdbId);
$eztv = fetchEZTV($imdbId);

$all = array_merge($yts, $pb, $eztv);

echo json_encode(["streams" => $all]);
