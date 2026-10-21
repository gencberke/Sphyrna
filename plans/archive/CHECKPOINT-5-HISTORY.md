# Checkpoint 5 — Terminal motoru ve ilk pencere

Güncel iş konumu: [STATUS.md](../STATUS.md). Aşağıdaki bölümler plan ve sonuç geçmişidir.

## 1. Amaç ve kapsam (28 Eylül 2026)

CP2 çekirdeğini, korunmuş tasarım içinde gerçek Claude/Codex terminalleriyle kullanılabilir hale getirmek. Checkpoint kimliği 5'tir; uygulama sırası sözleşme §3/§11 uyarınca 1 → 2 → **5'in ilk pencere kısmı** → 4 → 3'tür.

Kabul edilen kapsam: Claude/Codex, proje ve projesiz sohbet, proje/aktivite görünümü, arama, yeniden adlandırma, durum göstergeleri, devam/durdur, temel terminal kullanımı. macOS 27+. Kırmızı düğme/Cmd+W pencereyi kapatır, işler sürer; Cmd+Q tam çıkıştır.

Kapsam dışı: başka sağlayıcılar ve normal shell'in ürün seçeneği olması, çocuk görev ağacı/transkripti, Dock ve menü çubuğu dikkat bildirimleri, listeden/kalıcı silme, otomatik temizlik, koordinasyon, geçmiş içe alma, tam transkript araması, worktree yönetimi, kullanım hakkı ekranı, yeni chat arayüzü. Sentetik shell/fixture yalnızca geliştirme ve test aracıdır. İlk pencere tamamlandı demek bütün CP5 performans hedefleri veya v1 tamamlandı demek değildir.

## 2. Yerelde doğrulanan başlangıç ve açıklar

Başlangıç: `main`, `f064fb2`; çalışma ağacı temizdi. `git log -10 --oneline` ve `git status` okundu. Ortam: `sw_vers -productVersion` → 27.0; `swift --version` → Swift 6.4, arm64; SDK Command Line Tools altında. Bu bölüm kaynak incelemesidir; bu planlama turunda uygulama davranışı veya derleme yeniden sınanmadı.

| Kanıt | Sonuç / plan etkisi |
| --- | --- |
| `Package.swift:8` | macOS 14 yalnız test tabanı olarak yazılmış; uygulama hedefi yok. Kabul edilen minimum 27'ye uygulanacak. |
| `Sources/LoomCore/TerminalEndpoint.swift:6`, `:102`, `:112` | `TerminalOutputSink.receive` seri IO kuyruğunda senkron çağrılır; özel sink verildiğinde ikinci byte scrollback oluşturulmaz. UI'nin ayrı PTY başlatmasına gerek yok. |
| `Sources/LoomCore/SessionEventHub.swift:36`, `:71` | Her olay son oturum haritasını taşır; tüketici tamponu yalnız son frame'i saklar. Ara olayların hepsinin teslim edildiği varsayılamaz. |
| `Sources/LoomCore/SessionLifecycleController.swift:89`, `:120`, `:208`, `:309` | Otomatik değerlendirme, tek zamanlayıcı, bilinçli görüntüleme ve resume var. CP2 §22.2'de istenen akış/zamanlayıcı zaten uygulanmış; tekrar yazılmayacak. |
| `Sources/LoomCore/SessionCatalog.swift:17`, `:72`, `:95`, `:586` | Başlık ve çalışma dizini var; proje kayıtları/sırası ve başlık değiştirme işlemi yok. Liste bütün kayıtları okuyor; pencere için sayfalı okuma gerekiyor. |
| `Sources/LoomCore/ProcessSupervisor.swift:110`, `:727`, `:901` | Son stop raporu sorgulanabilir; otomatik lider çıkışının başarısız stop sonucu bütün UI tüketicilerine kalıcı son durum olarak taşınmıyor. CP2 §26 madde 2'nin görünür hata yolu bağlanmalı. |
| `Sources/LoomCore/CodexSessionCoordinator.swift:8`, `:111` | Onay istekleri ayrı akışta, yanıt işlemi mevcut. Yeni UI onayları kendiliğinden cevaplamaz; gerçek remote TUI akışının kullanıcı etkileşimiyle bitmesi sınanır. |
| `Sources/LoomCore/ProcessSupervisor.swift:498`, `Sources/LoomCore/ShutdownReport.swift:11` | Ortak shutdown ve başarı ölçütü var. Uygulama çıkışı bunun sonucuna dayanır; terminal görünümünün kalkması başarı kanıtı değildir. |
| `Sources/LoomCore/CoalitionCapability.swift:23`, `plans/DEVELOPMENT-STARTUP-ISOLATION.md` | Sahiplik katmanı süreç başlamadan sınanmalı; terminalden geliştirme girişinin tam izolasyonu ayrı açık iş. İlk pencere LaunchServices ile açılacak; ayrı plan otomatik kapanmaz. |

CP2 §28 kapanışı korunur. Pencere uyarlamasında ortaya çıkan kusurlar bu dosyada kaydedilir; CP2 bölümleri yeniden yazılmaz.

## 3. Terminal ve arayüz teknik yönü

### 3.1. Seçim ve kanıt

İlk aday **SwiftTerm**, AppKit `TerminalView`; pencere/menüler AppKit, sidebar ve uygulama kontrolleri SwiftUI. Sebep: mevcut Swift çekirdeğine doğrudan byte bağlantısı ve mevcut tasarımın native karşılıkları. Eski `LocalProcessTerminalView`/`NativeTerminalSession` süreç yönetimi taşınmaz; süreç sahibi LoomCore kalır.

28 Eylül 2026'da TinyFish ile [SwiftTerm ana belgesi](https://github.com/migueldeicaza/SwiftTerm) ve [Ghostty mimari belgesi](https://ghostty.org/docs/about) okundu. SwiftTerm belgesi, `TerminalViewDelegate` ile dış veri kaynağını bağlamayı açıkça tarif ediyor. Ghostty belgesindeki libghostty bilgisi tek başına harici PTY entegrasyonunu kanıtlamıyor; bu tur Ghostty entegrasyonu sınanmadı, performansı hakkında karşılaştırmalı sonuç çıkarılmadı. SwiftTerm A dilimini geçemezse motor kararı yeniden açılır; iki motorlu ürün veya peşinen fork yapılmaz.

Uzak kaynağın salt okunur incelemesi `/tmp/loom-cp5-swiftterm-20260928` altında yapıldı:

- `git ls-remote`: v1.13.0 → `8e7a1e154f470e19c709a00a8768df348ba5fc43`; o anda `main` → **`fe4fb45d5888ce33ff3788d6873870a73894a41b`**.
- 1.13.0 kaynakları eski `design/legacy-code/TerminalHost.swift:208` ayarlarının tümünü sunmuyor: `maximumOscBytes`, `kittyClipboardPolicy`, `suspendsRenderingWhenNotVisible` o etikette yok. Eski dosyayı kopyalamak derlenebilirlik kanıtı değildir.
- A dilimi yukarıdaki **main commit'ini tam revision ile** dener; hareketli branch'e bağımlılık verilmez. Bu, Claude/Codex sürümü sabitleme kararı değildir. Derleme ve entegre davranış henüz **doğrulanmadı**.
- Sabit revision kaynakları: [MacTerminalView.swift](https://github.com/migueldeicaza/SwiftTerm/blob/fe4fb45d5888ce33ff3788d6873870a73894a41b/Sources/SwiftTerm/Mac/MacTerminalView.swift) `:285` görünürlükte çizim durdurma, `:561` options alan kurucu, `:641` `setUseMetal`; [AppleTerminalView.swift](https://github.com/migueldeicaza/SwiftTerm/blob/fe4fb45d5888ce33ff3788d6873870a73894a41b/Sources/SwiftTerm/Apple/AppleTerminalView.swift) `:4411` arka plan thread'inden çağrılabilen `nonisolated feed`; [TerminalRenderOwner.swift](https://github.com/migueldeicaza/SwiftTerm/blob/fe4fb45d5888ce33ff3788d6873870a73894a41b/Sources/SwiftTerm/Apple/TerminalRenderOwner.swift) `:263` kilit altında parse; [TerminalOptions.swift](https://github.com/migueldeicaza/SwiftTerm/blob/fe4fb45d5888ce33ff3788d6873870a73894a41b/Sources/SwiftTerm/TerminalOptions.swift) `:182` OSC sınırı, `:188` clipboard politikası. Kaynaktaki yorum davranış testinin yerine geçmez.
- Yerel AppKit SDK `Headers/NSGlassEffectView.h:19` macOS 26+ API'yi içeriyor; `Headers/NSApplication.h:314` asenkron çıkış için `replyToApplicationShouldTerminate` sözleşmesini açıklıyor. Yeni minimum 27 olduğu için eski macOS cam yolu eklenmez.

### 3.2. Bağlantı kuralları

Terminal nesnesi run kimliğine bağlıdır. Aynı PTY içindeki `/clear` veya `/new` yeni katalog sohbetine geçince aynı terminal korunur; eski sohbet seçildiğinde yeni sohbetin terminaline yanlışlıkla girdi gönderilmez. Yeni run eski endpoint/sink/girdi işlerini devralmaz.

`receive` çıktıyı sırasını koruyarak motorun belgelenmiş arka plan feed yoluna verir. Byte başına MainActor işi/JSON/olay oluşturulmaz; sınırsız async kuyruk eklenmez. Parse ve çizim kilitlerinin IO'yu geciktirmesi A diliminde ölçülür. Gizli terminalin çıktısı okunmaya ve işlenmeye devam eder, çizimi durur. Sink ve view ömrü bitişteki son çıktı tamamlanana kadar korunur. Motorun UI nesnesine erişim kuralları varsayımla `@unchecked Sendable` eklenerek geçilmez.

Klavye, paste ve terminalin cevap byte'ları aynı sıralı yazma yolundan `TerminalEndpoint.write`'a gider. Her callback için bağımsız `Task` açıp byte sırası şansa bırakılmaz; kısa yazmanın kalan kısmı gönderilir, kapalı/eski run hata verir. Resize `TerminalEndpoint.resize` üzerinden son boyuta ulaşır. Süreç yöneticisi terminal IO yoluna tekrar sokulmaz.

Başlangıç teknik sınırları: 2.000 satır scrollback, 1 MiB tek OSC, 16 MiB Kitty image cache; `kittyClipboardPolicy: []`. Görsel protokollerde diğer depoların da sınırlı olduğu denetlenir; yalnız satır sınırı toplam bellek sınırı sayılmaz. A dilimi bu değerlerin seçilen revision'da uygulanabildiğini ve gerçek TUI'yi bozmadığını raporlar. Ham byte'lar taşmada sessizce atılmaz; ek kuyruk gerekirse kapasite ve açık hata davranışı kanıtla tanımlanır.

`TERM=xterm-256color`; `COLORTERM=truecolor` renk fixture'ı geçince verilir. İlk çizim deneyi CoreGraphics ve Metal yollarını aynı yükle ölçer; ürün tek yolla çıkar, motor ayarı kullanıcıya yüklenmez. Sonuç çıkmadan GPU üstünlüğü iddia edilmez.

## 4. Pencere ve kalıcı veri

### 4.1. İlk pencere davranışları

- Tasarım/ikonlar `design/DESIGN.md` §2–3'e göre korunur. Yerel aktivite referansı bu tur görsel olarak incelendi; özgün kullanıcı eki hâlâ mevcut değil. Başlangıç 1220×780 pt, minimum 780×500 pt; sidebar 300 pt, 220–520 pt aralığı; terminal minimum 480 pt. Küçük pencerede sidebar üst sınırı terminal genişliğini koruyacak biçimde daralır.
- Proje ekleme klasör seçiciyle; aynı standartlaştırılmış yol ikinci kez eklenmez. Boş proje kaldırılabilir; klasör dosyaları silinmez. Projeler daraltılır ve sıralanır. Projesiz yeni sohbet kullanıcının home dizininde çalışır.
- Aktivite görünümü son kullanım zamanına göre gün grupları; proje görünümü oluşturulma sırasına göre sabit liste. Seçim yalnız aktivite sırasını etkileyebilir. Sağlayıcı/başlık/proje adı araması; transkript veya kapsam dışı çocuk görev araması yok. Arama alanı görünür kalır.
- Kartta sağlayıcı, başlık, proje, bulunabiliyorsa branch, göreli son kullanım zamanı; süre model çalışma süresi olarak etiketlenmez. Branch okuması `.git/HEAD`/gitdir üzerinden yalnız ilgili projede olay veya uygulama öne gelişiyle yapılır; periyodik git subprocess'i yok.
- Çalışıyor, kullanıcı/onay bekliyor, bilinmiyor ve hata ayrı görünür. Sonlanmış run ile idle/stale yaşam döngüsü karıştırılmaz. Bitişten sonra bakılmamış işaret yalnız güvenilir durum bilgisiyle verilir. Seçili sohbet ancak pencere görünür ve etkinse okunmuş/görüntülenmiş sayılır; liste yenileme kullanım süresini değiştirmez.
- Uygulama açılışında katalog gösterilir; CLI veya terminal tamponu otomatik yaratılmaz. Canlı sohbet tıklanınca mevcut terminale geçilir; canlı run'ı olmayan kayıtta açık `Devam et` eylemi kullanılır. Stale kayıt görüntülenince başlamaz, `Yeniden etkinleştir ve devam et` ister. Eksik sağlayıcı geçmişinde yeni sohbet açılarak hata gizlenmez.
- Başlık özel olarak değiştirildiyse terminal başlık olayı onu ezmez; 160 karakter sınırı. Kimliksiz yeni kayıtta sağlayıcı ve proje temelli varsayılan başlık; başlık üretmek için model çağrısı yok.
- Temel terminal: giriş/çıktı, Unicode/Türkçe, klavye gezinmesi, resize, scroll/seçim, kopyala, bracketed paste, dosya yolu bırakma (Enter göndermez), CLI destekliyorsa yalnız görsel panoyu Ctrl+V olarak iletme, HTTP(S)/mevcut yerel dosya bağlantısı. Keyfi URL scheme çalıştırılmaz. Otomatik pano okuma/yazma izinleri açılmaz.
- Ayarlar: 11–20 pt terminal fontu, yerel CLI bulunma durumu ve tekrar kontrol. `Cmd+O`, `Cmd+N`, `Ctrl+Cmd+S`, `Cmd+,`, `Cmd+W`, `Cmd+Q` ve standart edit menüleri. Hareketi/Saydamlığı Azalt tercihleri çalışma sırasında izlenir; görseli değiştirmezken bütün listeyi sürekli çizen animasyon kullanılmaz.

### 4.2. Veri ve olay sınırı

Oturum/run/sağlayıcı kimliği/yaşam döngüsü SQLite ve supervisor'ın verisidir; UI'de ikinci yönetim modeli kurulmaz. UI yalnız gösterim, seçim ve yürüyen kullanıcı işlemlerini tutar. Tek olay tüketicisi son frame'den toparlanır. Atlama olasılığı olan `change` alanı tek kaynak yapılmaz; durum, okunmamış bitiş ve son stop hatası gerekiyorsa frame'in yeniden kurulabilir son durumuna eklenir. Bitiş bildirimi gibi kalıcı anlam taşıyan bilgi yalnız geçici callback'te bırakılmaz.

`SessionCatalog` içinde başlık değiştirme, proje/sıra ilişkisi ve sayfalı sorgu mevcut desenle eklenir. Schema 1→2 geçişi tek transaction ile mevcut sohbet/run/link verisini korur; yeni/bozuk/yeni sürümlü/yabancı veritabanı ayrımları sürer. Büyük migration veya genel persistence çerçevesi kurulmaz. Seçili kayıt, görünüm modu, sidebar genişliği ve font gibi UI tercihleri bundle'a özel preferences'ta tutulabilir; sağlayıcı kimliği/yaşam döngüsü burada saklanmaz.

Liste ilk 100 kaydı okur, devamını görünürlük ihtiyacıyla getirir; arama ve sıralama katalog sorgusundadır. Durum olayı bütün kataloğu tekrar okumaz. Mevcut çekirdeğin `sessions()` taramaları ve tam olay haritası maliyeti 1.000/10.000 geçmiş kayıt ölçeğinde ayrıca ölçülür; ölçüm başarısızsa önce o somut yol düzeltilir. Olay geldi diye her satır güncellenmez.

## 5. Sahiplik, kapatma ve geliştirme paketi

AppKit bir ana pencereyi yönetir. Cmd+W/kırmızı düğme mevcut pencereyi kapatır, supervisor/hook/server yaşamaya devam eder; Dock simgesine tıklama veya uygulamayı yeniden açma aynı pencereyi gösterir. Kapalı/gizli/örtülü pencerede terminal çizimi ve çalışma animasyonu durur; IO ve gerekli durum işleme sürer. Olağan idle politikası kapalı pencerede de geçerlidir.

Stop yalnız ilgili sohbetin işi için çekirdek işlemini çağırır. `/exit` sonrası arka plan işinin durduğu doğrulanamazsa `Durdurma doğrulanamadı` kalıcı görünür; `Tekrar dene` son raporu günceller. CP2 §26 madde 2'deki `Yine de kapat`, terminal görünümünü kapatıp durumu ve takip kaydını korumak olarak sunulur: kullanıcıya işlerin durduğunun doğrulanmadığı açık yazılır, başarılı stop/idle işaretlenmez ve ikinci run açılamaz. Takibi bırakma, başka sohbetin işini öldürme veya başarılı Quit gösterme anlamına gelemez; farklı bir ürün davranışı istenirse ayrı karar gerekir.

Cmd+Q yeni işleri engeller, lifecycle zamanlayıcısını durdurur, ortak `shutdown` sonucunu bekler; hook alıcısı yönetilen oturumlardan sonra kapanır. AppKit `terminateLater`/yanıt yolu kullanılır. Başarısızlıkta uygulama kapanmaz, rapor ve yeniden deneme görünür; kapanış başlamış supervisor üzerinden yeni iş başlatılmaz. Uzun bekleme görünürdür; zaman aşımı başarılı çıkış sayılmaz. Tek oturum stop'u ile ortak server'ı kapatma birbirine karıştırılmaz.

Yeni geliştirme uygulaması `Loom Dev.app`, bundle kimliği `local.loom.desktop.dev`; ürün için ayrı `local.loom.desktop`. Veriler sırasıyla `~/Library/Application Support/Loom-Dev/` ve `.../Loom/`; kabul deneyleri yalnız Dev/probe altında. `loom-hook` paket içinde bulunur. LaunchServices ile uygulama açılır; ortam çözümünden önce coalition sınanır. Başarısız probe sözleşmedeki dar garanti uyarısını korur.

Paketleme tekrarlanabilir script ile yapılır; sabit yerel code-sign kimliği kullanılır. Kimlik bulunamazsa durum raporlanır; ad-hoc imzayla izin sürekliliği doğrulandı denmez. Ürün uygulamasına kurulum/gerçek profillerle otomatik deneme bu brief'in parçası değildir. Geliştirme kullanıcıya kendiliğinden model çağrısı yaptırmaz, mevcut global CLI ayarlarını değiştirmez, güven onayını atlamaz. CLI kurulum/kimlik doğrulama kullanıcı tarafından terminalde yapılır; giriş bilgilerinin kopyalanması önerilmez.

## 6. Ölçüm ve kabul yöntemi

Bu plandaki sayısal değerler ilk mühendislik hedefleridir; sözleşme §10 için kabul edilmiş ürün bütçesi değildir. Ölçüm raporundan sonra kullanıcıya kaynak bütçesi sunulur. Hedef tutmuyorsa sessizce gevşetilmez; darboğaz ve maliyeti raporlanır.

- Aynı Mac, güç/ekran/ölçek, release build ve sabit fixture: 10 sn ısınma + 60 sn örnekleme, 3 tekrar. Ölçüm aracı boş durumda ayrıca ölçülür. CPU bir çekirdeğin yüzdesi; RSS/physical footprint ayrı. Loom, sağlayıcı/fixture çocukları ve WindowServer ayrı raporlanır.
- Ölçekler: 0/1/10/50 yaşayan **sentetik** terminal, 1.000/10.000 yalnız katalog kaydı. 50 gerçek sağlayıcı/model oturumu açılmaz. Yoğun çıktı yükleri: tek terminal 1 MiB/sn ve 10 terminalin her biri 100 KiB/sn, 60 sn; bir de sınırlı 20 MiB burst. Çıktı hızları fixture tarafından ölçülür, başarı yalnız gözle söylenmez.
- İlk hedefler: boş/gizli uygulamada 60 sn ortalama CPU ≤%1; ısınma sonrası hiçbir durum değişmemiş gizli terminalde çizim sayısı 0; yaşayan terminal olmadan 1.000 idle/stale kayıt ekleyince terminal nesnesi/PTY artışı 0. Geçiş/girdi→görüntü p95 ≤100 ms, sayfalı ilk liste ≤300 ms (yerel disk, 10.000 kayıt); zamanın başlangıç/bitiş noktası logda tanımlanır.
- Tamponlar dolduktan sonra aynı yükü 10 dakika sürdür: her dakika footprint ve tampon/iş kuyruğu sayısı; son 5 dakikada sürekli büyüme olmamalı, ilk/son dakika medyan farkı ≤10 MiB başlangıç hedefi. 100 aç/kapat çevrimi sonrası yaşayan terminal/sink/endpoint ve kuyruk sayısı başlangıca döner. Ölçüm cache ile leak'i ayırır.
- GPU matrisi: cam/opak × boşta/çıktı × görünür/örtülü; çizim motoru deneyi iki motorla aynı fixture. `powermetrics --help` yerelde `--show-process-gpu`, `--show-process-coalition`, sınırlı örnek sayısı ve samplers seçeneklerini gösterdi. Yetki ve gerçek GPU verisinin mevcut olduğu **sınanmadı**. Desteklenen GPU verisi varsa araç/sampler/birim/süre kaydedilir; yoksa `GPU doğrulanmadı` yazılır, CPU veya cihaz toplamı uygulama GPU maliyeti sayılmaz. Ölçüm yetkisi gerekiyorsa kullanıcıya gerekçesiyle sorulur; Xcode/Instruments kurulumu varsayılmaz.

## 7. Senaryo / kabul tablosu

Her satır uygulama raporunda **doğrulandı / başarısız / doğrulanmadı**, komut/run ve kanıt yoluyla cevaplanır. Mevcut kod okuması test sonucu değildir.

| ID | Senaryo | Ölçülebilir kabul | Dilim |
| --- | --- | --- | --- |
| A1 | Paket ve dış PTY bağlantısı | Sabit SwiftTerm revision'ıyla build; LaunchServices ile tek pencere; fixture PID'si supervisor'a ait, ikinci PTY sahibi yok; Quit raporu başarılı, fixture kalıntısı 0. | A |
| A2 | Byte sırası ve terminal | Bölünmüş UTF-8/ANSI, Türkçe/emoji, alternate screen, truecolor, terminal cevapları ve art arda paste/girdi beklenen son ekran/byte dizisini üretir; kısa yazma/eski run testleri geçer. | A |
| A3 | Görünür/gizli çıktı | §6 yükleri altında byte kaybı/sonsuz bekleme yok; gizle→aç son ekranı korur; örtülü/gizli çizim ısınmadan sonra 0; aynı run için ikinci scrollback yok. | A |
| A4 | Kaynak ve derleyici sınırı | Tampon/OSC/görsel/kuyruk sınırları kaynakla ve taşma fixture'ıyla gösterilir; ölçülen feed/girdi p95 kaydedilir; Swift concurrency hatası gizlenmez. | A |
| B1 | Şema ve liste | Schema 1 fixture'ı bütün sohbet/run/link kimlikleriyle korunur; kesilen migration tekrar açılır; bozuk/yabancı/yeni şema üzerine yazılmaz; 10.000 kayıtta sayfalama/arama/sıra doğru. | B |
| B2 | Yeniden açılış | Proje, sıra, başlık ve UI tercihleri korunur; uygulama açılışı hiçbir sağlayıcı/PTY başlatmaz; kayıt başına terminal yaratılmaz. | B |
| B3 | Olay kaybından toparlanma | UI tüketicisi bekletilip burst verilir; son frame'le durum, aktif run, kimlik ve son hata doğru gösterilir; ara `change` atlanınca yanlış bitiş/başarı oluşmaz. | B |
| C1 | Yeni Claude/Codex | Kullanıcı eylemiyle doğru dizin/profilde gerçek TUI; eksik CLI veya ortam hatası görünür, yeniden deneme çalışır, hayalet canlı run yok; güven/izin kullanıcıda. | C |
| C2 | Kimlik ve devam | `/clear` ve `/new` eski kaydı korur; aynı run görünümü yeni kimliğe bağlanır; eski kart yeni terminale yazamaz; açık resume aynı geçmişi açar; eksik geçmiş yeni sohbete dönüşmez. | C |
| C3 | Yaşam döngüsü | Aktif tur/onay/arka plan işi idle olmaz; idle ve stale seçimi kendiliğinden başlatmaz; görünür/etkin seçme kullanım zamanını günceller, gizli/pasif liste yenileme güncellemez. | C |
| C4 | Onay ve dürüst hata | Claude/Codex onayı kullanıcıya ulaşır ve kullanıcının yanıtıyla sonuçlanır; belirsiz kimlik, kopan server ve stop hatası doğru kartta kalır; otomatik onay yok. | C |
| C5 | Stop ve `/exit` | İki canlı sohbette birini durdurmak diğerini etkilemez; lider çıkışı sonrası iş denetlenir; başarısız stop yeniden açmayı engeller, görünümü kapatmak takibi silmez. | C |
| D1 | Tasarım ve girdi | İki görünüm 1220×780 ve minimum boyutta referansla karşılaştırılır; kontroller/başlıklar taşmaz; kısayollar, font, paste/drop, bağlantı ve erişilebilirlik tercihleri çalışır. | D |
| D2 | Pencere kapatma | Cmd+W/kırmızı düğme sonrası fixture işi sürer, çizim durur; Dock/yeniden açma aynı pencere/terminali getirir; pencere sayısı en fazla 1. | A,D |
| D3 | Tam çıkış ve hata | Başlatma sürerken/aktif turda/gizli pencerede Cmd+Q: başarılı normal çıkış sonrası tüm sahip olunan çalışan süreçler 0, dış kontrol süreci değişmez. Zorlanan hata başarı göstermez; tekrar deneme sınanır. | A,C,D |
| D4 | Uzun kullanım ve ölçek | §6'nın 50 terminal/10.000 kayıt/100 çevrim/10 dakika sonuçları tabloya yazılır; sınır aşımı veya sürekli büyüme varsa kapatma engelidir. | D |
| D5 | GPU ve görsel tercihler | Cam/opak matrisi ve azaltılmış hareket/saydamlık ayrı kayıtlı; ölçümün veremediği sonuç açıkça doğrulanmadı. Tam kaynak kabulü GPU/bütçe açıkken kapanmaz. | D |
| D6 | Çökme/Force Quit ayrımı | İzole fixture ile normal Quit'ten ayrı kanıt; sonraki açılış otomatik sohbet başlatmaz ve eski canlı durumunu başarıyla kapanmış saymaz; normal Quit sonucu çökmeye genellenmez. | D |

## 8. Uygulama sırası ve review kapıları

**A — Paket + bir terminalin bağlantısı.** `Loom Dev.app` hedefi/paketleme, sabit motor revision'ı, mevcut supervisor'a sink/girdi/resize bağlantısı, sentetik fixture, Cmd+W/yeniden açma/Cmd+Q. §7 A1–A4 ve D2/D3'ün sentetik kısmı. Proje kataloğu, bütün sidebar ve gerçek model turu yok. Çıkışta hangi motor/sınırlar seçildiği kanıtla önerilir. Review geçmeden B'ye geçilmez.

**B — Katalog ve arayüzün veri kaynağı.** Küçük migration/sayfalama, proje ve başlık işlemleri, son durum/stop hata görünürlüğü, UI gösterim modeli; §7 B1–B3. Veri katmanı durumu yöneten ikinci kaynağa dönüşmez. Review geçmeden sağlayıcı bağlantıları genişletilmez.

**C — Gerçek oturum işlemleri.** Tek uygulama runtime'ı mevcut Claude hook adapter, Codex manager/coordinator, lifecycle ve supervisor'ı birleştirir. Yeni/resume/kimlik değişimi/durum/onay/stop/hata; §7 C1–C5, D3 sağlayıcı kısmı. `Sources/loom-probe` deney akışları doğrudan ürün koordinatörü olarak kopyalanmaz. Model turu kapısı §9'dur.

**D — Görünüm ve kapanış kabulü.** Tasarımın son uygulaması, arama/ayarlar/branch/dikkat işaretleri, pencere yeniden açma, ölçek/CPU/bellek/GPU, çökme ayrımı. §7 D1–D6 ve birleşik senaryolar. Sayısal ürün bütçeleri ölçümle kullanıcıya sunulur. Tüm ilk pencere kabulü geçmeden `Tamamlandı` yazılmaz; tam CP5'ten kalanlar tek bölümde toplanır.

Her dilim sonunda implementer bu dosyaya numaralı uygulama sonucu ekler, durum satırını günceller ve durur. Reviewer kaynak/kanıtı inceler, `swift build` ve tam test paketini çalıştırır. Süreç/IO/çizim/kaynak değişikliği içeren dilim kapanmadan rol protokolündeki optimizer incelemesi yapılır; reviewer yöntem veya ölçümü doğrular. Bu planlama turunda optimizer çalıştırılmadı.

## 9. Model turu bütçesi ve karar kapıları

- **Onaylandı:** ilk pencere kapsamı, minimum macOS 27, pencere kapanınca işlerin sürmesi. Sözleşme §3'e işlendi.
- **Teknik varsayılan:** AppKit/SwiftUI ve §3'teki SwiftTerm revision'ı A diliminin adayı. Kullanıcıdan genel teknoloji seçimi beklenmez; sonuç başarısızsa kanıtla yeniden planlanır.
- **Şu an izinli model deneyi: 0 tur.** Kaynak/yardım okuma, sentetik test ve UI fixture'ı model çağırmaz. A/B diliminde gerçek model turu çalıştırılmaz.
- **C öncesi önerilen bütçe, henüz onaylanmadı:** toplam en fazla 8 model turu; sağlayıcı başına yeni sohbet, resume/hatırlama, kullanıcı onayı ve aktif turda Quit için 4 tur. Başarısız deneme ve tekrarlar bu toplamdan düşer; otomatik yeniden denemeyle aşılmaz. Onay istenirken hazır fixture, izolasyon kökü, prompt ve beklenen kanıt kullanıcıya gösterilir. Bütçe onaylanmazsa sentetik işler bitirilir, gerçek sağlayıcı kabulü doğrulanmadı kalır.
- **D sonrası kaynak kabulü:** §6 ölçümleri üzerine CPU/bellek/GPU/gecikme bütçesi için kullanıcı kararı; önceden hafiflik sözü verilmez. GPU ölçümü yoksa pencere işlevselliği ve tam performans kabulü ayrı raporlanır, açık kapı sessizce kaldırılmaz.

## 10. Kontroller, kanıtlar ve riskler

Gerekli komutlar: `swift build`, `swift test` ve makro yükleme sorunu varsa `swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`; `git diff --check`. Testlere dış süre sınırı konur, zaman aşımında tanı alınır ve yalnız deneye ait süreçler kimlikle temizlenir. Aynı girdide başarılı paketi sebepsiz 20 kez tekrarlama şartı yok. Dar regresyon testleri gerçek hatayı fix olmadan göstermeli. Birleşik sonucu reviewer doğrular.

Görsel/paket çalışma kabulü build'in yerine geçmez. LaunchServices açılışı, paket imzası, pencere ve terminal ekran görüntüleri, fixture byte sayımları, `shutdown.json`, kaynak `samples.json`, sürümler ve run kimliği saklanır. Kalıcı kanıt `~/Library/Application Support/Loom-Dev/probe/runs/<run-id>/` ve değerlerden arındırılmış özet `plans/experiments/` altında; geçici dosyalar `/tmp`'de ve iş bitince temizlenir. Gerçek profil/transkript/ortam/token/kimlik bilgileri loga veya repoya konmaz.

Riskler: etiketsiz motor revision'ının değişen API/derleme bağımlılıkları; senkron parse kilidinin IO'yu geciktirmesi; görünmez view'ın devam eden çizimi; görsel protokollerin satırdan bağımsız belleği; atlanabilen olaylar nedeniyle yanlış okunmamış/bitiş/stop durumu; büyük katalogdaki tam taramalar; tek shared server için yanlış oturum kapatma; yeniden açılışta otomatik süreç; gizli pencerede görünmeyen hata; imza/coalition'ın gerçek .app açılışında farklı davranması. Bunlar bu tur çalıştırılarak doğrulanmış kusurlar değildir; kabul senaryolarının gerekçeleridir.

## 11. Implementer brief — A dilimi

Goal: CP5 §8 A dilimini tamamla; LoomCore'un yönettiği sentetik PTY'yi tek bir native geliştirme penceresine bağlayıp çıktı, girdi, görünürlük ve kapanış kabulünü kanıtla.

Context: Önce `agents/implementer.md` ve `agents/README.md`, ardından `plans/CHECKPOINT-5.md` §2–3, §5–10. Kullanıcı macOS 27+, dar ilk pencere kapsamı ve Cmd+W ile işlerin sürmesini onayladı. SwiftTerm adayı §3'teki tam revision; eski LocalProcessTerminalView süreç yönetimi taşınmayacak. CP2 kapanışı korunacak.

Scope: Yalnız A dilimi; `Package.swift`/çözümlenen bağımlılık dosyası, yeni uygulama ve terminal sunum hedefi, paketleme scripti/kaynak bildirimi, gereken dar LoomCore bağlantısı ve mevcut test düzeninde ilgili test/fixture'lar. Kod tabanında yalnız değilsin; başkalarının değişikliklerini geri alma, başlangıç status/diff'ini okuyup uyum sağla. Tasarım varlıklarını değiştirme; B/C/D işlerine, ürün kurulumuna, gerçek kullanıcı profillerine ve sözleşme değişikliğine girme. Commit/push/PR yapma.

Done when: §7 A1–A4 ve D2/D3'ün sentetik kapsamı kanıtlı; §6'daki uygulanabilir başlangıç ölçümleri kayıtlı; motorun derlenemeyen veya sınanamayan yanı açık. Başka dilime geçmeden bu dosyaya sıradaki numarayla uygulama sonucu ekle; durum satırını güncelle. Model harcayan deney bütçesi 0.

Checks: §10 komutları, dar terminal/IO testleri, LaunchServices üzerinden paket smoke testi, gizli çıktı/resize/run değişimi/kısa yazma ve normal Quit sonrası kalıntı kontrolü. Sonuçları `Status / Result / Evidence / Unverified / Needs` sırasıyla bildir; kaynak tüketimi ve GPU için kanıtın sınırını belirt.

## 12. Uygulama sonucu (28 Eylül 2026)

Başlangıç: `main` `f064fb2`; çalışma ağacında yalnız `LOOM-PRODUCT-CONTRACT.md` değişikliği ve izlenmeyen bu dosya vardı, ikisine dokunulmadı (bu bölüm ve durum satırı hariç). Commit yapılmadı.

### 12.1. Değişiklikler

- `Package.swift`: minimum `.macOS("27.0")`; SwiftTerm tam revision `fe4fb45d5888ce33ff3788d6873870a73894a41b` (`Package.resolved` bunu kaydediyor). Yeni hedefler: `LoomTerminal` (motor köprüsü), `loom-app` (pencere), `LoomTerminalTests`.
- `Sources/LoomCore/TerminalInputQueue.swift`: run başına tek sıralı yazma yolu. `enqueue` eşzamanlı ekler (çağrı sırası = byte sırası); tek drain görevi kısa yazmanın kalanını gönderir, `EAGAIN`'de yalnız bekleyen byte varken geri çekilir. 4 MiB sınırını aşan payload bütün olarak reddedilir ve bildirilir; yazma hatası sonrası girdi reddedilir.
- `Sources/LoomTerminal/TerminalSurface.swift`: bir run'a bağlı `TerminalView`. Çıktı `TerminalOutputSink` üzerinden motorun arka plan `feedSender`'ına verilir (view tutulmaz, `@unchecked Sendable` yok); özel sink verildiği için çekirdek ikinci byte scrollback oluşturmaz. Klavye/paste/terminal cevapları `delegate.send` → aynı kuyruk; `attach` öncesi cevaplar sırayla, 64 KiB sınırla tutulur. Resize son boyuta birleştirilir. Bağlantı yalnız HTTP(S)/mevcut dosya; pano okuma/yazma kapalı; yalnız görsel panoda Cmd+V → Ctrl+V.
- `Sources/loom-app/`: tek AppKit penceresi (1220×780, min 780×500, `isReleasedWhenClosed = false`), Cmd+N sentetik terminal, Cmd+W/kırmızı düğme yalnız pencereyi kapatır, Dock/yeniden `open` aynı pencereyi getirir. Cmd+Q `terminateLater` + ortak `shutdown`; başarısızlıkta uygulama açık kalır, uyarı ve `Try Again`. Açılış hiçbir süreç başlatmaz; fixture yalnız `--fixture` argümanıyla. `--evidence <dir>` yalnız kabul aracı: kullanıcıyla aynı eylemleri (performClose, terminate) dağıtık bildirimle tetikler ve durum yazar. `--metal` yalnız çizim deneyi.
- `Sources/loom-test-child/main.swift`: `terminal-sample` (bölünmüş UTF-8/ANSI, Türkçe/emoji, truecolor, alternate screen, DSR cevabı, FNV girdi özeti), `stream <hız> <byte>` (raw mode, kesin toplam), `interactive`.
- `scripts/package-dev-app.sh`, `scripts/cp5-a-acceptance.sh`, `scripts/cp5-a-measure.sh`.

Sınır değerleri (`TerminalSurfaceLimits`): 2.000 satır scrollback, 1 MiB tek OSC, Kitty 8 MiB/ekran (ana + alternatif = 16 MiB), yerel Kitty medyası kapalı, `kittyClipboardPolicy: []`, sixel reklamı kapalı, 4 MiB bekleyen girdi. `TERM=xterm-256color`; `COLORTERM` bu dilimde verilmedi.

### 12.2. Uygulama sırasında bulunan kusur

Quit'in ilk sürümü `Task { @MainActor }` içinden raporu bekliyordu. `terminate` bir ana-kuyruk bloğundan çağrılınca (bildirim gözlemcisi; ileride bir buton `Task`'ı) AppKit'in iç bekleme döngüsü ana kuyruğu boşaltamadığı için Quit sonsuza kadar bekledi (`sample`: `-[NSApplication terminate:]` → `_shouldTerminate` içinde takılı; run `cp5-a-20260928T171435/window-cycle`, `quit.json` yok). Düzeltme: shutdown `Task.detached`, yanıt `RunLoop.main.perform(inModes: [.common])` (`AppDelegate.swift`, `applicationShouldTerminate`). Aynı senaryo sonrasında geçti (§12.3).

### 12.3. Kabul maddeleri

Kanıt kökü: `~/Library/Application Support/Loom-Dev/probe/runs/`; arındırılmış özet `plans/experiments/cp5-a-acceptance.json`, `plans/experiments/cp5-a-measure.jsonl`.

| ID | Sonuç | Kanıt |
| --- | --- | --- |
| A1 | **doğrulandı** | `scripts/package-dev-app.sh` → `.build/app/Loom Dev.app` (release, `minos 27.0`, ad-hoc imza); `open -a` ile açıldı. Fixture PPID = uygulama PID'i; uygulamada tek `/dev/ptmx` fd'si (`app-pty-fds.txt`). 3 kabul + 15 ölçüm Quit'i: `succeeded: true`, `remaining: 0`, fixture yok (`after-quit.txt`), sonunda `pgrep` boş. Run `cp5-a-20260928T171709`. |
| A2 | **doğrulandı** | `TerminalSurfaceTests.splitSequencesRepliesAndOrderedInputReachTheRun`: byte byte bölünmüş Türkçe/emoji ve bölünmüş SGR doğru ekran; alternate screen içeriği ana ekrana sızmıyor; DSR cevabı motor → Loom kuyruğu → PTY; truecolor hücresi (aynı byte'larla beslenen başsız motorda, çünkü view hücre özniteliğini açmıyor) `trueColor(255,100,0)`; 200 tuş + bracketed paste + 256 KiB paste, FNV özeti ve sayısı eşit. `TerminalInputQueueTests`: kısa/0 yazma altında sıra ve tamlık, taşma, yazma hatası. `endedRunRefusesInputAndNewRunGetsItsOwnSurface`: biten run'a girdi reddi ve görünür hata, eski endpoint yazmayı reddediyor, yeni run yeni yüzey. |
| A3 | **doğrulandı** (tek terminal) | `hiddenSurfaceParsesBurstWithoutLossOrFrames`: pencere yokken 20 MiB burst, alınan = gönderilen + trailer, motora giden = alınan, 0 frame, scrollback satır sınırında. Uygulamada 1 MiB/sn akışta pencere kapalı 10 sn: frame 408 → 408, çıktı +10,6 MB; yeniden açınca aynı run, pencere sayısı 1, çizim sürüyor. Ölçümde gizli akış 3/3 tekrar 0 frame, 60,2 MiB işlendi. Aynı run için ikinci scrollback yok (`endpoint.scrollback == nil`). |
| A4 | **kısmen** | Sınırlar §12.1'de, kaynak `TerminalSurfaceLimits`. Taşma testi yalnız girdi kuyruğu için. Motor sınırları için bu dilimde taşma fixture'ı yazılmadı. **Açık:** seçilen revision'da sixel her zaman parse ediliyor; tek görüntü 64 MiB ile sınırlı (`SixelDcsHandler.swift:14-15`) ama ekrandaki/scrollback'teki toplam görüntü belleğinin host ayarı yok; reklamı kapatmak bunu sınırlamaz. Feed süresi (IO kuyruğunda motorda geçen) p95 0,011–0,058 ms, maks 1,98 ms (1 MiB/sn). Girdi→görüntü p95 ölçülmedi. Swift 6 derlemesi uyarısız; `@unchecked Sendable` yalnız kilitli `TerminalInputQueue` ve test yardımcılarında. |
| D2 | **doğrulandı** (sentetik) | `performClose` (kırmızı düğme ve Cmd+W menüsünün seçicisi) sonrası fixture yazmayı sürdürdü, çizim durdu; ikinci `open -a` (`applicationShouldHandleReopen`) aynı pencereyi ve run'ı getirdi, `windowCount` 1. Gerçek tuş/Dock tıklaması otomasyonla basılmadı. |
| D3 | **kısmen** (sentetik) | Aktif akışta ve gizli pencerede Quit: başarılı, kalan 0, ~0,02 sn. "Başlatma sürerken" senaryosunda Quit, fixture başladıktan sonra ulaştı; gerçekten yarım kalmış launch sınanmadı. Zorlanmış hata yolu (uyarı + `Try Again`) kodda var, **sınanmadı**: gerçek bir durdurulamayan süreç fixture'ı yok. |

### 12.4. §6 başlangıç ölçümleri (release, ad-hoc paket, 10 sn ısınma + 60 sn, 3 tekrar)

`scripts/cp5-a-measure.sh 3`, run `cp5-a-measure-20260928T172305`. CPU bir çekirdeğin yüzdesi (`ps` kümülatif süre farkı); footprint `footprint -p`. Ekran/güç koşulları sabitlenmedi, makine kullanımdaydı; WindowServer sistem geneli olduğu için gürültülü.

| Senaryo | Loom CPU % | Fixture CPU % | WindowServer % | Frame / 60 sn | Footprint |
| --- | --- | --- | --- | --- | --- |
| Boş, görünür, terminal yok | 0,0 / 0,13 / 0,0 | — | 8,3 / 12,7 / 0,7 | 0 | 20–23 MB |
| Gizli pencere, boşta terminal | 0,02 / 0,0 / 0,25 | 0 | 8,5 / 8,8 / 6,0 | 0 / 0 / **2** | 55–57 MB |
| 1 MiB/sn, görünür, CoreGraphics | 38,8 / 34,9 / 34,3 | 6,4–7,6 | 29–36 | ~3.600 | 117–119 MB |
| 1 MiB/sn, görünür, Metal | 43,2 / 37,6 / 18,0* | 6,2–11,4 | 22–41 | 3.131 / 3.613 / 1.256* | 94–101 MB |
| 1 MiB/sn, gizli | 7,8 / 7,4 / 8,3 | 16,0–17,4 | 1–10 | 0 | 57–58 MB |

\* Metal 3. tekrarda frame sayısı düştü; pencere büyük olasılıkla kısmen örtüldü, bu tekrar karşılaştırmaya alınmamalı.

Okuma: boş/gizli uygulama ≤%1 hedefi 3/3 tuttu. "Isınma sonrası gizli ve durumu değişmemiş terminalde 0 çizim" hedefi 2/3; bir tekrarda 60 sn içinde 2 frame çizildi, nedeni araştırılmadı (**başarısız**, tekrar gerekir). CoreGraphics ve Metal arasında bu yükte Loom CPU'sunda anlamlı fark görünmedi; motor kararı için yeterli değil ve GPU ölçülmediği için Metal'in maliyeti bilinmiyor. Pencere kapatma, 1 MiB/sn'de Loom CPU'sunu ~%36'dan ~%8'e indiriyor. Gizli akışta fixture CPU'sunun artması (~%16) fixture'ın hızını tutturmak için daha çok döngü yapmasından; Loom maliyeti değil.

**Doğrulanmadı:** 10/50 terminal, 10 KiB/100 KiB çoklu yük, 10 dakika tampon/footprint büyümesi, 100 aç/kapat çevrimi (A diliminde tek terminal var; §8 D4), girdi→görüntü p95, 1.000/10.000 katalog kaydı (B), GPU (`powermetrics` yönetici yetkisi ister; istenmedi).

### 12.5. Sınırlar ve bulgular

1. **Coalition `.app`'de paylaşımlı çıktı.** LaunchServices uygulamaya kabuktan ayrı bir coalition veriyor (uygulama 31092, kabuk 27411), ama AppKit'in başlattığı Apple XPC servisi `SetStoreUpdateService` aynı coalition'a katılıyor ve uygulama kapandıktan sonra da yaşıyor; sonraki açılışlar aynı coalition kimliğini alıyor. Probe bu yüzden doğru şekilde dar garantiye düşüyor (`ownership-guarantee.txt`, `quit.json`). Risk: ilk açılışta servis henüz yoksa probe exclusivity'yi doğrular; servis sonradan katılırsa `OwnershipLedger.observe` coalition üyelerini sahiplendiği için (`OwnershipLedger.swift`, coalition `metadataSeeds`) Quit Apple'ın servisine sinyal gönderebilir. Bu yeniden üretilmedi, çünkü dış servise sinyal göndermeyi gerektirir. Kaynak okuması ve gözlenen üyelikle çıkarıldı.
2. Sixel toplam belleği sınırsız (A4).
3. İmza: yerelde kod imzalama kimliği yok (`security find-identity` → 0); paket ad-hoc imzalı. İzin sürekliliği doğrulanmadı.
4. Uygulama açılışında önceki çökmüş run'ların kurtarması (probe'daki `recoverStaleRuns` benzeri) yok; ledger ve `owner.json` yazılıyor, kurtarma D6'ya kaldı.
5. Görsel: yalnız koyu pencere + opak terminal paneli; sidebar/tasarım D'ye kaldı. Ekran görüntüsü alınmadı.
6. Test paketi: `swift build` temiz; `swift test` (makro bayrağıyla) 96 test geçti (93 + 3 `LoomTerminalTests`); `git diff --check` temiz.

### 12.6. Needs

- **Reviewer/kullanıcı:** Coalition üyeliği kararı. Seçenekler: coalition'ı yalnız marker/ancestry ile birlikte kanıt saymak (sistem XPC üyelerini asla sahiplenmemek) ya da exclusivity'yi `.app` için hiç iddia etmemek. Bu, CP1 sahiplik sözleşmesini değiştirir; A diliminde yapılmadı.
- **Reviewer:** Sixel için motor fork'u/üst akış yaması mı, yoksa kabul edilmiş risk mi.
- **Kullanıcı:** GPU ölçümü için `sudo powermetrics` yetkisi (§6); verilmezse GPU doğrulanmadı kalır.
- **Reviewer:** Gizli terminalde 2 frame'lik tekrarın incelenmesi A kapanış şartı mı?

## 13. Review: A dilimi (28 Eylül 2026)

**Sonuç: partial; A kapanmadı.** §12'nin açık sınırları doğru şekilde bildirmesi kabul maddelerini tamamlamıyor. A1/A2'nin tek çalıştırma kanıtı ve A3'ün tek terminal çıktı akışı destekleniyor; başlatma tekrar girişi, A4 ve D3 kapıları açık. Önceki bölümler korunur; aşağıdaki hükümler §12'deki yorumların review karşılığıdır.

### 13.1. Kontroller ve kanıt sınırı

- `git status --short`, izlenen diff ve bütün yeni uygulama/terminal/girdi/test/paketleme/ölçüm dosyaları okundu. Kod değiştirilmedi; commit yapılmadı.
- `swift build`: **başarılı**, dış komut 46,12 sn. Ardından belgelenmiş makro bayraklarıyla `swift test`: **başarılı**, 74,14 sn toplam; **93 LoomCore + 3 LoomTerminal = 96 test**. “Uyarısız” değil: Command Line Tools altında bulunmayan linker arama yolları uyarıları var; derleme/test hatası yok.
- Her iki komutta yalnız bu child ortamına `LOOM_FORCE_COALITION_FAILURE=1` verildi. Bu, madde 1 nedeniyle bağımsız coalition sahipliğini kapatan güvenli test koşuludur; coalition etkin `.app` kapanış kabulünü doğrulamaz. Tam pakete 180 sn dış sınır kondu; sınır aşılmadı. Sonunda test helper/fixture süreçleri için yapılan `ps` kontrolünde kalıntı görülmedi.
- `git diff --check` ve yeni plan için whitespace kontrolü temiz. İmza, yeni LaunchServices Quit, GPU veya gerçek sağlayıcı/model deneyi çalıştırılmadı.
- §12'deki iki kanıt kökü okundu: `cp5-a-20260928T171709` ve `cp5-a-measure-20260928T172305`. Toplam 18 `quit.json` başarı bildiriyor. `window-cycle` gerçek shutdown raporunda fixture kimliğine tek sinyal, kalan 0; dosyalardaki dar garanti ve görünürlük sayaçları özetlerle karşılaştırıldı. Bu, kayıtların doğrulanmasıdır; 18 deney reviewer tarafından tekrar yapılmadı. Bunların hepsi dar garanti altında; tüm olası kaçak süreçlerin bulunacağı anlamına gelmez.
- Reviewer'ın zararsız deneyleri ve kaynakları: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-a-review-20260928/` altında `review-results.json`, `build.log`, `test.log`, `ownership.swift`, `app-launch-review.swift`, `sixel-review.swift`. Derlenmiş mevcut Debug object'leriyle çalıştırıldılar. `app-launch-review.swift`, üretim `AppDelegate.swift` metnini değiştirmeden sonuna test kurulumu ekler; pencere açmaz, coalition kapalı supervisor kullanır ve yalnız kendi iki fixture'ını ortak shutdown ile kapatır. Kaynak SHA256 sonuç dosyasındadır. Sixel deneyi 3×6 piksellik küçük görseller kullanır; bellek tüketerek sistemi zorlama yapılmadı.

### 13.2. Engelleyici bulgular

1. **[P1] Coalition üyeliği tek başına dış süreci kapatma listesine sokuyor.**
   - Kaynak: `Sources/loom-app/AppDelegate.swift:116–125`; `Sources/LoomCore/CoalitionCapability.swift:23–48`; `Sources/LoomCore/OwnershipLedger.swift:67–76`, `:97–107`; `Sources/LoomCore/ProcessSupervisor.swift:849–855`, `:889–894`.
   - Çalıştırılan sentetik seçim deneyi: kayıtlı lider **0**, Loom run işareti **yok**, parent PID **1**, yalnız coalition eşleşmesi **var** → `observe` ilgisiz tek kaydı **seçti**. `ProcessSupervisor` bu seçimi sinyal listesine taşıyan yolu kullanıyor. Gerçek dış sürece sinyal gönderilmedi. Seçim hatası **doğrulandı**; Apple servisine gerçekten sinyal gönderildiği iddia edilmiyor.
   - §12'nin belirli `SetStoreUpdateService`/31092 üyeliği gözlemi geçmiş run'ın ayrı süreç tablosuyla tekrar doğrulanamadı; reviewer'ın güncel salt okunur servis taramasında o coalition yoktu. Bu tarihsel ayrıntı belirsizliği, yukarıdaki seçim hatasını ortadan kaldırmaz. Tek açılış probe'u, grubun ileride yalnız Loom işlerinden oluşacağı garantisi vermez. Çekirdekte önceden bulunan kural, yeni `.app` girişinde kritik hale geliyor.
   - Neden önemli: aynı kullanıcıya ait dış sistem yardımcısı sırf gruba katıldığı için TERM/KILL alabilir; PID+başlangıç zamanı kontrolü sürecin kimliğini doğrular, Loom'a ait olduğunu doğrulamaz.
   - Beklenen: tek başına coalition eşleşmesi sinyal yetkisi vermez; isim/Apple binary allowlist'iyle belirli servisi istisna etmek yeterli çözüm değildir. Korunacak garanti ve eski ledger'lardaki yalnız coalition üzerinden sahiplenilmiş kimliklerin yeniden doğrulanması açıkça ele alınır. Kullanıcının kabul ettiği tam temizlik güvencesi sessizce düşürülmez (§15).
   - Kabul: aynı grupta sonradan beliren bağımsız kayıt, onun çocukları ve eski ledger üzerinden geri gelen belirsiz kayıt için **0 sinyal**; gerçek Loom lideri/kanıtlı torunları kapanır; PID reuse ve boot farkı testleri geçer. Gerçek OS servisini öldürmeye gerek yok; mevcut `observe` seam'i ve sinyal kaydedicili sentetik sınama kullanılabilir.

2. **[P1] Başlatma tamamlanmadan ikinci yeni-terminal isteği kabul ediliyor.**
   - Kaynak: `Sources/loom-app/AppDelegate.swift:139–160`, `:165–175`, `:182–190`.
   - Guard `surface.runID != nil` koşuluna bağlı; bu değer ancak `launch` sonrasında atanıyor. Aynı MainActor turunda iki `newTerminal` çağrısı çalıştırıldı: **iki canlı managed session** oluştu. Sonuç `twoImmediateNewRequests liveSessions=2`; güvenli fixture shutdown'ı başarılı, kalan **0**.
   - Neden önemli: A dilimi tek terminal gösteriyor; ilk iş kullanıcı erişiminden düşüyor, ikinci çağrı ilk görünümü ve olay gözlemcisini değiştiriyor. Bu yalnız görsel çift tıklama sorunu değil, görünmeyen canlı iş ve gereksiz kaynak kullanımıdır.
   - Beklenen: başlatma rezervasyonu ilk async noktadan önce kurulur. Başlatılıyor/canlı/bitmiş ayrımı yapılır; eski başlatmanın geç başarısı veya hatası güncel görünümü ve `sessionID`'yi değiştiremez. Başlatma devam ederken Quit rezervasyonu doğru biçimde kapatır.
   - Kabul: aynı turda 2 ve 20 yeni-terminal isteğinde **en fazla 1 canlı run**; ilk başlatma hatasında tek doğru hata ve tekrar deneme; geciktirilmiş başlatma sırasında Quit'ten sonra görünmeyen süreç yok. Kontrol mevcut kusurla başarısız olmalı.

3. **[P1] Sixel'in toplam deposu sınırsız; satır ve Kitty sınırları yeterli değil.**
   - Kaynak: `Sources/LoomTerminal/TerminalSurface.swift:16–25`; sabit bağımlılıkta `EscapeSequenceParser.swift:797–800`, `SixelDcsHandler.swift:14–17`, `Apple/AppleTerminalView.swift:4588–4611`, `:4702–4723`, `Buffer.swift:256–262`, `BufferLine.swift:989–995`.
   - Gerçek `TerminalSurface` ve seçilen motorla küçük çalışma deneyi: her resimden önce imleç aynı satıra getirildi; `enableSixelReported=false` iken 10/100/1.000 resim verildi. Tampon **29 satır** kaldı, ilk satırın resim sayısı **10/100/1.000** oldu. Reklamı kapatmanın parse/depolamayı kapatmadığı ve satır sınırının toplam resim sayısını sınırlamadığı **doğrulandı**. Bu bir footprint/GPU ölçümü değildir.
   - Neden önemli: tek canlı terminal, scrollback satır sayısını artırmadan sürekli bellek biriktirebilir; A4 ve sözleşme §10 sağlanmıyor.
   - Beklenen: toplam decoded görsel deposu için sınırlı bir politika; Sixel ve aynı depoya gelen diğer inline-image yolları birlikte değerlendirilir. İlk tercih dar ve sınanabilir kota/eviction düzeltmesidir. “Sixel'i kapatıyoruz” denecekse gerçek parse/depo yolu kapanmalıdır; özellik kaybı ayrıca açık ürün kararıdır. Bu riski kabul ederek A'yı kapatma önerilmiyor.
   - Kabul: aynı hücreye tekrarlanan görsellerde toplam bayt/adet sınırı korunur; kota davranışı açık, normal terminal byte'ları kaybolmaz. OSC ve Kitty sınırları için de A4'te eksik olan taşma fixture'ları geçer; tampon dolduktan sonra uzun kullanım ölçümüyle sürekli büyüme olmadığı gösterilir.

4. **[P2] Dar sahiplik güvencesi kullanıcıya gösterilmiyor.**
   - Kaynak: `Sources/loom-app/AppDelegate.swift:116–134`; `Sources/loom-app/DevelopmentEvidence.swift:43–46`.
   - Kaynak incelemesinde açıklama yalnız `ownership-guarantee.txt` ve isteğe bağlı evidence Quit JSON'una yazılıyor; görünür pencere/uyarı yolu yok. Raporun “dar garanti uyarısını gösteriyor” ifadesi ancak dosya raporu anlamında destekleniyor. Bu tur GUI üzerinden tekrar sınanmadı.
   - Neden önemli: sözleşmedeki dar garantinin açık bildirimi kullanıcıya ulaşmadan, normal kapatma tüm işlerin temizleneceği izlenimini verir. Aşama A dahi bu sözleşmenin tüketicisidir.
   - Beklenen/kabul: zorlanmış coalition yokluğu ile açılan pencerede, iş başlatılmadan önce veya başlatma yüzeyinde kalıcı ve anlaşılır dar garanti açıklaması; kapatıp yeniden açınca korunur, normal terminal başlığı açıklamayı silemez. JSON/log bunun yerine sayılmaz.

5. **[P2] Quit'in hata ve yarım başlatma kabulü hâlâ sınanmıyor.**
   - Kaynak: `Sources/loom-app/AppDelegate.swift:54–70`, `:224–247`; `scripts/cp5-a-acceptance.sh:62–67`; §12 A4/D3 sonuçları.
   - Mevcut senaryo `launched.json` sonrasında koşuyor; launch'un belirli bir bekleme noktasında olduğuna dair bariyer yok. Implementer da çağrının fixture başladıktan sonra ulaştığını bildirmiş. Testler `quitFinished` başarısızlık uyarısı/`Try Again` ve ana kuyruktan tetiklenen AppKit nested-run-loop regresyonunu kapsamıyor. “Durdurulamayan gerçek süreç yok” bu kabulün ertelenme gerekçesi değildir; kontrollü sonuç/launch seam'i kullanılabilir.
   - Neden önemli: happy-path 18 başarı, kullanıcıyı uygulamada bırakan hata yolunun çalıştığını veya başlatma-Quit yarışında iş kalmadığını kanıtlamaz.
   - Beklenen/kabul: kontrollü başarısız shutdown → uygulama açık ve hata görünür → `Try Again` → kontrollü başarı; beklemede duran launch → Quit → süreç kalmaması. Aynı Quit girişi menü ve ana-kuyruk callback'i yolundan süre sınırıyla sınanır; eski asılma kusuru tekrar ortaya çıkarsa test başarısız olur. Gerçek dış süreç veya yönetici yetkisi gerekmez.

6. **[P2] Ölçüm senaryosunun geçerliliği doğrulanmadan kabul sonucu çıkarılıyor.**
   - Kaynak: `scripts/cp5-a-measure.sh:37–67`; `Sources/LoomTerminal/TerminalSurface.swift:40–68`; ayrıntı §14.
   - Gizli/örtülü koşulu bozulan tekrar geçersiz sayılmıyor; frame ile gerçek çizim karışıyor; feed p95/max ve CPU'nun zaman aralıkları farklı. Bu nedenle gizli çizim başarısızlığı ve renderer karşılaştırması kabul kararı için kullanılamaz.
   - Beklenen/kabul: görünürlük/occlusion değişimleri zaman damgasıyla kayıtlı; geçersiz tekrar açıkça reddedilir. `frames` ve `renders` ayrı; CPU gerçek monoton örnekleme süresiyle, feed dağılımı aynı ölçüm aralığıyla raporlanır. Eksik snapshot sıfır sayaç gibi yorumlanmaz. Girdi→görüntü p95 için A4'te eksik ölçüm ayrıca yapılır; feed p95 onun yerine geçmez.

### 13.3. Bu dilimi tek başına engellemeyen, açık tutulacak işler

- 10/50 terminal, 100 çevrim, büyük katalog ve tam görsel tasarım ilgili B/D dilimlerinde kalır; A'ya topluca çekilmez. Buna karşılık madde 3'ün kota düzeltmesinin anlamlı uzun kullanım sınaması A4 için gereklidir.
- GPU ölçülmedi; CPU'dan GPU sonucu çıkarılmaması doğru. Önce sahiplik engeli giderilir. Sudo izni bu review'ın tamamlanması için gerekmiyor; D'deki GPU kabul kapısı açık kalır.
- Ad-hoc imza ve izin sürekliliğinin doğrulanmaması doğru raporlanmış. Bu paketle sabit kimlik kabulü verilmez; yerel imza kurulmadan izin sürekliliği kapısı kapanmaz. Kullanıcının adına sertifika oluşturulmadı/değiştirilmedi.
- Çökme kurtarması D6'da açık; normal Quit kanıtı bunu kapatmaz. Katalog/gerçek sağlayıcı olmaması A kapsamına uygundur.
- `Package.resolved` motorun tam revision'ını tutuyor. Terminal sink'inde ikinci byte geçmişi yok. Kısa yazma/sıra/taşma testleri ve tek terminal Unicode/ANSI/DSR/burst testleri reviewer çalıştırmasında geçti. Bu olumlu sonuçlar yukarıdaki açıkların yerine geçmez.

## 14. Optimizasyon incelemesi (28 Eylül 2026)

Kullanıcının talimatıyla optimizer **GPT-6 Astra / high** olarak çalıştırıldı. Kaynak ve mevcut kanıt yöntemini salt okunur inceledi; yeni GUI/ölçüm/model deneyi çalıştırmadı. Reviewer aşağıdaki sonuçları dosyalardan kendisi kontrol etti; Sixel için ayrıca §13 madde 3 deneyini çalıştırdı.

1. **§12.4 “gizli terminalde 2 çizim, başarısız” hükmü düzeltilir.** `idle-hidden-3/state-start.json`: görünürlük false, occlusion false, frames 3, renders 2. `state-end.json`: görünürlük true, occlusion false, frames 5, renders 2. Gerçek çizim artışı **0**; senaryo kapalı pencere olarak sabit kalmadığı için **geçersiz tekrar**. SwiftTerm `AppleTerminalView.swift:4006–4019` frame-driver üretimi ile tamamlanmış çizimi ayrı tanımlar; `FrameDriver.swift:509–527` frame sayacını çizimden önce artırır. Motor kusuru bulunmuş sayılmaz ve onu “düzeltmek” için spekülatif optimizasyon yapılmaz.
2. **Metal 3. tekrarın örtülmesi kayıtlıdır.** `stream-visible-metal-3` occlusion başlangıç true, bitiş false. §12'nin şüphesi ham kayıtta destekleniyor; karşılaştırmadan çıkarılmalı. Eş koşullu yeterli tekrar olmadığı için CoreGraphics/Metal tercihi veya kazanç iddiası verilmedi.
3. **Feed p95 yalnız son 4.096 batch'tir.** CoreGraphics 1. tekrar batch 12.276→78.463, fark 66.187; halka bu ortalama hızda yaklaşık **3,7 sn** kapsar. `maxFeedMs` ise ısınma dahil run boyunca maksimumdur. Kaynak yorumları halka sınırını doğru söylüyor; 60 sn ölçümüyle aynı satırdaki değerler tam aralık gecikmesi olarak kullanılamaz. §13 madde 6'nın yöntem düzeltmesi gerekir.
4. **Sixel toplam sınırı eksikliği doğrulandı.** Optimizer'ın O(N) depo argümanı, reviewer'ın sabit satırda 1.000 küçük görsel deneyiyle desteklendi. Belirli bir MiB kazancı ölçülmedi; geniş motor fork'u veya protokol kapatma seçeneği sırf hız için önerilmedi.

Mevcut üç gizli akış kaydı: CPU medyan **%7,82**, aralık **%7,43–8,30**, footprint 57–58 MB, başlangıç/bitiş farkı 0 MB; bunlar ölçümün nominal süre/görünürlük sınırlarıyla okunur. CoreGraphics görünür yük CPU medyanı **%34,88**; optimize edilince ne kazanılacağına dair kanıt yok. Beş kontrollü tekrar ve ölçüm aracının ayrı maliyeti olmadığı için optimizer yönergesine göre karşılaştırmalı performans kararı verilmedi. Önce yöntemi düzeltmek gerekli; rastgele mikro-optimizasyon önerilmiyor.

## 15. Sonraki düzeltme sırası ve karar kapısı

Bu bölüm öneridir; yeni ürün uzlaşması kabul edilmiş sayılmaz. Sözleşme §3 değiştirilmedi, B dilimi açılmadı.

1. **Sahiplik kararı:** öneri, coalition üyeliğini tek başına sinyal yetkisi olmaktan çıkarmak; mevcut lider/session, doğrulanmış torun ve run işaretine dayanmak. Bunun bedeli CP1'deki işaretsiz ve gözlemden kaçan daemonlar için tam temizleme güvencesinin daralmasıdır. Eski ledger kimlikleri de güvenli yeniden doğrulamaya tabi olmalı; bir servis adı istisnası yeterli değildir. Kullanıcı bu daralmayı kabul ederse karar sözleşmeye yazılıp uygulama brief'i kesinleştirilir. Kabul etmezse tam sahipliği sağlayan başka sınır kanıtlanmadan yönetilen uygulama kabulü verilmez. Dış süreçlere sinyal gönderme hiçbir seçenekte kabul edilmez.
2. **Başlatma ve Quit düzeltmesi:** §13 madde 2/4/5; rezervasyon, görünür garanti, kontrollü hata/retry/yarım launch testleri. Bunlar mevcut kabulün düzeltmeleridir, yeni ürün özelliği değildir.
3. **Görsel depo sınırı:** §13 madde 3 için küçük, sınanabilir toplam kota düzeltmesini araştır ve uygula; bağımlılık revision'ı değişirse farkı ve bakım maliyetini açık yaz. Sixel özelliğini kaldırma veya sınırsız bellek riskini kabul etme kararı otomatik verilmez.
4. **Ölçümü onar ve tekrarla:** §13 madde 6 ve §14; güvenli sahiplik düzeltmesinden sonra, kontrollü koşullarla A kapsamındaki kanıtları tamamla. Girdi→görüntü p95 ve A4 taşma kabulünü ekle. GPU için şu aşamada sudo çalıştırma.

Yeni uygulama sonucu bu dosyaya sonraki numarayla eklenir; her §13 bulgusuna numarasıyla cevap verilir. Reviewer derleme/tam paket ve değişen kabul senaryolarını tekrar doğrular; A ancak engelleyici maddeler kapanınca tamamlanır. Model turu bütçesi **0** kalır.

## 16. Kullanıcı açıklaması: arkada kalan iş kabul edilmiyor (28 Eylül 2026)

Kullanıcı, §15'teki daraltma önerisine karşı Loom'da açılan Claude/Codex oturumunun gizlice arka planda çalışmasını istemediğini belirtti. Bu nedenle dar garanti uyarısını gösterip kaçak iş olasılığını kabul ederek A'yı kapatma yolu seçilmeyecek. Mevcut sözleşmenin normal Quit sonrası Loom'a ait çalışan iş kalmaması ve dış süreçlere dokunulmaması şartları birlikte korunur; sözleşmede garanti daraltması yapılmadı.

Kapsam: bir oturum için `Durdur`, uygulama için Cmd+Q. Başarılı durdurma/çıkış denebilmesi için Claude/Codex yanında o kapsamdaki alt ajan, arka plan shell'i, dev server ve yardımcı işler de doğrulanmalıdır. Sadece terminal penceresini veya TUI sürecini kapatmak yeterli değildir. Doğrulanamayan kapanış hata olarak görünür kalır; uyarı vermek tek başına tam kabul sağlamaz.

Daha önce onaylanan Cmd+W/kırmızı düğmeyle yalnız pencerenin kapanması ve işlerin sürmesi kararı değişmedi. Çökme/Force Quit garantisi de normal Quit'ten ayrı, henüz açık kabul konusudur; bu açıklama kanıtlanmamış bir garanti vermez.

Sıradaki sahiplik işi, dış sistem servislerini sahiplenmeden Loom'un başlattığı ayrılan işleri takip edebilen sınırı araştırmak ve zararsız sentetik deneylerle kanıtlamak. §15 madde 1'in daraltma seçeneği bu beklentiyle ilerleme yolu değildir. Yöntem kanıtlanmadan A kapanmaz; §13'teki diğer kusurlar ve model deneyi için 0 tur sınırı sürer.

## 17. Sahiplik araştırması: macOS 27 descendants istemcisi (28 Eylül 2026)

**Durum: araştırma yönü plana alındı; çalışma deneyi yapılmadı.** Kullanıcı bu yönün plana eklenmesini istedi. Bu, Endpoint Security'nin ürün mimarisi olarak seçildiği, Apple yetkisinin mevcut olduğu veya terminal özelliklerinden taviz verildiği anlamına gelmez. Sözleşme §3 değiştirilmez; §16'nın tam kapanış ve dış süreçlere dokunmama şartları korunur.

### 17.1. Amaç ve doğrulanan kaynaklar

Amaç, shell/Claude/Codex başlamadan önce işletim sistemi tarafından kapsamı belirlenen bir izleyici açmak; fork/exec/exit olaylarıyla Loom'un başlattığı işleri kaydetmek ve kapanışta bu kayıtları doğrulamak. Coalition üyeliği tek başına sinyal yetkisi olmayacak. İzleme mekanizması kendiliğinden bir kapatma veya izolasyon garantisi sayılmayacak.

- [Apple: `es_new_descendants_client`](https://developer.apple.com/documentation/endpointsecurity/es_new_descendants_client(_:_:)): çağıranın mevcut ve gelecekteki alt süreçlerini özyinelemeli kapsar; diğer süreçler bu istemciye görünmez. Yerel macOS 27 SDK `EndpointSecurity/ESClient.h:799–827` aynı arayüzü ve macOS 27 kullanılabilirliğini içeriyor; `usr/lib/libEndpointSecurity.tbd` sembolü bildiriyor. **Belge/SDK varlığı doğrulandı; istemci açılışı ve süreç kapsamı çalıştırılarak doğrulanmadı.**
- [Apple: gerekli uygulama yetkisi](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.endpoint-security.client): `com.apple.developer.endpoint-security.client` Apple'dan istenir. Descendants istemcisi belgesine göre root ve TCC/Tam Disk Erişimi onayı gerektirmez; bu, uygulama yetkisi ve imza gereksinimini kaldırmaz. §12'deki ad-hoc paket bu koşulların sağlandığını kanıtlamıyor.
- Apple'ın aynı arayüz için yayımladığı [Markdown belge](https://developer.apple.com/documentation/endpointsecurity/es_new_descendants_client(_:_:).md), çağıranın effective UID'si 0 değilse alt süreçlerde setuid/setgid programların çalıştırılamayacağını ve engellenen exec'in exit olayıyla görüleceğini belirtiyor. Bu ek not yerelde okunan header yorumunda bulunmuyor. Yerel `/usr/bin/sudo` setuid dosyası; **sudo/yetki yükseltme uyumu açık kabul kapısıdır**, sessiz özellik kaybı kabul edilmiş değildir.
- [Apple: `es_sync_client`](https://developer.apple.com/documentation/endpointsecurity/es_sync_client(_:_:)) kuyrukta kendisinden önceki olayların işlenmesini beklemeye yarar. Bu tek başına bütün işlerin durduğunu veya ileride yeni olay oluşmayacağını kanıtlamaz. Yerel `ESMessage.h:2711–2740`, sıra numaralarıyla olay kaybının saptanabileceğini açıklıyor. Olay kaybını gizlemek veya boş kayıt kümesini koşulsuz başarı saymak yasak.

### 17.2. Sınırlı deneyin sırası

1. **Yetki ve imza uygulanabilirliği.** Apple başvuru/provisioning koşullarını ve mevcut imza durumunu belirle; küçük istemcinin gerçek dönüş kodunu kaydet. Kullanıcı adına başvuru, hesap işlemi, sertifika/profil kurulumu veya ayrıcalık değişikliği otomatik yapılmaz. Yetki yoksa aşama `doğrulanmadı / Apple yetkisi gerekli` olarak raporlanır; korumaları kapatarak deneme yapılmaz. Bu sırada salt okunur araştırma ve sentetik test tasarımı tamamlanabilir.
2. **Başlatmadan önce kayıt.** Yetkili ve izole test çalıştırıcısı istemciyi açıp gerekli süreç olaylarına abone olduktan sonra kendi fixture'ını başlatır. Gerçek kullanıcı shell başlangıcı ve CLI profilleri kullanılmaz. İstemci/abonelik başarısızsa yönetilen fixture başlamaz. Başlangıç bariyeri ve pid/audit kimliği eşlemesi kanıtla kaydedilir.
3. **Soy bağı ve kapsam.** Fork, exec, hızlı çift fork, `setsid`, ebeveynin hemen çıkması ve okunabilir ortam işareti bulunmayan Apple binary'si sınanır. Kayıtlı süreç canlılığı ve olay kimlikleri karşılaştırılır; PID yeniden kullanımında eski kimlik yeni sürece taşınmaz. Kullanıcının gerçek servislerine sinyal verilmez.
4. **Durdurma ve eşzamanlı işler.** Aitliği doğrulanmış test işlerini kapat, olay kuyruğunu uygun bariyerlerle işle ve bağımsız fixture kimlikleri üzerinden sıfır kalıntıyı doğrula. İki oturumdan birini durdurmak diğerini etkilememeli. Ortak Codex app-server içindeki thread işi, OS alt süreç kapsamıyla otomatik olarak tek oturuma bağlanmış sayılmaz; mevcut sağlayıcı durdurma/doğrulama yolu ayrıca korunur.
5. **Takip kaybı ve sınır dışına iş devri.** Olay yoğunluğu, gecikmiş tüketici ve izleyici kopması kontrollü olarak sınanır. Kayıp halinde yeni iş engellenir ve başarı bildirilmez; mevcut işleri güvenle yeniden bulup temizleme yolu gösterilmeden tam kabul verilmez. `launchctl`/XPC gibi başka bir servis üzerinden yaratılan işler doğrudan soy ağacının içinde varsayılmaz; yalnız izole test servisiyle kapsam sınanır. Algılanamayan veya kapatılamayan yönetilen iş varsa aday §16'yı sağlamamış sayılır.
6. **Uyumluluk ve maliyet.** Setuid/setgid ve sudo davranışı ayrı gösterilir; gerçek yetki yükseltme deneyi ayrıca kullanıcı onayı gerektirir. 1/10/50 sentetik işte boşta ve fork/exec yükünde CPU, footprint, uyanma ve başlatma/kapanış gecikmesi ölçülür. Sonuç, terminal deneyimi ve kaynak sözleşmesiyle birlikte değerlendirilir; ölçülmemiş “hafif” veya “garantili” sonucu yazılmaz.

### 17.3. Kabul ve karar tablosu

| ID | Kanıtlanacak koşul | Kabul |
| --- | --- | --- |
| ES1 | Yetkili istemci ve başlangıç bariyeri | İmza/yetki kaynağı ve istemci dönüş kodu kayıtlı; istemci/abonelik kurulmadan fixture PID'si oluşmuyor; başarısız kurulmada süreç artışı 0. |
| ES2 | Hızlı ayrılan alt işler | Çift fork + setsid + ebeveyn çıkışı + işaretsiz fixture kimliklerinin tamamı izleyicide bulunuyor; normal kapanış sonrası bağımsız taramada çalışan fixture 0. |
| ES3 | Dış süreç sınırı | Bağımsız kontrol süreci ve izole dış servis için sinyal sayısı 0; aynı coalition üyeliği testinde dış kaydı sahiplenmiyor. Gerçek Apple servisini öldürerek kanıt aranmaz. |
| ES4 | Tek oturum ve tam Quit | İki eşzamanlı fixture oturumundan birini durdurunca yalnız onun işi kapanıyor; Quit ikisini de kapatıyor; eski run olayı yeni run'ı etkilemiyor. Shared server işi için ayrı eşleme/doğrulama gereksinimleri raporlu. |
| ES5 | Olay kaybı/izleyici hatası | Sıra boşluğu veya kopma kontrollü biçimde saptanıyor; yeni iş başlamıyor, yanlış başarılı kapanış yok; mevcut fixture'ların kalıntısız temizliği ayrıca kanıtlanıyor. Yalnız hata göstermek tam kabul değildir. |
| ES6 | Başka servise devredilen iş | İzole servis üzerinden başlatılan fixture'ın sahiplik ve kapatma sonucu belli; kapsam dışına kaçan iş yokluğu kanıtlanamadıysa garanti açıkça doğrulanmadı. |
| ES7 | Terminal uyumu | Normal komutlar ve setuid/setgid yolu ayrı sonuçlu; sudo kısıtı veya başka özellik kaybı varsa kullanıcı kararı olmadan ürün yöntemi seçilmiyor. |
| ES8 | Kaynak maliyeti | Aynı koşullarda en az 5 tekrar; medyan/dağılım, izleyici maliyeti ve olay kaybı sayısı kayıtlı; mevcut çekirdekle maliyet farkı açık. |

**Karar kapıları:** Apple yetkisine erişim; terminal/yetki yükseltme uyumu; bütün gerekli işlerin bulunup kapatılması; kabul edilebilir kaynak maliyeti. Birinin başarısızlığı otomatik olarak daha dar garantiye geri dönüş izni değildir. Çökme/Force Quit sonrası bu istemcinin ve kalıntıların davranışı ayrı araştırılır; normal Quit sonucu o senaryoya genellenmez.

**Kapsam ve çıktı:** Önce izole deney, sonra kanıta dayalı mimari kararı. Üretim sahiplik mekanizmasını bu plan eklemesiyle değiştirme, yeni daemon/sistem uzantısı kurma veya tüm uygulamayı yeniden düzenleme işi verilmiş değildir. Mevcut §13 kusurları açık kalır. Sonuç bu dosyaya sonraki numaralı bölüm olarak `doğrulandı / başarısız / doğrulanmadı`, komut, run kimliği ve kanıt yoluyla yazılır. Geçici deneyler `/tmp`; kalıcı arındırılmış kanıt `Loom-Dev/probe` altında. Model harcayan sağlayıcı deneyi bütçesi **0 tur**; ilk deneyler bütünüyle sentetik.

## 18. Review: düzeltmelerin ara incelemesi (28 Eylül 2026)

**Sonuç: partial; A kapanmaz.** Kullanıcının ilettiği ara rapor incelendi. İnceleme sırasında implementer'ın bahsettiği §18 uygulama sonucu dosyada henüz yoktu; sıradaki numara bu review için kullanıldı. Ölçümün uygulama sonucu, mevcut bölümleri değiştirmeden §19'dan sonraki boş numarayla eklenmeli. Üretim kodu, bağımlılık ve çalışan ölçüm değiştirilmedi; commit yapılmadı.

### 18.1. Engeller ve eksik kanıtlar

1. **[P1, açık] Sahiplik sorunu çözülmedi; başarılı fixture Quit'i tam kapanış güvencesi değil.** `Sources/LoomCore/OwnershipLedger.swift:67–76` aynı coalition üyeliğini sahiplik tohumu kabul etmeye devam ediyor; `Sources/loom-app/AppDelegate.swift:145` varsayılan ledger'ı kullanıyor. §13 madde 1'in dış süreç seçme riski ve §16'nın gözlemden kaçan işleri bırakmama şartı birlikte açık. Son dört paket kabul kaydının tamamı `Narrowed ownership` güvencesiyle başarılı; bu kayıtlar yalnız kullanılan fixture'ların kapandığını destekliyor. Yeni uyarı sorunu görünür kılıyor, sahiplik sınırını onarmıyor. **Beklenen/kabul:** §16 ve §17'deki dış kontrol sürecine sıfır sinyal, ayrılan işlerin tamamının bulunması ve doğrulanmış sıfır kalıntı; uygun yöntem seçilip kanıtlanmadan A/B geçişi yok. Bu tur dış sürece sinyal deneyi yapılmadı.
2. **[P1, teslim engeli] Derleme geçici, makineye özel bağımlılığa bağlı.** `Package.swift:17,24` `/tmp/loom-cp5-swiftterm` yolunu kullanıyor. Repodaki patch kendiliğinden uygulanmıyor; `Package.resolved` SwiftTerm kaynağını sabitlemiyor. Geçici klasör olmayan bir checkout bu haliyle kendine yeterli değil. Yerel klon HEAD'i `fe4fb45d5888ce33ff3788d6873870a73894a41b`; iki dosyalık diff repodaki patch ile byte düzeyinde aynı, toplam 53 ek satır. **Beklenen/kabul:** göreli vendored kaynak veya erişilebilir uzak tam commit; boş build diziniyle, `/tmp` klonuna erişmeden build ve tam test. Bu tur klasör silinmedi/yeniden adlandırılmadı ve temiz kurulum deneyi yapılmadı.
3. **[P2, D3 kanıtı eksik] Başarısız Quit'in gerçek uygulama uyarısı ve düğmeyle tekrar denemesi gösterilmedi.** `Tests/LoomTerminalTests/TerminalRunControllerTests.swift:144–173` yapay başarısız raporu denetleyiciye verip ikinci `requestQuit` çağrısını sınar; AppKit uygulama delegesi, uyarı penceresi ve düğme bu testin içinde yok. Gerçek yol `Sources/loom-app/AppDelegate.swift:230–242`. Son paket kabul run'ında dört Quit de ilk denemede başarılı, hata/retry kanıtı yok. Test yararlı ve kayıtta geçiyor; bundan “uygulamadaki hata penceresi ve Tekrar dene doğrulandı” sonucu çıkarılmaz. **Beklenen/kabul:** izole paket uygulamada kontrollü ilk Quit hatası; uygulama ve fixture canlı, yeni iş reddediliyor, uyarı görünür; gerçek Try Again eylemiyle doğrulanmış kapanış ve sıfır fixture kalıntısı. Kaynakta açık bir düğme kusuru saptanmadı; bu madde doğrulama boşluğudur.

§19'daki gerçek görsel maliyeti ve gecikme geçerliliği de A4 kabulünden önce giderilmeli.

### 18.2. Mevcut kayıtlarda doğrulanan ilerleme

- **§13 madde 2:** `TerminalRunController.swift:67–96` rezervasyonu ilk await'ten önce alıyor. Aynı turda 2/20 istek, canlıyken yeniden istek ve başlatma hatası/yeniden deneme testleri mevcut başarılı log'da var. Negatif log, rezervasyon kaldırılınca 2 ve 20 kabul edildiğini gösteriyor. Paket `ownership-notice/children.txt` bir çocuk içeriyor; üç ardışık istek sonrası aynı run yeniden açılışta korunmuş. “Aynı turda” birim testi ile ayrı bildirimler üzerinden paket deneyi birbirinin yerine yazılmadı.
- **§13 madde 4:** uyarı ayrı bir `NSTextField` olarak terminal başlığından bağımsız. Paket snapshot'larında ilk işten önce, isteklerden sonra ve yeniden açılışta `ownershipNoticeShown=true`. Bu tur ekran görüntüsüyle metnin tamamının görsel yerleşimi sınanmadı.
- **§13 madde 5, kısmen:** bekletilmiş başlatmanın Quit sonrasında reddi, denetleyici hata/retry ve iç içe main run loop testi başarılı log'da mevcut. Negatif log'da eski reply yaklaşımı 5 saniyede başarısız. Paket UI hata/retry için 18.1 madde 3 açık.
- **§13 madde 3, kısmen:** Sixel adet/hesaplanan bayt, Kitty taşması ve 1 MiB OSC sonrası normal akış testleri başarılı. Kota devre dışıyken iki Sixel testi sırasıyla 2.024 görsel ve 21.732.800 hesaplanan baytla başarısız. Gerçek bitmap baytı ayrıca §19 madde 1'de ele alındı; bu sayı ölçülmüş process footprint'i değildir.
- **ES1:** `cp5-es1-20260928T210547/es1.c` gerçek descendants istemcisini çağırıyor. `es1.txt`, yetkisiz istemcide `ERR_NOT_ENTITLED`/exit 2, düzeltilmiş entitlement denemesinde exit 137 kaydediyor; ilk hatalı plist denemesi ayrıca düzeltilerek açıklanmış. Yetkili istemci başarısı ve başlangıç bariyeri **doğrulanmadı**. Exit 137, tek başına öldürmenin nedenini kesinleştiren sistem teşhis kaydı değildir; eksik provisioning ile uyumlu sonuç olarak okunur. Apple yetkisi/imzalama kapısı sürüyor; burada hesap işlemi veya koruma değişikliği yapılmadı.

### 18.3. Kontroller ve bağımlılık önerisi

İncelenen tam test log'u `/tmp/loom-cp5-full.log`: build başarılı, 12 terminal + 93 core = **105 test başarılı**, exit 0. Bu **implementer'ın mevcut kaydıdır**; reviewer'ın bu tur yeniden çalıştırdığı test sonucu değildir. 5×6 CPU/çizim ölçümü çalışırken `swift build`, `swift test`, paket açma ve GUI deneyleri başlatılmadı. Review kapanışında, ölçüm bittikten ve kalıcı bağımlılık son halini aldıktan sonra reviewer build/tam test ve değişen kabul yollarını doğrulamalı. Şimdilik bağımsız kontroller: `git diff --check` ve üç script için `zsh -n` başarılı; patch/yerel klon farkı byte düzeyinde eşit. `git diff --check` untracked dosyaların tüm içeriğini denetlemez.

Kalıcı reviewer kanıtı: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-a-review2-20260928/`; burada `acceptance-audit.json`, `measurement-validity-replay.json`, incelenen tam/negatif test log'ları ve `source-sha256.json` var. Paket kanıtının kaynağı `cp5-a-20260928T210836`; dört `quit.json` başarılı, dört `after-quit.txt` uygulama çıkışı ve kaydedilmiş fixture PID'sinin yokluğunu bildiriyor. Testlerin ham kaynak/komut mutasyon geçmişi bağımsız yeniden üretilmedi.

**Öneri: kota doğrulandıktan sonra vendoring.** Bu küçük yama için fork yayını zorunlu değil; repo içinde göreli `Vendor/SwiftTerm` bağımlılığı derleme girdisini gözden geçirilebilir kılar. Kopyalanan sürümün tam upstream SHA'sı, yerel patch ve güncelleme yöntemi kaydedilmeli; mevcut `LICENSE` ve telif bildirimleri korunmalı. Sadece `Sources/SwiftTerm` klasörünü kopyalamak yeterli varsayılmamalı: mevcut manifest build-info plugin/generator ve başka hedef yolları da bildiriyor. Gerekli paket dosyaları ile temiz checkout'ta build/test kanıtı sağlanmalı; `.git`, build ürünleri ve geçici dosyalar alınmamalı. Bu review vendoring uygulamaz; fork/push/upstream PR yetkisi de vermez. Kullanıcı fork seçerse tam commit pin'iyle aynı yeniden üretilebilirlik kabulü aranır.

## 19. Optimizasyon incelemesi: kota ve ölçüm düzeltmeleri (28 Eylül 2026)

GPT-6 Astra high optimizer kullanıldı; rapordaki aşağıdaki noktalar reviewer tarafından ilgili kaynaklar ve mevcut JSON üzerinden kontrol edildi. Çalışan ölçüme yük ekleyecek derleme, performans deneyi veya GUI müdahalesi yapılmadı. Bu bölüm nihai performans kabulü değildir.

1. **[P2] Görsel bayt kotası oluşturulan bitmap'i eksik sayabiliyor.** `patches/swiftterm-inline-image-quota.patch:35`, uygulanan `Buffer.swift:282`, maliyeti `pixelWidth * pixelHeight * 4` sayıyor. Sabit upstream `AppleTerminalView.swift:4713` bu alanları `Int(stripeSize.width)` / `Int(cellSize.height)` ile aşağı yuvarlıyor; `MacTerminalView.swift:4312–4318` bitmap'i `ceil(width)` / `ceil(height)` ve `bytesPerRow = width * 4` ile oluşturuyor. Kesirli boyutlar için formüller farklı; `Tests/LoomTerminalTests/TerminalImageLimitTests.swift:20` aynı tahmini formülü tekrar sayarak bağımsız sınama yapmıyor. **Kaynakta görüldü; gerçek uygulamada bitmap baytı/footprint taşması çalıştırılmadı.** Adet kotası sınırsız birikmeyi engelliyor; bu bulgu kotanın tamamen etkisiz olduğu anlamına gelmez. **Beklenen/kabul:** yerleşim ölçüsünden ayrı gerçek depolama maliyeti (bitmap `bytesPerRow × height`) veya güvenli üst sınır; kesirli boyutlu Sixel/iTerm2 fixture'ında ekran başına gerçek raster ≤8 MiB ve adet ≤1.024, iki ekran ve clear/resize davranışı ayrıca sınanır. Geçici decode belleği ve renderer kopyaları bu depo sınırına otomatik olarak dahil sayılmaz. Retina nedeniyle otomatik dört kat fark iddiası mevcut Mac kaynağıyla desteklenmedi.
2. **[P2] Gecikme sonucunun geçerliliği kendi ölçüm aralığını ve eksik örnekleri kapsamıyor.** `scripts/cp5-a-measure.sh:65–68` `snapshot:end` sonrasında `latency:200` başlatıyor; `:79–110` geçerliliği yalnız önceki CPU/feed aralığına göre hesaplıyor. `DevelopmentEvidence.swift:55–78` timeout'ları yüzdeliklerden çıkarıyor. Reviewer, scriptin aynı Python özetleyicisini `latency-visible-1` kanıtının geçici kopyası üzerinde çalıştırdı: **latency.json yokken de, measured=0/timeouts=200 iken de `valid=true` çıktı.** Kopyalar temizlendi; sonuç `measurement-validity-replay.json` içinde. **Beklenen/kabul:** latency için ayrı başlangıç/bitiş/görünürlük olayları ve geçerlilik; kayıp kayıt, eksik 200 örnek veya timeout başarı sayılmaz; yüzdelikler yalnız açıklanmış geçerli kümeden hesaplanır. Pencerenin yalnız latency sırasında örtülmesi geçersiz sonuç üretmeli. İlk gerçek latency kaydı 200/200, timeout 0, p95 yaklaşık 18,409 ms; bu kaydın gerçekten örtüldüğü iddia edilmiyor, yöntem koşulu kanıtlamıyor. Ayrıca CoreGraphics hook'u `MacTerminalView.swift:1692–1693` çizim çağrısı dönüşünü ölçüyor; fiziksel ekrana/compositor sunumuna kadar gecikme olarak adlandırılmamalı.

**Kaynak ve mevcut kayıtla doğrulanan düzeltmeler:** CPU paydası monoton gerçek süre; feed yüzdelikleri kümülatif histogram farkıyla bütün terminal snapshot aralığından; run maksimumu ayrıca adlandırılmış. Frame tick/gerçek render ayrılmış. CPU/feed aralığındaki görünürlük değişimi ve eksik snapshot reddediliyor. `cp5-a-measure-20260928T210911` inceleme anındaki `stream-visible-cg` tekrar 2, başlangıç/bitiş örtülü olduğu için doğru biçimde `valid=false`; beş planlı tekrar beş geçerli tekrar demek değil. Nihai özet senaryo başına geçerli tekrar sayısını vermeli, geçersizleri ortalamaya katmamalı ve gerekli tekrar sayısını tamamlamalı. Devam eden run'dan renderer seçimi çıkarılmadı.

**Doğrulanmadı:** final 5×6 sonuçlar, araçların ayrı ölçüm maliyeti, gerçek görsel footprint'i/geçici decode tepe belleği, uzun kullanım/10–50 terminal ve GPU. Kaynakta yamanın metadata dizisi adet kotası ve dönemsel sıkıştırmayla sınırlı; bu incelemede ek mikro-optimizasyon önerilmedi.

## 20. Uygulama sonucu: §13 ve §18–19 düzeltmeleri (28 Eylül 2026)

Kullanıcı §15 sırasıyla (2/4/5 → 6 → 3 → §17 adım 1) ilerlemeyi onayladı; §18–19 sonrasında "devam" dedi. Fork/push/PR yapılmadı; bağımlılık reviewer önerisiyle vendoring'e alındı. Commit yapılmadı. Sahiplik (§13 madde 1 / §18.1 madde 1) bu bölümde **çözülmedi**.

### 20.1. Bulgulara cevap

- **§13 madde 1 / §18.1 madde 1 — çözülmedi.** `OwnershipLedger` değişmedi. §16 daraltmayı reddettiği için yöntem §17'ye bağlı; ES1 (20.2) yetkisiz. Paket kabul Quit'leri yine `Narrowed ownership` altında; yalnız kullanılan fixture'ların kapandığını gösterir.
- **§13 madde 2 — çözüldü.** `Sources/LoomTerminal/TerminalRunController.swift`: `launching/live/ended` durumu; rezervasyon ilk await'ten önce; geç başarı/hata yalnız kendi rezervasyonunu günceller; başlamış Quit (başarısız olsa da) yeni işi reddeder. Testler `TerminalRunControllerTests`: aynı turda 2 ve 20 istek → 1 kabul, 1 canlı run; canlıyken ret; ilk başlatma hatası tek bildirim + yeniden deneme. Negatif: rezervasyon kaldırılınca 2/20 isteğin hepsi kabul, canlı run >1 (`/tmp/loom-cp5-neg.log` içeriği 20.5'te özetli). Paket: `ownership-notice` senaryosunda 3 hızlı istek → 1 çocuk.
- **§13 madde 3 / §19 madde 1 — çözüldü (kaynak ve test), gerçek footprint ölçülmedi.** SwiftTerm'e ekran başına inline görsel (Sixel, iTerm2 OSC 1337) kotası: `TerminalOptions.inlineImageStorageLimitBytesPerScreen` ve `inlineImageLimitPerScreen`; `Buffer.attachImage` sonrası FIFO, en eski önce; kaldırma satır konumuyla değil görsel kimliğiyle. Bayt maliyeti, Mac bitmap'i `ceil` ile kurulduğu için (`MacTerminalView.bitmapContext`) `(w+1)(h+1)·4` üst sınırıyla sayılır. Loom ayarı 8 MiB ve 1.024 görsel / ekran (`TerminalSurfaceLimits`). Testler (`TerminalImageLimitTests`) gerçek CGImage `bytesPerRow × height` toplamını bağımsız ölçer: tek satıra 2.024 Sixel → ≤1.024; 14 ve 13,5 pt (kesirli hücre) fontta ana + alternatif ekranda ≤8 MiB raster; `?1049l`, `2J/3J`, 60×20 resize sonrası tekrar yük ≤8 MiB; ardından normal metin görünür. Negatif (kota ayarı kapalı): 2.024 görsel ve 13,5 pt'de 20.454.400 raster bayt → başarısız. Kitty: 4×4 MiB RGBA sonrası `totalImageBytes` ≤ 8 MiB, sonraki metin görünür. OSC: 1 MiB + 1 başlık düşer, sonraki çıktı ve küçük başlık gelir. Geçici decode belleği ve renderer kopyaları bu sınırın dışında; ölçülmedi.
- **§13 madde 4 — çözüldü.** Dar güvence pencerede kalıcı turuncu `NSTextField` (terminal başlığından ayrı). Paket `ownership-notice` (`LOOM_FORCE_COALITION_FAILURE=1`): ilk işten önce, isteklerden sonra ve kapat/aç sonrası `ownershipNoticeShown=true`. Ekran görüntüsüyle yerleşim sınanmadı.
- **§13 madde 5 / §18.1 madde 3 — çözüldü.** Denetleyici testleri: bekletilen başlatma + Quit → `shutdownStarted`, canlı run 0, sahip olunan süreç 0; kontrollü başarısız Quit → `failed`, yeni iş reddi, run canlı; ikinci `requestQuit` başarı. Ana-kuyruk bloğu içindeki iç içe run loop'ta Quit yanıtı geliyor; eski `Task { @MainActor }` yanıtıyla test 5 sn'de başarısız. Paket (`quit-failure-retry`, yalnız `--evidence --fail-first-quit` ile): ilk Quit `succeeded=false` (zorlanmış hata, süreç durdurulmadı), uygulama ve fixture canlı, uyarı sheet olarak bağlı (`Try Again`, `Keep Loom Open`), `new-terminal` reddedildi (aynı live session); uyarının gerçek `Try Again` düğmesine `performClick` → ikinci deneme `succeeded=true`, uygulama çıktı, fixture yok.
- **§13 madde 6 / §19 madde 2 — çözüldü (yöntem).** `scripts/cp5-a-measure.sh`: eksik snapshot, beklenen dışı görünürlük ve aralık içi görünürlük olayı → `valid=false` (sıfır sayılmaz); CPU monoton süreyle; `frames` ve `renders` ayrı; feed yüzdelikleri aynı aralığın kümülatif histogram farkı (2^i µs üst sınırı), run maksimumu ayrı adla. Girdi→çizim ölçümünün kendi aralığı ve geçerliliği var: 200/200 örnek, timeout 0, başta/sonda görünür ve örtülmemiş, ölçüm sırasında görünürlük olayı yok; `latency.json` yoksa geçersiz. Tanım: motorun girdisine verilen tuş → yankı motora verildikten sonraki ilk tamamlanmış terminal çizimi (CoreGraphics draw dönüşü / Metal present callback); compositor/ekran sunumu değildir.
- **§18.1 madde 2 — çözüldü.** `Vendor/SwiftTerm`: upstream `fe4fb45d…` kaynağı + `patches/swiftterm-inline-image-quota.patch`; indirgenmiş manifest (kütüphane, build-info eklentisi ve üreteci; hedef ayarları upstream'le aynı); `LICENSE` korunuyor; `LOOM-VENDOR.md` kaynak, yerel değişiklikler ve güncelleme yöntemini tutuyor. Build-info eklentisi, kopyanın içindeki `git`'in Loom checkout'unu raporlamaması için upstream kimliğini sabitliyor; etiket sızıntısı §21.1 madde 3'te bulundu ve §20.5'te düzeltildi. Vendored kütüphane = upstream + patch (`diff -r -q` farksız). Temiz kanıt: `.build` ve `.git` olmadan `/tmp/loom-cp5-clean` kopyası, `/tmp/loom-cp5-swiftterm` geçici olarak yeniden adlandırılmışken `swift build` exit 0, `swift test` 105 test geçti. `Package.resolved` artık SwiftTerm'i değil yalnız `swift-png` 4.5.1 ve onun `h` 1.0.1 bağımlılığını sabitliyor.

### 20.2. §17 adım 1 (ES1) — başarısız / Apple yetkisi gerekli

Run `~/Library/Application Support/Loom-Dev/probe/runs/cp5-es1-20260928T210547/` (`es1.c`, `es1.txt`). `clang -Wall -Wextra -Werror`, macOS 27.0 SDK. Linker ad-hoc imzalı istemci: `es_new_descendants_client` → `ERR_NOT_ENTITLED` (3), exit 2. Entitlement gömülü, provisioning profilsiz ad-hoc: açılışta exit 137 (SIGKILL); sistem teşhis kaydıyla nedeni kesinleştirilmedi. Yerelde kod imzalama kimliği 0. Başvuru/hesap/sertifika işlemi ve koruma değişikliği yapılmadı. Başlangıç bariyeri ve ES2–ES8 **doğrulanmadı**.

### 20.3. Test sırasında bulunan test kusuru

İlk tam pakette `repeatedRequestsStartAtMostOneRun(2)` 6 denemenin 4'ünde 5 sn `launching`'de kaldı. Ayrıştırma: denetleyici suite'i tek başına 3/3, yüzey suite'iyle 3/3 geçti; görsel suite'iyle 1/3. Neden: görsel testleri ~10 sn MainActor üzerinde senkron parse yapıyordu ve başlatma görevinin MainActor'a dönüşünü aç bırakıyordu. Üretimde besleme IO kuyruğunda olduğu için testler motorun `Sendable` feed tutamağıyla ana aktör dışından beslenecek şekilde düzeltildi. Sonra `LoomTerminalTests` 6/6 ve tam paket geçti. Ürün kusuru bulunmadı; zaman sınırı büyütülmedi.

### 20.4. Kontroller

- `swift build`: başarılı. `swift test` (makro bayrağıyla): 93 LoomCore + 13 LoomTerminal = **106 test geçti**, exit 0 (son çalıştırma §20.6, `cp5-a-fix3-*/test.log`). `git diff --check` temiz; `zsh -n` üç script için temiz.
- Paket: `scripts/package-dev-app.sh` (ad-hoc). Kabul: `scripts/cp5-a-acceptance.sh` → run `cp5-a-20260928T214808` (ve §20.6'daki son tekrar `cp5-a-20260928T221906`), 5 senaryo (`window-cycle`, `hidden-quit`, `quit-during-launch`, `ownership-notice`, `quit-failure-retry`), hepsinde son Quit başarılı, kalan 0, uygulama çıktı, fixture yok. Özet `plans/experiments/cp5-a-acceptance.json` son run ile güncellendi.

### 20.5. §21–22 bulgularına cevap

- **§21.1 madde 1 — çözülmedi.** Değişiklik yok; §20.2 ve §17 kapıları geçerli.
- **§21.1 madde 2 — çözüldü.** `TerminalImageLimitTests.byteQuotaCoversRasterRounding(kind:)`, Sixel ve iTerm2 (OSC 1337) için. View, gösterilmeyen bir pencerede ana ekrana bağlanır; görsel ölçeği pencereden gelir (`MacTerminalView.getImageScale`), paket uygulamayla aynı koşul. Pencere olmadan ölçek 1'dir, boyutlar tamsayı kalır ve fark oluşmaz: testin ön koşulu ilk sürümde bunu yakalayıp başarısız oldu. Ön koşul: en az bir görselde raster > bildirilen boyut. Yalnız bayt kotası (64 KiB, adet sınırı yok), 3.000 görsel. Kanıt (`cp5-a-fix3-*/`, geçici yazdırma ile):

  | Formül (`Buffer.swift:284`) | Sixel: bildirilen → raster, adet, raster bayt | iTerm2 `width=1%`: bildirilen → raster, adet, raster bayt | Sonuç |
  | --- | --- | --- | --- |
  | `(w+1)(h+1)·4` (mevcut) | 1×17 → 2×17, 455, 61.880 | 7×17 → 8×17, 113, 61.472 | geçti |
  | `w·h·4` (yalnız bu satır geri alındı) | 1×17 → 2×17, 963, 130.968 | 7×17 → 8×17, 137, 74.528 | başarısız (ikisi de > 65.536) |

  Satır ve test geri yüklendi (`grep` ile doğrulandı).
- **§21.1 madde 3 — çözüldü.** `Vendor/SwiftTerm/Sources/SwiftTermBuildInfoGenerator/BuildInfoGenerator.swift`: tanımlı ama boş `SWIFTTERM_BUILD_TAG` "etiket yok" demek; `git describe` çalışmaz. Eklenti bunu zaten boş veriyor. `LOOM-VENDOR.md` madde 3 güncellendi. Tam eklenti yoluyla küçük tüketici paket üç kurulumda derlendi (`cp5-a-fix3-*/build-info-tag.txt`): `.git` yok / etiketsiz depo / `loom-fixture-v99` etiketli depo → üçünde de `branch=loom-vendored tag=nil commit=fe4fb45d5888ce33ff3788d6873870a73894a41b dirty=true`. Loom deposuna etiket eklenmedi; geçici depolar silindi.

### 20.6. Kontroller ve ölçüm durumu

- `swift build` başarılı. `swift test` (makro bayrağıyla): **106 test** (93 + 13) geçti, exit 0 → `~/Library/Application Support/Loom-Dev/probe/runs/cp5-a-fix3-*/test.log`. `git diff --check` ve üç script için `zsh -n` temiz.
- Paket + kabul: run `cp5-a-20260928T221906`, 5 senaryo; `quit-failure-retry` denemeleri `[false, true]`, diğerleri `[true]`; hepsinde kalan 0, uygulama çıktı, fixture yok.
- **5×6 ölçüm tamamlanamadı; performans sonucu yok.** Run `cp5-a-measure-20260928T215913`, 8 satırdan sonra durduruldu (ilk run da kullanıcı tarafından durdurulmuştu). Görünür senaryoların hepsi pencere örtüldüğü için geçersiz: `stream-visible-cg-1` (aralıkta 4 görünürlük olayı), `stream-visible-metal-1`, `latency-visible-1` (`inputToDraw.valid=false`), `idle-visible-2`. Makine ölçüm sırasında kullanılıyordu; geçerlilik kontrolleri beklendiği gibi reddetti. Geçerli satırlar yalnız: `idle-visible-1` Loom CPU %0,0 (21 MB); `idle-hidden-1/2` %0,08 / %0,02, frames 0, renders 0 (54–56 MB); `stream-hidden-1` %6,88, renders 0, feed p95 üst sınırı 0,064 ms (57–58 MB). Durdurulmadan önceki her uygulama normal Quit ile kapandı, kalıntı yok. Ham satırlar `plans/experiments/cp5-a-measure.jsonl`. **Gerekli:** ekranı ~45 dk boyunca kullanılmayan makinede `scripts/cp5-a-measure.sh 5`; senaryo başına geçerli tekrar sayısı raporlanır, geçersizler ortalamaya girmez.

### 20.7. Açık kalanlar

1. Sahiplik (§13.1 / §18.1.1 / §21.1.1): Apple ES yetkisi olmadan ES1 ilerlemiyor; ES2–ES8 doğrulanmadı.
2. Geçerli 5×6 ölçüm ve renderer karşılaştırması, gerçek görsel footprint'i, uzun kullanım, çoklu terminal, GPU.
3. İmza: yerel imza kimliği yok; paket ad-hoc.

## 21. Review: vendoring ve ikinci düzeltme turu (28 Eylül 2026)

**Sonuç: partial; A kapanmadı.** Kullanıcının belirttiği §20 uygulama/ölçüm sonucu için numara korundu; bu inceleme sırasında bölüm henüz eklenmemişti. `/tmp/loom-cp5-section20.md` hazırlık taslağı okundu, değiştirilmedi ve tamamlanmış ölçüm raporu sayılmadı. Kaynak, mevcut kanıt ve hafif izole yeniden üretimler incelendi; üretim kodu/bağımlılık değiştirilmedi, commit yapılmadı.

### 21.1. Bulgular ve kapanış sınırları

1. **[P1, önceki engel açık] Süreç sahipliği çözülmedi.** `Sources/LoomCore/OwnershipLedger.swift:67–76` ve §18.1 madde 1 değişmedi. Son paket Quit başarıları yine dar sahiplik güvencesi altında fixture kabulüdür; §16'nın bütün yönetilen işleri durdurma ve dış süreçlere dokunmama şartlarının yerine geçmez. ES1 yetkisiz yol başarısız; yetki başvurusu/hesaba erişim, tek başına ES2–ES8 veya terminal uyumu kabulü değildir. **Kabul:** §17 deney kapıları ve §16 normal Stop/Quit şartları birlikte doğrulanmalı. Bu tur süreç sahipliği deneyi yapılmadı.
2. **[P2, önceki kabul kanıtı eksik] Kota regresyonu yuvarlama hatasını özel olarak sınamıyor.** `Tests/LoomTerminalTests/TerminalImageLimitTests.swift:58–84` 13,5 font kullanıyor ancak bildirilen boyut ile gerçek raster arasında fark oluştuğunu doğrulamıyor. `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift:1921,1940–1944` hücre boyutlarını yuvarlıyor; kesirli font, kesirli raster anlamına gelmez. `/tmp/loom-cp5-neg3.log` 20.454.400/21.732.800 raster bayt ile negatif sonuç içeriyor; implementer taslağı bu deneyde **kotanın kapatıldığını** söylüyor. Bu kayıt, yalnız `(w+1)(h+1)` düzeltmesi geri alındığında testin bozulduğunu göstermiyor. Sohbetteki ilk “eski hesapla başarısız” yorumum bu ayrımla düzeltildi. §19'daki iTerm2 fixture'ı da yok. **Kabul:** gerçek raster ile bildirilen boyutun farklı olduğu doğrulanan en az bir kesirli boyut fixture'ı; kota açıkken yalnız eski bayt formülüne dönünce başarısız, yeni hesapla başarılı test; iTerm2 yolu da dahil. **Bu yeni üretim belleği kusuru değildir:** mevcut Mac raster yolu için yeni formülün güvenli üst sınır olduğu kaynakta doğrulandı (§22).
3. **[P3, sürüm bilgisini düzelt; ana sahiplik engelinden ayrı] Vendored SwiftTerm Loom'un Git etiketini hâlâ sahipleniyor.** `Vendor/SwiftTerm/Plugins/SwiftTermBuildInfoPlugin/plugin.swift:19–24` etiketi boş string verir; `Sources/SwiftTermBuildInfoGenerator/BuildInfoGenerator.swift:21–22` boş değeri yok sayıp üst Loom deposunda `git describe --exact-match --tags` çalıştırır. Oluşan tag, aynı dosyanın `:120` sürüm hesabında ve `Sources/SwiftTerm/Terminal.swift:5216–5221` XTVERSION yanıtında kullanılır. Reviewer mevcut build-info üretecini geçici izole klonda, yalnız o klona verilen `loom-review-fixture-v99` etiketiyle çalıştırdı: upstream commit doğru kalırken SwiftTerm tag'i bu Loom etiketi oldu. Kullanıcının repo tag/commit'leri değiştirilmedi; geçici klon silindi. `LOOM-VENDOR.md` bunu zaten bilinen sınır olarak yazıyor; belgelendirme yanlış motor kimliğini düzeltmez. **Kabul:** vendored paket tag için de üst deponun Git bilgisinden bağımsız olmalı; etiketsiz, Loom etiketli ve `.git` olmayan kopyada aynı doğru motor kimliği. Bu küçük hata vendoring'in `/tmp` bağımlılığını kaldırdığı kabulünü geri açmaz.

### 21.2. Doğrulanan değişiklikler

- **§18.1 madde 2 — geçici bağımlılık kaldırıldı.** `Package.swift:17` göreli `Vendor/SwiftTerm` kullanıyor. Tam upstream `fe4fb45d5888ce33ff3788d6873870a73894a41b` Git blob'larına karşı 139 kopyalanmış dosya karşılaştırıldı: eksik dosya yok; yalnız `Buffer.swift`, `TerminalOptions.swift` ve build-info plugin farklı. İndirgenmiş manifest ve `LOOM-VENDOR.md` ayrı yerel dosyalar; lisans değişmemiş. `Package.resolved` kalan iki uzak bağımlılığı sabitliyor. Temiz kopya log'ları build ve 12+93 test başarısını içeriyor. `/tmp/loom-cp5-clean` içindeki üretim ve vendor kaynakları şu ankiyle aynı; sadece iki test dosyası sonradan değişmiş. `/tmp` klonunun o sırada erişilemez olduğu raporlandı; reviewer bu koşulu bağımsız tekrar kurmadı.
- **§18.1 madde 3 — paket hata/retry kanıtı mevcut.** `cp5-a-20260928T214808/quit-failure-retry/`: ilk deneme `succeeded=false`, sıfır sinyal; uygulama ve fixture canlı. Snapshot'ta controller `failed`, terminal `live`, gerçek alert pencereye sheet olarak bağlı ve iki düğmesi kayıtlı. Yeni iş isteğinden sonra tek fixture kalıyor. `AppDelegate.swift:355–357` gerçek alert düğmesinde `performClick` çağırıyor; ikinci deneme başarılı, uygulama ve kaydedilen fixture PID'si yok. Bu, ilk review'daki doğrudan ikinci controller çağrısından farklı olarak AppKit sheet/callback/terminate yolunu kapsıyor. Reviewer GUI'yi yeniden sürmedi; mevcut çalıştırma kanıtını ve uygulama yolunu doğruladı. Sınırlı sahiplik kapsamı değişmedi.
- **Testlerin ana aktörü meşgul etmesi:** görsel test beslemesi artık üretimdeki gibi sendable feed üzerinden arka planda; temiz kopyayla diff'te controller bekleme süresi hâlâ 5 saniye, yalnız hata ayrıntısı eklenmiş. Güncel `/tmp/loom-cp5-full.log` build ve 105 test başarı/exit 0 içeriyor. “6/6 tekrar” raporu bu tur altı ayrı ham log üzerinden bağımsız doğrulanmadı.

### 21.3. Kontroller ve kanıt

Yeni ölçüm `cp5-a-measure-20260928T215913` inceleme boyunca çalışıyordu. Reviewer `swift build`, `swift test`, paket açma ve ağır ölçüm başlatmadı; bu nedenle **bağımsız build/tam test kabulü hâlâ bekliyor**. İncelenen implementer log'ları başarılı olsa da reviewer'ın yeniden koştuğu sonuç diye sunulmaz. Ölçüm bittikten ve düzeltmeler son halini aldıktan sonra build/tam test yapılmalı; geçersiz tekrarlar nihai performans özetinden çıkarılıp gerekli geçerli tekrar sayısı sağlanmalı.

Bu tur bağımsız çalışan kontroller: upstream blob karşılaştırması, mevcut üreteçle izole tag yeniden üretimi, ölçüm scriptinin gerçek Python özetleyicisinin geçici JSON kopyalarıyla çalıştırılması, `git diff --check`, üç script için `zsh -n`; son iki kontrol başarılı. Kalıcı kanıt kökü `~/Library/Application Support/Loom-Dev/probe/runs/cp5-a-review3-20260928/`: `vendor-audit.json`, `build-info-tag-replay.json`, `quit-ui-audit.json`, `latency-summary-replay.json`, `source-sha256.json` ve incelenen güncel/temiz/negatif test log'ları. `/tmp` deney kopyaları temizlendi; implementer'ın kopyalarına dokunulmadı.

## 22. Optimizasyon incelemesi: ikinci düzeltme turu (28 Eylül 2026)

Mevcut GPT-6 Astra high optimizer ile salt okunur inceleme yapıldı. Kaynaklar ve kanıtlar reviewer tarafından tekrar kontrol edildi; yeni bir performans optimizasyonu önerisi yok.

- **§19 madde 1 kaynak düzeltmesi doğrulandı.** `Vendor/SwiftTerm/Sources/SwiftTerm/Buffer.swift:282–284` `(max(0,w)+1)*(max(0,h)+1)*4` sayıyor. Mevcut Mac bitmap yolu `MacTerminalView.swift:4312–4318` `ceil` boyutlarıyla 4 bayt/piksel üretir; aşağı yuvarlanmış pozitif boyuta +1 bu yol için üst sınırdır. `TerminalImageLimitTests.swift:14–29` artık bağımsız CGImage satır baytı × yükseklik toplamını okuyor. İki ekran, clear ve resize testleri mevcut başarılı log'da var; tam regresyon/iTerm2 kabul boşluğu §21.1 madde 2'de. Bu kaynak sonucu toplam process footprint'i, geçici decode tepesini veya renderer kopyalarını sınırlandırdığı iddiası değildir.
- **§19 madde 2 yöntem düzeltmesi doğrulandı.** `DevelopmentEvidence.swift:56–108` ayrı latency başlangıç/bitişi, görünürlük olayı, örnek sayısı ve timeout kontrolü yapıyor; tanım motor çizimidir. `scripts/cp5-a-measure.sh:111–121` sonucu ayrı `inputToDraw.valid` alanında taşıyor. Reviewer gerçek özetleyiciyi yeniden çalıştırdı: eksik dosya → false; 0/200 ölçüm ve 200 timeout → false; görünürlük geçersiz kaydı → false; tam/geçerli sentetik kayıt → true. Üst `valid` CPU/feed aralığına ait; latency kabulünde mutlaka `inputToDraw.valid` okunmalı. Bu JSON yeniden üretimi, gerçek pencerenin latency sırasında örtülmesi deneyinin yerine geçmez; uygulamanın yeni aralık kontrolünün GUI çalışma deneyi bu tur yapılmadı.
- **Nihai performans sonucu verilmedi.** Devam eden beş tekrar, ayrı ölçüm aracı maliyeti, gerçek görsel footprint'i, uzun kullanım, çoklu terminal ve GPU kabulü bu ara review ile kapanmaz. Önceki ham ölçümlerdeki başlangıç değerleri yeni sürüm için nihai sayı olarak taşınmadı.

## 23. Kullanıcı kararı: temel engeli ayır, pencereye ilerle (28 Eylül 2026)

Kullanıcı, tek temel sorunun ayrıca belirtilip beklemeye alınmasını ve ilk pencere işine devam edilmesini istedi. **Bu bölüm, §8 ve sonraki review'lardaki “A kapanmadan B açılmaz” geliştirme kapısını kaldırır.** Ürün sözleşmesi ve §16'daki kapanış şartı değişmez. A veya CP5 tamamlandı denmez; B'nin tamamlanması kendi kapsamına göre değerlendirilir.

**OWN-1 — Yönetilen bütün işleri durdururken dış süreçlere dokunmama.** Mevcut coalition üyeliği tek başına sahiplik kanıtı değil: Apple yardımcı servisi gruba sonradan katılabilir. Dar güvence de bütün kaçan/yeniden ebeveynlenen işleri kapsadığını kanıtlamıyor. Kaynak: `Sources/LoomCore/OwnershipLedger.swift:67–76`, §18.1.1 ve §21.1.1. Kapanış ölçütü: §16'nın tam Stop/Quit davranışı ve seçilen mekanizmanın adversarial sahiplik testleri birlikte geçmeli. §17 Endpoint Security bir araştırma adayıdır; ES1 yetkisiz başarısız, yetkili yol ve ES2–ES8 doğrulanmadı. Apple yetkisi tek başına çözüm kanıtı olmaz. **Engel ürünün tam kapanış kabulüne aittir; katalog/arayüz geliştirmesine değil.** B sırasında sahiplik araştırması yeniden açılmaz, uyarılar kaldırılmaz, başarısız kapanış başarılı gösterilmez.

Diğer açıklar kabul kanıtı borcudur: kontrollü 5×6 performans, uzun kullanım/çoklu terminal/GPU, kalıcı imza ve son A değişikliklerinin bağımsız kabulü. Silinmezler; birleşik kapanışta §20.7 ile birlikte ele alınırlar. B için tekrar 45 dakikalık ölçüm, sudo/GPU veya Apple hesap işlemi istenmez. Yeni ve somut bir B regresyonu bulunursa kapsamıyla raporlanır; eski borçların varlığı tek başına B'yi `partial` yapmaz.

Sıradaki akış: **B görünür katalog → B review → C gerçek Claude/Codex yeni/devam/durdur bağlantısı → D birleşik kabul.** C'nin gerçek model deneyleri için §9 bütçe kapısı devam eder. Bu karar arka planda iş bırakma izni, otomatik oturum başlatma veya ilk pencere kapsamına koordinasyon ekleme değildir.

## 24. Orca'dan alınacak fikirler ve Loom'daki yerleri (28 Eylül 2026)

İnceleme yerel `/Users/gencberke/Documents/github/orca` kaynaklarına dayanır. Kaynakta görülen tasarım ile Loom'da uygulanıp doğrulanmış davranış ayrıdır; Orca testleri bu incelemede çalıştırılmadı. TypeScript/Electron altyapısını taşımak yerine aşağıdaki davranış sınırları mevcut Swift çekirdeğine uygulanacak. Koordinasyon için bugün boş sınıf, tablo, servis veya genel framework kurulmaz.

| Fikir ve neden yararlı | Loom'a yerleştirme | Zaman |
| --- | --- | --- |
| **Durumun tek sahibi.** Liste, terminal ve gelecekte koordinatör ayrı ayrı “çalışıyor” kararı verirse birbirini yalanlar. Orca'nın durum deposu belgesi de kopya kaynakların sorununu anlatıyor; geçişinin tamamlandığı iddia edilmiyor. | `ProcessSupervisor`/sağlayıcı adaptörleri durumu üretir, mevcut `SessionEventHub` son durumu yayımlar; UI yalnız gösterim izdüşümüdür. Atlanan ara olaylardan sonra son snapshot yeterli olmalı. | B; mevcut yaklaşımı tamamla. |
| **İş, deneme ve süreç ayrı kimlikler.** Tekrar denenen bir göreve eski çalıştırmanın cevabı gelmesi yeni sonucu değiştirmemeli. | Kalıcı sohbet `ManagedSession`, OS çalıştırması `ManagedRun` olarak kalır. CP3'te görev ve görev denemesi bunlara referans verir; Orca'nın koordinasyon `Run` kavramı Loom'un `ManagedRun` alanına yüklenmez. | B/C bu ayrımı korur; görev/deneme modeli CP3. |
| **Kalıcı gelen kutusu ve teslim onayı.** Bildirim kaybolabilir; mesaj kaybolmamalı. “Kuyruğa alındı”, “okundu”, “iş bitti” aynı sonuç değildir. | CP3'te ayrı koordinasyon kayıtları; içerik saklamayan `SessionCatalog` transkript/inbox deposuna çevrilmez. Önce mesaj kalıcılaşır, sonra sağlayıcıya bildirim denenir; alıcı onayı ayrı kaydedilir. Bellekteki `pendingPromptIDs` kalıcı teslim kanıtı sayılmaz. | CP3; sağlayıcı teslim yetenekleri ayrıca kanıtlanır. |
| **Tekrarlanan istekte aynı sonuç; eski denemeyi reddetme.** Bağlantı koptuğunda yeniden istek ikinci bir iş doğurmamalı. | İstek kimliği + çağıran + içerik özetiyle işlem kaydı; aynı kimlik/farklı içerik reddi. Yetkiyi kullanıcı görevlendirmesi belirler; denemeye ve süreç kimliğine bağlı capability/generation bu kapsamı uygular. Sonucu belirsiz dış etki körlemesine yinelenmez. | CP3; bugün genel komut altyapısı ekleme. |
| **Görev sonucu ile kaynak bırakma ayrı.** “İş bitti” cevabı terminalin/alt işlerin kapandığını kanıtlamaz. | CP3 görev sonucu ve cleanup sonucu ayrı tutulur. Gerçek durdurma mevcut supervisor/stop raporundan geçer; yeni süreç sahibi/daemon kurulmaz. Açık kullanıcı devri dışında sahiplik sessizce bırakılmaz. | C mevcut stop gerçeğini gösterir; CP3 görev sonucuna bağlar. |

Kaynak dayanakları:

- Orca `docs/reference/agent-status-store.md:5–20,24–44`; Loom `Sources/LoomCore/SessionEventHub.swift:3–42,63–69` ve `ManagedSession.swift:3–47`.
- Orca `skill-guides/orchestration.md:48–54,118–127`: Task/Dispatch yetkisi ve açık sonuç. Bu dosya araştırma kaynağıdır; burada Orca ajan iş akışı yürütülmüyor.
- Orca `src/main/runtime/orchestration/db/messages/role-mailbox-delivery.ts:42–99,121–145`: transaction, tekrar teslim ve generation kontrolü; `db/dispatch-context/dispatch-capability.ts:22–39,79`: capability ve yeni tüketici nesli.
- Orca aynı kökte `db/mutation-receipts/mutation-receipt-store.ts:41–70`: istek/özet eşleştirme; `mailbox-pointer-submit.ts:114–125` ve `src/main/runtime/orchestration-mailbox-crash-recovery.test.ts:34–75`: Enter denemesini önce kaydetme ve belirsiz sonuçta ikinci Enter göndermeme.
- Orca `src/main/runtime/orchestration/worker-terminal-ownership.ts:133–151`: kaynak sahipliği ile bırakma kararını ayırma.

**Alınmayacak davranışlar:** Orca normal Quit'te daemon bağlantısını kesip oturumları yaşatabiliyor (`src/main/startup/main-process-quit.ts:245`, `src/main/daemon/daemon-provider-state.ts:124–129`); Loom'un tam çıkış sözüyle uyuşmaz. PTY'ye inbox işaretçisi ve Enter yazılması da Claude'un canlı/bekleyen oturumuna belgelenmiş, güvenilir teslim kanıtı değildir. CP3'ün mevcut teslim deney kapısını kaldırmaz. DAG scheduler, uzak host, mobil istemci ve çocuk görev ekranı bu ilk pencereye eklenmez. Orca OWN-1'i çözmüş kabul edilmez.

## 25. B dilimi: görünür katalog ve pencere (28 Eylül 2026)

**Amaç:** Kullanıcı Loom'u açıp projelerini ve kayıtlı sohbetlerini görebilsin, iki görünüm arasında geçsin, arasın ve adlandırsın. Teslim yalnız veri katmanı değildir; `Loom Dev.app` içinde görülebilir ve kullanılabilir olmalıdır. Gerçek Claude/Codex başlatma/devam/durdur bağlantısı bir sonraki C dilimidir.

### 25.1. Uygulama sırası ve sınırlar

1. `SessionCatalog` içinde §4.2 ve B1 migration, proje/başlık/sıra ve sayfalı sorguları ekle. Sohbet, OS run ve sağlayıcı kimliklerini koru. Mevcut metadata saklama desenini sürdür.
2. AppKit pencere yaşam döngüsüne SwiftUI katalog görünümünü bağla: proje/projesiz, aktivite/proje görünümü, seçim, arama, yeniden adlandırma; §4.1 ve `design/DESIGN.md` ölçü/ikonları. **Arama ve temel görsel yerleşim §8 D'den B'ye alınır.** Branch, ayrıntılı ayarlar ve terminal girdi özelliklerinin kalanları D'de kalır.
3. Tek UI olay tüketicisini mevcut çekirdeğe bağla. Son durum/stop hatası/bakılmamış bitiş için gereken bilgi atlanabilir callback'te kaybolmasın; snapshot'tan toparlanabilsin. UI kendi süreç/durum otoritesini kurmasın. Katalog işlemleri disk hatasında görünür hata versin, yapılmamış değişiklik kaydedilmiş görünmesin.
4. Seçim ve yeniden açılış hiçbir CLI/PTY yaratmasın. Geçmiş kaydın ana paneli başlık/durum ve dürüst boş görünüm gösterebilir. Henüz bağlanmayan yeni/devam/durdur eylemleri başarılı işlem taklidi yapmasın; C'ye ait olduğu açık olsun. Fixture sohbetler yalnız izole geliştirme/kabul verisinde bulunsun; normal katalog örnek sohbetlerle doldurulmasın. Mevcut A sentetik terminal yolu geliştirme kanıtı olarak korunabilir; açılışta otomatik başlamasın.
5. Görünüm modu, seçim ve sidebar tercihlerinin kalıcılığını bağla. Pencere kapatma/açma ve ortak Quit yolu korunsun. Gerçek sağlayıcı profillerine yazma, transkript içe alma, orkestrasyon, ES, vendor/renderer refactor'u, commit/push kapsam dışıdır.

### 25.2. Kabul ve kontroller

| ID | B'nin bitiş ölçütü |
| --- | --- |
| B1 | §7 B1: şema 1→2 sohbet/run/link/kimlik ilişkileri kayıpsız; kesinti rollback/yeniden açma, yabancı/bozuk/yeni şema korunur. 10.000 kayıtta ilk sayfa en fazla 100; sayfalama/arama/sıra doğru, eksik/çift kayıt yok. |
| B2 | §7 B2: projeler, sıra, özel başlık ve UI tercihleri yeniden açılışta korunur. Başlangıç ve geçmiş kayıt seçimi sıfır sağlayıcı/PTY/terminal tamponu üretir. |
| B3 | §7 B3: yavaş tüketici ve atlanan frame testinde son run, kimlik, durum, stop hatası ve güvenilir bitiş işareti doğru; eski run olayı yeni run sonucunu bozmaz. Liste yenileme kullanıcı görüntülemesi sayılmaz. |
| B4 | Paket uygulamada izole verilerle proje ekleme/yol tekrarını önleme, projesiz kayıt, iki liste modu, arama, seçim ve yeniden adlandırma çalışır. Özel başlık terminal başlık olayıyla ezilmez. 1220×780 ve minimum 780×500 boyutta kritik kontroller görünür; ekran görüntüsüyle kontrol edilir. |
| B5 | Durum güncellemesi bütün kataloğu yeniden sorgulamaz; kayıt başına timer/terminal yok. 1.000/10.000 kayıtla sorgu ve UI güncelleme yolu kısa ölçümle raporlanır; tam listeyi her olayda okuyan yol varsa düzeltilir. Bu, ertelenen terminal/GPU performans kabulü değildir. |

`swift build`, tam `swift test` (gerekiyorsa `agents/README.md` makro bayrağı), `git diff --check`; yeni untracked dosyalar da kontrol edilir. B1/B3 için gerçek sınır testleri ve B2/B4 için paket uygulama kanıtı gerekir. Süreç kullanan izole kontrollerde yalnız test child/app ortamına `LOOM_FORCE_COALITION_FAILURE=1` verilir; OWN-1 nedeniyle coalition üzerinden dış sürece sinyal riski alınmaz. Bu koşul tam sahiplik kabulü değildir ve ürün davranışına kalıcı daraltma olarak eklenmez. Model turu bütçesi **0**. 45 dakikalık A ölçümü/GPU/Apple hesabı bu kontrollerin parçası değildir.

B1–B5 doğrulanınca implementer **`Status: done` (B uygulaması; review bekliyor)** der; OWN-1 ve ertelenen kabul borcunu `Unverified` altında ayrı belirtir. B içinde başarısız veya doğrulanmamış kabul varsa `partial` kullanır. B sonucu bir sonraki boş numaralı uygulama bölümüne eklenir; durum satırı güncellenir. Reviewer B'nin bağımsız kontrollerini ve kapanış öncesi optimizer incelemesini yapar; optimizer yalnız **GPT-6 Astra medium/high** olur. Sonra C brief'i hazırlanır; B bitti diye otomatik C/CP3'e geçilmez.

## 26. Uygulama sonucu: B dilimi (28 Eylül 2026)

**Status: done (B uygulaması; review bekliyor).** Kapsam §25.1 sırasıyla uygulandı; commit/push yapılmadı, C'ye geçilmedi. OWN-1 araştırması ve 45 dakikalık A ölçümü yeniden açılmadı. Model turu: 0. Mevcut değişiklikler korundu (yalnız aşağıdaki dosyalar eklendi/değişti).

### 26.1. Ne yapıldı

**Katalog (`SessionCatalog`, şema 1→2).** Tek transaction: `projects` tablosu, `sessions.project_id` ve `sessions.title_is_custom` sütunları, beş indeks; `user_version` aynı transaction'da 2 olur, sohbet/run/link/kimlik satırlarına dokunulmaz. Yeni/yabancı/bozuk dosya reddi ve "yeni sürümlü dosyaya dokunmama" korundu. Yeni işlemler: `addProject` (yol standartlaştırılır: sembolik bağ çözülür, sondaki `/` ve `..` atılır; aynı klasör ikinci kez eklenmez, var olan döner), `removeProject` (yalnız boş; klasör dosyaları silinmez), `moveProject`, `setProjectCollapsed`, `sessionCounts`, `renameSession` (özel başlık işareti; 160 karakter; boş = otomatiğe dön), `recordTerminalTitle` (özel başlığı ezmez), `sessionPage` (keyset sayfalama, en çok 100; kapsam: tümü/proje/projesiz; sıra: son kullanım azalan veya oluşturma artan; arama SQL'de, terimler AND, sağlayıcı/başlık/proje adı, `%` `_` sözcük olarak, Türkçe dahil ASCII dışı büyük/küçük harf duyarsız için `loom_fold` SQL fonksiyonu), `sessions(ids:)`, `oldestLastUsed`.

**Olay çekirdeği (B3).** `SessionViewState` yeniden kurulabilir son duruma iki alan aldı: `stopFailure` (doğrulanamayan son stop; doğrulanan stop veya yeni run temizler) ve `unviewedCompletion` (güvenilir sağlayıcı `turnComplete`'i, o sırada kimse bakmıyorsa; yalnız `SessionEventHub.setViewed` veya yeniden `working` temizler). Otomatik lider çıkışı dahil her stop sonucu `ProcessSupervisor.recordStopReport` üzerinden hub'a taşınır (CP2 §26 madde 2'nin görünür hata yolu). Eski run'ın gecikmiş `runEnded/runDetached` olayı yeni run'ı bitirmez. `SessionViewState.lifecycle` artık opsiyonel ("bu süreçte bildirilmedi; katalog satırı geçerli"): `ProcessSupervisor.restoring` geçmiş kayıtları olay haritasına koymuyor.

**B5 ile bulunan/düzeltilen iki yol.** (1) `SessionLifecycleController.reschedule/timerFired` her olayda `catalog.sessions()` ile bütün kataloğu okuyordu; artık yalnız yaşayan sohbetler (`ProcessSupervisor.runningSessionIDs`, `catalog.sessions(ids:)`) ve en eski idle satırı (`oldestLastUsed`) okunuyor. (2) Geri yüklemede her kayıt için olay yayımlanıyor ve yayım başına tam harita kopyalanıyordu (10.000 kayıtta ölçülen 358 µs/olay, doğrusal); geçmiş artık haritaya girmiyor.

**Pencere (`LoomCatalogUI`, `loom-app`).** `NSSplitViewController`: SwiftUI kenar çubuğu (native sidebar, 220–520 pt, varsayılan 300; detay ≥480 pt; pencere 1220×780, min 780×500) ve detay paneli. Kenar çubuğu: üst çubuk (kenar çubuğu düğmesi, klasör/saat görünüm seçimi, üç nokta menüsü), her zaman görünen arama alanı, aktivite görünümü (gün grupları) ve proje görünümü (daraltılabilir projeler, oluşturma sırası, "Sessions" projesiz grubu), iki satırlı kartlar (durum göstergesi, başlık, göreli son kullanım; durum etiketi, proje, renkli sağlayıcı simgesi), sol altta proje ekle, sağ altta (dürüstçe devre dışı) ayarlar. Menü: `Cmd+O` proje ekle, `Ctrl+Cmd+S` kenar çubuğu, `Cmd+1/2` görünüm; `Cmd+N` "New Conversation (not connected yet)" devre dışı; A'nın sentetik terminali `Option+Cmd+N` "(Development)" olarak korundu. Durum modeli: `CatalogModel` yalnız gösterim izdüşümü (sayfalar, arama, seçim, hata mesajları); canlı durum tek olay tüketicisinden gelir (ardışık frame → tek satır, atlanan frame → frame'in tam son durumundan onarım). Geçmiş kaydın detayı kimlik/durum/tarih gösterir ve "Conversation actions are not connected yet" der; Resume/Stop devre dışı, hiçbir yol CLI/PTY başlatmaz. Tercihler (görünüm modu, seçim, kenar çubuğu genişliği/daralma) `<veri kökü>/ui-preferences.json`'da: değişince atomik yazılır, sürükleme bitince tek yazım, bozuk dosya kenara alınır. Geliştirme aracı `loom-catalog-fixture` (paketlenmez): izole katalog tohumlar/inceler, şema 1 dosyası üretir. `--data-root` yalnız `--evidence` ile geçerli.

**Ortam notu.** Bu ortamda (yalnız Command Line Tools) `SwiftUIMacros` eklentisi yok; `@State` derlenmez. Rename iletişim kutusunun durumu bu yüzden görünüm-yerel değil, `RenameDraft` (`@Observable`, model tutar). `@Observable`/`@Bindable`/`@Environment` çalışıyor.

Değişen/eklenen: `Sources/LoomCore/{SessionCatalog,SessionEventHub,SessionLifecycleController,ProcessSupervisor}.swift`; yeni `Sources/LoomCatalogUI/`, `Sources/loom-catalog-fixture/`, `Sources/loom-app/MainSplitViewController.swift`; `Sources/loom-app/{AppDelegate,DevelopmentEvidence}.swift`; `Package.swift`; `scripts/{package-dev-app,cp5-b-acceptance}.sh`; testler `Tests/LoomCoreTests/{SessionCatalogV2,CatalogScale}Tests.swift`, `SessionEventHubTests`/`ProcessSupervisorTests` eklemeleri, yeni `Tests/LoomCatalogUITests/`.

### 26.2. Kabul (§25.2)

| ID | Durum | Kanıt |
| --- | --- | --- |
| B1 | **doğrulandı** | `SessionCatalogV2Tests`: şema 1 dosyası (WAL) → 2, bütün sütunlar/kimlikler/link/run satırları birebir, `foreign_key_check` ve `quick_check` temiz; migration transaction'ı içinde hata → geri alınır, dosya şema 1 ve satırlar aynı, sonra açılır; `/usr/bin/sqlite3` ile aynı DDL açık transaction'da SIGKILL → yeniden açılır ve göç eder; yeni sürüm (3), yabancı `application_id`, bozuk dosya reddedilir, bayt bayt değişmez, `-wal` oluşmaz. 10.000 kayıt: ilk sayfa 100 (0,38–0,44 ms); aktivite ve oluşturma sırası, proje/projesiz kapsamı, ortak zaman damgalı satırlar, arama (sağlayıcı, başlık, proje adı, AND, `%`/`_` sözcük, kapsamlı arama) beklenen kümeyle birebir, eksik/çift yok; sayfalar arası eklenen/yeniden adlandırılan satır sonucu bozmaz. Paket: `cp5-b-20260928T235413/schema-one`: paketli uygulama şema 1 dosyasını açtı, satırlar aynı, şema 2, `quick_check` ok. |
| B2 | **doğrulandı** | Paket (`main` → `reopened`): 10.000 kayıtlı açılışta ve satır seçimi/görünüm/arama sırasında uygulamanın çocuk süreci 0, `ptmx` tanıtıcısı 0, terminal yüzeyi yok. Kapat-aç: görünüm modu, seçim ve seçili başlık, proje sırası ve daraltma, kenar çubuğu genişliği (kayıtlı 380 pt → açılışta geri geldi), özel başlık (katalogda `titleIsCustom`) korunur; Quit başarılı. `CatalogModelTests`: gerçek `ProcessSupervisor` ile 20 seçim + mod değişimi → yaşayan run 0, sahip olunan süreç 0. |
| B3 | **doğrulandı** | `SessionEventHubTests`, `ProcessSupervisorTests` (gerçek fixture çocuk, başarısız hook), `CatalogModelTests`: bekletilen tüketici (300 gürültü olayı) tek frame'den doğru run, kimlik, durum, `stopFailure`, `unviewedCompletion`'ı kurar; geç eski-run `runEnded` yeni run'ı bozmaz (hub ve model düzeyinde); lider çıkışı sonrası başarısız stop sonradan abone olan tüketicide de görünür, doğrulanan stop temizler; run bitişi güvenilir `turnComplete` olmadan "bitti" üretmez, çalışma yeniden başlayınca işaret düşer. Liste yenileme, arama, mod geçişi, pencere pasifken seçim görüntüleme sayılmaz; yalnız görünür+etkin pencerede seçili sohbet işareti temizler. |
| B4 | **doğrulandı** | Paket, 34 denetim (`plans/experiments/cp5-b-acceptance.json`, kanıt `cp5-b-20260928T235413/`): iki liste modu, aktivite gün grupları, arama iki modda ve temizleme, aynı klasörü iki kez ekleme (tek proje + görünür bilgi), projesiz grup, taşıma/daraltma, dolu projeyi kaldırma reddi (görünür hata) ve boş projeyi kaldırma, seçim; yeniden adlandırma iletişim kutusu gerçekten pencere sheet'i olarak açılır, Save başlığı yazar ve sheet'i kapatır; terminal başlık olayı özel başlığı ezmez (aynı yol katalogda `titleIsCustom` ile kalıcı); klasör seçici (Add Project) sheet olarak açılır ve kapanır; pencere 1220×780 ve 780×500 (iki mod, kenar çubuğu daraltılmış hal) ekran görüntüleri `main/screenshot-*.png` (uygulamanın kendi içerik görüntüsü; okundu: arama, mod düğmeleri, kartlar, ekle/ayarlar, detay ve turuncu sahiplik uyarısı görünür, taşma yok). |
| B5 | **doğrulandı** (kısa ölçüm) | Sorgu (`CatalogScaleTests`, yerel disk, ortanca): ilk sayfa 1.000 kayıtta ~190 µs, 10.000'de ~190 µs; arama 1.000'de ~3,1 ms, 10.000'de ~2,8 ms; `ProcessSupervisor.restoring` (bir tam okuma) 3,5 / 32 ms. Paket: 10.000 kayıtta `start()` (projeler + sayımlar + ilk sayfa) 1,2 ms, bellekte en çok 500 satır modeli, iş parçacığı sayısı <40, zamanlayıcı/terminal/PTY yok. Durum güncellemesi: 100 durum olayı → katalogdan çözülen satır 0 (1.000 ve 10.000 kayıt); 1 yaşayan sohbet + 2.000 kayıt, 40 olay → 2 satır (eski yol ~2.000×olay); `CatalogModelTests`: 1.000 durum olayında sayfa sorgusu 0; olay haritası 10.000 geçmişte 1 durum, yayım ~1,7 µs/olay (önce 358 µs). Bilinmeyen sohbetin ilk olayı en çok bir birleşik yenileme doğurur. Bu, ertelenen terminal/GPU kabulü değildir. |

**Kontroller.** `swift build` başarılı. `swift test` (makro bayrağıyla): **143 test geçti** (13 LoomTerminal + 110 LoomCore + 20 LoomCatalogUI; B öncesi 106), exit 0. `git diff --check` temiz; izlenmeyen yeni dosyalar için sondaki boşluk taraması temiz (yalnız `patches/*.patch` içindeki yama bağlam satırları, B'den önce vardı). Üç `zsh -n` temiz. `LOOM_FORCE_COALITION_FAILURE=1`: yeni süreçli testlerde `.probe(forceFailure: true)` ledger'ı, paket koşullarında `open --env` ile. A'nın paket regresyonu: `scripts/cp5-a-acceptance.sh` → `cp5-a-20260928T234321`, 5 senaryo, hepsinde son Quit başarılı ve fixture yok (`quit-failure-retry` denemeleri `[false, true]`), yeniden açma tek pencere, gizli pencerede çıktı sürüyor.

**Regresyon testlerinin düzeltmesiz başarısızlığı** (kaynak tek satır bozularak, sonra geri alındı, `cmp` ile doğrulandı): hub'daki eski-run koruması kalkınca `lateEventOfAnEarlierRun…` ve model testi; lifecycle `catalog.sessions()`'a dönünce `CatalogScaleTests` (iki test); migration transaction'sız iken `interruptedMigrationRollsBack…`; `title_is_custom` koşulu kalkınca iki başlık testi; restore olayları geri gelince ölçek testi (`sessions.isEmpty`); `stopFailure` yayımı kalkınca iki supervisor testi.

### 26.3. Sınırlar ve kararlar

- Seçim, `last_used_at`'i güncellemez ve yaşam döngüsünü değiştirmez; "görünür/etkin seçme kullanım zamanını günceller" C3'e bırakıldı (§7). B'de yalnız okunmamış-bitiş işareti görüntülemeyle temizlenir.
- Sağlayıcı olayları henüz katalog kartına bağlanmadı (C): kartların durum göstergeleri (çalışıyor/onay/hata/bekliyor/bilinmiyor/bakılmamış bitiş/stop doğrulanamadı) `SessionIndicator` eşlemesi ve olay-tüketici testleriyle doğrulandı, paket içinde canlı sağlayıcı olayıyla görülmedi. Terminal → `terminalTitleChanged` bağlantısı da C'de: paket kanıtı model çağrısını sürüyor, terminal `onTitle` henüz katalog satırına bağlı değil.
- Bilinçli eksikler: branch (D), ayrıntılı ayarlar (Cmd+, devre dışı), sürükleyerek proje sıralama (menüden Yukarı/Aşağı taşı), Dock/menü çubuğu bildirimleri. Yeni/devam/durdur devre dışı ve "not connected yet" der.
- Ekran görüntüleri `cacheDisplay` ile alındı (ekran kaydı izni yok); pencerenin native kırmızı/sarı/yeşil düğmeleri görüntüde yok, üst çubuk 74 pt boş bırakılıyor. Tasarım referansıyla piksel karşılaştırması yapılmadı; `design/DESIGN.md` §2–3 ölçü ve renkleri uygulandı ve ekran görüntüleri gözle okundu. Cam malzeme etkisi (sidebar yarı saydamlığı) ve Saydamlığı/Hareketi Azalt tercihleri paket içinde denenmedi (kod tercihleri izliyor).
- Proje klasör seçicisi ve iletişim kutusu işaretçiyle tıklanmadı; aynı model yolları ve sheet'in gerçekten sunulduğu kanıtlandı.
- Paketleme ad-hoc imzalı (§20.7 madde 3).
- `Loom-Dev` veri kökünde A kabul betiğinin uygulama açışı boş `catalog.sqlite3` ve `ui-preferences.json` yarattı; örnek sohbet eklenmedi.
- `scripts/cp5-b-acceptance.sh` ekran görüntüsü ve durum dosyalarını `probe/runs/` altına yazar; özet `plans/experiments/cp5-b-acceptance.json`.

### 26.4. Unverified ve Needs

**Unverified (B'yi tek başına `partial` yapmaz, §23):** OWN-1 (tam süreç sahipliği ve kapanış; ES1 yetkisiz, ES2–ES8 yok); geçerli 5×6 A performans ölçümü, renderer karşılaştırması, uzun kullanım/çoklu terminal/GPU; kalıcı imza; son A değişikliklerinin bağımsız kabulü; §26.3'teki görsel/etkileşim sınırları; gerçek sağlayıcı olayının kartta görünmesi (C).

**Needs:** B review ve optimizer incelemesi (yalnız GPT-6 Astra medium/high, §25.2); sonra C brief'i. Kullanıcı kararı gerekmiyor. Teknik varsayılanlar: projeler `standardizedFileURL + resolvingSymlinksInPath` ile eşlenir; hub geçmişi haritaya koymaz; tercihler veri kökündeki JSON dosyasındadır (UserDefaults değil, izolasyon için).

## 27. Review: B katalog ve pencere (29 Eylül 2026)

**Sonuç: B için üç dar düzeltme gerekli (§27.1); sahiplik/uzun ölçüm kapısı yeniden açılmıyor.** Bağımsız debug build ve **143 test geçti** (13 terminal, 110 core, 20 UI). Yeniden paketlenen release uygulamanın kabulü **33/34**; başarısız panel kontrolü aşağıda ayrı açıklanıyor. Sonuç yalnız §26 raporunun tekrarı değildir: mevcut kütüphanelere bağlanan izole programlarla iki katalog/UI hatası yeniden üretildi. Üretim/test kodu değiştirilmedi, commit/model turu yok.

### 27.1. Bulgular

1. **[P2] Sohbet adı değişince açık aramanın sonuç kümesi yenilenmiyor.** `Sources/LoomCatalogUI/CatalogModel.swift:499–507,523–530`: `refreshRow` satır nesnesinin başlığını değiştirip listeleri stale işaretliyor, görünür listeyi tekrar sorgulamıyor. Reviewer gerçek `CatalogModel` + SQLite ile hem aktivite hem projesiz/proje görünümünü çalıştırdı: `Needle` aramasındaki kayıt `Unrelated` yapılınca SQL sonucu boşken UI'de `Unrelated` kaldı. Tersi de doğrulandı: seçili kaydın adı `Newmatch` yapıldığında SQL bir kayıt döndürürken açık `Newmatch` aramasında UI boş kaldı. `settle()` sonrasında da aynı. **Etkisi:** kullanıcı yanlış arama sonucu görüyor; B4 arama/yeniden adlandırma birleşimi eksik. **Kabul:** iki görünümde de aramaya giren/aramadan çıkan kayıt doğru yansısın; seçili detay kaydı korunabilsin; özel başlık koruması, sayfalama ve eski sorgu sonucunu reddetme sürsün. Terminal başlığı da aynı yenileme yolunu kullandığı için testte kapsansın. Regresyon testleri mevcut kodla başarısız olmalı. Kanıt: `repro.swift`, `repro.log`.

2. **[P2] Yeni sohbet kimliğine geçiş proje ilişkisini kaybediyor.** `Sources/LoomCore/SessionCatalog.swift:350–354` yeni satırı `projectID` vermeden ekliyor; varsayılan `nil` (`:838–859`). `ProcessSupervisor.swift:419–426` aynı run içinde yeni sağlayıcı kimliğini bu yoldan kaydediyor. Reviewer projeye bağlı oturum + sentetik run kaydı oluşturup gerçek `transitionRun` çağrısını çalıştırdı: eski sohbetin projectID'si duruyor, yeni sohbetinki **nil**, proje sorgusunda yalnız eski kayıt, projesiz sorgusunda yeni kayıt var. OS süreci/model başlatılmadı. **Etkisi:** C'de `/clear` veya `/new` bağlanınca yeni sohbet aynı çalışma dizinindeyken projesiz gruba düşer. Gerçek sağlayıcı komutuyla henüz sınanmadı; katalogdaki veri kaybı bağımsız doğrulandı. **Kabul:** yeni sohbet mevcut sohbetin proje ilişkisini aynı transaction içinde devralsın; projesiz kaynak projesiz kalsın; mevcut başka sohbete resume geçişi hedefin kendi proje ilişkisini ezmesin; eski sohbet ve run-link geçmişi korunsun. Mevcut `SessionCatalogTests.swift:149` geçiş testi projeye bağlı kaynak kullanmadığından bu regresyonu kaçırıyor. Kanıt: `project-transition.swift`, `project-transition.log`.

3. **[P2, kabul aracı] Başarısız paket kabulü başarılı çıkış koduyla dönüyor.** `scripts/cp5-b-acceptance.sh:233–240` `allPassed=false` sonucunu dosyaya ve `SOME FAILED` olarak çıktıya yazıyor; Python/shell başarısız exit üretmiyor. Reviewer çalıştırmasında 33/34, `summary.json` false ve **komut exit 0** birlikte görüldü. **Etkisi:** yalnız komut sonucuna dayanan kontrol/sonraki adım hatalı kabulü başarı sayar. **Kabul:** en az bir başarısız kontrol nonzero exit, bütün kontroller geçtiğinde 0; özet/ham kanıt iki durumda da korunur. Negatif özetle bu ayrım sınansın. Panel kontrolü için §27.2'deki pencere/odak koşulu görünür biçimde denetlensin; yalnız süreyi uzatarak veya kontrolü kaldırarak yeşile çevrilmesin.

### 27.2. Bağımsız kontroller ve sınırlar

- `LOOM_FORCE_COALITION_FAILURE=1 swift build`: exit 0. Aynı ortamla `swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`: exit 0, **143/143**. Var olan migration, hata/rollback, 10.000 kayıt sayfalama, olay atlama, özel başlık, otomatik süreç başlatmama ve A regresyon testleri geçti. Bu iki yeni yeniden üretim mevcut testlerde yok.
- `scripts/package-dev-app.sh /tmp/loom-review-b/app`: release build, paket ve ad-hoc imza doğrulaması başarılı. Bu pakette `scripts/cp5-b-acceptance.sh '/tmp/loom-review-b/app/Loom Dev.app'`: run **`cp5-b-20260929T090831`**, 33/34. Migrasyon, iki liste, yeniden adlandırma, yeniden açılış tercihleri, 10.000 kayıtta süreç/PTY/terminal yokluğu ve sentetik terminal Quit kontrolleri geçti. Sayım/sonuç için `summary.json` esas; shell çıkışı madde 3 nedeniyle güvenilir değil.
- **Panel sınırı:** başarısız kontrol `attachedSheet=None → None`. `CatalogModel.swift:473–474` key window varsa sheet, yoksa standalone panel açıyor; betik yalnız ana pencerenin sheet'ini kontrol ediyor ve sabit süre bekliyor. Ayrı izole uygulamada CUA ile gerçek Add project kontrolüne basıldı, native Open paneli görüldü, gerçek Cancel ile Loom'a dönüldü. Bu nedenle “klasör seçici açılmıyor” ürün bulgusu çıkarılmadı. Bu çalıştırmada sheet/standalone farkının kesin nedeni ve gerçek klasör seçimiyle kayıt tamamlanması doğrulanmadı. İlk Go To denemesi kayıtla sonuçlanmadı; başarılı klasör ekleme UI kanıtı diye sunulmuyor. Dar UI deneyi Cmd+Q ile kapandı: 0 sinyal, 0 kalan, başarılı Quit.
- Mevcut minimum-boyut içerik görüntüsü gözle incelendi; bu native pencere düğmeleri veya piksel eşliği kanıtı değildir. B paket scriptindeki boyut denetimi yalnız genişliği kontrol ediyor (kayıt `[780,468]` içerik, 500 dış pencere yüksekliği); bunu “780×500 içerik alanı” olarak genellemeyin. Cam/erişilebilirlik matrisi ve D'nin ayrıntılı görsel kabulü ertelenmiş kapsamda kalır.
- `git diff --check`, paket/B kabul scriptleri `zsh -n`: başarılı. Reviewer GUI deneyleri yalnız `/tmp/loom-review-b` veri kökü ve izole paket kullandı. Normal kullanıcı kataloğu/sağlayıcı profili değiştirilmedi. OWN-1 dar test koşulu tam sahiplik kabulü sayılmadı. A paketinin bütün beş senaryosu bu tur tekrar çalıştırılmadı; tam suite içindeki A testleri ve B paketindeki sentetik yol geçti.

Kalıcı reviewer kanıtı: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-b-review-20260929/`: build/test/package/kabul log'ları, iki yeniden üretimin Swift kaynağı ve çıktısı, optimizer yöntem kaynağı/bağımsız tekrar çıktısı, `panel-ui-check.txt`, `panel-quit.json`, `source-sha256.json`, `commands.txt`. Paket ham kanıtı ayrı `cp5-b-20260929T090831/`. Implementer'ın §26 ve eski özet dosyaları değiştirilmedi.

## 28. Optimizasyon incelemesi: B'nin yaşlanan geçmiş yolu (29 Eylül 2026)

GPT-6 Astra high optimizer kullanıldı. Reviewer belirleyici kaynakları ve ölçüm programını okudu; aynı programı mevcut release çekirdeğine karşı bağımsız tekrar çalıştırdı. **Bu, bugün B penceresinin takıldığı iddiası değildir:** `SessionLifecycleController` pencereye henüz bağlanmıyor. Bulguyu **C'nin yaşam döngüsü bağlantısından önce giderilecek ön koşul** olarak ayırıyoruz; OWN-1'e veya yeni bir uzun ölçüm turuna dönmüyoruz.

1. **[P2, C ön koşulu] Eski kayıtları stale yapınca büyük olay haritası geri geliyor.** `Sources/LoomCore/SessionLifecycleController.swift:220–225` her eski kayıt için ayrı lifecycle olayı üretir; `SessionEventHub.swift:118–124` bunları haritaya kalıcı ekler ve her frame'de bütün haritayı taşır. Bekleyen tüketici son frame'i tuttuğunda copy-on-write, toplu sınıflandırmada karesel ve sonraki durum olaylarında geçmiş sayısıyla doğrusal maliyet doğurur. `CatalogScaleTests.swift:16–17` tarihleri özellikle stale süresinden genç tuttuğu için §26'nın küçük harita ölçümü bu yolu kapsamaz.

   Gerçek `classifyStale()`; 20 günlük idle kayıtlar, son frame'i tutan tüketici, sonra 1.000 durum olayı; 1 ısınma + 5 tekrar. Supervisor testte dar ledger ile kuruldu, süreç/model başlatılmadı. Reviewer tekrarında:

   | Geçmiş kayıt | Toplu stale medyanı (min–max) | Sonraki olay medyanı (min–max) | Haritada kalan |
   | --- | --- | --- | --- |
   | 1.000 | 25,65 ms (25,28–29,36) | 64,34 µs (59,80–73,92) | 1.000 |
   | 10.000 | 2.253,86 ms (2.218,67–2.386,62) | 454,70 µs (437,87–489,39) | 10.000 |

   Optimizer'ın ayrı serisi 10.000'de 2.287,42 ms ve 457,43 µs idi; aynı büyüme doğrulandı. Küçük harita için optimizer 1/10/50 durum medyanını 10,93/10,91/13,18 µs ölçtü. Bunlar izole çekirdek süreleridir; masaüstü/UI/WindowServer maliyeti veya üretim CPU bütçesi değildir.

   **Yön:** yalnız kalıcı katalog lifecycle değişiklikleri bütün geçmişi canlı durum haritasına taşımamalı; toplu katalog değişimini sınırlı bildirimle ve kaçırılmış olaydan toparlanabilir biçimde duyur. Son stop hatası veya bakılmamış bitişi kaybeden kör harita temizliği kabul edilmez. Mevcut live durum/hata ve kalıcı katalog arasındaki sorumluluğu koru; genel event framework'ü kurma.

   **Kabul:** 10.000 eski kayıtla gerçek yaşlandırma yolunu kapsayan regresyon; canlı harita yalnız tarihçe sayısıyla büyümesin; geciken tüketici görünen kartları doğru stale durumuna getirsin, mevcut hata/bitiş/aktif run bilgisi korunsun. Aynı 1+5 yöntemiyle toplu süre ve sonraki olay maliyetindeki düşüş mutlak değerle raporlansın; son olay maliyeti küçük canlı küme düzeyine dönsün. Ürüne yeni sabit sayısal performans bütçesi bu review ile eklenmedi.

**İncelendi, ek öneri yok:** indeksli ilk sayfa/sayfalama ve canlı kayıtları seçerek okuma doğru yönde. Optimizer ilk 100 sorguda 1.000/10.000 için 0,128/0,131 ms; 10.000 kayıtta hiçbir şey bulmayan aramada 13,83 ms ölçtü. Yöntem okundu, bu ek sayılar reviewer tarafından tekrar ölçülmedi; bu ölçekte yeni arama altyapısı gerekçesi bulunmadı. Kayıt başına timer/terminal eklenmedi. GUI toplam maliyeti ve ertelenen uzun/GPU ölçümlerine sonuç çıkarılmadı.

## 29. Sonraki dar iş ve C'ye geçiş (29 Eylül 2026)

**Şimdi:** §27.1 madde 1–3'ü düzelt: görünür arama sonuçlarının başlık değişimiyle tutarlılığı, yeni sohbetin proje ilişkisi, kabul betiğinin doğru başarı/başarısızlık sonucu. Bunlar yeni özellik veya yeniden A çalışması değildir. Her biri mevcut suite'e anlamlı regresyonla eklenir; düzeltmesiz başarısızlık gösterilir. Şema/framework değişikliği gerektirmeyen mevcut desenler tercih edilir. Panel kabulündeki eksik koşulu dar paket deneyiyle doğrula; diğer paket sonuçlarını kaybetme.

**Sonra:** bu düzeltmelerin review'u ile B kapanabilir. §28 madde 1, C runtime/lifecycle bağlamasının ilk ön koşuludur; C tamamlandı denmeden giderilir. C ayrıca §26.3'te ertelenen gerçek sağlayıcı olayları, terminal başlığı ve görünür/etkin seçimde kullanım zamanı bağlantılarını içerir. Bunlar B'de uygulanmış sayılmaz. C uygulama brief'i ayrı verilecek; bu review gerçek sağlayıcı deneyi/model turu yetkisi vermez.

**Implementer brief:**

- **Goal:** §27.1'deki üç B review bulgusunu mevcut mimaride düzelt ve B'yi yeniden kabul edilebilir hale getir.
- **Context:** `agents/implementer.md`, bu plan §23–29. Bağımsız 143 test geçti; iki veri/UI hatası izole yeniden üretildi. OWN-1 ve uzun A/GPU/imza borcu ayrı. §28 C ön koşulu bu dar düzeltme turunun dışındadır.
- **Scope:** `CatalogModel` başlık/arama yenileme yolu; `SessionCatalog` yeni sohbet geçişinde proje ilişkisi; B kabul betiği ve gerekirse panel kanıtındaki pencere koşulu. İlgili mevcut testler. C/ES/vendor/refactor/gerçek sağlayıcı/commit/push yok; mevcut ortak çalışma değişikliklerini koru.
- **Done when:** §27.1 madde 1–3 kabulü kanıtlandı; uygulama raporunda her maddeye numarasıyla cevap verildi, durum satırı güncellendi. B paketinin başarısız kontrolü nonzero çıkar, başarılı sonuç yalnız gerçekten geçen kontrollerden oluşur. Sadece genel `swift test geçti` ile yeni regresyon kanıtı yerine getirilmiş sayılmaz.
- **Checks:** dar regresyonların düzeltmesiz/sonrası sonucu, `swift build`, tam `swift test`, diff/untracked kontrolü, değişen arama/başlık ve panel yolu paket kanıtı. Paket/süreçli testlerde §25.2 izolasyonu; model turu 0. 45 dakikalık ölçüm çalıştırma. Raporlayıp dur.

## 30. Uygulama sonucu: §27.1 düzeltmeleri (29 Eylül 2026)

**Status: done (B düzeltmeleri; review bekliyor).** Yalnız §29 kapsamı: `CatalogModel`, `SessionCatalog.transitionRun`, B kabul betiği ve panel kanıtı. §28 (C ön koşulu), C, ES, vendor, gerçek sağlayıcı, model turu (0), commit/push yok; mevcut ortak çalışma değişiklikleri korundu.

### 30.1. Bulgulara cevap

- **§27.1 madde 1 — çözüldü.** `CatalogModel.refreshRow` (`Sources/LoomCatalogUI/CatalogModel.swift`): açık arama varken satırı güncelledikten sonra görünür listeleri (count korunarak, eski sorguyu reddeden generation koruması aynen) yeniden sorgular; arama yokken sorgu yapmaz (başlık sıra/üyelik anahtarı olmadığı için sık terminal başlıkları sorgu doğurmaz). Seçili detay kaydı `pruneRowModels` ile korunur. Regresyon `CatalogModelTests.renameAndTerminalTitleKeepTheOpenSearchResultsConsistent(mode:)` (aktivite ve proje görünümü): `Needle` aramasında kayıt `Unrelated` olunca sonuçtan çıkar (UI ve SQL boş), `Newmatch` aramasında `Other` `Newmatch` olunca girer, terminal başlığı aynı yoldan girer ve özel başlığı ezmez, seçili detay yeni başlığıyla kalır, yarım kalmış arama sonrası boş arama üç kaydı da getirir. Düzeltmesiz (`if isSearching` satırı kaldırılınca): iki modda da 4 beklenti başarısız (ilk: `shownTitles == []` — reviewer'ın gördüğü `Unrelated` kalıntısı). Paket: `search-title-in/out/back` (aktivite görünümü, gerçek katalog): 1 → 0 (seçili başlık `Different name`) → 1 satır.
- **§27.1 madde 2 — çözüldü.** `SessionCatalog.transitionRun(_:from:to:)`: kaynak sohbetin `project_id`'si aynı transaction içinde okunur ve yeni sohbet satırına yazılır; projesiz kaynak projesiz kalır; `toExistingSessionID` yolu hedefin kendi projesini değiştirmez (kod değişmedi, testle sabitlendi). Regresyon `SessionCatalogV2Tests.newConversationInheritsTheProjectAndExistingTargetsKeepTheirOwn`: projeye bağlı kaynak → yeni sohbet aynı proje ve proje sorgusunda ikisi, projesiz sorguda yalnız projesiz kayıt; eski sohbet `idle` ve projesi duruyor; run-link geçmişi `[eski (unlinked), yeni]`; başka projedeki mevcut sohbete resume geçişi hedefin projesini ve önceki sohbetin projesini korur; projesiz kaynak → projesiz yeni. Düzeltmesiz (`projectID: nil`): 3 beklenti başarısız (yeni sohbetin projesi nil, proje sorgusunda eksik, projesiz sorguda fazla).
- **§27.1 madde 3 — çözüldü.** Yeni `scripts/cp5-b-summary.py`: `checks.json`'dan `summary.json` üretir, yalnız bütün kontroller geçtiğinde (ve en az bir kontrol varken) 0 döner, aksi halde 1; her iki durumda özet ve ham kanıt kalır. `scripts/cp5-b-acceptance.sh` değerlendiriciyi çalıştırıp bu betiği **son komut** olarak çağırır (çıkış kodu betiğin çıkış kodudur). Negatif: `python3 scripts/cp5-b-summary.py --selftest` → tamamı geçer: `all-pass exit=0 allPassed=True`, `one-fails exit=1 allPassed=False`, `empty exit=1 allPassed=False`. Ayrıca kabul çalışmalarında betik exit kodu gerçek sonuçla eşleşti: panel adımında uygulama çökünce (aşağıda 30.3) çıkış 1, tam başarıda 0.
- **Panel kabulü (§27.2) — dar deney yapıldı; neden kesinleşti.** Reviewer'ın `attachedSheet None → None` sonucunun nedeni: `presentAddProject` sheet'i yalnız `NSApp.keyWindow` varsa bağlıyordu. Loom aktif uygulama değilken key window yoktur ve panel bağımsız pencere olarak açılır. Eski kodla yeniden üretildi (Finder öndeyken `open-add-project-panel`): `appActive=false, windowIsKey=false, attachedSheet=None, openPanelVisible=true`. Ürün paneli açıyordu (bulgu "açılmıyor" değildi), ama davranış odak durumuna bağlıydı ve betik bunu denetlemiyordu. Düzeltme: `CatalogModel.presentingWindow` (AppDelegate ana pencereyi verir); pencere görünürse sheet, değilse bağımsız panel; `Cmd+O` menüsü önce ana pencereyi öne getirir. Betik artık dört durumu ayrı denetler: aktif (sheet, iptal), klasör seçimi (proje eklenir), **Loom pasif** (`appActive=false`, `windowIsKey=false`, yine sheet ve kapanır) ve **pencere kapalı** (bağımsız panel görünür, `attachedSheet=None`, kapanır). Süre uzatılmadı, kontrol kaldırılmadı.
- **§27.2 boyut sınırı — düzeltildi.** Betik artık dış pencere çerçevesini denetler (`windowFrameSize == 780×500`) ve içerik alanını (780×468) ayrı etiketler; "780×500 içerik alanı" iddiası yok. Ayrıca `activity-780x500` ekran görüntüsünden önce aktivite moduna geçilir (önceki sürümde proje ekleme modu değiştirmişti, dosya adı yanlış modu gösteriyordu).

### 30.2. Kontroller

- `swift build` başarılı. `swift test` (makro bayrağıyla): **145 test geçti** (13 LoomTerminal + 111 LoomCore + 21 LoomCatalogUI; §27'de 143), exit 0. `git diff --check` temiz; izlenmeyen yeni dosyalar için sondaki boşluk taraması temiz (`patches/` yama bağlam satırları hariç, B'den önce vardı); dört `zsh -n` ve `py_compile` temiz.
- Paket: `scripts/package-dev-app.sh` (ad-hoc) sonra `scripts/cp5-b-acceptance.sh` → run `cp5-b-20260929T095326`, **38/38**, exit 0; özet `plans/experiments/cp5-b-acceptance.json`. §26.2'nin B1/B2/B4/B5 denetimleri aynen geçti; yeni: arama-yeniden adlandırma (1→0→1), klasör seçimi, pasif uygulamada sheet, kapalı pencerede bağımsız panel, dış çerçeve 780×500. A'nın paket senaryoları bu turda yeniden çalıştırılmadı (değişiklik A yolunu etkilemiyor; tam suite ve B paketindeki sentetik terminal Quit'i geçti). İzolasyon §25.2: paket koşuları `LOOM_FORCE_COALITION_FAILURE=1`, veri kökü `probe/runs/…/data-*`; model turu 0.

### 30.3. Sınırlar ve bulunan test-aracı hatası

- **Gerçek "Open" tıklaması yapılmadı.** Klavye/işaretçi sentezi için izin yok (`osascript` "not allowed to send keystrokes"). `panel-choose` kanıtı gerçek sheet'i iptal edip seçilen klasörü panelin tamamlama işleyicisiyle aynı `folderPanelFinished(accepted:url:)` yoluna verir (ve `CatalogModelTests`/paket, projenin eklendiğini gösterir); AppKit'in kendi `panel.url` dönüşü **doğrulanmadı**. Gerçek Cancel ve sheet sunumu doğrulandı.
- **Kanıt aracı kusuru (ürün değil):** ilk `panel-choose` denemem `NSOpenPanel.ok(_:)` çağırıyordu; AppKit bunu doğrudan çağırmayı `NSException` ile reddediyor ve uygulama çöküyordu (`-[NSSavePanel ok:]`; çöküş raporlarından biri bunun ardından uygulama-devre-dışı bildiriminde `MainActor.assumeIsolated` kontrolünde görünüyordu). `ok:` çağrısı kaldırıldı, gözlemciler eski haline döndü; Loom pasifleşme (Finder öne) ve panel iptal/seçim sonrası çökme tekrar üretilmedi. Ürün kodundaki bildirim gözlemcileri değişmedi.
- Diğer sınırlar §26.3 ile aynı (branch/ayarlar/sürükle-sırala D; sağlayıcı olayları ve terminal başlığı bağlantısı C; ekran görüntüleri `cacheDisplay`, native düğmeler yok; cam/erişilebilirlik tercihleri denenmedi).

### 30.4. Unverified ve Needs

**Unverified:** OWN-1 ve ertelenen A/GPU/imza borcu (§23); §28 madde 1 (bu turda yapılmadı, C ön koşulu); gerçek Open tıklamasının AppKit URL dönüşü; §26.3 görsel sınırları.

**Needs:** düzeltmelerin review'u; B kapanışı ondan sonra. Kullanıcı kararı gerekmiyor. Teknik varsayılan: başlık değişimi sonrası yeniden sorgu yalnız açık aramada yapılır.

## 31. Review: B düzeltmeleri ve kapanış (29 Eylül 2026)

**Sonuç: B tamamlandı ve review'dan geçti. Yeni engelleyici bulgu yok.** §27.1 madde 1–3 kapandı. Bu yalnız B'nin katalog/pencere kabulüdür; A'nın ertelenmiş kaynak kabulü, OWN-1 ve bütün CP5 kapanmış sayılmaz. Üretim/test kodu değiştirilmedi, commit/push/model turu yok.

### 31.1. Bulguların kapanışı

1. **§27.1 madde 1 — doğrulandı, kapandı.** `CatalogModel.swift:537–549` açık aramada görünür listeleri mevcut sayfalı/generation korumalı yoldan yeniliyor. Reviewer önceki `repro.swift` programını aynı girdilerle yeni debug kütüphanesine karşı tekrar çalıştırdı: aktivite ve proje görünümünde `Needle → Unrelated` sonrası UI ve SQL boş; seçili kaydı `Newmatch` yapınca UI ve SQL aynı tek sonucu gösteriyor. Yeni `renameAndTerminalTitleKeepTheOpenSearchResultsConsistent(mode:)` testi tam pakette geçti; seçili detay, özel başlık ve terminal başlığı yollarını da kapsıyor. Düzeltmesiz davranış önceki reviewer kanıtında zaten mevcut; bu tur repo kaynakları geriye çevrilmedi. **İfade düzeltmesi:** “arama yokken sorgu yapılmıyor” yalnız *liste sorgusu* için doğru; `refreshRow` tek kaydı hâlâ okuyor. Bu bir yeni bulgu değil.
2. **§27.1 madde 2 — doğrulandı, kapandı.** `SessionCatalog.swift:348–367` kaynak projesini aynı transaction içinde tek satırdan alıp yeni kayda veriyor. Reviewer önceki `project-transition.swift` programını tekrar çalıştırdı: eski/yeni projectID aynı, proje sorgusu 2 kayıt, projesiz sorgusu 0. Yeni test ayrıca projesiz kaynağı, mevcut hedefin kendi projesini ve run-link geçmişini korumayı kapsıyor ve geçti. Gerçek `/clear`/`/new` sağlayıcı bağlantısı C'de sınanacak; katalog düzeltmesi için model turu gerekmiyor.
3. **§27.1 madde 3 — doğrulandı, kapandı.** `cp5-b-summary.py --selftest` reviewer tarafından çalıştırıldı: bütün kontroller başarılı → exit 0; bir hata → exit 1; boş kontrol kümesi → exit 1. Her durumda summary yazılıyor. Kabul shell betiğinin son komutu bu Python betiği; sonucu sonraki başarılı bir komutla örtmüyor. Mevcut `cp5-b-20260929T095326` ham kayıt/özetleri incelendi: 38/38, `allPassed=true`. Tam 38 adımlı paket betiği bu tur tekrar çalıştırılmadı.

### 31.2. Panel ve bağımsız kontroller

- **Panelin gerçek tamamlama yolu da doğrulandı.** Reviewer yeni kaynakla release paketini `/tmp/loom-review-b-fix/app/Loom Dev.app` olarak derleyip ad-hoc imzalı açtı. İzole veri kökü ve `LOOM_FORCE_COALITION_FAILURE=1` kullanıldı. CUA ile gerçek **Add project** düğmesi → native Go To → `/tmp/loom-review-b-fix/chosen-project` → native **Add Project** düğmesine basıldı. Panel sheet olarak görüldü; kapanınca sidebar'da `chosen-project` göründü. Salt okunur SQLite denetimi tam yolun doğru kaydedildiğini gösterdi. `panel-choose` veya `folderPanelFinished` doğrudan çağrılmadı. Böylece §30.3'te kalan AppKit `panel.url`/gerçek onay düğmesi kanıtı bu senaryo için tamamlandı. CUA paste ilk denemede clipboard timeout verdi; panel açık kaldı, desteklenen `typeText` ile yol girilerek devam edildi; ürün çökmesi olmadı.
- Paket kayıtlarında pasif uygulama + görünür ana pencerede sheet, kapalı ana pencerede bağımsız panel ve iptal doğru. Ancak ilk `panel-open` kaydı da `appActive=false`; bunu bağımsız aktif-uygulama deneyi diye saymıyoruz. Yeni gerçek UI deneyi ile temel kullanıcı yolu ayrıca görüldü. Tüm odak/erişilebilirlik/görsel matrisi test edildi iddiası yok.
- Native **Cmd+Q** sonrası uygulama çıktı; reviewer `quit.json`: `succeeded=true`, kalan 0, sinyal 0. Bu boş katalog/panel deneyi ve dar sahiplik koşuludur, OWN-1 kanıtı değildir. Test uygulaması açık bırakılmadı.
- Bağımsız `LOOM_FORCE_COALITION_FAILURE=1 swift build`: exit 0. Aynı ortamla `swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`: exit 0, **145 test** (13 terminal + 111 core + 21 UI). Release paketleme/imza kontrolü başarılı. `git diff --check`, değişen shell betiklerinde `zsh -n` ve yeni/değişen B dosyalarında trailing-whitespace kontrolü temiz.

Kalıcı reviewer kanıtı: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-b-review-fix-20260929/`: build/test/package log'ları, önceki iki yeniden üretimin kaynakları ve düzelmiş çıktıları, `summary-selftest.log`, `acceptance-audit.json`, `native-panel-result.json`, `panel-quit.json`, `source-sha256.json`, `review-checks.json`. İncelenen kaynak hash'leri review sonunda aynı; geçici uygulama/deney kopyaları temizlendi. Implementer'ın §30 ve önceki kabul kayıtları değiştirilmedi.

### 31.3. C'ye taşınan girdiler — tek liste

- **İlk ön koşul §28 madde 1:** stale sınıflandırması geçmişin tamamını canlı olay haritasına taşımamalı; yavaş tüketici toparlanması ve hata/bitiş bilgisi korunmalı. Yeni uzun ölçüm turu değil, tanımlı kısa regresyon ve 1+5 karşılaştırması.
- **C'nin ürün bağlantısı:** mevcut supervisor, lifecycle, Claude adapter ve Codex manager/coordinator'ı tek uygulama runtime'ında birleştirme; yeni/devam/durdur, `/clear`/`/new`, kimlik ve dürüst durum/onay/hata akışları (§7 C1–C5). B'nin devre dışı eylemleri hâlâ çalışır sayılmaz.
- **Ertelenen bağlantılar:** gerçek sağlayıcı durumunun kartta görünmesi, terminal başlığının kataloğa iletilmesi, yalnız görünür/etkin seçimde kullanım zamanının güncellenmesi (§26.3). Proje bağını koruma artık bu bağlantıların hazır katalog temelidir.
- **Ayrı kalanlar:** OWN-1; geçerli uzun A/GPU/çoklu terminal/kalıcı imza kabulü; D görsel/erişilebilirlik kapsamı. B'yi yeniden açmazlar, CP5 bütünü kapanırken değerlendirilirler.
- **Yetki/sıra:** C brief'i ayrıca hazırlanır; bu review C kodlamasını veya gerçek sağlayıcı/model deneyini başlatmaz. §9 model turu bütçesi hâlâ 0. Orca koordinasyon fikirleri §24'teki aşamalarında kalır.

## 32. Optimizasyon incelemesi: B düzeltmeleri (29 Eylül 2026)

Mevcut **GPT-6 Astra high** optimizer ile dar takip incelemesi yapıldı; reviewer belirleyici yolları kaynaktan ayrıca kontrol etti. **Yeni anlamlı kaynak/ölçek bulgusu yok, ek optimizasyon önerisi yok.**

- Arama açıkken başlık üyelik anahtarını değiştirebildiğinden mevcut sayfalı liste yenileniyor; arama yokken liste sorgusu eklenmiyor, tek kayıt okuması sürüyor. Normal durum olaylarına sorgu eklenmemiş (`CatalogModel.swift:238–264,537–549`).
- Proje aktarımı mevcut transaction içinde primary key ile tek satır okuması (`SessionCatalog.swift:348–367`); yeni tarama veya döngü yok.
- Panel yalnız kullanıcı eyleminde pencere seçiyor; yeni timer/polling yok, pencere closure'ı `weak self` (`AppDelegate.swift:54`). Özet betiği test sonunda çalışıyor, uygulama runtime'ına maliyet eklemiyor.

Yeni performans sayısı üretilmedi; §30'daki başlangıç/sorgu sayıları implementer kayıtlarıdır. Sık terminal başlığı akışının gerçek sağlayıcı maliyeti C'de bağlı olmadığından ölçülmedi. §28 bulgusu C ön koşulu olarak korunuyor; B kapanışına yeniden engel yapılmadı.

## 33. Çalışma akışının geçişi (29 Eylül 2026)

**Yazan:** kullanıcıyla çalışma düzenini düzenleyen yönetim oturumu.
**Muhatap:** planner-reviewer.
**Yanıt:** §31.3 sonraki iş ve §32 son inceleme.

Kullanıcı kararıyla ortak protokol kök [AGENTS.md](../AGENTS.md) dosyasına taşındı; roller sadeleştirildi. Plan ve sonuçlar bu dosyaya eklenerek paylaşılır; ayrıca taşınacak brief/prompt hazırlanmaz. Güncel iş konumu yalnız [STATUS.md](../STATUS.md) dosyasında tutulur ve planner-reviewer ile implementer her tur sonunda günceller. Optimizer checkpoint kapanışında zorunludur; her slice'ın rutin adımı değildir. Önceki ayrı brief/durum güncelleme talimatlarının yerini yeni protokol alır; geçmiş kayıtlar korunur.

**Korunan durum:** §31'e göre B kabul edildi. C henüz başlamadı. §28 madde 1 ve §31.3 girdileri, OWN-1 ile ertelenen A/GPU/imza kabulü açık kalır; bu düzenleme bunları kapatmaz veya yeniden doğrulamaz. §9 model turu bütçesi 0'dır.

**Sonraki adım — planner-reviewer:** §31.3 girdilerinden C için uygulanabilir plan bölümünü yaz: kapsam, sıra, kabul ölçütleri, kontroller ve gerekli kararlar. §28 madde 1'i ilk ön koşul olarak koru. Ayrı brief bekleme/üretme; plan hazır olduğunda status'u implementasyon bekleniyor olarak güncelle ve implementer'ı bu bölüme yönlendir. Bu geçiş kaydı C implementasyon planının kendisi veya yeni gerçek sağlayıcı/model deneyi yetkisi değildir.
