// Vercel serverless: ElevenLabs TTS proxy. Key never reaches the browser.
// Env: ELEVENLABS_API_KEY (required), ELEVENLABS_VOICE_ID (optional)
const PHRASES = {
  welcome:   'Welcome to Golden Eye.',
  luck:      'Good luck!',
  wild:      'Wild!',
  nice:      'Nice!',
  great:     'Great!',
  bigwin:    'Big win!',
  megawin:   'Mega win!',
  epicwin:   'Epic win!',
  freespins: 'Free spins!',
  bonus:     'Bonus!',
  jackpot:   'Jackpot!'
};
const cache = new Map(); // warm-instance cache

module.exports = async (req, res) => {
  const k = String(req.query.k || '');
  const text = PHRASES[k];
  if (!text) return res.status(400).json({ error: 'unknown phrase' });
  const key = process.env.ELEVENLABS_API_KEY;
  if (!key) return res.status(500).json({ error: 'ELEVENLABS_API_KEY missing' });
  const voice = process.env.ELEVENLABS_VOICE_ID || 'cgSgspJ2msm6clMCkdW9'; // Jessica

  let buf = cache.get(k);
  if (!buf) {
    const r = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${voice}?output_format=mp3_44100_128`, {
      method: 'POST',
      headers: { 'xi-api-key': key, 'Content-Type': 'application/json', 'Accept': 'audio/mpeg' },
      body: JSON.stringify({
        text,
        model_id: 'eleven_multilingual_v2',
        voice_settings: { stability: 0.4, similarity_boost: 0.8, style: 0.6, use_speaker_boost: true }
      })
    });
    if (!r.ok) return res.status(502).json({ error: 'elevenlabs ' + r.status, detail: await r.text() });
    buf = Buffer.from(await r.arrayBuffer());
    cache.set(k, buf);
  }
  res.setHeader('Content-Type', 'audio/mpeg');
  // Vercel edge + browser cache: aynı cümle bir daha ElevenLabs'e gitmez
  res.setHeader('Cache-Control', 'public, max-age=31536000, s-maxage=31536000, immutable');
  res.status(200).send(buf);
};
