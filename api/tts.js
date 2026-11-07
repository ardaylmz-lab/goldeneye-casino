// Vercel serverless: ElevenLabs TTS proxy. Key never reaches the browser.
// Env: ELEVENLABS_API_KEY (required), ELEVENLABS_VOICE_ID (optional)
// Only the fixed phrases below can be synthesised; free text is deliberately not accepted.
const { post, fail, serve } = require('./_eleven');

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
const DEFAULT_VOICE = 'cgSgspJ2msm6clMCkdW9'; // Jessica (premade)
const cache = new Map();   // phrase -> Promise<Buffer> (warm-instance cache)
let workingVoice = null;   // voice id that this account is confirmed to be allowed to use

function tts(voice, text, key) {
  return post(`https://api.elevenlabs.io/v1/text-to-speech/${voice}?output_format=mp3_44100_128`, key, {
    text,
    model_id: 'eleven_multilingual_v2',
    voice_settings: { stability: 0.4, similarity_boost: 0.8, style: 0.6, use_speaker_boost: true }
  });
}

// If the preferred voice is not available on this account/plan, use the first voice the account can use.
async function fallbackVoice(key, avoid) {
  const r = await fetch('https://api.elevenlabs.io/v1/voices', { headers: { 'xi-api-key': key } });
  if (!r.ok) return null;
  const list = ((await r.json()).voices || []).filter(v => v.voice_id !== avoid);
  const v = list.find(x => x.category === 'premade') || list[0];
  return v ? v.voice_id : null;
}

async function make(k, key) {
  const text = PHRASES[k];
  const preferred = workingVoice || process.env.ELEVENLABS_VOICE_ID || DEFAULT_VOICE;
  let r = await tts(preferred, text, key);
  if (!r.ok && !workingVoice && [400, 402, 403, 404, 422].includes(r.status)) {
    const alt = await fallbackVoice(key, preferred);
    if (alt) { const r2 = await tts(alt, text, key); if (r2.ok) { workingVoice = alt; r = r2; } }
  }
  if (!r.ok) await fail(r);
  if (!workingVoice) workingVoice = preferred;
  return Buffer.from(await r.arrayBuffer());
}

module.exports = async (req, res) => {
  const k = String(req.query.k || '');
  if (!PHRASES[k]) return res.status(400).json({ error: 'unknown phrase' });
  const key = process.env.ELEVENLABS_API_KEY;
  if (!key) return res.status(500).json({ error: 'ELEVENLABS_API_KEY missing' });
  await serve(res, cache, k, () => make(k, key));
};
