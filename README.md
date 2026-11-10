# Golden Eye Casino 🎰

Arkadaşlar arası eğlence oyunu. **Sanal euro bakiyesi kullanılır, gerçek para yoktur.**

**Canlı:** https://ardaylmz-lab-goldeneye-casino.vercel.app (alias: https://goldeneye-casino-fvni.vercel.app)
Vercel projesi: `arda-5509s-projects/ardaylmz-lab-goldeneye-casino`. Sesli sürüm budur; API fonksiyonları burada çalışır.
GitHub Pages kopyasında API olmadığı için ses yoktur. `goldeneye-casino.vercel.app` ayrı ve eski bir projedir, key tanımlı değildir.

- Slot: Burning Fruits ve Jade Dragon (5x5, 20 hat, wild/scatter, free spin) ve Diamond Heist (free spin yerine bonus oyunlar: 3+ kasa kapısı → Kasa Odası seçme oyunu, içinden Soygun Çarkı çıkabilir; 6+ altın külçe → Kasayı Doldur tut-kazan turu; MINI/MINOR/MAJOR/GRAND jackpot külçeleri bahsin sabit katları). Rulet (3D çark; Şimşek modu: her turda 1–5 sayıya 50x–500x çarpan, sayı bahsi 29:1, açılıp kapatılabilir), Blackjack (6 koltuklu masa, birden fazla el, böl/2x, 3:2; masa three.js ile 3D: oyuncu tarafından bakış, oturulan tabureye göre kayan kamera, kutudan uçan ve çevrilen kartlar, çip yığınları, taburelerde sırttan oturan figürler; sağ üstteki düğmeyle klasik 2D görünüme geçilir ve tercih hatırlanır, WebGL ya da CDN yoksa 2D masa kalır), Texas Hold'em (5/10 € kör, 500 € giriş; giriş yapınca ortak masa: 3 koltuk, arkadaşlar aynı masada, boş koltuklar botlarla dolar, deste ve kapalı kartlar sunucuda; giriş yoksa iki bota karşı yerel; 7 kart el değerlendirici, yan potlar, 25 sn hamle süresi)
- `avatars/` — oyuncu avatarları: GPT ile üretilen 3D karakter sayfasından (dört görünüm) kesilen büst (`<ad>.png`, 256x256, şeffaf), tam boy ön görünüm (`<ad>_full.png`) ve küçültülmüş sayfa (`<ad>_sheet.png`). Eşleme `index.html` içindeki `AVATARS` sözlüğünde profil adına göre yapılır (küçük harf; ilk kelime de eşleşir). Madalyon blackjack taburesinde ve çevrimiçi listesinde görünür. Poker ve rulette madalyon yerine 2.5D oturan figür vardır: karakter sayfasından kesilen yarım boy (`<ad>_front.png`, `<ad>_back.png`); pokerde karşıdakiler önden ve rayın arkasında, sen sırttan masanın önünde, rulette koltukta önden. Önden görünen figürler poz sayfasından kesilen beş hizalı kesiti kullanır (`<ad>_idle.png`, `_cards.png`, `_sip.png`, `_win.png`, `_lose.png`; aynı tuval, gövde merkezi ortada, `AVPOSE` içinde tuval oranı `r`): pokerde elde kart varken kartlı poz, el bitince kazanan sevinir ve showdown'da kaybeden üzülür; rulette sonuçta kazanan sevinir, kaybeden üzülür; her figür 20–40 sn'de bir viskisini yudumlar. Pozlar arası 280 ms çapraz geçiş vardır; kişi ya da görünüm değişince katmanlar sıfırlanır. Figürler ayrıca nefes alır gibi salınır, sırası gelen öne eğilir, pas geçen solar, kazanan zıplar. Sırt görünümü (`_back.png`) karakter sayfasından gelir ve tek pozdur.
- `index.html` — oyunun tamamı (tek dosya). Rulet çarkı WebGL ile 3D (three.js, CDN'den yüklenir): piksel piksel üretilen cilalı maun dokusu, fırçalanmış pirinç, sedefli top, tepeden yumuşak gölgeli spot ışık, elmas saptırıcılara çarpan top, hız izi, kazanan cep ışığı, boşta salınan kamera; çanak çuhaya gölge düşürür. WebGL ya da CDN yoksa CSS çark devreye girer.
- `audio/music/*.mp3` — ElevenLabs Music ile üretilmiş üç lounge parçası; ilk dokunuşla kısık sesle başlar, parçalar çapraz geçişle döner (🎵 ile kapatılır).
- `audio/tts/*.mp3`, `audio/sfx/*.mp3` — ElevenLabs'te bir kez üretilmiş sabit klipler; oyun sesleri önce buradan yükler (GitHub Pages dahil her yerde çalışır), dosya yoksa `api/…` proxy'sine düşer.
- `api/tts.js` — ElevenLabs sesli anons proxy'si (Vercel serverless). Key sadece Vercel ortam değişkeninde durur.
- `api/sfx.js` — ElevenLabs ses efekti proxy'si (makara dönüşü, durma, scatter, gerilim, kazanç, coin, büyük kazanç, free spin, kayıp, tık). Her efekt bir kez üretilir, CDN'de 1 yıl önbellekte kalır. Efekt yüklenemezse oyun kendi sentez tonlarına döner.
- `api/_eleven.js` — ortak yardımcılar: 429 (eşzamanlılık sınırı) olursa bekleyip tekrar dener, aynı klip için eşzamanlı istekleri tekilleştirir. Oyun tarafı klipleri aynı anda en fazla 2 istekle yükler (ElevenLabs ücretsiz plan sınırı).
- `api/health.js` — `{"ok":true,"key":true}` görmelisin; `key:false` ise `ELEVENLABS_API_KEY` deploy'a girmemiş demektir.

## Supabase (hesaplar, ortak bakiye, çok oyunculu)
1. supabase.com → New project. Authentication → Providers → Email açık; "Confirm email" kapatılırsa kayıt tek adımda olur.
2. SQL Editor → `supabase/schema.sql` dosyasının içeriğini yapıştır → Run (profiller, otomatik profil, bakiye RPC'si, koltuklar, Realtime).
   Ardından `supabase/bj_engine.sql` → Run (ortak blackjack masası: dağıtım, hamleler, krupiye, ödeme sunucuda; herkes aynı eli izler)
   ve `supabase/rl_engine.sql` → Run (ortak rulet masası: bahisler, tek sonuç, ödemeler ve şimşek sayıları sunucuda; çark herkeste aynı anda döner; şimşek modu masa ayarıdır, `rl_light` ile açılıp kapanır),
   sonra `supabase/pk_engine.sql` → Run (ortak Texas Hold'em: tek masa, 3 koltuk; deste ve kapalı kartlar `pk_secret` tablosunda, kimse okuyamaz, oyuncu kendi kartlarını `pk_my_cards` ile alır; botlar, süre aşımı ve yeni el `pk_tick` ile sunucuda işler; 2 dakika sessiz kalan oyuncu kaldırılır ve yığını bakiyesine döner). `bj_engine.sql` kurulu olmalıdır (bakiye fonksiyonları ortak).
3. Project Settings → API → **Project URL** ve **anon public** anahtarını `index.html` içindeki `SUPA` sabitine yaz. anon anahtarı tarayıcıda durmak için tasarlanmıştır; **service_role** anahtarını asla koyma.
4. `SUPA.key` boşsa oyun eski PIN girişiyle ve yerel bakiyeyle çalışmaya devam eder.

## Vercel kurulumu
1. vercel.com → Add New → Project → bu repoyu import et → Deploy
2. Project → Settings → Environment Variables:
   - `ELEVENLABS_API_KEY` = ElevenLabs key'in
   - `ELEVENLABS_VOICE_ID` = (isteğe bağlı) ses ID'si; boş bırakılırsa "Jessica"
3. **Redeploy** (env var ancak yeni deploy'da fonksiyonlara girer). İlk açılışta klipler üretilir (11 anons + 10 efekt, tek seferlik kredi). Metinleri değiştirirsen `index.html` içindeki `AUD_V` değerini artır ki önbellek yenilensin.
   Seçili ses hesabın planında kullanılamıyorsa `api/tts.js` hesabın kullanabildiği ilk sese otomatik düşer.
4. `https://<proje>.vercel.app/api/health` → `{"ok":true,"key":true}` görmelisin.

Giriş PIN'i `index.html` içinde `const PIN='7777'`.
