<?php
header("Content-Type: application/json; charset=UTF-8");
header("Access-Control-Allow-Origin: *");

$trackers = [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://tracker.openbittorrent.com:6969/announce"
];

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

function fetchPirateBay($imdbId) {
    $url = "https://apibay.org/q.php?q=" . urlencode($imdbId);
    $ctx = stream_context_create(["http" => ["timeout" => 5, "header" => "User-Agent: ZyPlayer\r\n"]]);
    $json = @file_get_contents($url, false, $ctx);
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
    $url = "https://yts.mx/api/v2/list_movies.json?query_term=" . urlencode($imdbId);
    $ctx = stream_context_create(["http" => ["timeout" => 5, "header" => "User-Agent: ZyPlayer\r\n"]]);
    $json = @file_get_contents($url, false, $ctx);
    if (!$json) return [];

    $data = json_decode($json, true);
    $movie = $data['data']['movies'][0] ?? null;
    if (!$movie || !isset($movie['torrents'])) return [];

    $streams = [];
    foreach ($movie['torrents'] as $t) {
        $streams[] = [
            "name" => "ZyPlayer\n" . $t['quality'],
            "title" => $movie['title'] . " [" . $t['quality'] . " " . strtoupper($t['type']) . "]\n💾 " . $t['size'] . "  👤 " . $t['seeds'] . "  ⚙️ YTS",
            "infoHash" => strtolower($t['hash']),
            "fileIdx" => 0
        ];
    }
    return $streams;
}

$yts = fetchYTS($imdbId);
$pb = fetchPirateBay($imdbId);
$all = array_merge($yts, $pb);

echo json_encode(["streams" => $all]);
