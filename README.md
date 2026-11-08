# Golden Eye Casino 🎰

Arkadaşlar arası eğlence oyunu. **Sanal euro bakiyesi kullanılır, gerçek para yoktur.**

**Canlı:** https://ardaylmz-lab-goldeneye-casino.vercel.app (alias: https://goldeneye-casino-fvni.vercel.app)
Vercel projesi: `arda-5509s-projects/ardaylmz-lab-goldeneye-casino`. Sesli sürüm budur; API fonksiyonları burada çalışır.
GitHub Pages kopyasında API olmadığı için ses yoktur. `goldeneye-casino.vercel.app` ayrı ve eski bir projedir, key tanımlı değildir.

- Slot (5x5, 20 hat, wild/scatter, free spin), Rulet (3D çark), Blackjack (6 koltuklu masa, birden fazla el, böl/2x, 3:2)
- `index.html` — oyunun tamamı (tek dosya). Rulet çarkı WebGL ile 3D (three.js, CDN'den yüklenir); WebGL ya da CDN yoksa CSS çark devreye girer.
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
