# Golden Eye Casino 🎰

Arkadaşlar arası eğlence oyunu. **Sanal jeton kullanılır, gerçek para yoktur.**

**Canlı:** https://goldeneye-casino.vercel.app (sesli sürüm; API fonksiyonları burada çalışır)
GitHub Pages kopyasında API olmadığı için ses yoktur.

- Slot (5x5, 20 hat, wild/scatter, free spin), Rulet, Blackjack
- `index.html` — oyunun tamamı (tek dosya)
- `api/tts.js` — ElevenLabs sesli anons proxy'si (Vercel serverless). Key sadece Vercel ortam değişkeninde durur.
- `api/sfx.js` — ElevenLabs ses efekti proxy'si (makara dönüşü, durma, scatter, gerilim, kazanç, coin, büyük kazanç, free spin, kayıp, tık). Her efekt bir kez üretilir, CDN'de 1 yıl önbellekte kalır. Efekt yüklenemezse oyun kendi sentez tonlarına döner.
- `api/_eleven.js` — ortak yardımcılar: 429 (eşzamanlılık sınırı) olursa bekleyip tekrar dener, aynı klip için eşzamanlı istekleri tekilleştirir. Oyun tarafı klipleri aynı anda en fazla 2 istekle yükler (ElevenLabs ücretsiz plan sınırı).
- `api/health.js` — `{"ok":true,"key":true}` görmelisin; `key:false` ise `ELEVENLABS_API_KEY` deploy'a girmemiş demektir.

## Vercel kurulumu
1. vercel.com → Add New → Project → bu repoyu import et → Deploy
2. Project → Settings → Environment Variables:
   - `ELEVENLABS_API_KEY` = ElevenLabs key'in
   - `ELEVENLABS_VOICE_ID` = (isteğe bağlı) ses ID'si; boş bırakılırsa "Jessica"
3. **Redeploy** (env var ancak yeni deploy'da fonksiyonlara girer). İlk açılışta klipler üretilir (11 anons + 10 efekt, tek seferlik kredi). Metinleri değiştirirsen `index.html` içindeki `AUD_V` değerini artır ki önbellek yenilensin.
   Seçili ses hesabın planında kullanılamıyorsa `api/tts.js` hesabın kullanabildiği ilk sese otomatik düşer.
4. `https://<proje>.vercel.app/api/health` → `{"ok":true,"key":true}` görmelisin.

Giriş PIN'i `index.html` içinde `const PIN='7777'`.
