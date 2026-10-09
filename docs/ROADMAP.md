# Yol Haritası — Önerilen Özellikler

Bu dosya, `claude/stoic-clarke-y7hh1f` dalında yapılan işlerden sonra önerilen
yeni özellikleri toplar. Hiçbiri henüz yapılmadı; her biri ayrı bir iş olarak
ele alınabilir.

## Özet

| # | Özellik | Model gerekir mi? | Öncelik | Zorluk |
| --- | --- | --- | --- | --- |
| 1 | [Laya ile CLI araç kategorileri](#1-laya-ile-cli-araç-kategorileri) | Laya (isteğe bağlı) | 🥇 Yüksek | Orta |
| 2 | [Güncelleme risk etiketi](#2-güncelleme-risk-etiketi) | Laya (isteğe bağlı) | 🥇 Yüksek | Orta |
| 3 | [Yerel Modeller sayfası](#3-yerel-modeller-sayfası) | Hayır | 🥇 Yüksek | Orta |
| 4 | [Güvenlik açığı taraması (OSV)](#4-güvenlik-açığı-taraması-osv) | Hayır | 🥈 Orta | Düşük |
| 5 | [Hata sınıflandırma ve açıklama](#5-hata-sınıflandırma-ve-açıklama) | Laya / Ollama (isteğe bağlı) | 🥈 Orta | Orta |
| 6 | [MCP sunucu yönetimi](#6-mcp-sunucu-yönetimi) | Hayır | 🥈 Orta | Orta |
| 7 | [Yeni Mac'e taşı](#7-yeni-mace-taşı) | Hayır | 🥉 Düşük | Orta |
| 8 | [Ollama ile güncelleme özeti ve “Bu ne?”](#8-ollama-ile-güncelleme-özeti-ve-bu-ne) | Ollama (isteğe bağlı) | 🥉 Düşük | Orta |
| 9 | [Doğal dil araması ve komutları](#9-doğal-dil-araması-ve-komutları) | Ollama (isteğe bağlı) | 🥉 Düşük | Yüksek |
| 10 | [Homebrew'e geçiş eşleştirmesi](#10-homebrewe-geçiş-eşleştirmesi) | Laya / Ollama (isteğe bağlı) | 🥉 Düşük | Orta |

Önerilen sıra: **1 → 2 → 3 → 4**. 1 ve 2 aynı Laya altyapısını kullanır; 3 ve 4
modelsiz çalışır.

## Bütün yapay zekâ özellikleri için ortak kurallar

- **İsteğe bağlı.** Ayarlarda bir anahtarla açılır, varsayılan kapalıdır.
- **Yalnızca yerel.** Model bu Mac'te çalışır (Laya sunucusu veya Ollama,
  `localhost`). Kurulu uygulama listesi kişisel veridir, internete gönderilmez.
- **Karar vermez, önerir.** Model hiçbir kurulumu başlatmaz veya engellemez.
  Team ID, Gatekeeper, EdDSA ve checksum denetimleri olduğu gibi kalır.
- **Yedek her zaman var.** Model kapalıysa, çalışmıyorsa ya da emin değilse
  uygulama bugünkü davranışına döner; hiçbir özellik bozulmaz.
- **Dışarıdan gelen metin güvenilmezdir.** Sürüm notları ve hata çıktıları
  modele yalnızca veri olarak verilir; modelin hiçbir aracı yoktur, çıktısı
  sabit bir etiket kümesiyle sınırlıdır (prompt injection'a karşı).
- **Bellek.** Model yalnızca gerektiğinde yüklenir; menü çubuğu uygulaması onu
  sürekli bellekte tutmaz.

## Laya hakkında

[Laya](https://github.com/NandhaKishorM/laya) bir sohbet modeli değil, bir
**karar motorudur**: metin üzerine sorulan sorulara tek seferde cevap verir.

| Özellik | Değer |
| --- | --- |
| Soru türleri | `choice` (bir etiket seç), `score` (sıralı puan), `noul` (evet/hayır olasılığı) |
| Modeller | `laya` (ModernBERT-large, 421M, İngilizce), `laya-multilingual` (mmBERT-base, 322M, 100+ dil — Türkçe dahil), `laya-typed-decisions` |
| Hız | README'deki ölçüme göre T4 GPU'da soru başına ~33 ms, toplu ~7 ms |
| Mac | Apple Silicon'da MPS ile çalışır |
| Boyut | Toplam ~2.3 GB |
| Lisans | Apache-2.0 |
| Arayüzler | Python (`Router().predict`), CLI (`laya`), HTTP (`laya-serve`, `POST /v1/systemone`, Jev uyumlu), MCP (`laya-mcp-server`) |

**Bağlantı planı:**

1. Kullanıcı isteğe bağlı kurar: `uv tool install "laya[serve]"`, sonra
   `laya-serve`.
2. Uygulama yerel sunucuya HTTP isteği atar (`localhost`).
3. Sunucu yoksa ya da cevap vermezse bugünkü yönteme dönülür.
4. Ayarlar → Gelişmiş: "Yerel karar modeli (Laya)" anahtarı ve sunucu adresi.
5. Uygulama zaten `uv` araçlarını listelediği için Laya'nın kurulu olup
   olmadığını ve güncellemesini de kendi listesinde gösterir.

**Dikkat:** README, modellerin "olduğundan daha emin" cevap verdiğini ve çok
dilli modelin henüz kalibre edilmediğini söylüyor. Bu yüzden her cevap bir
güven eşiğinden geçmeli; eşiğin altındaki cevaplar kullanılmamalı. HTTP
isteğinin tam biçimi, uygulamaya geçmeden önce README'nin geri kalanından
doğrulanmalı.

---

## 1. Laya ile CLI araç kategorileri

**Sorun:** Komut Satırı Araçları sayfası, araçları `CLIToolCategory.swift`
içindeki elle yazılmış anahtar kelime listeleriyle kategorilere ayırıyor
("runtime environment", "javascript" …). Açıklaması alışılmadık olan araçlar
"Diğer"e düşüyor.

**Öneri:** Her aracın adı ve `brew desc` açıklaması Laya'ya `choice` sorusu
olarak verilir; seçenekler mevcut 11 kategoridir.

- Sonuç `cache/` altında (araç adı, açıklama) anahtarıyla saklanır; aynı araç
  için model bir daha çalışmaz.
- Güven eşiğinin altındaysa anahtar kelime yöntemi kullanılır.
- Homebrew dışı araçlar (npm, pipx, uv …) de ilk kez kategorilere ayrılabilir.

**Neden önce bu:** 100'ü aşkın araçta etkisi hemen görünür; mevcut yöntem
yedek olarak kaldığı için risk düşüktür.

## 2. Güncelleme risk etiketi

**Öneri:** Sürüm notu (Sparkle `<description>`, GitHub release metni) Laya'ya
verilir:

- `choice`: kırıcı değişiklik / güvenlik yaması / hata düzeltmesi / yeni özellik
- `score`: aciliyet, 1–5

Güncellemeler sayfasındaki satırda küçük bir rozet olarak görünür
(🔴 kırıcı, 🟡 güvenlik, 🟢 düzeltme). Sonuç (paket, sürüm) anahtarıyla
saklanır.

## 3. Yerel Modeller sayfası

**Öneri:** Yerel yapay zekâ modellerini paket gibi yöneten yeni bir sayfa.

| Kaynak | Nereden okunur |
| --- | --- |
| Ollama | `http://localhost:11434/api/tags` |
| Hugging Face | `~/.cache/huggingface/hub` |
| LM Studio | `~/.lmstudio/models` |

- **Güncelleme:** Ollama modelinin yayındaki sürümü yerelden farklıysa
  "Güncelle" (`ollama pull`).
- **Disk:** Model başına boyut ve son kullanım; kullanılmayanları silme.
- **Neden:** Modeller onlarca GB tutar ve kimse takip etmez; bildiğimiz kadarıyla
  modelleri paket gibi güncelleyen bir güncelleyici yok.

## 4. Güvenlik açığı taraması (OSV)

**Öneri:** [OSV.dev](https://osv.dev) ücretsiz ve açık bir veritabanıdır; npm,
PyPI ve crates.io paketlerini destekler. Kurulu sürümler sorgulanır, bilinen
açığı olan paketler kırmızı uyarıyla işaretlenir ve güncellemeleri öne
çıkarılır.

- Model gerekmez.
- Homebrew dışı kaynaklar listesi zaten var (`other_packages`), yani girdi
  hazır.

## 5. Hata sınıflandırma ve açıklama

**Öneri:** Başarısız bir güncellemenin hata çıktısı (`ProcessOutcome.summary`)
modele verilir:

- Laya ile `choice`: ağ / parola gerekli / disk dolu / paket bozuk / diğer
- İsteğe bağlı olarak Ollama ile kullanıcının dilinde 1–2 cümlelik açıklama
  ("ne oldu, ne yapmalısın")

Mevcut `ItemRunResult.Reason` kodlarıyla birlikte gösterilir.

## 6. MCP sunucu yönetimi

**Öneri:** Claude Desktop ve Claude Code ayar dosyaları okunur
(`~/Library/Application Support/Claude/claude_desktop_config.json`,
`~/.claude.json`):

- Hangi MCP sunucusunun nerede tanımlı olduğu
- Güncellemesi olanlar (npm/uv listesinden)
- Ayarda tanımlı ama kurulu olmayanlar; kurulu ama hiçbir yerde
  kullanılmayanlar

## 7. Yeni Mac'e taşı

**Öneri:** Tek tıkla bir kurulum betiği üretilir: Homebrew (Brewfile) + App
Store + npm + pipx + uv + cargo, sürümleriyle birlikte. Yeni Mac'te betik
çalıştırılınca her şey kurulur.

## 8. Ollama ile güncelleme özeti ve "Bu ne?"

**Öneri (Ollama ile, isteğe bağlı):**

- **Güncelleme özeti:** Sürüm notunun Türkçe 2–3 cümlelik özeti.
- **"Bu ne?":** `codebase-memory-mcp`, `agy` gibi açıklaması olmayan araçlar
  için adından ve yolundan tahmin; arayüzde "muhtemelen" diye işaretlenir.

Tavsiye edilen küçük modeller: Qwen2.5 3B veya Gemma 3 4B (Türkçede Llama 3.2
3B'den daha iyi). 4-bit 3B bir model ~2 GB bellek kullanır.

## 9. Doğal dil araması ve komutları

**Öneri:** "PDF ile ilgili ne kurulu?" gibi aramalar; daha sonra "Xcode hariç
her şeyi güncelle" gibi komutların yapısal bir eyleme çevrilmesi. Her eylem
çalışmadan önce **mutlaka** onay ister.

## 10. Homebrew'e geçiş eşleştirmesi

**Öneri:** `lib/migrate.sh` uygulama adından cask adını bulmak için
`app_token_map.conf` ve aday başına `brew info` kullanıyor. Model aday cask
adları önerir; her öneri yine `brew info` ile doğrulanmadan gösterilmez.

---

## Mevcut daldan kalan küçük işler

- **Bağımsız kurulum listesi kalabalık:** `/opt/homebrew/bin` içindeki
  `pip install` ile kurulmuş Python komutları muhtemelen burada görünüyor.
  Ayrı bir "pip" grubuna alınmalı (önce kullanıcının listesine bakılacak).
- **Warp başlatıcısı** hiç gerçek Warp'ta denenmedi.
- **Go** paketleri için güncelleme kontrolü yok (güncelleme komutu var).
- **`agy`** gibi araçların sürümü boş görünüyor; güvenlik için bulunan araçlar
  çalıştırılmıyor (`--version` sorulmuyor).
