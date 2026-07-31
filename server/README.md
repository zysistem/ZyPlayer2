# 🚀 ZyPlayer Self-Hosted Torrent Provider Sunucusu

Bu klasördeki Node.js sunucusu, engelli `torrentio.strem.fun` adresine bağımlı kalmadan kendi web siteniz veya VPS/Vercel sunucunuz üzerinden kesintisiz torrent verisi çekmenizi sağlar.

---

### 🌐 Nasıl Çalışır?
- **Cloudflare / İSS Engellerine Takılmaz:** Kendi sunucunuz (Vercel, Render, VPS veya kendi siteniz) üzerinden YTS ve PirateBay veritabanlarını anında sorgular.
- **Stremio / Torrentio Standardına Tam Uyumlu:** ZyPlayer uygulamasıyla tak-çalıştır şeklinde uyumludur.

---

### 📦 Hızlı Kurulum (Kendi Sunucunuzda / Bilgisayarınızda)

1. **Gerekli bağımlılıkları yükleyin:**
   ```bash
   cd server
   npm install
   ```

2. **Sunucuyu başlatın:**
   ```bash
   npm start
   ```
   *Sunucu `http://localhost:7000` portunda çalışmaya başlayacaktır.*

---

### ☁️ Vercel / Render / Kendi Sitenize Yükleme (Ücretsiz)

#### ⚡ Vercel İle Tek Tıkla Dağıtım:
1. `server` klasörünü GitHub deponuza yükleyin.
2. [Vercel.com](https://vercel.com) adresine girip projeyi içe aktarın (Import).
3. Dağıtım tamamlandıktan sonra Vercel size bir URL verecektir:
   `https://my-zyplayer-server.vercel.app`

#### 📲 ZyPlayer Uygulamasına Ekleme:
1. ZyPlayer uygulamasını açın -> **Ayarlar** sekmesine gidin.
2. **Torrentio API Adresi** alanına kendi site adresinizi yapıştırın:
   `https://my-zyplayer-server.vercel.app` (veya `http://localhost:7000`)
3. Artık tüm filmler ve diziler hiçbir engele takılmadan kendi özel sunucunuz üzerinden saniyesinde çekilecektir! 🎉
