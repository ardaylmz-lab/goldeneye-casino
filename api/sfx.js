// Vercel serverless: ElevenLabs Sound Effects proxy. Key never reaches the browser.
// Env: ELEVENLABS_API_KEY (required)
// Each effect is generated once and then cached by the Vercel CDN (immutable, 1 year).
// Bump AUD_V in index.html to force regeneration after changing a prompt.
const { post, fail, serve } = require('./_eleven');

const EFFECTS = {
  click:     { text: 'Short crisp casino slot machine button click, dry, no reverb', d: 0.5 },
  spin:      { text: 'Slot machine reels spinning, fast mechanical ticking whir, steady and even, seamless loop', d: 2, loop: true },
  stop:      { text: 'Single slot machine reel stopping with a heavy mechanical clunk and a short metallic click', d: 0.6 },
  scatter:   { text: 'Bright magical sparkle chime, quick ascending twinkle, casino bonus symbol landing', d: 1.2 },
  antic:     { text: 'Rising suspense drum roll with a tension riser, casino slot machine anticipation, building to a peak', d: 2.2 },
  win:       { text: 'Short cheerful slot machine win jingle, bright bells, quick ascending arpeggio', d: 1.4 },
  coin:      { text: 'Single gold coin dropping onto a pile of coins, short metallic clink', d: 0.5 },
  bigwin:    { text: 'Triumphant casino big win fanfare with brass, bells and coins pouring out, celebratory', d: 4 },
  freespins: { text: 'Exciting slot machine bonus trigger fanfare, magical chimes and a rising orchestral hit', d: 3 },
  lose:      { text: 'Soft low descending two note tone, subtle quiet slot machine near miss sound', d: 0.7 }
};
const cache = new Map(); // effect -> Promise<Buffer>

async function make(fx, key) {
  const r = await post('https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_128', key, {
    text: fx.text,
    duration_seconds: fx.d,
    prompt_influence: 0.6,   // consistent, prompt-faithful results
    loop: !!fx.loop,         // only honoured by eleven_text_to_sound_v2
    model_id: 'eleven_text_to_sound_v2'
  });
  if (!r.ok) await fail(r);
  return Buffer.from(await r.arrayBuffer());
}

module.exports = async (req, res) => {
  const k = String(req.query.k || '');
  const fx = EFFECTS[k];
  if (!fx) return res.status(400).json({ error: 'unknown effect' });
  const key = process.env.ELEVENLABS_API_KEY;
  if (!key) return res.status(500).json({ error: 'ELEVENLABS_API_KEY missing' });
  await serve(res, cache, k, () => make(fx, key));
};
