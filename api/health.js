module.exports = (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json({ ok: true, key: !!process.env.ELEVENLABS_API_KEY, voice: process.env.ELEVENLABS_VOICE_ID || 'default' });
};
