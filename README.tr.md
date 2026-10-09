<div align="center" markdown="1">

[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.6.0-blue)](https://github.com/dogukannparlak/mac_software_manager/releases)

![Engine](https://img.shields.io/badge/engine-zsh%20%2B%20Homebrew-blue?logo=homebrew&logoColor=white)
![App](https://img.shields.io/badge/app-macOS%2014.0%2B-blue?logo=apple&logoColor=white)
![Universal](https://img.shields.io/badge/binary-Apple%20Silicon%20%2B%20Intel-blue?logo=apple&logoColor=white)

</div>

# Mac Software Manager

🇬🇧 English: [README.md](README.md)

Mac Software Manager, Mac'inizdeki her uygulamayı ve komut satırı aracını takip
eder: her birinin nereden geldiğini, bekleyen bir güncelleme olup olmadığını ve
sizin yerinize Homebrew'un yönetip yönetemeyeceğini gösterir. Hepsini tek bir
yerden, arka planda günceller; elle kurduğunuz uygulamaları ayarlarını
kaybetmeden Homebrew'a devredebilir.

## Gereksinimler

İki katmanın gereksinimleri farklıdır ve birini diğeri olmadan da
kullanabilirsiniz:

| Katman | Gereksinim |
| --- | --- |
| **Kabuk motoru** (`update_system.1h.sh`, `lib/*.sh`, `setup_mac.sh`) | `zsh` ve **Homebrew** — motor `brew` olmadan çalışmayı reddeder (`update_system.1h.sh` içindeki ön kontrol). App Store uygulamaları için `mas` isteğe bağlıdır. |
| **MacUpdaterGuide.app** (`GuideApp/`) | **macOS 14.0 veya üzeri** — `GuideApp/MacUpdaterGuide.xcodeproj/project.pbxproj` içindeki `MACOSX_DEPLOYMENT_TARGET = 14.0` ve [GuideApp/Package.swift](GuideApp/Package.swift) içindeki `.macOS(.v14)`. Universal binary: Apple Silicon ve Intel. |

## Nasıl kurgulandı

İki katman ve aralarında tek bir durum dizini var:

* **Kabuk motoru** Homebrew, App Store (`mas`), Sparkle appcast'leri ve GitHub
  release akışlarıyla konuşmayı bilir. Bütün işi o yapar ve bulduklarını
  `~/Library/Application Support/MacSoftwareUpdater/cache/` altına yazar.
* **SwiftUI uygulaması** (`GuideApp/`) bu cache'i okur, motorun alt
  komutlarını çağırarak onu sürer ve menü çubuğu ögesinin sahibidir. Motorun
  her çağrısı bir alt komut adı taşır; argümansız çalıştırılırsa kullanım
  metnini basıp **2** ile çıkar.

Cache biçimi ikisi arasındaki sözleşmedir ve
[CACHE_FORMAT.md](CACHE_FORMAT.md) içinde belgelenmiştir.

## Özellikler

* **Her şeyi tek yerden güncelleyin.** Homebrew formula ve cask'leri, `mas`
  üzerinden App Store uygulamaları ve kendini bir Sparkle appcast'i ya da GitHub
  releases akışı üzerinden güncelleyen uygulamalar.
* **Anında açılan menü.** Gösterilen her şey cache'ten okunur ve arka planda
  tazelenir; menüyü açmak asla Homebrew'u veya ağı beklemez.
* **Canlı ilerleme.** Motor o anda ne yaptığını yazar — Homebrew tazeleniyor,
  adı verilen bir paket yükseltiliyor, temizlik yapılıyor — ve hem menü çubuğu
  ögesi hem de Güncellemeler sayfası bunu bildirir; çalışma ister arka planda
  ister bir terminalde olsun.
* **Dürüst geçmiş.** Bir çalışmadan sonra her paket yeniden denetlenir ve gerçek
  sonuç kaydedilir; başarısız bir güncelleme başarılı sayılmak yerine başarısız
  olarak kaydedilir.
* **Kaynağıyla birlikte envanter.** Her uygulama; simgesi, sürümü ve nereden
  geldiğiyle listelenir: Homebrew, App Store, Setapp, Apple ya da elle kurulmuş —
  bir kurulum programının bir alt klasöre koyduğu uygulamalar da dahil
  (`/Applications/<Üretici>/<Uygulama>.app`).
* **CLI araçları kendi sayfasında.** Makinedeki her Homebrew formula'sı,
  kategorilere ayrılmış hâlde (aşağıya bakın) — ve altında, başka yerden gelen
  her şey: npm, pipx, uv, Cargo ve Go kurulumları, Claude Code gibi bağımsız
  araçlar, uygulamaların içindeki komut satırı araçları ve kurulum paketleri
  (`.pkg`). Ana kaynak yine Homebrew'dur; gerisi isteğe bağlıdır.
* **Homebrew'e Taşı.** Elle kurduğunuz uygulamalardan bir Homebrew cask'inin
  güncel tutabileceklerini bulur, her eşleşmeye ne kadar güvendiğini ve taşımanın
  tam olarak ne yapacağını söyler, sonra uygulamayı yerinde devreder.
* **Doğrulanmış self-update.** Terminalden kurulan motor kendini ancak
  indirilen dosya yayımlanmış `SHA256SUMS` ile eşleştikten sonra değiştirir —
  bkz. [Güvenlik](#güvenlik). Uygulamanın içindeki motor kendini asla
  değiştirmez; uygulamayla birlikte güncellenir.
* **Doğrulanmış uygulama değiştirme (opt-in).** Doğrudan DMG/ZIP indirmesi olan
  uygulamalarda motor güncellemeyi kendisi kurabilir; ancak Team ID, kod imzası,
  Gatekeeper ve (yayımlanmışsa) Sparkle'ın EdDSA imzası geçtikten sonra.
  Varsayılan olarak kapalı.
* **Ayrıntılı denetim.** Bir uygulamayı yoksayın (sabitleyin), nasıl takip
  edildiğini düzeltin, bir uygulama adını Homebrew cask token'ına eşleyin ya da
  otomatik bulunmuş web sitesi/GitHub bağlantısını düzeltin — hepsi uygulamadan
  ve hepsi motorun kendi yapılandırma dosyalarına yazılarak.
* **Yerel bildirimler.** Motor her olay için `notifications/` altına bir dosya
  bırakır; uygulama bunların her birini **Aç** eylemli gerçek bir
  `UNUserNotificationCenter` bildirimine çevirir. Uygulama çalışmıyorsa motor
  `osascript`'e düşer.
* **Kurulacak hiçbir şey yok.** Motor **uygulamanın içinde** gelir ve oradan
  çalışır — kurulum adımı yok, indirme yok, sürüm uyuşmazlığı yok, uygulamanın
  kendi durum klasörü dışına hiçbir şey yazılmaz. Yalnızca Homebrew ya da
  `mas` eksikse bir kurulum sayfası bu ikisini önerir; ikisi de varsa sayfa
  hiç görünmez. Uygulama parolanızı asla istemez: yönetici gerektiren tek adım
  (Homebrew'un kendi kurulum betiği) Terminal'de açılır, uygulama sonucu izler.
* **İki dil.** İngilizce ve Türkçe, yeniden başlatmadan değiştirilebilir.

## Menü çubuğu durumları

Simgeyi uygulama çizer (`MacUpdaterGuideApp.swift` içindeki `MenuBarLabel`) ve
üç durumu vardır:

| Durum | SF Symbol | Anlamı |
| :--- | :--- | :--- |
| **Güncel** | `checkmark.circle` | Bekleyen bir şey yok. |
| **Bekleyen güncelleme** | `arrow.triangle.2.circlepath.circle` + sayı | Bekleyen güncelleme sayısı simgenin yanına yazılır. |
| **Yenileniyor** | `arrow.triangle.2.circlepath` | Bir cache tazelemesi sürüyor. |

## Kurulum

Uygulama ile motor ayrı ayrı kurulur. Çoğu kişi ikisini de ister ama her biri
tek başına da çalışır.

### 1. Uygulama

[GitHub Releases](https://github.com/dogukannparlak/mac_software_manager/releases)
sayfasından indirin:

| Dosya | Ne için |
| --- | --- |
| `MacUpdaterGuide-<version>-macOS-universal.dmg` | Sürükle-bırak kurulum |
| `MacUpdaterGuide-<version>-macOS-universal.zip` | Daha küçük indirme |

İkisi de universal binary'dir — Apple Silicon ve Intel — ve macOS 14.0 veya
üzerini gerektirir. Her release ayrıca indirmenizi doğrulayabileceğiniz bir
`SHA256SUMS.txt` yayımlar:

```bash
shasum -a 256 MacUpdaterGuide-<version>-macOS-universal.dmg
```

Uygulama Apple Developer ID ile değil, **ad-hoc imzalıdır**; bu yüzden macOS ilk
denemede açmayı reddeder. Ya:

* uygulamaya **sağ tıklayın → Aç → Aç**, ya da
* `xattr -dr com.apple.quarantine /Applications/MacUpdaterGuide.app` çalıştırın.

Yalnızca bir kez.

> 1.6.0 release'i bu satırlar yazılırken hâlâ **taslak** durumda, dolayısıyla
> varlıkları henüz herkese açık olarak indirilebilir değil. Yayımlanana kadar
> uygulamayı kaynaktan derleyin — bkz. [Geliştirme](#geliştirme).

### 2. Motor ve geçiş sihirbazı

**Uygulamadan: yapılacak bir şey yok.** `MacUpdaterGuide.app` motorun tamamını
— `update_system.1h.sh`, `lib/*.sh` ve `uninstall.sh` — kendi içinde taşır ve
doğrudan paketin içinden çalıştırır. Kurulum adımı, indirme ve "motor bulunamadı"
durumu yoktur: uygulama ile motor tek bir sürümdür, birbirinin ne yazdığı
konusunda anlaşmazlığa düşemezler.

Bu mümkün, çünkü motor kendi yanına hiçbir şey yazmaz. Sakladığı her şey
`~/Library/Application Support/MacSoftwareUpdater/` altına gider; bu klasörü her
çalışmasında kendisi oluşturur ve `settings.conf` yokken varsayılanlarla
çalışır. Uygulama `MSU_LIB_DIR`'i kendi kaynaklarına yöneltip motoru çağırır.
Terminal penceresinde açılan bir çalışma da aynı değişkeni komut satırında
taşır; değişken olmadan başlayan motor ise kütüphanesini önce kendi yanında
arar, ancak bulamazsa destek klasörüne döner — böylece betik ve `lib/` hep aynı
sürümden gelir.

Uygulamanın yanında getiremediği tek şey Homebrew ve `mas`. Biri eksikse kurulum
sayfası onları önerir — Homebrew'u resmî kurulum betiğini Terminal'de açarak
(uygulama içinde asla: yönetici parolası ister), `mas`'ı `brew install mas` ile.
İkisi de varsa sayfa hiç görünmez.

**Terminalden.** Depoyu klonlayın (ya da Releases sayfasından kaynak arşivini
indirin) ve sihirbazı çalışma kopyasından çalıştırın:

```bash
git clone https://github.com/dogukannparlak/mac_software_manager.git
cd mac_software_manager
./setup_mac.sh
```

`setup_mac.sh` motoru
`~/Library/Application Support/MacSoftwareUpdater/` altına kurar, `settings.conf`
dosyasını yazar ve aşağıda anlatılan geçiş adımında size yol gösterir.
`--local` olmadan kurduğu her dosyayı indirir ve yerine koymadan önce
yayımlanmış `SHA256SUMS` ile doğrular; yalnızca doğrulanmış hiçbir uzak kaynağa
ulaşılamadığında kurulumun yanındaki kopyaya düşer. `./setup_mac.sh --help`
bütün bayrakları anlatır.

`--unattended`, uygulamanın kurulum sayfasının kullandığı moddur ve terminalden
de çalışır — sıfırdan bir Mac'i betikle kurmak için kullanışlıdır. Her soruyu
güvenli varsayılanıyla yanıtlar (varsa mevcut yapılandırma, yoksa Terminal.app
ve açık App Store güncellemeleri), geçiş sihirbazını atlar, giriş ögesi
eklemez ve normal çıktısının yanında makine tarafından okunabilir
`STEP|<id>|<durum>|<metin>` satırları basar. Homebrew'u asla kurmaz: kurulu
olmayan bir Mac'te tek satır sebep basıp **3** ile çıkar. Çıkış kodları: `0`
başarı, `2` hatalı kullanım, `3` Homebrew yok, `1` diğer.

`setup_mac.sh` motoru
`~/Library/Application Support/MacSoftwareUpdater/` altına kurar; uygulamanın
kurulu bir kopya için baktığı yer burasıdır.

Kurulum sırasında yedek mirror için bir **Codeberg kullanıcı adı** sorar. Atlamak
için boş bırakın: indirmeler yine çalışır ve yalnızca GitHub'a karşı doğrulanır;
menü de bunu sessizce güvenceyi düşürmek yerine açıkça söyler. Bkz.
[Güvenlik](#güvenlik).

### Geçiş adımı

`setup_mac.sh`, `/Applications` içinde hiçbir paket yöneticisinin sahiplenmediği
yazılımları tarar ve her biri için eşleşen bir Homebrew cask'i ya da App Store
kaydı olup olmadığını denetler. Yönetilmeyen her uygulama için ne yapacağını
sorar:

* **[A]pp Store** — elle kurulmuş kopyayı App Store sürümüyle değiştirir.
* **[B]rew Cask** — ayarları koruyarak bir Homebrew cask'i ile değiştirir.
* **[L]eave** — uygulamayı olduğu gibi bırakır.

Herhangi bir geçişten önce yerel bir yedek (`.app.bak`) alır; yeni kurulum
başarısız olursa yedeği otomatik geri yükler ve yedeği yalnızca kurulum tümüyle
başarılı olduktan sonra siler.

**[L]eave** demenin bir maliyeti yok: aynı iş daha sonra uygulamadaki
**Ayarlar → Homebrew'e Taşı** (Settings → Move to Homebrew) sayfasından,
terminale gerek kalmadan yapılabilir.

## Kullanım

### Uygulama

Pencere bir kenar çubuğu ve bir ayrıntı panelinden oluşur:

Kenar çubuğunda altı girdi var: **Güncellemeler**, **Yüklü Uygulamalar**,
**Komut Satırı Araçları**, **Geçmiş**, **Rehber** ve **Ayarlar**. Her biri
aşağıda anlatılıyor.

Menü çubuğu ögesini uygulamanın kendisi oluşturur. Bekleyen sayısını ve bir
çalışma sürerken hangi pakette olduğunu gösterir. Bilinçli olarak salt
okunurdur — bir bakış noktasıdır, bir kontrol paneli değil.
**Ayarlar → Genel → Sadece menü çubuğu (Dock simgesini gizle)** Dock simgesini
kaldırır.

Uygulama motorun kendi kopyasını taşır; ayrıca kurulu bir kopya için
`~/Library/Application Support/MacSoftwareUpdater/` altına da bakar. Başka bir
yerde tutuyorsanız **Ayarlar → Gelişmiş** (Settings → Advanced) altından
gösterin.

#### Güncellemeler (Updates)

Bekleyen her şey, kaynağa göre gruplanmış ve gerçek uygulama simgeleriyle. Tek
bir ögeyi ya da hepsini güncelleyin, geride kalmak istediğinizi gizleyin.
**Şimdi Yenile** (Refresh) cache'i yeniden okur; **Homebrew'u Denetle**
(Check Homebrew) en güncel Homebrew ve tap üstverisini isteğe bağlı olarak
çeker.

Güncellemeler varsayılan olarak arka planda çalışır; ilerleme şeridi fazı, o an
kurulan paketi, x/y sayacını ve bir İptal düğmesini gösterir. Toplu bir
çalışmayı iptal etmek önce onay ister (`ToolkitController.cancelUpdate()`). Terminal penceresi
isteğe bağlıdır; Ayarlar → Genel altından açılır.

#### Yüklü Uygulamalar (Installed Apps)

Her uygulama; simgesi, sürümü ve kaynağıyla — Homebrew, App Store, Setapp,
Apple ya da elle kurulmuş. Kaynağa göre süzün ve arayın.

Her satırdaki **"…" menüsü** o uygulamaya dair her şeyi barındırır: web
sitesini veya GitHub sayfasını açmak, bu bağlantıları düzeltmek, güncellemeler
için nasıl takip edildiğini değiştirmek, bir Homebrew cask'ine yeniden
eşlemek ya da yoksaymak. Her düzeltme yereldir ve anında uygulanır.

#### Komut Satırı Araçları

**Homebrew dışı.** Sayfa, Homebrew kategorilerinin altında motorun başka her
yerde bulduklarını listeler (`collect_other_packages`, `lib/updaters.sh`): global
npm paketleri, pipx ve uv araçları, `cargo install` ile kurulan crate'ler, Go
ikilileri, `~/.local/bin`, `~/bin`, `~/.bun/bin`, `~/.deno/bin` ve (Apple
Silicon'da) `/usr/local/bin` içindeki bağımsız çalıştırılabilir dosyalar ile
Apple'a ait olmayan `pkgutil` kurulum paketi kayıtları. Bulunan hiçbir şey
çalıştırılmaz — yalnızca paket yöneticilerinin kendi listeleme komutları
çalışır. npm bekleyen güncellemeleri bildirir; npm, pipx, uv, Cargo ve Go için
satırın menüsünde **Terminalde Güncelle** bulunur ve o yöneticinin kendi
güncelleme komutunu çalıştırır. Bölümün tamamı **Ayarlar → Güncellemeler →
Homebrew dışını da tara** (`OTHER_SOURCES_ENABLED`) ile kapatılabilir.

Homebrew'da bir formula'nın kategorisi diye birinci sınıf bir kavram yok; bu
yüzden bu sayfa Homebrew'un gerçekten sunduğu tek gerçek üstveriye yaslanır:
`brew leaves` — yani gerçekten sizin istediğiniz şeyler, geçişli olarak
sürüklenip gelenlerin karşıtı — artı her leaf'in kendi `brew desc` açıklaması
üzerinde çalışan bir anahtar sözcük sezgiseli.

Leaf'ler on bir kategoriye ayrılır: Sürüm Kontrolü, Diller ve Çalışma Zamanları,
Bulut/DevOps ve Yapay Zeka, Veritabanları, Ağ ve Güvenlik, Derleme ve Paket
Araçları, Medya ve Belgeler, Kabuk ve Metin Araçları, Test Araçları, Diğer
Araçlar ve Kütüphaneler ve Bağımlılıklar.

Leaf **olmayan** bir formula başkasının bağımlılığıdır; sizin "kategorisi olan
bir araç" diye düşündüğünüz bir şey değildir. Bu yüzden ne iş yaparsa yapsın
daima **Kütüphaneler ve Bağımlılıklar** kovasına düşer. Çoğu makinede en büyük
kova bu olduğu için kendi alt başlıklarına da ayrılır (Dil Çalışma Zamanı
Desteği, Ağ ve Güvenlik Kütüphaneleri, Veritabanları, Grafik, Yazı Tipi ve Medya
Kütüphaneleri, Metin, Unicode ve Veri Kütüphaneleri, Sıkıştırma ve Arşivleme,
AWS SDK Bileşenleri, X11 / Pencereleme, Çekirdek ve Sistem Kütüphaneleri).

#### Geçmiş (History)

Son 7 veya 30 günde güncellenenler, güne göre gruplanmış. Başarısızlıklar
gizlenmez, işaretlenir — bir çalışmadan sonra her paket yeniden denetlenir ve
kaydedilen şey gerçek sonuçtur.

#### Rehber (Guide)

Tüm özellik rehberi uygulamanın içinde, İngilizce ve Türkçe, yeniden
başlatmadan değiştirilebilir.

#### Ayarlar (Settings)

Sekiz sayfa: Genel, Güncellemeler, Takip Edilen Uygulamalar, İsim Eşlemesi,
Homebrew'e Taşı, Yoksayılanlar, Gelişmiş, Hakkında. Her şey doğrudan motorun
kendi yapılandırma dosyalarına yazılır; böylece uygulama ile terminal asla
birbirinden farklı şey söylemez.

Genel sayfasındaki **Aynı Anda Yapılabilecek Güncelleme Sayısı**, tek satırlık
çalıştırmaların motorun özel kilidinden neden muaf olduğunun sebebidir:
eşzamanlılık sınırını uygulama kendisi uygular
(`AppPreferences.maxConcurrentUpdates`); toplu kilidi de almak onları yeniden
teker teker çalışmaya indirgerdi.

#### Ayarlar → Homebrew'e Taşı (Settings → Move to Homebrew)

Sihirbazın geçiş adımı; istediğiniz zaman ve terminale gerek kalmadan.

**Tarama**, `/Applications` ve `~/Applications` dizinlerini gezer, zaten hesabı
görülmüş her şeyi atlar (Homebrew cask'leri, App Store uygulamaları, Setapp'in
kataloğu, Apple'ın kendi uygulamaları, yoksaydıklarınız) ve kalanların her biri
için Homebrew'a o adda bir cask olup olmadığını sorar. **Tarama hiçbir şeyi
değiştirmez**: her satırın kararı cask'in kendi JSON üstverisinden ve kurulu
paketin `Info.plist` dosyasından okunur; siz bir satır seçene kadar hiçbir şey
indirilmez, kurulmaz veya taşınmaz. Asla arka planda çalıştırılmaz — yönetilmeyen
her uygulamanın her adayı için bir `brew info` çağrısı saatlik tik için fazla
pahalı — bu yüzden liste, düğmeye en son bastığınız andan bir anlık görüntüdür.

Sonuçlar üç grupta toplanır:

* **Taşınmaya hazır** — Homebrew diskteki mevcut kopyayı devralır. Onay kutuları
  ve toplu bir düğme var, çünkü adopt yıkıcı değildir.
* **Onayınız gerekiyor** — kurulu kopya cask'in gönderdiği sürüm değil, bu yüzden
  adopt reddedilir ve taşımak, uygulamayı cask'in sürümüyle *değiştirmek*
  demektir. Her seferinde bir tane; iki sürümü de gösteren ve taşımanın bir
  sürüm düşürme olacağı durumda sizi uyaran bir onay yaprağının arkasında.
* **Taşınamaz** — süzülüp atılmak yerine nedeniyle birlikte listelenir, çünkü
  "uygulamam neden listede yok" sorusunu süzülmüş bir liste doğurur.

**Başarısız bir taşımanın neden hiçbir maliyeti yok.** Varsayılan
`brew install --cask --adopt`'tur; bu, indirip yerine koymak yerine hâlihazırda
oradaki paketi devralır. Homebrew adopt etmeyi kabul etmediğinde bunu söyler ve
**hedefe hiç dokunmaz** — reddedilen bir adopt kurulumunuzu silmez, taşımaz veya
üzerine yazmaz; yani en kötü durum hiçbir şeyin olmamasıdır. Yıkıcı yol (yedekle,
yeniden kur, hata olursa geri yükle) yalnızca "Onayınız gerekiyor" grubunda
açıkça istenerek gerçekleşir.

**Taşımanın hiç mümkün olmadığı durumlar.** Üç hâl var ve sayfa her satır için
hangisinin geçerli olduğunu söyler:

* **pkg / installer cask'leri** (`logitech-g-hub` bilindik örnektir) bir `.app`
  yerine bir paket kurar; dolayısıyla Homebrew'un devralacağı bir paket de, bir
  şey ters giderse geri koyacağı bir paket de yoktur.
* **Yönetici gerektiren cask'ler** — `sudo` bildiren bir kurulum betiği ya da
  `/Library` altında bir hedef. Araç seti arka plandaki bir çalışmadan asla
  `sudo` çalıştırmaz, çünkü parola istemini gösterecek bir yeri olmaz; bu yüzden
  satır size kendiniz çalıştırmanız için `brew install --cask <token>` satırını
  gösterir.
* **Hedef uyuşmazlığı** — genellikle `/Applications` içine kuran bir cask için
  `~/Applications` içindeki bir uygulama. Adopt bir paketi *taşımaz*; cask'in
  kendi hedefine ikinci bir kopya kurar ve sizinkini olduğu yerde bırakır.

Her satır ayrıca uygulamanın cask'e nasıl bağlandığını da söyler. Cask'in kendi
üstverisine (uygulama dosyası adı ya da uygulamanızın tam bundle tanımlayıcısı)
veya `app_token_map.conf` içine yazdığınız bir satıra dayanan eşleşme doğrulanmış
sayılır; yalnızca uygulamanın adından türetilmiş bir tahmin olan eşleşme
**Doğrulanmamış** olarak işaretlenir ve bir şeyi taşımadan önce denetleyebilmeniz
için cask'in sayfasına bağlantı verilir.

**Kurulumdaki geçiş adımıyla ilişkisi.** İkisi aynı işin iki giriş noktasıdır:
`setup_mac.sh` soruyu bir kez, siz kurarken sorar; bu sayfa ise sonrasında
istediğiniz zaman sorar. Sihirbaz araç seti var olmadan *önce* çalışır — zaten
`~/Library/Application Support/MacSoftwareUpdater/lib` dizinini oluşturan odur —
bu yüzden `lib/` içinden hiçbir şeyi `source` edemez ve token eşleştirmesinin de
geçişin kendisinin de kendi kopyasını taşır. Bu yineleme bir gözden kaçma değil,
bilinçli bir tercihtir; eşleştirme kuralları değiştiğinde iki kopya birlikte
değişir. Her birinin çalıştığı yerden iki fark doğar: sihirbazın bir terminali
vardır, bu yüzden `sudo` ile yetki yükseltebilir ve reddedilen bir adopt'tan
doğrudan yedekle-ve-yeniden-kur yoluna düşer; sayfa ise parola istemini
gösterecek yeri olmadan başsız çalışır ve siz adıyla istemedikçe bir uygulamayı
asla değiştirmez.

### Terminalden

Uygulama isteğe bağlıdır. Terminalden tam bir güncelleme:

```bash
~/Library/Application\ Support/MacSoftwareUpdater/update_system.1h.sh run all
```

## Motorun komut satırı

`update_system.1h.sh` bir önyükleyici ve dağıtıcıdır; işlevleri `lib/*.sh`
içinde (on modül) durur ve çalışma anında `source` edilir. Her çağıran
aşağıdaki alt komutlardan birini adlandırır; başka her şey kullanım metnini
basıp **2** ile çıkar.

| Çağrı | Ne yapar |
| --- | --- |
| `run all` | Önce `plugin`, sonra `system`: self-update (yalnızca terminal kurulumlarında), ardından tam güncelleme. Özel güncelleme kilidini alır. |
| `run system` | Homebrew ve (etkinse) App Store yükseltmeleri, artı isteğe bağlı temizlik. Özel kilit. |
| `run plugin` | Bekleyen motor güncellemesini kurar — betik ve `lib/` kümesi, ya hepsi ya hiçbiri. Yalnızca terminal kurulumlarında; uygulamanın içindeki motor bunu söyleyip çıkar. Özel kilit. |
| `run single <args>` | Tek bir ögeyi başsız günceller. Özel kilit almaz — eşzamanlılık sınırını uygulama kendi tarafında uygular. |
| `run install <args>` | Bir uygulamanın güncellemesini DMG/ZIP'inden kurar. Özel kilit almaz. |
| `run migrate <app> <token> [adopt\|replace\|dry]` | Tek bir uygulamayı Homebrew'a devreder. Özel kilit almaz. |
| `refresh_cache [auto\|force]` | `auto` (varsayılan) yalnızca bayatlamış katmanları tazeler; `force` (ya da `all`) her şeyi tazeler. Engellemez — zaten bir tazeleme sürüyorsa çıkar. |
| `check_updates` | Elle self-update denetimi (yalnızca terminal kurulumlarında). |
| `brew_update` | Yalnızca `brew update`: hiçbir şeyi yükseltmeden en güncel Homebrew ve tap üstverisini çeker. Bir çalışmayla aynı kilidi alır. |
| `scan_migration` | Homebrew'un yönetebileceği uygulamaları tarar. Asla arka plan tazelemesinin parçası değildir. Cache kilidini alır. |
| `migrate_app <app> <token> [adopt\|replace\|dry]` | Tek bir uygulamanın başsız geçişi. Asla `sudo` çalıştırmaz. |
| `migrate_app_in_terminal <app> <token> [adopt\|replace\|dry]` | Aynısı, seçtiğiniz terminalde — Homebrew'un parola isteyebileceği yerde. |
| `install_app <app> [live\|dry]` | Terminalinizde `run install` başlatır. |
| `update_app <args>` | Terminalinizde `run single` başlatır. |
| `update_tool <source> <name>` | Tek bir npm/pipx/uv/cargo/go paketini terminalinizde günceller (`run tool`); yalnızca son tarama onu listelediyse. |
| `ignore_app <brew\|cask\|mas\|sparkle> <id> [name]` | Bir formula'yı sabitler ya da ögeyi `ignored_apps.conf` dosyasına ekler. |
| `unignore_app <type> <id>` | Bunu geri alır. |
| `toggle_mas` | App Store (`mas`) desteğini açar veya kapatır. |
| `toggle_cleanup` | Çalışma sonrası `brew cleanup --prune=all` seçeneğini açar veya kapatır. |
| `toggle_auto_install` | Otomatik uygulama paketi değiştirmeyi açar veya kapatır. |
| `change_terminal` | Tercih edilen terminal: Terminal, iTerm2, Warp, Alacritty veya Ghostty. |
| `change_branch` | Güncelleme kanalı — bkz. [Güncelleme kanalı](#güncelleme-kanalı). |
| `about_dialog` | Hakkında penceresi. |
| `launch_update [mode]` | Seçtiğiniz terminalde bir çalışma başlatır. |

### Güncelleme kanalı

`change_branch`, **Stable (Main)** ve **Beta (Develop)** seçeneklerini sunar ve
`UPDATE_BRANCH` içine `main` ya da `develop` yazar ve o branch'in motorunun
tamamını (betik ve her `lib/*.sh`, tek bir küme olarak doğrulanarak) kurar.
Yalnızca terminalden kurulan motor için geçerlidir: uygulamanın içindeki motorun
kendi kanalı yoktur, uygulamayla birlikte gelir. Ayar var ve çalışıyor, ancak
**`develop` branch'i şu an yayımda değil** — `origin` üzerinde yalnızca `main` ve
`feature/debug-page` var — dolayısıyla bugün Beta seçmek self-update'i var
olmayan bir branch'e yöneltir. Bir `develop` branch'i duyurulana kadar Stable'da
kalın.

## Yapılandırma dosyaları

Hepsi `~/Library/Application Support/MacSoftwareUpdater/` altında.

| Yol | Ne işe yarar |
| --- | --- |
| `settings.conf` | Motorun ayarları; `setup_mac.sh` tarafından yazılır, yukarıdaki toggle'larla düzenlenir. Mod `600`. |
| `ignored_apps.conf` | Güncelleme listesinden gizlenen uygulamalar (`type\|id\|name`). |
| `tracked_apps.conf` | Tek tek uygulamaların güncellemeler için nasıl denetlendiği. |
| `app_token_map.conf` | Uygulama adı → Homebrew cask token eşlemesi. |
| `app_links.conf` | Bir uygulamanın otomatik bulunmuş web sitesi / GitHub deposu düzeltmeleri. Yalnızca uygulamaya ait — kabuk motoru bu dosyayı hiç okumaz. |
| `cache/` | Önbelleğe alınmış güncelleme verisi ve motor sözleşmesi dosyası. Silmek güvenlidir; otomatik yeniden oluşturulur. |
| `notifications/` | Motorun uygulamanın alması için bıraktığı tek seferlik bildirim istekleri. TTL'li durum değil, olay. |
| `results/` | Tek öge çalıştırması başına bir dosya; o çalıştırmanın sonucunu tutar. |
| `lib/` | On bir motor modülü; tek bir atomik küme olarak indirilir ve doğrulanır. |

`update_history.log` da bunların yanında durur ve uygulamanın gösterdiği geçmişi
tutar.

### `settings.conf` anahtarları

`setup_mac.sh`'ın yazdıklarının tamamı:

| Anahtar | Anlamı |
| --- | --- |
| `PREFERRED_TERMINAL` | `Terminal`, `iTerm2`, `Warp`, `Alacritty` veya `Ghostty`. Warp bir Launch Configuration ile sürülür; bu yüzden onu seçmek `~/.warp/launch_configurations/mac-software-manager-run.yaml` dosyasını yazar — bu araç setinin kendi klasörü dışına yazdığı tek dosya. |
| `MAS_ENABLED` | App Store güncellemeleri. `1` = açık, `0` = kapalı. |
| `UPDATE_BRANCH` | Güncelleme kanalı: `main` (stable) veya `develop` (beta). |
| `AUTOSTART` | Eski otomatik başlatma bayrağı. Kimse okumuyor — girişte başlatma uygulamanın kendi ayarı, macOS tarafından tutuluyor. |
| `CLEANUP_ENABLED` | Her güncellemeden sonra `brew cleanup --prune=all` çalıştır. |
| `AUTO_INSTALL_APPS` | Kendini güncelleyen uygulama paketlerini doğrudan değiştir. Varsayılan `0`. |
| `OTHER_SOURCES_ENABLED` | npm, pipx, uv, Cargo, Go, bağımsız araçlar ve `.pkg` kayıtlarını da listele. Varsayılan `1`. |
| `CODEBERG_USERNAME` | Yedek mirror için kullanıcı adı. Boş = yalnızca GitHub, çift kaynaklı doğrulama yok. |

`setup_mac.sh`'ı yeniden çalıştırmak mevcut değerleri korur.

### `tracked_apps.conf`

Kendi güncellemelerini yöneten uygulamalar otomatik olarak bulunur
(`Info.plist` içindeki Sparkle akışı; yoksa o akıştan ya da bir
`com.github.owner.repo` bundle tanımlayıcısından türetilen bir GitHub deposu).
Otomatik tahmin yanlış ya da eksik olduğunda buraya bir satır ekleyin:

```
App Name|method|identifier

MyApp|sparkle|https://example.com/appcast.xml   # explicit appcast URL
MyApp|github|owner/MyApp                        # GitHub releases feed
MyApp|homebrew|my-app                           # leave it to the Homebrew section
MyApp|skip|                                     # never check this app
```

`App Name`, `.app` uzantısı olmadan paket adıdır ve büyük/küçük harf ayrımı
gözetilmeden eşleştirilir. **Ayarlar → Takip Edilen Uygulamalar**
(Settings → Tracked Apps) üzerinden düzenleyin ya da Yüklü Uygulamalar
sayfasında bir uygulamanın "…" menüsünü açıp yalnızca onu düzeltmek için
**Takip Yöntemini Düzenle…** (Edit Tracking Method…) seçin.

### `app_token_map.conf`

Bazı Homebrew token'ları uygulamanın adından türetilemez (`lghub`,
`logitech-g-hub` cask'idir). Satır başına bir eşleme:

```
lghub|logitech-g-hub
Sublime Text|sublime-text
```

Geçiş sihirbazı da elle bir cask adı yazdığınızda eşlemeyi otomatik ekler; böylece
bir sonraki çalıştırmada eşleşir. **Ayarlar → İsim Eşlemesi**
(Settings → Name Mapping) üzerinden ya da uygulamanın "…" menüsünden
düzenlenebilir.

Buradaki bir eşleme **Homebrew'e Taşı** taramasında `override` sayılır ki bu en
güçlü eşleşmedir: cevabı siz söylediniz, dolayısıyla ondan sonra hiçbir şey
tahmin edilmez ve addan türetilmiş hiçbir aday onu geçemez.

### `app_links.conf`

Web sitesi ve GitHub bağlantıları otomatik bulunur (bir Homebrew cask'inin
bildirdiği homepage ve indirme URL'sinden ya da bir GitHub deposunun kendi
homepage alanından) ve genellikle doğrudur. Biri yanlış ya da eksik olduğunda
uygulamanın "…" menüsündeki **Bağlantıları Düzenle…** (Edit Links…) ile
düzeltin — buraya elle bir şey yazmanız gerekmez:

```
App Name|website|owner/repo
```

Yalnızca o alan için otomatik bulunan değeri korumak üzere iki alandan biri boş
bırakılabilir. Tümüyle yereldir: kabuk motoru bu dosyayı hiç okumaz.

## Güvenlik

Bir güvenlik açığı bildirmek için [SECURITY.md](SECURITY.md) dosyasına bakın —
lütfen bunun için herkese açık bir issue açmayın.

### Self-update

Self-update, her menü tazelemesinde çalışan bir betiğin üzerine yazar; bu yüzden
üç denetimden geçmeden hiçbir şey kurulmaz: indirilen dosya `zsh` olarak
ayrıştırılabilmeli, SHA-256'sı yayıncının `SHA256SUMS` dosyasıyla eşleşmeli ve —
bir mirror yapılandırılmışsa — ikinci kaynağın `SHA256SUMS` dosyası da aynı
şeyi söylemelidir.

* **`CODEBERG_USERNAME` ayarlıyken:** iki bağımsız kaynak karşılaştırılır. Ele
  geçirilmiş ya da yarım gönderilmiş tek bir mirror böyle yakalanır ve ikisi
  uyuşmazsa güncelleme reddedilir.
* **Ayarlı değilken:** dosya yalnızca GitHub'a karşı doğrulanır. Bu açıkça
  söylenir — motor her denetimde bunu yazar — güvence sessizce düşürülmez.

Kendini yalnızca terminalden kurulan motor günceller — betik ve `lib/` ikisi de
`~/Library/Application Support/MacSoftwareUpdater/` altındayken. Uygulamanın
içindeki motor kod imzalı bir pakette durur: içine yazmak imzayı bozar, bu
yüzden `check_updates`, `run plugin` ve `change_branch` ona dokunmaz; o
uygulamayla birlikte güncellenir.

İndirmeler HTTPS üzerinden ve TLS 1.2 zorunlu tutularak yapılır. Kurulu
betikleri kendiniz değiştirirseniz checksum karşılaştırması bunu yakalar ve bir
araç seti güncellemesi uyarısı görürsünüz.

### Uygulama değiştirme

Varsayılan olarak kapalıdır (`AUTO_INSTALL_APPS=0`); **Ayarlar → Güncellemeler**
(Settings → Updates) altından açın.

Açıkken bir uygulama paketini değiştirmek
[lib/app_install.sh](lib/app_install.sh) üzerinden geçer ve diske bir şey
yazılmadan önce her denetimin geçmesi gerekir:

1. **Team ID eşleşmesi** — indirilen paketin `TeamIdentifier` değeri kurulu
   olanınkiyle aynı olmalıdır. İmzasız bir kurulu uygulamanın
   karşılaştırılacak bir şeyi yoktur, bu yüzden asla değiştirilmez.
2. **Kod imzası** — indirilen dosya üzerinde `codesign --verify`.
3. **Gatekeeper** — `spctl -a -t open`. Dağıtım için imzalanmamış ve notarize
   edilmemiş her şeyi reddeder.
4. **Sparkle EdDSA** — uygulama bir `SUPublicEDKey` yayımlıyorsa ve akış bir
   imza taşıyorsa doğrulanır. Eşleşmeyen bir imza ölümcüldür; eksik anahtar ya
   da imza ise geçildi diye değil, denetlenmedi diye bildirilir.
5. **Sürüm eşleşmesi** — paket, akışın vaat ettiği sürüm olmalıdır.

Yalnızca `.dmg` ve `.zip` kabul edilir. **`.pkg` doğrudan reddedilir**: root
olarak preinstall/postinstall betikleri çalıştırır; bu ne sandbox'lanabilir ne de
geri alınabilir. Eski paket silinmez, kenara alınır ve herhangi bir hatada geri
yüklenir. Her kurulum ayrıca indirmeyi ve tüm imza denetimlerini hiçbir şeyi
değiştirmeden yapan bir **Kuru çalıştırma (değişiklik yok)** (Dry run) seçeneği
sunar.

## Kaldırma

Bunun iki yolu var ve ikisi de aynı kodu çalıştırır.

### Uygulamadan

**Ayarlar › Kaldır** sayfası, aracın bu Mac'e bıraktığı her şeyi ögesi başına
bir onay kutusuyla listeler; her satırda tam olarak hangi yolun silineceği
yazar. Gitmesini istediklerinizi işaretleyin, **Seçilenleri Kaldır**'a basın,
bir kez onaylayın. Aracın her yerinde olduğu gibi burada da bir **Kuru
çalıştırma** var: işaretli her ögenin neyi kaldıracağını bildirir, hiçbir şeyi
kaldırmaz.

Sayfa, `uninstall.sh`'yi işaretlenen adımları bayrak olarak vererek çalıştırır;
bu da betiğin sorularını tamamen kapatır — seçim zaten arayüzde yapılmıştır.
İki şeyi betik yerine Swift tarafında yapar, çünkü bunları yalnızca çalışan
uygulama kalıcı kılabilir: `SMAppService` giriş ögesini kapatmak ve
tercihlerin bellekteki, kapanışta diske geri yazılacak kopyasını düşürmek.

Mac'te `uninstall.sh` hiç yoksa — uygulama disk imajından sürüklenmiş ve
`setup_mac.sh` hiç çalışmamışsa — sayfa bunu söyler ve uygulamayı Çöp
Kutusu'na taşıyıp tercihlerini temizlemeyi önerir; o durumda kaldırılacak
başka bir şey zaten yoktur.

### Terminalden

`setup_mac.sh` application support klasörüne bir kaldırma betiği bırakır:

```zsh
~/Library/Application\ Support/MacSoftwareUpdater/uninstall.sh
```

Argümansız çalıştırıldığında beş adımın her birinden önce sorar:

1. **Uygulama** — `/Applications/MacUpdaterGuide.app` dizinini kaldırır; 4.
   adımın çalışabilmesi için bundle tanımlayıcısını önce paketten okur.
2. **Giriş ögesi** — eski usul LaunchAgents ve System Events giriş ögelerini
   kaldırır. Uygulamanın kendisi `SMAppService` üzerinden kaydolur; bu ancak
   uygulamanın içinden ya da Sistem Ayarları'ndan kapatılabildiği için betik o
   bölmeyi açmayı önerir.
3. **Veri ve yapılandırma** —
   `~/Library/Application Support/MacSoftwareUpdater` dizinini siler.
4. **Uygulama tercihleri** — 1. adımda okunan bundle tanımlayıcısı için
   `defaults delete`.
5. **İsteğe bağlı bağımlılıklar** — `mas`'ı kaldırmayı önerir, kendi onayının
   arkasında. Araç setinin kendisi için kurduğu tek paket odur. Homebrew'a
   dokunulmaz: ilgisiz yazılımları da barındıran sistem geneli bir paket
   yöneticisidir, onu kaldırmak bu betiğin işi değildir. Betik bunu söyler ve
   Homebrew'un kendi yönergelerine yönlendirir.

Adı verilen adımlar hiçbir şey sormadan çalışır; uygulama betiği böyle sürer:

```zsh
uninstall.sh --list                  # neler var, adım başına bir satır
uninstall.sh --app --data            # yalnızca bu ikisini kaldır, soru sorma
uninstall.sh --all --dry-run         # her şeyi bildir, hiçbir şeyi kaldırma
uninstall.sh --help                  # tüm bayraklar
```

Adı verilen her adım bir `RESULT|adım|sonuç|ayrıntı` satırı, `--list` ise bir
`ITEM|adım|yes|no|ayrıntı` satırı basar; böylece çağıran taraf çıkış kodundan
tahmin yürütmek yerine adım adım sonuç bildirebilir.

## Geliştirme

Akış, tek bir kural kopyasını güncel tutmak için burada değil kendi
belgelerinde duruyor. [CONTRIBUTING.md](CONTRIBUTING.md) (İngilizce) bunun
tamamıdır: çalışma kopyanızı `--local` ile kurmak, iki test takımını da
çalıştırmak, sürüm ve checksum kuralı, CI'nın dört işinin ne denetlediği ve bir
cache biçimi değişikliğinin ulaşması gereken dört yer. Pull request'ler `main`
dalına gönderilir.

* **[CONTRIBUTING.md](CONTRIBUTING.md)** — kurulum, testler, kabuk stili,
  sürüm/checksum kuralı, CI, dallar ve pull request'ler.
* **[GuideApp/README.md](GuideApp/README.md)** — SwiftUI uygulaması tek başına:
  `run.sh` ile derlemek, sayfa–view eşlemesi ve Hata Ayıklama sayfası.
* **[CACHE_FORMAT.md](CACHE_FORMAT.md)** — motorun ve uygulamanın ikisinin de
  uymak zorunda olduğu dosya sözleşmesi.
* **[CHANGELOG.md](CHANGELOG.md)** — her sürümde nelerin değiştiği.

## Bilinen sınırlar

* **Apple'ın kendi uygulamaları** (iMovie, GarageBand ve arkadaşları) çoğu zaman
  `mas` CLI'ına görünmez. İzlenebilirler ama güncellemenin kendisi App Store'da
  yapılmalıdır.
* **Apple Silicon üzerinde çalışan iPad/iPhone uygulamaları** bu araca görünmez.
  Bu, araç setinin değil `mas`'ın sınırıdır.
* **Setapp** — `/Applications/Setapp/` altındaki her şey tümüyle atlanır. Setapp
  kendi güncelleyicisiyle gelir ve o paketleri değiştirmek onu bozar.
* **`.pkg` indirmeleri kurulamaz.** Yalnızca `.dmg` ve `.zip`; bir `.pkg` her
  zaman yayıncının sayfasını açar.
* **Düz "Apple Development" sertifikasıyla imzalanmış uygulamalar** — küçük açık
  kaynak projelerde sık görülür — Gatekeeper tarafından reddedilir ve elle
  kurulmaları gerekir. Bu, çözülmesi gereken bir hata değil, amaçlanan sonuçtur.
* **`develop` güncelleme kanalı** seçilebilir ama o branch şu an yayımda değil.

## Lisans

MIT — bkz. [LICENSE](LICENSE).
