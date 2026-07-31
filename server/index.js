const express = require('express');
const cors = require('cors');

const app = express();
app.use(cors());
app.use(express.json());

const PORT = process.env.PORT || 7000;

const TRACKERS = [
  "udp://tracker.opentrackr.org:1337/announce",
  "udp://open.demonii.com:1337/announce",
  "udp://open.stealth.si:80/announce",
  "udp://tracker.torrent.eu.org:451/announce",
  "udp://exodus.desync.com:6969/announce",
  "udp://tracker.openbittorrent.com:6969/announce"
];

const TRACKERS_QUERY = TRACKERS.map(t => "tr=" + encodeURIComponent(t)).join("&");

// Manifest (Stremio Addon Standard)
app.get('/manifest.json', (req, res) => {
  res.json({
    id: "org.zyplayer.torrent",
    version: "1.0.0",
    name: "ZyPlayer Self-Hosted Torrent Provider",
    description: "Özel sunucu üzerinden YTS ve PirateBay torrent akışları",
    resources: ["stream"],
    types: ["movie", "series"],
    idPrefixes: ["tt"]
  });
});

// PirateBay Scraper API (apibay.org)
async function fetchPirateBay(imdbId) {
  try {
    const response = await fetch(`https://apibay.org/q.php?q=${imdbId}`);
    if (!response.ok) return [];
    const data = await response.json();
    if (!Array.isArray(data)) return [];

    return data
      .filter(item => item.name !== "No results found" && item.info_hash)
      .map(item => {
        const sizeMB = (parseInt(item.size) / (1024 * 1024)).toFixed(1);
        const seeds = parseInt(item.seeders) || 0;
        return {
          name: "ZyPlayer\n1080p",
          title: `${item.name}\n💾 ${sizeMB} MB  👤 ${seeds}  ⚙️ PirateBay`,
          infoHash: item.info_hash.toLowerCase(),
          fileIdx: 0
        };
      });
  } catch (err) {
    return [];
  }
}

// YTS Scraper API (yts.mx)
async function fetchYTS(imdbId) {
  try {
    const response = await fetch(`https://yts.mx/api/v2/list_movies.json?query_term=${imdbId}`);
    if (!response.ok) return [];
    const data = await response.json();
    const movie = data?.data?.movies?.[0];
    if (!movie || !movie.torrents) return [];

    return movie.torrents.map(t => {
      return {
        name: `ZyPlayer\n${t.quality}`,
        title: `${movie.title} [${t.quality} ${t.type.toUpperCase()}]\n💾 ${t.size}  👤 ${t.seeds}  ⚙️ YTS`,
        infoHash: t.hash.toLowerCase(),
        fileIdx: 0
      };
    });
  } catch (err) {
    return [];
  }
}

// Movie Endpoint
app.get('/stream/movie/:imdbId.json', async (req, res) => {
  const imdbId = req.params.imdbId.replace('.json', '');
  
  try {
    const [pbStreams, ytsStreams] = await Promise.all([
      fetchPirateBay(imdbId),
      fetchYTS(imdbId)
    ]);

    const allStreams = [...ytsStreams, ...pbStreams];
    res.json({ streams: allStreams });
  } catch (err) {
    res.json({ streams: [] });
  }
});

// Series Endpoint
app.get('/stream/series/:query.json', async (req, res) => {
  const query = req.params.query.replace('.json', '');
  const imdbId = query.split(':')[0];

  try {
    const streams = await fetchPirateBay(imdbId);
    res.json({ streams });
  } catch (err) {
    res.json({ streams: [] });
  }
});

app.get('/', (req, res) => {
  res.send('ZyPlayer Torrent Server is Running! Use /manifest.json in ZyPlayer settings.');
});

app.listen(PORT, () => {
  console.log(`ZyPlayer Torrent Server running on http://localhost:${PORT}`);
});
