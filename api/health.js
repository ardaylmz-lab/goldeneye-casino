module.exports = (req, res) => res.status(200).json({ ok: true, key: !!process.env.ELEVENLABS_API_KEY });
