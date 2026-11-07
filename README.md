# Golden Eye Casino 🎰

Arkadaşlar arası eğlence oyunu. **Sanal jeton kullanılır, gerçek para yoktur.**

- Slot (5x5, 20 hat, wild/scatter, free spin), Rulet, Blackjack
- `index.html` — oyunun tamamı (tek dosya)
- `api/tts.js` — ElevenLabs sesli anons proxy'si (Vercel serverless). Key sadece Vercel ortam değişkeninde durur.
- `api/sfx.js` — ElevenLabs ses efekti proxy'si (makara dönüşü, durma, scatter, gerilim, kazanç, coin, büyük kazanç, free spin, kayıp, tık). Her efekt bir kez üretilir, CDN'de 1 yıl önbellekte kalır. Efekt yüklenemezse oyun kendi sentez tonlarına döner.

## Vercel kurulumu
1. vercel.com → Add New → Project → bu repoyu import et → Deploy
2. Project → Settings → Environment Variables:
   - `ELEVENLABS_API_KEY` = ElevenLabs key'in
   - `ELEVENLABS_VOICE_ID` = (isteğe bağlı) ses ID'si; boş bırakılırsa "Jessica"
3. Redeploy. İlk açılışta efektler üretilir (10 efekt, ~16 sn ses, tek seferlik kredi). Efekt metinlerini değiştirirsen `index.html` içindeki `SFX_V` değerini artır ki önbellek yenilensin.
4. `https://<proje>.vercel.app/api/health` → `{"ok":true,"key":true}` görmelisin.

Giriş PIN'i `index.html` içinde `const PIN='7777'`.
