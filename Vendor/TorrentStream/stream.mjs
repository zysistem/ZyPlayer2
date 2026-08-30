// ZyPlayer torrent stream helper.
//
// Streams one torrent over local HTTP so mpv can play it while it downloads.
// Everything lands in --dir, which the app wipes when it quits.
//
// Speaks one JSON object per line on stdout:
//   {"event":"ready","url":...,"name":...,"length":...}   server is up
//   {"event":"playable"}                                  head + tail buffered
//   {"event":"progress","progress":0..1,"downloaded":N,"speed":N,"peers":N,
//    "buffer":0..1}
//   {"event":"warn","message":...}                        survived a library error
//   {"event":"error","message":...}                       fatal
import dns from 'node:dns'
import dnsPromises from 'node:dns/promises'
import WebTorrent from 'webtorrent'

// Some ISPs hijack or sinkhole DNS for tracker/DHT-bootstrap hostnames rather
// than blocking the IPs outright — the symptom is a swarm that reports peers
// (their fake/dead ones) but never yields a byte. Resolving those hostnames
// straight against public resolvers instead of the OS/ISP one sidesteps that.
// `dns.lookup` is what `net`/`http`/the tracker & DHT libraries actually call,
// so it — not just `setServers` — is what needs overriding; `dns.resolve*`
// alone would miss anything that resolves through the OS path.
dns.setServers(['1.1.1.1', '8.8.8.8', '9.9.9.9'])
const trustedResolve = (hostname) => new Promise((resolve, reject) => {
  dns.resolve4(hostname, (err4, addrs4) => {
    if (!err4 && addrs4?.length) return resolve({ address: addrs4[0], family: 4 })
    dns.resolve6(hostname, (err6, addrs6) => {
      if (!err6 && addrs6?.length) return resolve({ address: addrs6[0], family: 6 })
      reject(err4 || err6 || new Error(`DNS: ${hostname} çözülemedi`))
    })
  })
})
const osLookup = dns.lookup.bind(dns)
dns.lookup = (hostname, options, callback) => {
  if (typeof options === 'function') { callback = options; options = {} }
  const wantedFamily = typeof options === 'number' ? options : options?.family
  trustedResolve(hostname)
    .then(({ address, family }) => callback(null, address, wantedFamily || family))
    .catch(() => osLookup(hostname, options, callback)) // offline/unreachable resolver: fall back rather than fail outright
}
dnsPromises.lookup = (hostname, options) => new Promise((resolve, reject) => {
  dns.lookup(hostname, options || {}, (err, address, family) => {
    if (err) reject(err); else resolve({ address, family })
  })
})

// The magnet/torrent's own tracker list is sometimes thin or half-dead, which
// leaves the swarm mostly (or entirely) made of unresponsive peers — visible
// as a nonzero peer count that never turns into downloaded bytes. Widening
// discovery with a curated set of healthy public trackers gives the client a
// real shot at finding peers that actually answer piece requests.
const EXTRA_TRACKERS = [
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.stealth.si:80/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://explodie.org:6969/announce',
  'udp://tracker.dler.org:6969/announce',
  'udp://open.demonii.com:1337/announce',
  'udp://tracker-udp.gbitt.info:80/announce',
  'http://tracker.openbittorrent.com:80/announce',
  'https://tracker.gbitt.info:443/announce'
]

const argv = process.argv.slice(2)
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`)
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : fallback
}

const torrentID = arg('torrent')
const dir = arg('dir')
const port = Number(arg('port', '0'))
/** Which file to play. Season packs hold a whole series, so "the biggest file"
 *  would play the wrong episode; the index comes from the torrent index. */
const fileIndexArg = arg('file-index')
const fileIndex = fileIndexArg === undefined ? null : Number(fileIndexArg)

const say = (obj) => {
  try { process.stdout.write(JSON.stringify(obj) + '\n') } catch {}
}

if (!torrentID || !dir) {
  say({ event: 'error', message: 'missing --torrent or --dir' })
  process.exit(1)
}

// The player is the only client and it reconnects on its own, so a stray error
// from a socket or a library tick must never take the process down: dying
// mid-playback strands mpv on a dead port with nothing to report.
process.on('uncaughtException', (err) => {
  say({ event: 'warn', message: String(err?.stack || err) })
})
process.on('unhandledRejection', (err) => {
  say({ event: 'warn', message: String(err?.stack || err) })
})

const VIDEO = /\.(mkv|mp4|m4v|avi|mov|webm|ts|m2ts|flv|wmv|mpg|mpeg|ogv)$/i

/** Head buffer: enough for the demuxer probe plus a few seconds of playback. */
const HEAD_BYTES = 8 * 1024 * 1024
/** Tail buffer: mp4 keeps its `moov` atom at the end and ffmpeg cannot start
 *  without it — sequential download would reach it last, i.e. never. */
const TAIL_BYTES = 4 * 1024 * 1024
/** How long the tail may hold up the head before we give up on it. The player
 *  asks for that range itself when it needs it, and the server serves it with
 *  priority, so waiting longer than this costs more than it saves. */
const TAIL_DEADLINE_MS = 30_000

const client = new WebTorrent()
client.on('error', (err) => say({ event: 'error', message: String(err?.message || err) }))

// `assumeEmpty` is a ZyPlayer patch and it is required, not an optimisation.
// Without it WebTorrent hashes every piece of the freshly allocated 2 GB file on
// add, and that pass discards the pieces the download is filling in — the
// buffered count climbs and falls for ever and playback never starts. The cache
// directory is created empty for every stream, so there is nothing to verify.
const torrent = client.add(torrentID, {
  path: dir,
  strategy: 'sequential',
  assumeEmpty: true,
  announce: EXTRA_TRACKERS
})
torrent.on('error', (err) => say({ event: 'error', message: String(err?.message || err) }))

let announcedPlayable = false
/** Piece ranges to watch, filled in once the metadata is here. */
let headRange = null
let tailRange = null
let deadlinePassed = false

/** How many pieces of an inclusive range are verified and on disk. */
const have = (range) => {
  if (!range) return 0
  let count = 0
  for (let i = range[0]; i <= range[1]; i++) if (torrent.bitfield.get(i)) count++
  return count
}

const size = (range) => (range ? range[1] - range[0] + 1 : 0)

torrent.on('ready', () => {
  const picked = Number.isInteger(fileIndex) ? torrent.files[fileIndex] : null
  const video = picked
    || torrent.files
      .filter((f) => VIDEO.test(f.name))
      .sort((a, b) => b.length - a.length)[0]
    || torrent.files[0]

  if (!video) {
    say({ event: 'error', message: 'torrent has no playable file' })
    process.exit(1)
  }

  // Nothing is wanted yet. The tail is claimed first below; the rest of the
  // file is only selected once that is in.
  for (const file of torrent.files) file.deselect()

  const server = client.createServer({}, 'node')
  server.server.on('error', (err) => say({ event: 'error', message: String(err?.message || err) }))
  // An aborted range request (mpv seeks constantly) surfaces as a socket error.
  server.server.on('connection', (socket) => socket.on('error', () => {}))
  server.server.on('clientError', (_err, socket) => socket.destroy())

  server.server.listen(port, '127.0.0.1', () => {
    const bound = server.server.address().port
    say({
      event: 'ready',
      url: `http://127.0.0.1:${bound}${video.streamURL}`,
      name: video.name,
      length: video.length
    })
  })

  const headEnd = Math.min(HEAD_BYTES, video.length) - 1
  const tailStart = Math.max(headEnd + 1, video.length - TAIL_BYTES)
  const pieceOf = (offset) => Math.floor((video.offset + offset) / torrent.pieceLength)

  headRange = [pieceOf(0), pieceOf(headEnd)]
  if (tailStart < video.length) tailRange = [pieceOf(tailStart), pieceOf(video.length - 1)]

  // Priorities, highest first: the tail, then the head, then the rest in order.
  //
  // The tail leads because mp4 keeps its `moov` atom at the end and ffmpeg
  // cannot start without it — the player's very first act is to seek there.
  // Under the sequential strategy every request slot otherwise goes to the
  // lowest missing piece, so the end of the file would arrive last, i.e. never.
  //
  // Progress is read off the bitfield rather than from a read stream:
  // `createReadStream` was seen delivering a trickle while the pieces it covers
  // were already verified and on disk, which stalled playback indefinitely.
  if (tailRange) {
    torrent.select(tailRange[0], tailRange[1], 10)
    torrent.critical(tailRange[0], tailRange[1])
  }
  torrent.select(headRange[0], headRange[1], 5)
  torrent.critical(headRange[0], headRange[1])
  video.select()

  // A tail that will not come must not hold playback hostage for ever.
  setTimeout(() => { deadlinePassed = true }, TAIL_DEADLINE_MS)
})

/// Announced from two places: the head stream ending, and the status tick
/// noticing the bytes are all in. The stream's own `end` cannot be relied on —
/// it has been seen delivering every byte and then staying open.
function announcePlayable () {
  if (announcedPlayable) return
  announcedPlayable = true
  say({ event: 'playable' })
}

/// Share of the pieces playback waits on that are verified: the head, plus the
/// tail until its deadline passes.
const bufferRatio = () => {
  const wanted = size(headRange) + (deadlinePassed ? 0 : size(tailRange))
  if (!wanted) return 0
  const got = have(headRange) + (deadlinePassed ? 0 : have(tailRange))
  return Math.min(got / wanted, 1)
}

/** Some swarms are mostly (or entirely) dead/poisoned peers that complete a
 *  handshake — so they count toward `numPeers` — but choke forever and never
 *  answer a piece request. Left alone, WebTorrent just sits on those
 *  connections. If nothing has been downloaded for a while despite having
 *  peers, drop every current wire: closed connections trigger WebTorrent's
 *  own reconnect/re-announce path (torrent.js `conn.on('close', ...)`), which
 *  gives the tracker/DHT swarm a chance to hand back a different peer set. */
const STALL_EVICT_MS = 20_000
let lastDownloaded = 0
let lastDownloadedAt = Date.now()

setInterval(() => {
  if (torrent.ready && headRange) {
    const headIn = have(headRange) === size(headRange)
    const tailIn = !tailRange || have(tailRange) === size(tailRange) || deadlinePassed
    if (headIn && tailIn) announcePlayable()

    if (torrent.downloaded !== lastDownloaded) {
      lastDownloaded = torrent.downloaded
      lastDownloadedAt = Date.now()
    } else if (!announcedPlayable && torrent.numPeers > 0 &&
      Date.now() - lastDownloadedAt > STALL_EVICT_MS) {
      say({ event: 'warn', message: `${torrent.numPeers} eş bağlı ama veri gelmiyor — bağlantılar yenileniyor.` })
      torrent.wires.slice().forEach((wire) => wire.destroy())
      lastDownloadedAt = Date.now()
    }
  }
  say({
    event: 'progress',
    progress: torrent.ready ? torrent.progress : 0,
    downloaded: torrent.ready ? torrent.downloaded : 0,
    speed: torrent.downloadSpeed || 0,
    peers: torrent.numPeers || 0,
    buffer: bufferRatio(),
    // Reported so a stall can be read straight off the log instead of guessed at.
    head: `${have(headRange)}/${size(headRange)}`,
    tail: `${have(tailRange)}/${size(tailRange)}`
  })
}, 700)

process.on('SIGTERM', () => process.exit(0))
process.on('SIGINT', () => process.exit(0))
