// Shared helpers for the ElevenLabs proxies (tts.js, sfx.js). Not an endpoint (leading underscore).
const sleep = ms => new Promise(r => setTimeout(r, ms));

// POST to ElevenLabs; on 429 (free tier allows 2 concurrent requests) wait and retry a few times.
async function post(url, key, body) {
  let r;
  for (let i = 0; i < 4; i++) {
    r = await fetch(url, {
      method: 'POST',
      headers: { 'xi-api-key': key, 'Content-Type': 'application/json', 'Accept': 'audio/mpeg' },
      body: JSON.stringify(body)
    });
    if (r.status !== 429) return r;
    await sleep(900 * (i + 1) + Math.random() * 500);
  }
  return r;
}

async function fail(r) {
  const e = new Error('elevenlabs ' + r.status);
  e.status = r.status;
  e.detail = await r.text();
  throw e;
}

// Serve one cached audio clip. `make` generates the Buffer; the promise is cached so that
// concurrent requests on a warm instance trigger a single generation.
async function serve(res, cache, k, make) {
  let p = cache.get(k);
  if (!p) { p = make(); cache.set(k, p); p.catch(() => cache.delete(k)); }
  try {
    const buf = await p;
    res.setHeader('Content-Type', 'audio/mpeg');
    // Vercel CDN + browser cache: the same clip never goes back to ElevenLabs
    res.setHeader('Cache-Control', 'public, max-age=31536000, s-maxage=31536000, immutable');
    res.status(200).send(buf);
  } catch (e) {
    res.setHeader('Cache-Control', 'no-store');
    res.status(502).json({ error: e.message, detail: e.detail || String(e) });
  }
}

module.exports = { post, fail, serve };
