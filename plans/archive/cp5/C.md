# CP5 / C — Gerçek oturum işlemleri

[Checkpoint hedefi ve kabul tablosu](../CHECKPOINT-5.md) · [Güncel iş konumu](../../STATUS.md)

## 1. Planlamaya devir (29 Eylül 2026)

**Yazan / Muhatap:** çalışma düzenini düzenleyen yönetim oturumu → planner-reviewer.
**Yanıt:** [eski §31.3 C girdileri](../CHECKPOINT-5-HISTORY.md#31-review-b-düzeltmeleri-ve-kapanış-29-eylül-2026) ve [§33 planlama devri](../CHECKPOINT-5-HISTORY.md#33-çalışma-akışının-geçişi-29-eylül-2026).

Bu kayıt mevcut açıkları devreder; C için uygulanabilir implementasyon planı henüz yazılmadı. B kabulü korunur; bu düzenleme ürün davranışını yeniden sınamaz.

### Planın devralacağı işler

- İlk ön koşul: [§28 madde 1](../CHECKPOINT-5-HISTORY.md#28-optimizasyon-incelemesi-bnin-yaşlanan-geçmiş-yolu-29-eylül-2026) — stale sınıflandırması bütün geçmişi canlı olay haritasına taşımamalı. Geciken tüketici ve hata/bitiş/aktif run bilgisi korunmalı. 10.000 eski kayıt regresyonu ve aynı 1+5 kısa karşılaştırma kabulü geçerli.
- Supervisor, lifecycle, Claude adapter ve Codex manager/coordinator tek uygulama runtime'ında bağlanacak. Yeni/devam/durdur, `/clear`/`/new`, kimlik, durum, onay ve hata davranışları checkpoint'in **C1–C5 ve D3 sağlayıcı kabulünü** karşılamalı. `loom-probe` doğrudan ürün koordinatörü olarak kopyalanmamalı.
- Sağlayıcı durumunun karta, terminal başlığının kataloğa, yalnız görünür/etkin seçimin kullanım zamanına bağlanması gerekiyor. Yeni kimlikte proje ilişkisini koruyan B düzeltmesi temel alınacak.
- OWN-1, uzun A/GPU/kalıcı imza kabulü ve D görsel/erişilebilirlik işleri ayrı kalır; [kapsam kararı](../CHECKPOINT-5-HISTORY.md#23-kullanıcı-kararı-temel-engeli-ayır-pencereye-ilerle-28-eylül-2026) korunur. C sırasında ilgisiz sahiplik araştırması veya uzun ölçüm turu açılmaz.
- Model bütçesi **0 tur**; önerilmiş 8 tur onaylı değildir. [Deney yetkisi kapısı](../CHECKPOINT-5-HISTORY.md#9-model-turu-bütçesi-ve-karar-kapıları) değişmez. Planlama ve sentetik işler için yeni kullanıcı kararı gerekmiyor.

**Sonraki adım — planner-reviewer:** ilgili kodu ve yukarıdaki dayanakları inceleyip bu dosyaya §2 olarak C planını ekle: kapsam, uygulama sırası, kabul kimlikleri, kontroller ve varsa karar gerektiren noktalar. Plan hazır olunca status'u implementere yönlendir. Implementer sonucu ve sonraki review'lar bu dosyanın sonuna kısa ekler olarak gelecek; kapalı A/B geçmişini buraya kopyalama.

## 2. C uygulama planı (29 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → implementer.
**Yanıt:** §1; geçmiş §28 madde 1 ve §31.3.
**Sonuç:** C'nin uygulama sırası ve kabul kapıları aşağıdadır. Kullanıcı implementer'ı kendisi yönlendirecek; bu kayıt başka bir oturumu başlatmaz. Model turu bütçesi **0** kalır.

### 2.1. Hedef, kapsam ve kaynak dayanakları

Hedef, mevcut katalog penceresinden Claude/Codex için yeni/devam/durdur işlemlerini gerçek terminal yolu üzerinden yönetmek; kimlik, yaşam döngüsü, onay ve hata durumunu doğru konuşmaya bağlamaktır. Uygulama açılışı ve kart seçimi sağlayıcı çalıştırmaz. Projede yeni sohbet proje dizinini, projesiz sohbet home dizinini kullanır; devam kayıtlı çalışma dizinini ve sağlayıcı kimliğini korur. Kaybolan dizin/geçmiş sessizce başka dizine/yeni sohbete dönüşmez.

İncelenen kaynaklar mevcut altyapıyı ve bağlanacak boşlukları gösteriyor; bunlar yeni çalışma zamanı kabulü değildir:

- [ProcessSupervisor](../../Sources/LoomCore/ProcessSupervisor.swift): katalog alan kurucu ve `restoring` yolu mevcut. [AppDelegate](../../Sources/loom-app/AppDelegate.swift) supervisor'ı katalog bağlamadan kuruyor; `startSupervisor` yalnız sentetik `TerminalRunController` oluşturuyor.
- [SessionLifecycleController](../../Sources/LoomCore/SessionLifecycleController.swift) `classifyStale` içinde her eski kayıt için olay yayınlıyor; [SessionEventHub](../../Sources/LoomCore/SessionEventHub.swift) her olayı canlı haritaya ekliyor. Geçmiş §28 madde 1'in kaynak yolu sürüyor.
- [TerminalRunController](../../Sources/LoomTerminal/TerminalRunController.swift) tek terminal varsayımı taşıyor. [TerminalSurface](../../Sources/LoomTerminal/TerminalSurface.swift) ve mevcut PTY/girdi kuyruğu yeniden kullanılacak; ikinci PTY sahibi veya ikinci scrollback oluşturulmayacak.
- [Claude adapter](../../Sources/LoomCore/ProviderSessionAdapters.swift), [hook server](../../Sources/LoomCore/ClaudeHook.swift), [Codex manager](../../Sources/LoomCore/CodexAppServerManager.swift), [coordinator](../../Sources/LoomCore/CodexSessionCoordinator.swift) ve [resume planner](../../Sources/LoomCore/ProviderResume.swift) çekirdekte mevcut. Ürün koordinasyonu `loom-probe` deney sürücüsünü kopyalayarak kurulmayacak.
- [CatalogModel](../../Sources/LoomCatalogUI/CatalogModel.swift) görünür/etkin seçimi event hub'a bildiriyor; kalıcı `markViewed` bağlantısı yok. Terminal başlığı AppDelegate'te yalnız pencere alt başlığına gidiyor; katalog başlık yolu mevcut. [DetailView](../../Sources/LoomCatalogUI/DetailView.swift) ve [SidebarView](../../Sources/LoomCatalogUI/SidebarView.swift) oturum eylemleri devre dışı.

Yazma kapsamı: ilgili `LoomCore`, `LoomTerminal`, `LoomCatalogUI`, `loom-app` bağlantıları; mevcut test paketleri, gerektiğinde dar fixture/paketleme/kabul araçları. Yeni runtime tipi gerekirse mevcut hedeflerden uygun olanına yerleştir; sırf koordinasyon için yeni framework/bağımlılık kurma. Ürün sözleşmesi §3, vendor motoru, OWN-1 araştırması, uzun A/GPU/imza kabulü, branch/ayrıntılı ayarlar ve D'nin kalan girdi/görsel işleri bu uygulamanın dışında.

### 2.2. Uygulama sırası

1. **C ön koşulu — geçmiş §28.1:** kalıcı toplu stale değişimini, yalnız geçmiş sayısı yüzünden canlı haritayı büyütmeden bildir. Bildirim atlanınca son frame/katalog üzerinden toparlanabilmeli; kör harita temizliğiyle son stop hatası, bakılmamış bitiş veya aktif run bilgisi silinmemeli. Önce 10.000 eski kayıtla başarısız regresyonu göster, sonra düzelt. Aynı 1 ısınma + 5 tekrar yöntemiyle 1.000/10.000 kayıt, son frame'i tutan tüketici ve ardından 1.000 durum olayı için önce/sonra süreleri, medyan/min–max ve harita büyüklüğünü raporla. Sayısal ürün bütçesi icat etme; sonraki olay maliyetini küçük canlı küme kontrolüyle karşılaştır.
2. **Tek uygulama runtime'ı:** katalog, supervisor, lifecycle ve sağlayıcı bağlantılarını ortak sahiplik altında kur. Katalog yeniden açılışında kayıtlar geri gelir, eski OS run'ları başlamaz. Katalog hatasında eylemler engellenir; çalışan süreci kalıcı kayıt yokken başarılı sohbet gibi gösterme. Tek otomatik lifecycle dinleyicisi/timer yaklaşımını koru. UI yalnız niyet iletir; süreç başlatma ve bekleme MainActor'ı bloke etmez. Aynı sohbetin tekrar tıklanan launch/resume isteği tek run'a gider; Quit başladıktan sonra yeni iş kabul edilmez.
3. **Başlatma ve sağlayıcı bağlantıları:** mevcut yönetilen ortam çözümleme ve capability/profile yollarını kullan; sürüm sabitleme veya sessiz alternatif daemon yolu ekleme. Ortam uyarıları görünür, ortam/CLI hatası uygulamayı kapatmadan yeniden denenebilir olmalı. Claude hook kimlik doğrulaması/run eşlemesi ve paketlenmiş `loom-hook` yolu bağlanmalı. Codex ilk talepte ortak app-server'ı açmalı, yeni TUI kimlik rezervasyonlarını sıraya almalı, resume kimliğini açık bağlamalı. Son kullanıcı run'ı bırakıldığında server kapanmalı; internal server katalogda sohbet olmamalı. Yarım başlatma, iptal ve kimlik zaman aşımında rezervasyon/lease/PTY kaynaklarını doğrulanmış şekilde bırak; başarısız cleanup'ı gizleme.
4. **Çoklu terminal ve kimlik devri:** canlı terminali run kimliğiyle tut; kart seçimi yalnız ilgili terminali görünür kılar. `/clear`/`/new` aynı run'ı yeni konuşma kaydına taşırken eski kayıt ve proje ilişkisi korunur. Yeni kart terminalin sahibi olur; eski kartın gecikmiş girdi, başlık ve eylem callback'leri yeni konuşmaya yazamaz. Geçiş olayları kaçırılsa da en son durumdan toparlan. Codex lease ve onay eşleşmesinin yeni konuşma kimliğiyle tutarlı kaldığını, eski kaydı durdurmanın yeni run'ı yanlışlıkla etkilemediğini sına. Terminal başlığı özel kullanıcı başlığını ezmeden kataloğa ulaşmalı.
5. **Yaşam döngüsü ve kullanıcı eylemleri:** yeni/devam/durdur menü ve düğmelerini mevcut tasarım içinde bağla. İlk prompt öncesi terminali sözleşmedeki `active` tanımıyla karıştırma. Görünür ve etkin seçimi hem okunmamış bitişe hem kalıcı kullanım zamanına bağla; pasif/gizli pencere, liste yenilemesi ve sağlayıcı olayları kullanım sayılmaz. Stale seçim stale kalır; açık devam eylemi gerekir. Aktif tur, onay/girdi, arka plan işi, bilinmeyen durum ve belirsiz kimlik otomatik idle'ı engeller. Baseline yakalamayı keyfi süre sonuna bağlayıp çalışan kullanıcı işini baseline'a katma; güvenilir başlangıç koşulu yoksa idle engelini görünür koru. Girdi/idle-stop yarışı mevcut pending-delivery ve run denetimiyle kayıpsız, çoğaltmasız yönetilmeli; normal terminal bayt akışını prompt metni tahminiyle değiştirme. Başarılı idle/stop sonrasında terminal kaynaklarını bırak.
6. **Onay, hata ve çıkış:** Claude'un native izin akışı korunur. Codex coordinator'ın kullanıcı yanıtı gerektiren istekleri doğru kartta görünür ve açık yanıtla sonuçlanır; istek düşmesi, kopan bağlantı veya yanıt hatası otomatik onay/başarı sayılmaz. Desteklenmeyen istek açık hata olarak kalır. Resume geçmiş hatası, belirsiz kimlik ve stop hatası doğru kartta korunur. `/exit` yalnız liderin çıkışı diye bütün işin bittiği sayılmaz. Cmd+W görünümü kapatır; Cmd+Q başlatma dahil tüm yönetilen işleri kapsar, katalog işlemlerini tutarlı bitirir ve başarısız kapanışta uygulamada tekrar deneme sunar. Tek sentetik controller'a bağlı Quit yolunu bütün runtime'ı kapsayacak şekilde bağla; mevcut AppKit terminate-later/MainActor kilitlenme korumasını kaybetme.

### 2.3. Kabul ve kontroller

Her satırın sentetik sonucu ve gerçek sağlayıcı sonucu ayrı raporlanır. Sentetik geçiş C'nin gerçek sağlayıcı kabulünü kapatmaz.

| Kabul | Gerekli gözlem / dar kontrol |
| --- | --- |
| C ön koşulu | Gerçek `classifyStale` ile 10.000 eski kayıt; geciken tüketici doğru stale kartları gösterir, canlı harita tarihçeyle büyümez; mevcut hata/bitiş/run korunur. §2.2.1 kısa karşılaştırması. |
| C1 | Proje/projesiz başlatmada doğru cwd ve izole profil; terminal çift yönlü çalışır. Eksik CLI, ortam hatası, erken çıkış ve iptal sonrası hayalet canlı run yok; tekrar deneme başarılı. Tekrarlanan tıklama ikinci run oluşturmaz. |
| C2 | Her iki sağlayıcı kimlik geçişinde eski/yeni kayıt, proje ve run-link doğru; aynı terminal yeni karta taşınır. Eski kart girdi gönderemez. Resume aynı kimlikle açılır; eksik kimlik/geçmiş açık hata, yeni sohbete fallback yok. Gecikmiş eski-run olayları yeni run'ı bitiremez. |
| C3 | Kısaltılmış test politikasıyla engelli idle ve güvenli idle; stop ile yeni girdi yarışı kayıp/çift teslim üretmez. Seçim başlatmaz; yalnız görünür/etkin kullanım tarihi güncellenir, stale durumu değişmez. Yeniden açılışta provider/PTY/terminal sayısı 0. |
| C4 | Claude hook/onay ve Codex request/response fixture'larında doğru kart, açık kullanıcı yanıtı, tekrar yanıt koruması. Kopan server/yanıt hatası ve belirsiz kimlik dürüst görünür; yanlış kartta başarı yok. |
| C5 | İki canlı oturumda birini durdurunca diğerinin girdi/çıktısı sürer; iki Codex lease'i ve son lease kapanışı sınanır. Kimlik devrinden sonra release doğru. Lider çıkışı/arka plan fixture'ı, başarısız stop ve retry; görünümü kapatmak sahiplik takibini silmez. |
| D3'ün C payı | Başlatma sürerken, aktif işte ve gizli pencerede Quit; sahip olunan fixture süreçleri 0, dış kontrol süreci değişmez. Zorlanmış kapanış hatasında başarı gösterilmez; tekrar deneme sınanır. OWN-1 genel güvencesi bu dar deneyden çıkarılmaz. |

Mevcut `LoomCoreTests`, `LoomTerminalTests`, `LoomCatalogUITests` içinde anlamlı entegrasyon/regresyon ekle; yalnız mock koordinatörünü sınayıp üretim runtime'ını dışarıda bırakma. Üretim yolu test edilemiyorsa dar bir test sınırı aç; ikinci ürün runtime'ı yazma. Özellikle provider routing, kimlik devri, çoklu terminal, girdi/stop ve Quit yarışları gerçek uygulama bağlantısını kapsamalı.

Gerekli birleşik kontroller: `swift build`, `swift test` (makro yükleme sorunu varsa DEVELOPMENT.md'deki komut), `git diff --check`; değişen C/shell katmanı varsa ilgili derleyici/sözdizimi kontrolü. Regresyon için düzeltmesiz başarısızlık kanıtı gerekir; ortak çalışma ağacını geriye çevirme. Dar paket kabulü LaunchServices ile izole katalog ve sahte sağlayıcı/PTY fixture'larında gerçek düğme, kart seçimi, terminal girdi/çıktısı, pencere kapatma ve Quit yollarını kapsar. Test aracı doğrudan callback çağırıyorsa bunu native UI kanıtı diye yazma. Etkilenen B davranışlarını mevcut suite ile koru; ilgisiz uzun A/D ölçümlerini tekrarlama.

Kanıtı run kimliği, komut/sonuç ve kaynak sürümü/hash'leriyle izole probe runs alanında; değerlerden arındırılmış özeti `plans/experiments/` altında sakla. Hata veya boş kontrol kümesi kabul betiğini başarısız bitirmeli. Token, ortam değerleri ve gerçek transkript kayda girmez. Reviewer birleşik davranışı bağımsız doğrular; implementer sonucu kabul kararı değildir.

### 2.4. Gerçek sağlayıcı kapısı ve teslim

Bu plan **gerçek model turu çalıştırma yetkisi vermez**. İlk teslim uygulama, sentetik kontroller ve gerçek sağlayıcı deneyine hazır düzenektir. Kullanıcının gerçek profilleri/oturumları test verisi değildir. Önceki 8 tur önerisi onaylı bütçe değildir; deneme/tekrarlar dahil bir bütçe ancak kullanıcı kararıyla açılır.

Implementer gerçek kabul için sağlayıcı başına yeni sohbet, resume ile önceki içeriği hatırlama, kullanıcı onayı ve aktif turda Quit senaryolarının tam promptlarını, izole profil/dizinlerini, çalıştırma komutlarını ve beklenen kanıtını hazırlasın; çalıştırmasın. `/clear`/`/new`, iki canlı oturum ve `/exit` kapsamının hangi senaryoya bağlandığını, ek tur gerekiyorsa sayısını açık yazsın. Bütçe veya gerçek sağlayıcı deneyi kararı, düzenek review edildikten sonra kullanıcıya götürülecek. Bu kapı sentetik implementasyona engel değildir; gerçek kabul doğrulanmadan C kapanmaz.

**Doğrulandı:** yukarıdaki kaynak bağlantıları ve devralınan kapsamın kod karşılıkları incelendi. **Başarısız:** bu planlama turunda çalışma testi yapılmadı; yeni test başarısızlığı iddiası yok. **Doğrulanmadı:** C1–C5/D3 çalışma davranışı, performans düzeltmesi ve gerçek sağlayıcı kabulü.

**Sonraki rol/adım — implementer:** kullanıcı yönlendirdiğinde §2.2 sırasıyla uygula; kontroller ve açık kabul kapılarını kısa §3 ekiyle raporla, ardından status'u review bekleniyor yap. Plan/teknik belirsizlikleri planner-reviewer'a numaralı açık madde olarak bırak. Bu planlama oturumu devir noktasında durur; implementer'a mesaj gönderilmez.

## 3. Uygulama sonucu (29 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §2 (yalnız §2.2 adım 1–6 ve §2.3 kabul tablosu; §2.4 düzeneği).
**Sonuç:** sentetik uygulama tamam; **gerçek sağlayıcı kabulü doğrulanmadı** (bütçe 0, çalıştırılmadı). Commit/push yok. Kanıt: run `cp5-c-20260929T123723` (22/22, exit 0; özet [cp5-c-acceptance.json](../experiments/cp5-c-acceptance.json)), 191 birim/entegrasyon testi geçti, `swift build`, `git diff --check`, betik `zsh -n` temiz.

### 3.1. Ne yapıldı

1. **Ön koşul §28.1.** `classifyStale` artık tek `catalogLifecycle` çerçevesi + `catalogRevision` yayınlıyor; harita yalnız zaten canlı girdisi olan sohbetleri günceller. Atlanan çerçeve sonraki çerçevenin `catalogRevision` farkıyla `CatalogModel` tarafından yakalanır (kataloğu yeniden okur). Düzeltmesiz başarısızlık gösterildi (harita 10.000, testler ✘). 1 ısınma + 5 tekrar, **release**, 1.000 / 10.000 geçmiş: toplu stale **29,00 ms (28,83–31,33) → 2,08 ms (2,06–2,13)** / **2.937,9 ms (2.591,6–3.070,6) → 22,1 ms (22,0–27,4)**; ardından 1.000 durum olayında olay başına **51,7 µs → 1,20 µs** / **538,9 µs (500,1–601,0) → 1,21 µs**; harita **1.000/10.000 → 0, olaylardan sonra 1**. Küçük canlı küme kontrolü (1 canlı, geçmiş yok): 1,20 µs. Debug seri de kaydedildi (2.082 → 24,4 ms; 400,8 → 1,73 µs). İzole çekirdek süreleri; UI/WindowServer değil. Kalan 22 ms SQL sınıflandırmasıdır.
2. **Tek runtime.** `SessionRuntime` (LoomCore): supervisor, katalog, lifecycle, Claude hook sunucusu + adapter, Codex manager/coordinator/adapter tek sahiplikte. Ortam/CLI/yetenek çözümü `SystemProviderToolchains` (başarısız çözüm önbelleğe alınmaz, satır oluşmaz). `ConversationController` (LoomCatalogUI) yalnız niyet iletir, çalıştırma actor'da; `AppDelegate` supervisor'ı katalogla `restoring` kurar, Quit tek `runtime.shutdown()`. Katalog hatasında runtime kurulmaz, eylemler kapalı. Tekrarlı tıklama tek run (`alreadyStarting`).
3. **Başlatma/sağlayıcı.** Yeni sohbet proje klasöründe, projesiz home'da; devam kayıtlı dizin + kimlikle; eksik dizin/kimlik/geçmiş açık hata, yeni sohbete dönüşme yok. Codex ilk talepte ortak sunucuyu açar, rezervasyonlar sıralı, son lease'de kapanır, sunucu katalogda kart değildir. Yarım başlatma/kimlik zaman aşımı/Quit'te rezervasyon+lease+PTY bırakılır (TUI başlangıçta ölürse zaman aşımı beklenmez).
4. **Çoklu terminal / kimlik devri.** Terminal run kimliğiyle tutulur, kart yalnız sahibi olduğu terminali görür; `/clear`/`/new` sonrası terminal yeni karta geçer, eski kartın eylemi (`notRunning`) yeni run'a dokunamaz, başlık geri çağrıları sahibi çağrı anında çözer.
5. **Yaşam döngüsü.** Baseline yalnız ilk güvenilir sakin anda (turnComplete, bekleyen iş 0) alınır; ilk tur öncesi idle engeli görünür kalır. Yeni **`TerminalInputGate`**: idle stop girdi kuyruğunu atomik kapatır; bekleyen bayt varsa stop engellenir, kapandıktan sonra gelen girdi bütün olarak görünür hatayla reddedilir (kabul edilip sessizce kaybolmaz, çift teslim yok). Görünür+etkin seçim `markViewed`'e bağlı; pasif/gizli pencere, yenileme, sağlayıcı olayları saymaz.
6. **Onay/hata/çıkış.** Codex komut/dosya onayı doğru kartta Approve/Deny; diğer türler yanıtlanamaz olarak açık kalır; kopan bağlantı/teslim düşmesi/yanıt hatası isteği açık ve başarısız gösterir. Kartta `Problem` ve `Identity unclear` durumları.

### 3.2. Bu turda bulunup düzeltilen hatalar (hepsi düzeltmesiz başarısızlıkla gösterildi)

- `SessionCatalog.markUsed(reactivate:false)` idle satırı görüntülemede `active` yapıyordu → yalnız kullanım tarihi güncellenir (sözleşme §5). Test: `viewingKeepsIdleAndStaleState…`.
- Codex stop kancası "thread not found" yüzünden hiç doğrulanamıyor, silinmiş geçmişle resume'da run kapanmıyordu → o hata "durdurulacak iş yok" sayılır (`isThreadNotFound`). Test: `resumeOfAMissingThread…`.
- `CodexWebSocketTransport.receive` 0,25 sn'lik poll'u `send`'in beklediği kilitle tutuyordu; her RPC ~266 ms gecikiyor, Codex Stop 1,8–2,5 sn sürüyordu → kilit poll sırasında bırakılır (Stop ~0,03 sn, 20 RPC 5,32 sn → ~0,02 sn). Test: `requestsAreNotDelayedByTheReadersPollInterval` (eski kilitle 5,32 sn ✘).
- Hızlı çıkan devam edilen run: `launch` döndüğünde run bitmiş olabiliyordu → run kimliği önceden verilir, bitmiş run düzgün işlenir.

### 3.3. Kabul (sentetik / gerçek ayrı)

| Kabul | Sentetik | Gerçek sağlayıcı |
| --- | --- | --- |
| C ön koşulu | **doğrulandı** (gerçek `classifyStale`, 10.000, gecikmiş tüketici; 1+5 ölçüm §3.1) | — |
| C1 | **doğrulandı** (cwd/profil, çift yön, eksik CLI, erken çıkış, iptal, çift tıklama; paket kabulü) | **doğrulanmadı** |
| C2 | **doğrulandı** (Claude `/clear`, Codex `/new`, resume, eksik geçmiş, eski kart engeli, proje devri) | **doğrulanmadı** |
| C3 | **doğrulandı** (engelli/güvenli idle kısaltılmış politikayla, girdi kapısı, görüntüleme, yeniden açılışta 0 süreç) | **doğrulanmadı** |
| C4 | **doğrulandı** (Claude `waitingForApproval` engeli, Codex istek/yanıt, tekrar yanıt, kopan sunucu, yanıt hatası, belirsiz kimlik) | **doğrulanmadı** |
| C5 | **doğrulandı** (iki Claude, iki Codex lease, kimlik devri sonrası release, lider çıkışı + izlenen arka plan, başarısız stop + retry, Codex `/exit`) | **doğrulanmadı** |
| D3 (C payı) | **doğrulandı** (aktif turda/gizli pencerede/başlatma sürerken Quit, zorlanmış hata + Try Again, dış süreç sağlam) | **doğrulanmadı** |

### 3.4. Doğrulanmadı ve sınırlar

- **Gerçek Claude/Codex hiç çalıştırılmadı**; sahte sağlayıcı gerçek TUI'yi, izin/güven ekranlarını ve gerçek hook/app-server yük biçimlerini taklit etmez. Codex istek yanıtı biçimi (`{"decision": accept|decline}`) yalnız kurulu `codex app-server generate-json-schema` çıktısına dayanır. **Codex sunucu isteklerinin Loom bağlantısına da gelip gelmediği** (plan varsayımı) gerçek sağlayıcıyla sınanmadı.
- Paket kabulü kanıt komutlarını (`start:`, `type:`, `answer:`…) kullanır: bunlar model niyetlerini ve terminal delegesini çağırır; **yerel tık/tuş kanıtı değildir**. Ekran görüntüleri (`cacheDisplay`) yerleşimi gösterir (Stop, onay bandı, kartlar) ama terminal alanını beyaz çiziyor; terminal rengi bu yolla doğrulanmadı.
- Apple platform ikilisi (ör. `/bin/sleep`) lider çıkışından sonra ortam işaretçisiz kalır ve izlenemez; fixture izlenebilir kardeş ikili kullanır. Bu OWN-1 kapsamındadır, kanıtlanmadı.
- Yerel paketleme ad-hoc imzalı. Sayısal ürün bütçesi eklenmedi.
- Girdi kapısı yalnız terminal yüzeyine bağlı girdiyi kapsar; başka bir yoldan gelen bayt yoktur.
- Yeni fixture hedefi `loom-fake-provider` paketlenmez; `Package.swift` ve kabul betiği (`scripts/cp5-c-acceptance.sh`, kaynak/ikili hash'i `source-and-binary.txt`) eklendi.

### 3.5. Gerçek sağlayıcı düzeneği (§2.4) ve Needs

Senaryolar, tam istemler, izole profiller, komutlar, beklenen kanıt ve tur sayısı hazır, çalıştırılmadı: [cp5-c-real-provider-setup.md](../experiments/cp5-c-real-provider-setup.md). **Taban 8 tur** (Claude 4 + Codex 4; `/clear`, `/new`, iki oturum, `/exit` ek tur gerektirmez), yeniden deneme payı yok.

**Needs (kullanıcı kararı):** düzenek review edildikten sonra gerçek sağlayıcı deneyi ve tur bütçesi. **Sıradaki rol:** planner-reviewer review'u; kabul kararı implementer sonucu değildir.

## 4. Review ve düzeltme işi (29 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → implementer.
**Yanıt:** §3.1–3.5; kabul dayanağı §2.2–2.4.
**Sonuç:** **C kabul edilmedi.** C ön koşulu kapandı; aşağıdaki altı madde açık. 191 testin geçmesi §3.3'teki bütün sentetik kabul iddialarını doğrulamıyor. Ürün kodu değiştirilmedi; model turu 0. İki dar reviewer incelemesi kullanıldı; belirleyici kaynaklar ana reviewer tarafından da okundu, girdi/Quit ve native UI deneyleri bağımsız yapıldı.

### 4.1. Açık bulgular

1. **[P1 — C3] PTY'ye yazılmış ama sağlayıcının okumadığı prompt otomatik idle'da kayboluyor.** [SessionLifecycleController.swift:287](../../Sources/LoomCore/SessionLifecycleController.swift#L287), [TerminalInputQueue.swift:80](../../Sources/LoomCore/TerminalInputQueue.swift#L80). Girdi kapısı yalnız Swift kuyruğunu denetliyor; boş kuyruk, sağlayıcı teslimi demek değil. Gerçek runtime + fixture deneyinde sakin tur/baseline sonrasında okuyucu SIGSTOP ile kısa süre duraklatıldı (PTY'ye yazma ile sağlayıcı okuması arasını deterministik yapmak için). Gerçek endpoint kuyruğuna verilen prompt `accepted=true`, `pending=0`, `errors=0`; buna rağmen idle değerlendirmesi `transitioned`, `promptProcessed=false`, `liveRun=false` döndü. Kullanıcıya hata da gitmedi. Bu, kapandıktan sonraki girdinin açık reddinden farklıdır. **Kapanış:** girdi kabulü ile idle kararını run bazında eşgüdümle; yeni kabul edilmiş girdinin eski `turnComplete`/kullanım anıyla durdurulmasını önle. Prompt metnini tahmin ederek veya sabit bekleme ekleyerek çözme. Aynı üretim kuyruğu/PTY sınırını kullanan regresyon, girdi ya hiç kabul edilmeden açıkça reddediliyor ya da kaybolmadan işleniyor sonucunu göstermeli. Kanıt: `input-race.swift`, `input-race.log`.

2. **[P1 — C3] İlk turda başlatılan arka plan işi başlangıç baseline'ına alınabiliyor.** [SessionRuntime.swift:843](../../Sources/LoomCore/SessionRuntime.swift#L843), [SessionLifecycleController.swift:180](../../Sources/LoomCore/SessionLifecycleController.swift#L180). İlk `turnComplete + pendingProviderWorkCount == 0` anındaki bütün süreçleri sağlayıcı başlangıç yardımcısı saymak güvenli değil. İzole fixture kopyasında yalnız Stop yükündeki `background_tasks` kaldırıldı; gerçek çocuk süreç, hook ve runtime yolları korundu. İş canlıyken runtime baseline aldı; idle değerlendirmesi başarılı geçiş yaptı ve çalışan çocuğu öldürdü. Bu sahipliği bilinmeyen bir kaçak/OWN-1 değil, sample'da bulunan bilinen çocuk. Mevcut test yalnız sağlayıcının işi ayrıca ilan ettiği yolu kapsıyor. **Kapanış:** kullanıcı işinin ilk tamamlanma veya `/clear`/`/new` sonrasındaki baseline'a eklenmesini engelle. Güvenilir başlangıç sınırı yoksa baseline/idle engelini koru; bilinmeyen işi yardımcı süreç varsayma. Bildirilmiş ve bildirilmemiş canlı çocukla regresyon ekle; ikisi de otomatik idle'ı engellemeli. Gerçek Claude'un belirli yükü gönderip göndermediği sınanmadı; sentetik hata doğrudan doğrulandı. Kanıt: `ui-baseline-repro.swift`, `ui-baseline-fixture.patch`, `ui-baseline-repro.txt` (logdaki `child_in_baseline` alanı sample üyeliğini ölçer; baseline'a dahil olma capture sırası ve başarılı idle sonucuyla doğrulanır).

3. **[P1 — C1/D3] CLI yetenek sorgusu başarılı Quit'ten sonra çalışabiliyor; timeout da bütün sorguyu sınırlamıyor.** [ProviderToolchain.swift:88](../../Sources/LoomCore/ProviderToolchain.swift#L88), [ProviderToolchain.swift:118](../../Sources/LoomCore/ProviderToolchain.swift#L118), [SessionRuntime.swift:387](../../Sources/LoomCore/SessionRuntime.swift#L387). Probe doğrudan `Process.run()` kullanıyor; yönetilen ortam sorgusu gibi supervisor'a kayıtlı değil. Aynı public probe API'sini çağıran runtime resolver ile başlatma sürerken `shutdown()` denendi: **`succeeded=true`, `remaining=0`, fakat aynı PID+doğum kimliğiyle probe hâlâ canlı**. Ayrıca lider çıkıp stdout/stderr'ı çocukta açık bıraktığında `capture(timeout: 0.2)` hata vermeden **4,02 saniyede** döndü; son `group.wait()` sınırsız. `readDataToEndOfFile().prefix(...)` de okumayı sınırlamıyor, yalnız sonradan kırpıyor. **Kapanış:** bu yardımcıların başlatma, iptal, çıktı kotası, son tarih ve Quit takibini mevcut sahiplik yoluna bağla. Yavaş lider, liderden uzun yaşayan pipe sahibi ve fazla çıktı fixture'larıyla sınırları doğrula; başarılı Quit sonrası yardımcı kalmamalı, başarısız temizlik açık raporlanmalı. Yeni sahiplik araştırması istenmiyor. Kanıt: `probe-quit.swift`, `probe-quit.log`, `slow-probe.sh`, `loom-probe-descendant.swift`, `probe-timeout.log` (süre `/usr/bin/time` ölçümü).

4. **[P2 — C2] Seçili canlı terminal kimlik değişince geçmiş ekranına düşüyor.** [ConversationController.swift:252](../../Sources/LoomCatalogUI/ConversationController.swift#L252). Native düğmeyle açılan Claude terminalinde gerçek klavye yoluyla `/clear` girildi: yeni kart oluştu, eski kart seçili kaldı, terminal görünümü yerini eski kaydın Resume ekranına bıraktı ve odak pencereye döndü. Yeni karta elle tıklayınca aynı terminal çalışmayı sürdürdü. `reconcile` yalnız terminal sahibini değiştiriyor. **Kapanış:** kullanıcı o run'ı görüntülüyorsa seçimi/odağı yeni sahibine taşı; başka karta geçmişse seçimini çalma. `/clear` ve `/new`, geciken frame, eski karttan girdi engeli ve yeni kartta kesintisiz native girdi regresyonlarıyla göster. Kanıt: `native-ui.json`; eski/yeni katalog kimlikleri kayıtlı.

5. **[P2 — C1/C2] Terminal ortamındaki özel `CODEX_HOME` yok sayılıyor.** [ProviderToolchain.swift:233](../../Sources/LoomCore/ProviderToolchain.swift#L233). Explicit deney override'ı yokken çözülmüş ortamın `CODEX_HOME` değeri yerine doğrudan home altındaki `.codex` seçiliyor; probe ve launch profili bu yolu zorla kullanıyor. Kullanıcının terminalinde seçtiği profil/hesap/geçmiş değişebilir; sözleşme §3'teki yönetilen terminal ortamına aykırı. **Kapanış:** açık izole override > çözülmüş terminal ortamı > varsayılan profil önceliğini koru; özel profilin probe, app-server ve remote TUI/resume'a aynı şekilde ulaştığını gerçek profillere dokunmayan fixture testiyle doğrula. Kod yolu doğrulandı; gerçek hesapla deney yapılmadı.

6. **[P2 — §2.4 deney hazırlığı] Gerçek kabul düzeneği henüz çalıştırmaya hazır değil.** [Düzenek:31–45](../experiments/cp5-c-real-provider-setup.md#sıra-tek-uygulama-oturumları-toplam-8-tur). R4 Quit'ten sonra R5 için yeniden açılış, R9'un iki canlı oturum ve kimlik değişimi sonrası güncellenen `<C>/<X>` sırası belirtilmiyor; eski `<C>` ile `/exit` yeni terminale yazamaz. R3/R7 için onay gerektiren izole izin politikası belirtilmediğinden `touch` isteğinin onay üretmesi garanti değil. Daha önemlisi, “yalnız belirteç var/yok” denmesine rağmen önerilen `snapshot` yolu [ham `screenTail` yazıyor](../../Sources/loom-app/AppDelegate.swift#L618); [DevelopmentEvidence](../../Sources/loom-app/Evidence/DevelopmentEvidence.swift) bunu doğrudan dosyaya kaydediyor. **Kapanış:** 8 tur önerisini harcamadan çalıştırılabilir sıra, yeniden açılış/kimlik devri, onayı zorlayan izole ön koşullar ve beklenen ret/onay kanıtını netleştir. Gerçek deney kanıtında ham terminal içeriğini diske yazmadan arındır; fixture için ham ekran kanıtı ayrı kalabilir. Kod düzeltmeleri ve bu hazırlık review edilmeden bütçe onayı istenmeyecek. Codex onayının hangi bağlantıya geldiği hâlâ açık kabul sorusudur; TUI'de görünmesi Loom düğmesinin çalıştığını kanıtlamaz.

### 4.2. Doğrulananlar ve sınırlar

- **Doğrulandı — C ön koşulu kapandı:** gerçek `classifyStale`, 10.000 eski kayıt, geciken tüketicinin katalog revision'ından toparlanması ve mevcut hata/bitiş bilgilerinin korunması testleri geçti. Bağımsız debug 1+5 ölçüm: 1.000/10.000 kayıt toplu medyan **2,45/27,64 ms**; sonraki olay **1,84/1,89 µs**, küçük canlı küme **1,81/1,82 µs**; harita toplu işlem sonrası 0, olaylardan sonra 1. Bunlar çekirdek ölçümleri; release/WindowServer/GPU sonucu diye sunulmaz. §3.1'in release sayıları bu tur yeniden ölçülmedi.
- **Doğrulandı — kontroller:** `swift build` exit 0; makro yükleme seçeneği ve dar sahiplik ortamıyla tam `swift test` exit 0, **191 test (13 terminal + 148 core + 30 UI)**. Release paketleme ve imza doğrulaması başarılı; ad-hoc imza. `git diff --check` temiz. Ürün kaynakları review sonunda hash ile karşılaştırıldı, aynı kaldı; kanıt kaydı aşağıdadır.
- **Doğrulandı — native sentetik yollar:** yeni Claude düğmesi, klavyeden terminal girdisi, yeni Codex kısayolu, doğru kartta bekleyen onay ve native Approve, Codex Stop sonrası diğer Claude'a girdi; terminal metni ve koyu arka plan gerçek ekran görüntüsünde görüldü. Native Cmd+Q sonrası uygulama çıktı, rapor başarılı/kalan 0. Cmd+W sonrası fixture canlıydı; AX ağacından pencerenin gizliliği ayrıca kabul edilmedi. Bunlar §3.4'teki native kanıt açığını bu dar yollar için azaltır; tam UI/erişilebilirlik matrisi değildir.
- **Başarısız:** §4.1 madde 1–4 senaryoları; madde 5 kaynak davranışı ve madde 6 düzenek tutarsızlığı açık. C3/D3'e sentetik tam kabul verilmiyor.
- **Doğrulanmadı:** gerçek Claude/Codex, gerçek izin/güven akışı ve C'nin tam kabulü. OWN-1, uzun A/GPU/imza ve D birleşik kabulü aynen açık; yeni model/sağlayıcı çalıştırılmadı.

Kalıcı reviewer kanıtı: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-review-20260929/` — komutlar, build/test/package log'ları, kaynak hash'leri, native sonuç/Quit kaydı ve üç hata düzeneği. Değerlerden arındırılmış sonuç: [cp5-c-review.json](../experiments/cp5-c-review.json). §3 ve geçmiş bölümler değiştirilmedi.

**Sonraki rol/adım — implementer:** önce §4.1 madde 1–3 yaşam döngüsü/kapanış hatalarını, ardından 4–5 bağlantıları ve 6 deney hazırlığını düzelt. Her maddeye numarasıyla yanıt ver; regresyonların düzeltmesiz başarısızlığını göster ve birleşik kontrolleri çalıştır. Sonucu §5'e ekle, sonra status'u review bekleniyor yap. Bu oturum implementer başlatmaz/mesaj göndermez; kullanıcı yönlendirecek. C kapanmadığı için D veya checkpoint optimizer kapanışı açılmıyor.

## 5. Uygulama sonucu: review düzeltmeleri (29 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §4.1 madde 1–6. Commit/push yok; model turu 0; gerçek sağlayıcı çalıştırılmadı.
**Kanıt:** `swift build`, tam `swift test` **202 test** (13 terminal + 157 core + 32 UI) geçti; `git diff --check` ve yeni dosyalarda sondaki boşluk taraması temiz; paket kabulü yeniden çalıştı: run `cp5-c-20260929T133653`, **22/22, exit 0** ([özet](../experiments/cp5-c-acceptance.json)). Düzeltmesiz başarısızlıklar aşağıda; madde 3'ün eski `Process` yolu kaldırıldığı için düzeltmesiz sonuç reviewer'ın kayıtlı repro'sudur (`probe-quit.log`: Quit sonrası probe canlı; `probe-timeout.log`: 4,02 sn).

1. **Madde 1 — çözüldü.** Yazılmış bayt sağlayıcının okuduğu anlamına gelmediği için, terminalin kabul ettiği girdi son kullanım sayılır: `TerminalInputQueue.closeIfIdle` son kabulden `idleAfter` geçmemişse kapanmaz (`recentTerminalInput` engeli); kabul/kapanış aynı kilitte. Zamanlayıcı bir sonraki süreyi son girdiden hesaplar (olay beklemez, engel `blockedDue`'ya yazılmaz). Prompt metni tahmini ve ek sabit bekleme yok. Regresyon (üretim `TerminalInputQueue`+endpoint, okuyucu SIGSTOP): `aPromptAcceptedBeforeTheProviderReadsItIsNotLostToTheIdleStop` — düzeltmesiz (`quietFor: 0`) `transitioned`, sağlayıcı istemi işlemeden öldürüldü; düzeltmeli `blocked(recentTerminalInput)`, hata 0, istem tam bir kez işlendi. Ek: `recentInputPostponesTheAutomaticIdle…` (zamanlayıcı yolu). Mevcut kapı testi yeni anlamı yansıtacak şekilde güncellendi.
2. **Madde 2 — çözüldü.** Baseline yalnız kullanıcının run'daki ilk isteminden (`firstPromptDate`) önce/anında başlamış süreçleri alır; sonradan başlayan (bildirilmiş ya da bildirilmemiş, `/clear` öncesi dahil) iş `nonBaselineDescendants` olarak idle'ı engeller. İlk istem sınırı yoksa baseline alınmaz (engel görünür kalır). Claude'da sınır olarak yardımcının damgası (`min(receivedAt, sentAt)`) kullanılır. Fixture'da istem olayı artık süreç başlamadan önce gelir; `/hidden` (Stop yükünde iş yok) eklendi. Testler: `aChildStartedInTheFirstTurnNeverBecomesPartOfTheBaseline` (`/hidden`, `/background`), `aChildFromBeforeClearStaysWork…`. `/hidden`, sınırsız (`startedNoLaterThan: nil`) düzeltmesiz başarısız. Kalan sınır: gerçek Claude'un istem hook'unun süreç başlangıcından önce gelmesi varsayımı doğrulanmadı.
3. **Madde 3 — çözüldü.** `Process` probe'u kaldırıldı. Yetenek sorguları `ProcessSupervisor.captureHelper` ile yönetilen ortam kabuğunun yolundan geçer: ledger'a kayıtlı, kendi süreç grubu, tek toplam süre sınırı, 4 MiB çıktı kotası, `shutdown` iptal eder/bekler, dönüşte grup kalıntısı öldürülür. Testler (`ProviderToolchainTests`): pipe'ı tutan uzun yaşayan çocukla 0,5 sn sınırı ~0,2 sn'de döner ve çocuk ölür; yavaş lider zaman aşımına uğrar ve ölür; fazla çıktı kotada durur; süren probe varken başarılı `shutdown` sonrası PID yok. Sınır: süreç grubundan ayrılan (kendi grubunu kuran) torun bu yolla öldürülmez (OWN-1).
4. **Madde 4 — çözüldü.** Kimlik değişince kullanıcı o terminali seçili görüyorsa seçim yeni sahibe geçer; başka karta geçmiş kullanıcının seçimi çalınmaz. Testler: `clearMovesTheTerminal…` (seçim izler; düzeltmesiz ✘), `clearDoesNotStealTheSelection…`. **Doğrulanmadı:** yerel klavye/odak yolu (odak `viewDidMoveToWindow` ile yeniden verilir; bu ortamda yerel UI sürülmedi) — reviewer'ın native deneyiyle tekrar sınanmalı.
5. **Madde 5 — çözüldü.** Codex profili: açık izole override > çözülmüş terminal ortamındaki `CODEX_HOME` > `~/.codex`. `SystemProviderToolchains` ortam kaynağı enjekte edilebilir; probe seçilen profille çalışır. Claude'un terminal `CLAUDE_CONFIG_DIR`'ı zaten korunuyordu (profil dizini yoksa değişken ortamdan aynen geçer). Test: `codexHomePrefersTheOverrideThenTheTerminalEnvironmentThenTheDefault` (fixture `codex --version` seçilen `CODEX_HOME`'u yansıtır; gerçek profile dokunulmaz). Sunucu ve TUI aynı `codexHome(toolchain)` değerini kullanır (mevcut Codex runtime testleri TUI'de `home=` görür).
6. **Madde 6 — çözüldü (hazırlık).** [Düzenek](../experiments/cp5-c-real-provider-setup.md) yeniden yazıldı: oturum A/B/C sırası (yeniden açılışlar, kimlik devrinden sonra `<C>/<X>`'in yeniden okunması), 8 tur taban, onayı zorlayan izole ilke ve 0 tur ön doğrulama, R7 için "Loom'a geldi / gelmedi" iki sonucu ve ret/onay beklentisi. Kod: `--fake-providers` olmadan `snapshot` ham terminal metni, kart başlığı ve istek metni yazmaz; yalnız `--evidence-tokens` belirteçlerinin varlığı; `screenshot:` kapalı. Test: `redactedEvidenceCarriesTokenPresenceAndNoScreenText`. Codex isteğinin Loom bağlantısına gelip gelmediği açık kabul sorusu olarak duruyor.

**Doğrulanmadı:** gerçek Claude/Codex; yerel odak/klavye (madde 4); Claude/Codex izin-politikası anahtarlarının gerçek sözdizimi (düzenekte 0 tur ön doğrulama olarak tanımlı); OWN-1, uzun A/GPU/imza ve D. **Needs:** review; C kapanmadığı için D/optimizer açılmaz. **Sıradaki rol:** planner-reviewer.


## 6. İkinci review ve kalan düzeltme (29 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → implementer.
**Yanıt:** §5 madde 1–6; önceki §4.1 numaraları korunur.
**Sonuç:** **C kabul edilmedi.** Madde 1, 3, 4, 5 ve madde 6'nın tanımlı deney hazırlığı kapandı; **madde 2 açık**. Ürün kodu değişmedi, model turu 0. Kanıt özeti: [cp5-c-review2.json](../experiments/cp5-c-review2.json).

### 6.1. Açık madde 2 — asenkron hook zamanı güvenilir başlangıç sınırı değil [P1, C3]

[ProviderLaunchProfile.swift:113](../../Sources/LoomCore/ProviderLaunchProfile.swift#L113) `UserPromptSubmit` dahil hook'ları `async: true` kuruyor. [loom-hook/main.swift:19](../../Sources/loom-hook/main.swift#L19) zarfı yardımcı çalışıp girdiyi okuduktan sonra oluşturuyor; `sentAt` sağlayıcının istemi aldığı an değil. [ProviderSessionAdapters.swift:75](../../Sources/LoomCore/ProviderSessionAdapters.swift#L75) bu zamanı ilk istem sınırı yapıyor; [SessionRuntime.swift:849](../../Sources/LoomCore/SessionRuntime.swift#L849) baseline filtresine aktarıyor. Yardımcı gecikirse kullanıcı işi bu sınırdan önce doğmuş olabilir. `min(receivedAt, sentAt)` yalnız iletim gecikmesini azaltır, bu yarışı çözmez.

**Başarısız — güncel çekirdekle çalışma kanıtı:** ilk tur çocuğu oluşturulduktan sonra istem hook'u gelen ve Stop yükünde arka plan işini ayrıca bildirmeyen fixture çalıştırıldı. Sınır çocuğun doğumundan **6,94 ms sonra**; çocuk canlı ve sample'da görünürken baseline alındı, idle `transitioned` döndü ve çocuk öldü. Logdaki `child_in_baseline` eski harness alan adıdır ve sample üyeliğini ölçer; baseline'a yanlış alınma, tarih filtresi ve canlı çocukla başarılı idle geçişiyle doğrulanır. Gerçek Claude'un bu sıralamayı ne sıklıkta ürettiği doğrulanmadı; mevcut asenkron yapı bunu dışlamıyor. Fixture'da hook'u çocuk öncesine taşımak yalnız olumlu sırayı test ediyor.

**Kapanış işi:** sağlayıcı kullanıcı işini başlatmadan önce kurulmuş güvenilir bir sınır kullan; bu garanti yoksa baseline/idle engelini koru. Prompt metni tahmini, ek sabit bekleme veya geç hook zamanını başlangıç kanıtı sayma. Olumlu sıraya ek olarak gecikmiş/asenkron `UserPromptSubmit`, bildirilmemiş canlı çocuk ve kimlik devri sonrası aynı run için regresyon ekle. Bilinen canlı kullanıcı işi hiçbirinde baseline yardımcısına dönüşmemeli; otomatik idle engellenmeli. Bu düzeltme gerçek model turu gerektirmez. Kanıt: `baseline-repro.swift`, `baseline-fixture-main.swift`, `baseline-async-hook.log`.

### 6.2. Kapanan maddeler ve doğrulama sınırı

- **1 kapandı:** bağımsız üretim kuyruğu/PTY + SIGSTOP deneyi `accepted=true`, kuyruk boş, hata 0 iken `blocked(recentTerminalInput)` döndü; SIGCONT sonrası prompt işlendi, run canlı kaldı. Zamanlayıcı regresyonu da geçti.
- **3 kapandı:** supervisor sahipliği, iptal, toplam süre ve çıktı kotası yolu incelendi; yavaş lider, pipe tutan çocuk, çıktı taşması ve başlatma sürerken Quit testleri geçti. OWN-1 dışına taşan yeni sahiplik garantisi verilmedi.
- **4 kapandı:** paketlenmiş uygulamada native `/clear` ve `/new` sonrasında yeni kart seçili kaldı; başka bir tıklama olmadan yazılan iki belirteç doğru terminalde işlendi. Diğer kartın seçimini koruyan ve eski kartın terminalini ayıran testler geçti. Native Cmd+Q başarılı, kalan 0. Tam erişilebilirlik matrisi değildir.
- **5 kapandı:** profil önceliği fixture probe testiyle doğrulandı; app-server/TUI/resume aynı seçilmiş home'u kullanıyor. Runtime testleri `home=` değerinin kendisini assert etmiyor; bu kısım kaynak takibiyle doğrulandı, gerçek hesap deneyi yapılmadı.
- **6 tanımlı deney için kapandı:** A/B/C sırası, yeniden açılışlar, kimlikleri yeniden okuma, izole onay ilkesi ve 0 tur ön kontrolü açık. Ham terminal yerine belirteç varlığı testi geçti; gerçek modda ekran görüntüsü kapalı. Bu, bütün tanı alanları için genel içerik arındırma garantisi değildir. Gerçek izin sözdizimi ve Codex onayının Loom bağlantısına gelmesi hâlâ deneyde doğrulanacak.

**Doğrulandı:** bağımsız `swift build`, tam `swift test` **202 test (13 terminal + 157 core + 32 UI)**, release paketleme/imza ve `git diff --check`. Test komutu makro kütüphanesi yükleme seçeneği ve `LOOM_FORCE_COALITION_FAILURE=1` ile çalıştı. Kaynak hash karşılaştırması ürün dosyalarının review boyunca değişmediğini gösterdi. İki dar reviewer kaynak incelemesi kullanıldı; belirleyici kaynaklar ana reviewer tarafından da kontrol edildi. **Başarısız:** §6.1. **Doğrulanmadı:** gerçek sağlayıcı kabulü, OWN-1, uzun A/GPU/kalıcı imza ve D. Implementer'ın 22/22 paket otomasyonu bu tur tekrar edilmedi; bağımsız dar native deney yapıldı.

Kalıcı kanıt: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-review2-20260929/`; [özet](../experiments/cp5-c-review2.json). Önceki bölümler değiştirilmedi.

**Sonraki rol/adım — implementer:** yalnız §6.1'i kapat; regresyonun düzeltmesiz başarısızlığını ve birleşik kontrolleri §7'de raporla, ardından status'u review bekleniyor yap. Gerçek sağlayıcı bütçesi 0 kalır; düzeltme kabul edilmeden bütçe talebi/D/optimizer açılmaz. Bu oturum implementer başlatmaz veya mesaj göndermez; kullanıcı yönlendirecek.


## 7. Uygulama sonucu: asenkron hook/baseline düzeltmesi (29 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §6.1 / önceki madde 2 — **çözüldü (implementasyon); kabul review bekliyor**.
**Sonuç:** baseline yalnız supervisor'ın başlatırken kaydettiği ana süreç kimliğini içerir. İlk prompt/hook tarihiyle çocukları başlangıç yardımcısı sayan filtre ve artık kullanılmayan `firstPromptDates` kaydı kaldırıldı. Sessiz tur yalnız değerlendirmeye izin verir; canlı çocuklar `nonBaselineDescendants` engeli olarak kalır. Aynı run'ın `/clear` ile yeni karta geçmesi bu kuralı değiştirmez. Hook zamanı yalnız kullanım tarihidir; prompt tahmini, sabit bekleme veya yeni bağımlılık eklenmedi. Runtime, baseline kaydını ancak çağrı başarılı döndüğünde tamamlanmış sayar.

**Doğrulandı — C3 regresyonu:** üretim runtime/PTY/hook helper yolunda `/hidden`, `/background`, `/delayed-hidden`, `/delayed-background`; ayrıca normal ve gecikmiş bildirilmeyen çocuğun `/clear` sonrası aynı run'da korunması: **2 test / 6 vaka geçti**. Fixture gecikmiş sırada çocuğu başlatıp sonra prompt helper'ını çalıştırır; Stop yükünde bildirilmeyen çocuk ayrıca sınanır. Düzeltme öncesi aynı testler **exit 1, 5 ihlal**: iki `/delayed-hidden` vakasında idle geçişi canlı çocuğu öldürdü; düzeltme sonrası **exit 0**, çocuklar canlı ve idle engelli. Mevcut çocuksuz güvenli idle/zamanlayıcı testleri de geçti.

**Doğrulandı — birleşik kontroller:** `swift build`; `LOOM_FORCE_COALITION_FAILURE=1` ve makro yükleme seçeneğiyle tam `swift test` **202 test (13 terminal + 157 core + 32 UI)**; release paketleme/imza doğrulaması (ad-hoc); `git diff --check`. Paket sentetik kabulü **22/22, exit 0**, run `cp5-c-20260929T142414`. Paket otomasyonu LaunchServices + geliştirme callback'lerini kullanır; bağımsız native klavye/odak kabulü değildir.

**Kanıt:** [değerlerden arındırılmış sonuç ve kaynak hash'leri](../experiments/cp5-c-hook-fix.json), [paket sonucu](../experiments/cp5-c-acceptance.json). Kalıcı run: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-hook-fix-20260929/` — `commands.txt`, `regression-before.log`, `regression-after.log`, `build.log`, `tests.log`, `package.log`, `package-acceptance.log`, `source-hashes.json`. Kod: [baseline](../../Sources/LoomCore/SessionLifecycleController.swift#L189), [runtime](../../Sources/LoomCore/SessionRuntime.swift#L839), [regresyonlar](../../Tests/LoomCoreTests/SessionRuntimeTests.swift#L667).

**Sınır / doğrulanmadı:** başlangıç yardımcısı olduğu kanıtlanamayan meşru sağlayıcı çocukları da canlı kaldıkça otomatik idle'ı engeller; güvenilir ayrım olmadığı için bilinmeyen işi yardımcı saymama tercihidir. Gerçek Claude/Codex kabulü, OWN-1, uzun A/GPU/kalıcı imza ve D doğrulanmadı. Model turu **0**, gerçek sağlayıcı çalıştırılmadı; commit/push yok.

**Sonraki rol/adım — planner-reviewer:** §6.1 düzeltmesini ve bu temkinli idle davranışını bağımsız doğrula. C kabul edilmedi; gerçek sağlayıcı bütçesi 0 kalır, bu düzeltmenin kabulünden önce bütçe talebi/D/optimizer açılmaz.


## 8. Üçüncü review ve idle yeniden değerlendirmesi (29 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → implementer.
**Yanıt:** §7 / §6.1 (önceki madde 2).
**Sonuç:** **Madde 2 kapandı; C kabul edilmedi.** Yalnız başlatılan ana süreci baseline saymak, bilinmeyen işi yardımcı varsaymama ölçütünü karşılıyor. İlk hook zamanına bağımlılık kaldırılmış. Ancak aşağıdaki yeni madde 7, çocuk kalmadığında otomatik idle'ın toparlanmasını engelliyor. Ürün kodu değişmedi; model turu 0. Kanıt: [cp5-c-review3.json](../experiments/cp5-c-review3.json).

### 8.1. [P2 — C3] Çocuk bittikten sonra otomatik idle yeniden değerlendirilmiyor (madde 7)

[SessionLifecycleController.swift:175](../../Sources/LoomCore/SessionLifecycleController.swift#L175) `nonBaselineDescendants` dahil engelleri `blockedDue` içine yazar; [reschedule:133](../../Sources/LoomCore/SessionLifecycleController.swift#L133) aynı kullanım tarihindeki oturumu zamanlamadan çıkarır. Engelin temizlenmesi [handle:110](../../Sources/LoomCore/SessionLifecycleController.swift#L110) içindeki sağlayıcı/run olaylarına bağlıdır. Bir çocuğun çıkması bu olaylardan birini üretmek zorunda değildir. Yeni leader-only baseline ile kısa ömürlü yardımcılar da bu yola girebilir. Meşru yardımcı canlıyken temkinli engelleme kabul edilebilir; yardımcı bittikten sonra eski engeli süresiz korumak değildir.

**Başarısız — bağımsız runtime/PTY/hook deneyi:** 0,3 sn idle politikasıyla bildirilmeyen canlı çocuk ilk değerlendirmeyi engelledi. Ardından çocuk bitirildi; bir saniye sonra `supervisor.sample` yalnız canlı ana süreci döndürdü. Buna rağmen timer sayacı **1 → 1**, canlı run **1**, gösterilen engel hâlâ `nonBaselineDescendants(1)` idi. Son `shutdown` başarılı. Deneyde yeni prompt veya kullanım olayı gönderilmedi. Kanıt: `child-exit-repro.swift`, `child-exit-repro.log`. Bu, önceki madde 2'nin yeniden açılması değil; güvenli engelden sonraki toparlanma eksikliği.

**Kapanış işi:** çocuk çıkışında eski engeli geçersiz kılıp otomatik değerlendirmeyi yeniden kur; canlı/bilinmeyen işi baseline'a ekleyerek çözme. Mevcut kaynak sınırlarına uygun, sonlanabilen bir izleme/yeniden değerlendirme yolu kullan; meşgul döngü kurma. Regresyon, önce canlı çocukla idle'ın engellendiğini, çocuk bittikten sonra yeni prompt/kart seçimi/sağlayıcı olayı olmadan güvenli idle'a geçildiğini göstermeli. Kısa ömürlü hook yardımcısının karar anına denk gelmesi de kapsanmalı. Önceki altı çocuk/kimlik devri vakası korunmalı.

### 8.2. Doğrulama ve sınırlar

- **Doğrulandı — madde 2:** ikinci review'daki aynı gecikmiş-hook fixture'ı güncel çekirdekle yeniden çalıştı; `blocked(nonBaselineDescendants(1))`, çocuk canlı, run canlı, ardından başarılı shutdown. Eski harness'teki `child_in_baseline` adı sample üyeliğidir; doğrudan baseline üyeliği iddiası değildir. Implementer'ın altı regresyon vakası tam test çalışmasında geçti; düzeltmesiz beş ihlal kaydı ve kaynak hash'leri de kontrol edildi.
- **Doğrulandı:** bağımsız `swift build`, `git diff --check`; review öncesi/sonrası kaynak hash'leri aynı. Native UI değişmediği için §6.2'nin `/clear`/`/new` klavye kanıtı tekrarlanmadı. Release paket/22 kabul için §7 kanıtı devralındı, bu tur tekrar edilmedi.
- **Başarısız:** bağımsız tam `swift test` **202 testte 2 test / 5 ihlal, exit 1**: `idleIsBlockedUntilAReliableQuietMomentThenStopsSafely` dört ihlal; `aPromptAcceptedBeforeTheProviderReadsItIsNotLostToTheIdleStop` beklenen `recentTerminalInput` engelini bulamadı. **Dar tekrar 2/2 geçti.** Bu tekrar ilk başarısızlığı silmez. İlk log anlık süreç/engel kümesini içermediğinden iki testin kesin kök nedeni madde 7 diye sunulmuyor; düzeltme turunda ilgili engeli/süreçleri kaydederek kararlılığı doğrula. Makro yükleme seçeneği ve `LOOM_FORCE_COALITION_FAILURE=1` kullanıldı.
- **Doğrulanmadı:** gerçek sağlayıcılar, OWN-1, uzun A/GPU/kalıcı imza ve D. Gerçek deney bütçesi 0 kalır; sentetik kabul kapısı kapanmadığı için bütçe talebi yapılmadı.

Kalıcı kanıt: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-review3-20260929/`; [özet](../experiments/cp5-c-review3.json).

**Sonraki rol/adım — implementer:** madde 7'yi düzelt; dar regresyon ve birleşik kontrollerin sonucunu §9'a ekle, ardından status'u review bekleniyor yap. Bu oturum implementer başlatmaz veya mesaj göndermez; kullanıcı yönlendirecek. C kapanmadan D/optimizer açılmaz.


## 9. Uygulama sonucu: çocuk çıkışından sonra idle toparlanması (29 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §8.1 madde 7 — **çözüldü (implementasyon); bağımsız kabul bekliyor**; §8.2 aralıklı test sonuçları.
**Sonuç:** `nonBaselineDescendants` nedeniyle engellenen aktif oturumlar mevcut tek zamanlayıcı üzerinden **5 saniye sonra** yeniden değerlendirilir. Başka sağlayıcı olayı gerekmez; çocuk canlıysa engel korunur, bitmişse normal güvenli idle kontrolleri çalışır. Yeni kullanım daha sonraki idle süresini korur. Yeniden kontrol kaydı oturum bitişinde/kimlik-durum olayında geçersizleşir, canlı olmayan kayıtlardan ayıklanır; otomatik değerlendirme durdurulunca temizlenir. Yeni döngü veya oturum başına timer yok; baseline hâlâ yalnız ana süreçtir. Çıkış algılama anlık değildir, planlanan kontrolde gerçekleşir.

**Doğrulandı — regresyon:** üretim runtime/PTY/hook yolu iki vakayla sınandı: bildirilmeyen çocuk; gerçek Stop hook tesliminden sonra çıkışı test tarafından geciktirilen helper wrapper'ı. Önce canlı süreçle idle engeli ve run'ın yaşaması, ardından yeni prompt/kart seçimi/sağlayıcı olayı olmadan idle, boş engel ve run'ın kapanması doğrulandı. Düzeltmesiz **2 vaka / 6 ihlal, exit 1**: çocuk gittikten sonra timer **1 → 1**, eski engel kaldı. Düzeltmeli **2/2, exit 0**: timer **1 → 2**, engel temizlendi. Sık timer dönüşü olmaması ve shutdown sonrası sayaç değişmemesi kontrol edildi; önceki altı çocuk/kimlik devri vakası korundu.

**§8.2 test kararlılığı:** ilk birleşik koşuda girdi testi yine başarısız oldu; bu kez kayıt açıkça `nonBaselineDescendants(1)` döndüğünü gösterdi (`tests.log`). `turnComplete` hook helper'ının çıktığı anlamına gelmediğinden, yalnız okunmamış PTY girdisini sınayan test önce önceki yardımcının çıkıp sample'da yalnız ana sürecin kaldığını doğrular; mevcut `recentTerminalInput`, kayıpsız/tek teslim ve canlı run beklentileri korunur. Canlı helper engeli yeni regresyonda ayrıca sınanır. Son tam koşu geçti; iki aralıklı testin **5 tekrarında 10/10** geçiş var, süreç/engel/timer tanıları loglarda. Önceki review'daki iki başarısızlığın tamamının kesin kök nedeni aynıymış gibi sunulmuyor; ilk başarısız log korunuyor.

**Doğrulandı — birleşik kontroller:** `swift build`; makro yükleme seçeneği ve `LOOM_FORCE_COALITION_FAILURE=1` ile tam `swift test` **203 test (13 terminal + 158 core + 32 UI), exit 0**; `git diff --check` ve değişen izlenmeyen dosyaların whitespace kontrolü; release paketleme/ad-hoc imza doğrulaması; paket sentetik kabulü **22/22, exit 0**, run `cp5-c-20260929T144209`. Paket otomasyonu LaunchServices + geliştirme callback'leridir; bağımsız native klavye/odak kanıtı değildir.

**Kanıt:** [özet ve kaynak hash'leri](../experiments/cp5-c-idle-retry.json), [paket sonucu](../experiments/cp5-c-acceptance.json); [zamanlama](../../Sources/LoomCore/SessionLifecycleController.swift#L170), [regresyon](../../Tests/LoomCoreTests/SessionRuntimeTests.swift#L720). Kalıcı run: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-idle-retry-20260929/` — `commands.txt`, `before.log`, `after.log`, `tests.log`, `tests-final.log`, `stability-1.log`–`stability-5.log`, build/paket logları ve `source-hashes.json`.

**Doğrulanmadı:** bağımsız kabul, gerçek sağlayıcılar, OWN-1, uzun A/GPU/kalıcı imza ve D. Model turu **0**; gerçek sağlayıcı çalıştırılmadı; commit/push yok.
**Sonraki rol/adım — planner-reviewer:** madde 7'yi ve test kararlılığı kanıtını review et. C kabul edilmedi; gerçek sağlayıcı bütçesi 0, D/optimizer açılmadı.


## 10. Dördüncü review ve gerçek sağlayıcı karar kapısı (29 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → kullanıcı / sonraki uygulayıcı.
**Yanıt:** §9, madde 7; kullanıcının risk odaklı test kapsamı talimatı.
**Sonuç:** **Madde 7 kapandı; sentetik review bulgusu kalmadı.** C'nin tam kabulü gerçek sağlayıcı kapısını bekliyor. Ürün kodu değişmedi, gerçek sağlayıcı/model turu 0. Kanıt: [cp5-c-review4.json](../experiments/cp5-c-review4.json).

**Doğrulandı:** önceki bağımsız runtime/PTY/hook düzeneği yeniden çalıştı. Canlı çocuk ilk idle'ı engelledi; çocuk bittikten sonra yeni kullanım/sağlayıcı olayı olmadan timer **1 → 2**, engel **boş**, canlı run **0**, shutdown başarılı. Yalnız yeni 5 saniyelik kontrol aralığını bekleyecek şekilde gözlem süresi uzatıldı. Böylece §8.1'in başarısız senaryosu kapandı. Lider-only baseline korunuyor; yeniden kontrol mevcut tek timer'da, yalnız ilgili aktif oturumlar için ve yeni kullanım süresini gözeterek yapılıyor. Çocuk çıkışı anında değil, planlanan kontrolde algılanır.

**Doğrulandı — dar kontroller:** bağımsız **7 test / 12 vaka, exit 0**: çocuk ve Stop helper çıkışı, güvenli idle, onay/arka plan engeli, okunmamış girdi koruması, yeni girdinin idle süresini ertelemesi, ilk turda bildirilen/bildirilmeyen ve gecikmiş hook sıraları, `/clear` sonrası aynı run'daki çocuğun korunması. Helper çıkışını bekleyen test önkoşulu yalnız girdi yarışını ayırıyor; kayıpsız/tek teslim beklentileri duruyor ve canlı helper ayrı regresyonda sınanıyor. Kaynak hash'leri implementer kanıtıyla eşleşti ve review boyunca değişmedi; `git diff --check` temiz. Test derlemesi başarılı. §9'daki `swift build`, 203 testlik tam koşu, 5×2 kararlılık ve 22/22 paket kanıtı devralındı; aynı kaynak için yeniden koşulmadı. Native UI değişmediği için §6.2 kanıtı korunur.

**Başarısız:** bu review'un dar kontrollerinde yok. **Doğrulanmadı:** gerçek Claude/Codex, izin ilkesi ön kontrolü, Codex onayının Loom bağlantısına gelmesi, OWN-1 ve ertelenmiş A/D kaynak/görsel kabulü. Sentetik geçiş bunları kapatmaz.

**Test kapsamı kararı:** kullanıcının bu tur talimatıyla [geliştirme rehberi](../../DEVELOPMENT.md#2-build-and-test) güncellendi. Rutin revizelerde değişen ve etkilenmesinden endişe edilen davranışların testleri yeterlidir; tam suite checkpoint kapanışında veya büyük revizyon/implementasyonda çalışır. Önceki tur kayıtları tarihsel kanıt olarak korunur.

**Sonraki adım — kullanıcı kararı:** [hazır gerçek sağlayıcı düzeneği](../experiments/cp5-c-real-provider-setup.md) için **8 model turu (Claude 4 + Codex 4), yeniden deneme payı 0** önerisi artık karar için hazır. Yeni/devam/kimlik devri/onay/aktif turda Quit senaryoları; izole profiller ve 0 tur izin ön kontrolü düzenekte tanımlı. Yetki verilmeden çalıştırılmaz. Bütçe onaylanırsa kullanıcı uygulayıcıyı yönlendirir; sonuç §11'e yazılır ve planner-reviewer C1–C5/D3 gerçek kabulünü değerlendirir. Bu oturum implementer başlatmaz/mesaj göndermez. C tamamlanmadan D veya checkpoint optimizer kapanışı açılmaz.

Kalıcı reviewer kanıtı: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-review4-20260929/`; [özet](../experiments/cp5-c-review4.json).


## 11. Sınırlı Haiku deneyi planı (29 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → kullanıcı / implementer.
**Yanıt:** §10 bütçe önerisi; kullanıcının Claude kullanımının dar olduğu ve Haiku ile birkaç küçük teste izin verdiği açıklaması.
**Sonuç:** geniş 8 tur önerisi çalıştırılmayacak. Kullanıcının izni için temkinli uygulama sınırı **Claude Haiku en fazla 2 kısa model turu, yeniden deneme 0; Codex 0** olarak belirlendi. Bu sayı kullanıcının birebir verdiği kota değil, “birkaç ufak test” iznine seçilen alt sınırdır. Henüz tur harcanmadı.

**Kapsam ve sıra:** [düzeneğin](../experiments/cp5-c-real-provider-setup.md) izolasyon/kanıt kurallarıyla yalnız A1 ve A3'ün Claude yolu:
1. İzole Claude profilini kullan; istem göndermeden TUI'nin model seçicisinde **Haiku** olduğunu doğrula. Default/Sonnet/Opus'a sessiz geçiş yok; Haiku veya izole giriş hazır değilse model turu başlatma. Küçük, boş deney klasörü kullan; repo/vault bağlamı, araç işi veya dosya okuma isteme.
2. **Tur 1:** yeni oturumda `Reply with exactly LOOM_C_R1 and nothing else.` Tek satırlık yanıt, doğru kart/dizin ve sağlayıcı kimliği doğrulansın.
3. Stop → aynı karttan resume; modelin hâlâ Haiku olduğunu doğrula. **Tur 2:** `What exact token did you reply with earlier in this conversation? Reply with only that token.` Aynı sağlayıcı kimliği/geçmiş ve yeni yanıt doğrulansın; terminalde eski belirtecin görünmesi tek başına hatırlama kanıtı sayılmasın.
4. Model çağırmadan `/clear` kimlik devri ve normal Stop/Quit kontrol edilebilir; ek prompt, otomatik tekrar veya başka sağlayıcı/model yok. Kanıtta yalnız durum/kimlik/belirteç sonucu; ham içerik yok.

**Kabul:** bu küçük deney yalnız Claude yeni/devam bağlantısını ve gözlenen 0 tur yollarını doğrulayabilir. Claude onayı/aktif turda Quit, Codex ve C'nin tam kabulü açık kalır; iki turun sonucu bütün slice kabulü değildir. Başarısız adım tekrar edilmez, raporlanır. **Kontroller:** yalnız değişen/etkilenen alan testleri; tam suite gerekmez.

**Kanıt:** bu tur plan ve belge tutarlılığı/whitespace kontrolü; model davranışı **doğrulanmadı**, çalışma deneyi yapılmadı. **Sonraki rol/adım — implementer:** kullanıcı yönlendirdiğinde bu sınırla deneyi uygula; tüketilen tur/model, geçen/kalan kabul ve kanıtı §12'ye ekle, status'u review bekleniyor yap. Bu oturum implementer başlatmaz veya mesaj göndermez.


## 12. Sınırlı Haiku deneyi sonucu: model öncesi başlatma hatası (29 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §11; kullanıcının sıradaki testi inceleyip sürdürme talimatı.
**Sonuç:** **A1 başlatma aşaması başarısız; model deneyi başlamadı.** Ayrı katalog ve boş çalışma klasörüyle paketli Loom açıldı; mevcut izole Claude profili kullanıldı. Native proje menüsünden bir Claude oturumu başlatıldı. Sağlayıcı kimliği oluşmadan terminal kapandı; kart `Not running`, sağlayıcı kimliği `Not assigned yet` gösterdi. Tek run katalogda **5,312 sn**, `processExited`, ham wait status **256 / exit code 1** ile kayıtlı. Terminal tanısı artık görünmediğinden kesin hata nedeni **doğrulanmadı**; giriş, model erişimi veya ayar hatası olduğu varsayılmadı.

**Bütçe / sınır:** Haiku model seçicisine ulaşılamadı; model doğrulanmadı, hiçbir istem gönderilmedi. **Harcanan model turu 0/2; kalan 2; tekrar 0; Codex 0.** §11'in “Başarısız adım tekrar edilmez, raporlanır” sınırı gereği yeni başlatma/resume denenmedi; iki model istemi ve `/clear` çalıştırılmadı. Kalan model bütçesi tek başına başlatmayı yeniden deneme yetkisi olarak yorumlanmadı.

**Doğrulandı:** native Add Project yolu boş deney klasörünü kaydetti; tek Claude kartı ve run oluştu, kayıtlı cwd/proje ilişkisi doğru. Native Cmd+Q sonrası uygulama çıktı; `quit.json` **succeeded=true, remaining=0, errors=[]**. Bu, başarısız başlangıçtan sonraki normal Quit kanıtıdır; aktif turda Quit kabulü değildir. Gerçek `~/.claude` üst düzey stat karşılaştırması değişmedi. Eşzamanlı Codex ortamındaki `~/.codex` stat değerleri değişti; deney Codex başlatmadı, bu değişimlerin kaynağı yalnız stat ile belirlenemez. Gerçek profillere deney tarafından yazma/kopyalama yapılmadı.

**Kanıt:** [arındırılmış sonuç, kimlikler ve kaynak/ikili hash'leri](../experiments/cp5-c-haiku.json). Run `cp5-c-haiku-20260929`, kalıcı dizin `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-haiku-20260929/`: `commands.txt`, `summary.json`, salt okunur sorgulanan `data/catalog.sqlite3`, `evidence/quit.json`, `profile-stats-before.json`, `profile-stats-after.json`. Kalıcı deney kanıtına terminal metni/model çıktısı/kimlik bilgisi yazılmadı. Ürün kodu değişmedi; önceki sentetik testler tekrar edilmedi. Belge bağlantıları/JSON/whitespace kontrol edildi; commit/push yok.

**Doğrulanmadı:** Haiku hazır oluşu, gerçek yeni/devam yanıtı ve geçmiş hatırlama, `/clear`, Claude onayı/aktif turda Quit, Codex ve C'nin tam kabulü.
**Sonraki rol/adım — planner-reviewer:** model öncesi başlatma hatasını ve erken çıkışta tanının kaybolmasını inceleyip sonraki sıfır-tur tanı/düzeltme işini planla. Başarısız gerçek başlatmayı yeniden denemeden önce §11'in tekrar sınırını kullanıcıyla netleştir. C kapanmadı; D/optimizer açılmadı.


## 13. Kullanıcı yetkisiyle Haiku tekrarı: yeni/devam başarılı (29 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §12; kullanıcının “doğrusunu öğren tekrar dene olmazsa tekrar raporla” talimatı, bu tur için önceki başlatma-tekrar sınırının yerine geçti. Model bütçesi genişletilmedi: kalan iki kısa Haiku turu kullanıldı.
**Sonuç:** **Claude yeni/devam dar deneyi geçti.** Yerel CLI `--help` ile model parametresi doğrulandı: `claude --model haiku`. İzole profille, aynı boş çalışma klasöründe sıfır-tur PTY ön kontrolü **Claude Code 2.1.284 / Haiku 4.5** açtı ve `/exit` ile başarıyla kapandı. Boş deney klasörünün güven seçimi tamamlandı; dış `CLAUDE.md` importları reddedildi. Ardından Loom için yalnız izole `settings.json` dosyasına geçici `model: haiku` kondu; deney sonunda önceki model ayarı geri getirildi. Gerçek profil/model varsayılanı değiştirilmedi.

**§12 tanısına düzeltme:** bu ön kontrolde ilk klasör ekranının varsayılanının **“No, exit”** olduğu görüldü. Önceki native menü tıklamasından sonra gönderilen ek Enter'ın bu seçimi onaylayıp çıkışa yol açması olasıdır; tarihsel hatanın kesin nedeni diye sunulmuyor. Bu tur ek Enter gönderilmeden Loom açıldı. Önceki `exit 1` tek başına yanlış model veya ürün başlatma hatasının kanıtı değildir.

**Doğrulandı — 2/2 Haiku turu:** native proje menüsünden yeni Claude başlatıldı; her turdan önce `/model` seçicisinde **Haiku 4.5** işaretli görüldü. §11'in ilk istemi tek belirteç yanıtını üretti, kart `Working → Ready` oldu ve sağlayıcı kimliği kaydedildi. Native Stop → aynı karttan Resume sonrası aynı sağlayıcı kimliği ve proje korundu; ikinci isteme **yeni üretilen** yanıt önceki belirteçle eşleşti ve kart tekrar Ready oldu. Yalnız eski ekran içeriğinin varlığı hatırlama kanıtı sayılmadı: ikinci istemin altındaki ayrı yeni yanıt gözlendi. Katalogda aynı kart için iki farklı run var; ilki `requested` ile sonlandı.

**Doğrulandı — sıfır-tur yollar:** `/clear` eski kartı koruyup seçimi yeni karta taşıdı; aynı ikinci run yeni sağlayıcı kimliğine bağlandı, proje ilişkisi korundu (SQLite `run_sessions` kanıtı). Yeni kartta Stop başarılı; native Cmd+Q sonrası uygulama çıktı, `quit.json` **succeeded=true, remaining=0, errors=[]**. Bu normal Stop/boşta Quit kanıtıdır; aktif turda Quit veya Claude araç onayı kabulü değildir.

**Bütçe:** bu tur **Claude Haiku 2**, kalan **0**; model tekrar **0**, Codex **0**. Sıfır-tur CLI ön kontrolünde model istemi yok. Ürün kodu değişmedi; kabul edilmiş sentetik suite tekrar edilmedi. Belge/JSON/bağlantı/whitespace kontrolü yapıldı; commit/push yok.
**Kanıt:** [arındırılmış sonuç](../experiments/cp5-c-haiku-retry.json); run `cp5-c-haiku-retry-20260929`, `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-haiku-retry-20260929/`: `commands.txt`, `summary.json`, `after-first-start.json`, `after-resume.json`, `after-clear.json`, `data/catalog.sqlite3`, `evidence/quit.json`. Native CUA eylemleri ve anlık model/yanıt gözlemi kullanıldı; deney dosyalarına ham terminal/model yanıtı veya ekran görüntüsü yazılmadı.

**Doğrulanmadı:** Claude araç onayı, aktif turda Quit, Codex ve C'nin tam gerçek kabulü; OWN-1 ve ertelenen A/D kapsamı.
**Sonraki rol/adım — planner-reviewer:** bu dar gerçek Claude sonucunu değerlendir; kalan kabul ve bütçe kararını kullanıcıya sun. Yeni model turu yetkisi yok; C/D/optimizer kapanışı ilan edilmedi.


## 14. Beşinci review: dar gerçek Claude kabulü (29 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → kullanıcı / sonraki uygulayıcı.
**Yanıt:** §12–13; §11'in sınırlı kabul ölçütleri.
**Sonuç:** **Claude yeni/devam dar deneyi kabul edildi.** `/clear` kimlik/proje devri, açık Stop ve boşta Quit gözlenen kapsamda kabul edildi. Yeni engelleyici bulgu yok; **C'nin tamamı kapanmadı**. Review sırasında model turu 0, kalan yetki 0. Kanıt: [cp5-c-review5.json](../experiments/cp5-c-review5.json), [deney sonucu](../experiments/cp5-c-haiku-retry.json).

**Doğrulandı — bağımsız kanıt kontrolü:** deney kataloğu salt okunur açıldı; iki run'ın aynı ilk karta ait olduğu, ikisinin de `requested` ve bitiş zamanı taşıdığı doğrulandı. İki kart aynı proje/dizini koruyor; üç `run_sessions` bağlantısı ikinci run'ın `/clear` ile eski karttan yeni kimliğe geçtiğini gösteriyor. Saklanan ara sorgu sonuçları son katalogla tutarlı. `quit.json` başarılı/kalan 0/hata yok; bu boşta Quit'tir. Ürün kaynak hash'leri dördüncü review ile aynı.

**Kanıt sınırı:** Haiku 4.5 seçimi, yeni üretilmiş iki yanıt ve native seçim/odak sonucu §13'ün anlık CUA gözlem kaydına dayanır; reviewer bunları yeniden model çalıştırarak tekrarlamadı. Ham yanıt/ekran görüntüsü saklamama kuralı korunmuş. Dar kabul, bu gözlem kaydı ile bağımsız katalog/Quit kontrolünün birleşimine dayanır; SQLite tek başına model/yanıt doğrulaması sayılmaz. §12'nin tarihsel exit 1 nedeni hâlâ kesin değil; tekrardaki güven ekranı açıklaması olasılık olarak kalır, ürün hatası diye açılmadı.

**Kontroller:** ürün kodu değişmediğinden build/test suite yeniden çalıştırılmadı. Kaynak bütünlüğü, JSON/katalog tutarlılığı, belge bağlantıları ve whitespace kontrolü yapıldı. **Başarısız:** bu review'da yeni kontrol başarısızlığı yok. **Doğrulanmadı:** Claude araç onayı ve aktif turda Quit; bütün gerçek Codex kabulü; OWN-1 ve ertelenen A/D kapsamı. Önceki sentetik kabul korunur.

**Sonraki adım — kullanıcı kararı:** Claude kullanımını korumak için ilave Haiku deneyi şimdilik önerilmiyor. Önce [mevcut düzenekteki](../experiments/cp5-c-real-provider-setup.md) Codex A2 → A4 → C1 → C2 için **4 kısa model turu, tekrar payı 0** bütçe önerisi: yeni, devam, araç onayı ve aktif turda Quit. Claude adımları çalıştırılmaz; ayrı açılışlarda aynı izole Codex katalog/profili kullanılır, arada normal Stop/Quit yapılır. Onay bağlantısının Loom'a gelmemesi başarısız/açık kabul olarak raporlanır; TUI yanıtı Loom düğmesini doğrulamaz. Bu öneri henüz yetki değildir. Claude'un kalan iki kabulü ayrıca açık tutulur; Codex geçse de C kendiliğinden kapanmaz. Kullanıcı yetki ve uygulayıcı yönlendirmesi vermeden model çalıştırılmaz/implementer başlatılmaz. Sonuç sıradaki ek olarak kaydedilir; D/optimizer kapanışı açılmaz.


## 15. Codex deney yetkisi ve uygulama sırası (29 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → implementer.
**Yanıt:** §14'teki dört kısa Codex turu önerisine kullanıcının açık “onaylıyorum” yanıtı.
**Sonuç:** **Codex en fazla 4 kısa model turu onaylı, harcanan 0, kalan 4; tekrar payı 0.** Claude Haiku 2/2 harcandı; ek Claude turu yok. Onay deney bütçesidir; C kabulü veya implementer oturumunu başlatma talimatı değildir.

**Kapsam/sıra:** [gerçek sağlayıcı düzeneğinin](../experiments/cp5-c-real-provider-setup.md) izole profil, boş çalışma klasörü, izin ön kontrolü ve arındırılmış kanıt kurallarıyla yalnız Codex:
1. Model turu harcamadan izole giriş/CLI/izin politikasını doğrula. Gerçek kullanıcı profiline yazma. Model/sürüm kaydını içeriksiz tut; başlangıçta engel varsa istem gönderme.
2. **Tur 1 — A2:** yeni Codex oturumunda `Reply with exactly LOOM_C_R5 and nothing else.` Doğru dizin/proje, thread kimliği, Ready ve belirteç yanıtını doğrula.
3. Stop → aynı karttan resume. **Tur 2 — A4:** `What exact token did you reply with earlier in this conversation? Reply with only that token.` Aynı thread/geçmiş ve yeni üretilen yanıtı doğrula; eski ekran metni tek başına yeterli değil. Model çağırmadan `/new` kimlik devri ve `/exit` denenebilir; ardından normal Quit ve aynı katalogla yeniden açılış.
4. **Tur 3 — C1:** yeni Codex oturumunda `Run exactly this shell command and nothing else: touch loom-c-approval-codex.txt`. İzole onay ilkesi önceden doğrulanmış olsun. Loom isteği alıyorsa doğru karttan accept; dosya ve istek kapanışını doğrula. İstek yalnız TUI'ye geliyorsa bunu ayrı kaydet; kullanıcı TUI onayıyla ilerleyebilir fakat Loom onay kabulü açık kalır. İkinci bir model istemiyle yeniden deneme yok.
5. **Tur 4 — C2:** aynı oturumda `Run exactly this shell command and wait for it: sleep 40. Then reply DONE.` Working sırasında Quit; sahip olunan süreçlerin ve ortak sunucunun kapanışını, dış kontrol sürecinin korunmasını doğrula. İzin ekranı nedeniyle komut başlamazsa aktif işte Quit doğrulanmış sayılmaz.

**Kabul/kontroller:** yeni/devam, gözlenen kimlik devri, onay teslimi ve aktif-tur Quit sonuçlarını ayrı değerlendir. Model çağrısı yapmayan komutlar ek istem yetkisi değildir. Başarısız adım tekrarlanmaz; kalan adım başarısız önkoşula bağlıysa durup raporla. Tur bütçesi aşılmaz. Kod değişmezse suite/build tekrarı gerekmez; kanıt/JSON/katalog ve belge tutarlılığı kontrol edilir. Kod düzeltmesi gerekirse önce bulgu raporlanır; test kapsamı etkilenen davranışla sınırlıdır.

**Kanıt:** bu tur yalnız kullanıcı yetkisi ve uygulanabilir sıra kaydedildi; model çalıştırılmadı. Gerçek davranış **doğrulanmadı**. **Sonraki rol/adım — implementer:** kullanıcı yönlendirdiğinde uygula; tüketilen model/tur, geçen/başarısız/doğrulanmayan kabulü ve kanıtı §16'ya yaz, status'u review bekleniyor yap. Bu oturum implementer başlatmaz/mesaj göndermez. Claude'un kalan araç onayı/aktif Quit kabulü ve C'nin tam kapanışı ayrıca açık kalır.


## 16. Codex deneyi: app-server başlatma ön koşulu başarısız (29 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §15, kullanıcının Codex deneylerini işleme talimatı.
**Sonuç:** **Model öncesi başlatma başarısız; A2/A4/C1/C2 çalıştırılamadı.** Yerel `codex-cli 0.158.0`, `--remote` ve `app-server --listen unix://PATH` desteği yardım çıktısından doğrulandı. İzole `CODEX_HOME=~/.loom-dev/codex-home` giriş durumu başarılı (`Logged in using ChatGPT`). Yalnız izole config'de `approval_policy="untrusted"`, `sandbox_mode="workspace-write"` kuruldu; TUI açılamadığından politikanın runtime'da etkinliği/model **doğrulanmadı**. Deney sonunda bu iki alan eski değerlerine döndürüldü.

**Başarısız — C1 ön koşulu:** ayrı katalog ve boş çalışma klasörüyle paketli Loom'da native proje menüsünden tek Codex başlatma eylemi yapıldı. Görünür hata: `Codex could not be started: Codex app-server connect: No such file or directory`. Katalog: proje **1**, sohbet/run/run-link **0**; model istemi gönderilmedi. Kaynakta sunucu başlatıldıktan sonra sokete bağlantının süre sonuna kadar denendiği, son bağlantı hatasının UI'a aktarıldığı görüldü ([manager](../../Sources/LoomCore/CodexAppServerManager.swift#L173)). Bu kayıt sunucunun neden soketi oluşturmadığını açıklamıyor; yanlış model, giriş/config hatası veya socket uzunluğu kesin neden diye sunulmuyor. İç sunucu çıktısı için bu yolda kalıcı tanı yok.

**Doğrulandı:** hata UI'da görünür ve hayalet sohbet kartı yok. Native Cmd+Q sonrası uygulama çıktı; `quit.json` **succeeded=true, remaining=0, errors=[]**. Bu başarısız başlangıçtan sonraki boşta Quit'tir; aktif işte Quit kabulü değildir. Gerçek profillere deney tarafından yazılmadı; önce/sonra yalnız üst düzey stat alındı. Eşzamanlı Codex faaliyetleri nedeniyle gerçek profil metadata değişimleri deneye atfedilmez.

**Bütçe:** **Codex 0/4 harcandı, kalan 4; tekrar 0; Claude ek tur 0.** §15 gereği başarısız başlatma tekrar edilmedi; kalan dört model adımı bu ön koşula bağlı olduğu için çalıştırılmadı. Kod değiştirilmedi, kabul edilmiş build/suite tekrar edilmedi. Kanıt JSON/katalog tutarlılığı ve belge/whitespace kontrolleri yapıldı.
**Kanıt:** [arındırılmış sonuç ve hash'ler](../experiments/cp5-c-codex.json); run `cp5-c-codex-20260929`, `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-codex-20260929/`: `commands.txt`, `summary.json`, `data/catalog.sqlite3`, `data/runs/` sahiplik kayıtları, `evidence-a/quit.json`, profil stat kayıtları. Ham terminal/model yanıtı veya kimlik bilgisi deney kanıtına yazılmadı.

**Doğrulanmadı:** gerçek Codex yeni/devam/kimlik devri/onay teslimi/aktif-tur Quit; Claude kalan kabulü ve tam C kabulü.
**Sonraki rol/adım — planner-reviewer:** model harcamayan app-server başlatma tanısı ve gerekiyorsa çıktı yakalama/düzeltme işini planla; tekrar sınırı ile gerçek deneyin yeniden açılışını netleştir. Mevcut dört tur harcanmadı; C/D/optimizer kapanmadı.


## 17. Codex başlangıç hatası incelemesi ve tanı düzeltmesi (29 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → implementer.
**Yanıt:** §16; kullanıcının Codex deneyindeki sorunu inceleme talimatı.
**Sonuç:** gerçek sunucunun neden hazır olmadığı **doğrulanmadı**; mevcut hata kök neden değil, son soket bağlantısının sonucudur. **Madde 8 [P2, C1]: erken app-server çıkış tanısı kayboluyor** bağımsız fixture ile doğrulandı. Ürün kodu değiştirilmedi, gerçek başlatma tekrarlanmadı, model turu 0. [Kanıt](../experiments/cp5-c-codex-diagnosis.json).

**Doğrulandı:** deney kataloğu salt okunur kontrol edildi: proje 1, sohbet/run/link 0. Kaynak ve uygulama hash'leri §16 ile aynı. Yerel `codex app-server --help` belirtilen Unix listen biçimini destekliyor; hesaplanan soket yolu 42 bayt, mevcut üst dizin 0700. Bunlar uzunluk/izin şüphesini desteklemiyor; tarihsel ortamın tümünü kanıtlamıyor. İzole profilin mevcut log verisi deneyden önceye ait; bu başarısız başlatmanın nedenini vermiyor. Login/model/config hatası veya socket uzunluğu kök neden diye atanmadı.

**Madde 8 — konum ve kanıt:** [CodexAppServerManager.swift:188](../../Sources/LoomCore/CodexAppServerManager.swift#L188) launch'ın döndürdüğü terminali bırakıyor; [197–212](../../Sources/LoomCore/CodexAppServerManager.swift#L197) erken lider çıkışını değerlendirmeden son bağlantı hatasına kadar bekliyor, ardından iç kaydı siliyor. PTY çıktısı mevcut endpoint scrollback'inde tutulabilse de manager bu çıktıyı kullanmıyor. Üretim manager/supervisor yoluna bağlanan izole shell fixture `LOOM_FIXTURE_STARTUP_FAILURE` yazıp **exit 42** ile çıktı. Manager **0,63 sn** sonra yalnız `Codex app-server connect: No such file or directory` döndürdü; ayırt edici metin ve çıkış kodu yoktu. Lease 0, canlı session 0 ve shutdown başarılıydı. Bu deney gerçek Codex'in exit 42 verdiğini iddia etmez; aynı yüzey hatasının farklı asıl hataları gizlediğini gösterir.

**Düzeltme işi ve kapanış ölçütleri:**
1. İç sunucunun başlangıç endpoint'ini/sonucunu izle; erken çıkışta süre sonuna kadar soket hatasıyla beklemek yerine aşamayı ve gerçek çıkış/sinyal sonucunu bildir. Sunucu çalışıyor fakat bağlantı hazır değilse mevcut timeout ve son bağlantı nedeni korunsun.
2. Yalnız başlangıç tanısı için sınırlı bellek çıktısını mevcut PTY sahiplik yolu üzerinden kullan; ek süreç sahibi veya sınırsız log oluşturma. Tanı token/kimlik bilgisi/ortam değeri sızdırmamalı, gerçek sağlayıcının ham çıktısı varsayılan olarak deney dosyalarına yazılmamalı. İlgili güvenli hata ayrıntısı kullanıcıya ulaşsın; test marker'ı fixture kanıtında açıkça doğrulanabilsin.
3. Erken stderr+nonzero exit, sessiz nonzero exit, sinyalle çıkış, yaşayan ama socket açmayan sunucu ve başarılı gecikmiş başlangıcı kapsayan dar regresyonlar ekle/çalıştır. Başarısızlık ve başlangıçta Quit sonrası lease/süreç kalmaması da kontrol edilsin. Düzeltmesiz fixture tanısının kaybı gösterilsin. İlgili manager/runtime başlatma testleri yeterli; tam suite gerekmez.

**Sonraki adım/yetki:** implementer kullanıcı yönlendirdiğinde yalnız bu tanı düzeltmesini ve sentetik kontrolleri yapıp §18'e raporlasın. Gerçek Codex'in kök nedeni için sonraki adım, düzeltilmiş tanı yoluyla izole **model istemsiz** başlatma gözlemidir; bu inceleme önceki “tekrar 0” sınırını kaldırmaz ve gerçek başlatma burada yapılmadı. Bu ayrı sıfır-tur tekrarın yetkisi netleştirildikten sonra yalnız ilk hatayı açıklayacak şekilde yürütülmeli; model turlarına otomatik devam edilmemeli. **Codex 0/4 harcandı, kalan 4; Claude ek yetki 0.** C kabulü ve kalan deneyler açık. Bu oturum implementer başlatmaz/mesaj göndermez.

**Kontroller:** bağımsız sahte-sunucu repro, salt okunur katalog/hash/yardım/izin incelemesi, belge/JSON/whitespace. Tam suite veya gerçek model çalıştırılmadı. Kalıcı tanı kanıtı: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-codex-diagnosis-20260929/`.

## 18. App-server başlangıç tanısı düzeltmesi (29 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §17, madde 8.
**Sonuç:** **Madde 8 çözüldü, review bekliyor.** [Manager](../../Sources/LoomCore/CodexAppServerManager.swift) başlangıç endpoint'inin çıkışını izliyor; bekleme süresi dolmadan gerçek exit code/sinyal ve başlangıç aşamasını bildiriyor. Yaşayan fakat soket açmayan süreç için timeout ve son sistem bağlantı nedeni korunuyor. Başlangıçta Quit, ortak startup task'ını iptal ediyor; süreç temizliği mevcut supervisor üzerinden yapılıyor.

**Tanı sınırı:** mevcut PTY sink'i üzerinden ilk **16 KiB** bellek çıktısı tutuluyor. Ham satırları güvenli saymak yerine yalnız sabit hata kategorileri (ör. `permission denied`) UI hata metnine giriyor; bilinmeyen çıktı saklanıyor. Token, yol ve ortam değeri aktarılmıyor; gerçek çıktı dosyaya yazılmıyor. `LOOM_FIXTURE_STARTUP_FAILURE` tamponda yakalama testinde açıkça doğrulandı; public hata metninde ham marker veya satır yayımlanmıyor. Bu bilinçli sınır nedeniyle tanınmayan gerçek sağlayıcı mesajı ayrıntısının görünürlüğü **doğrulanmadı**.

**Doğrulandı:** [yeni dar testler](../../Tests/LoomCoreTests/CodexAppServerManagerTests.swift): stderr+exit 42, sessiz exit 7, SIGTERM 15, yaşayan/soketsiz timeout, gecikmiş başarılı başlangıç, başlangıçta Quit ve bounded çıktı/gizli değer aktarılmaması. Erken çıkışlar 3 sn deadline'a karşı 2 sn altında; başarısızlık ve Quit sonrası lease/canlı run 0, shutdown başarılı. Manager ve mevcut Codex runtime birlikte **21 test geçti**; `swift build` ve `git diff --check` geçti. Build'de mevcut SDK linker arama yolu uyarıları sürüyor. Tam suite çalıştırılmadı.

**Regresyon dayanağı:** §17'nin [düzeltmesiz fixture kanıtı](../experiments/cp5-c-codex-diagnosis.json) exit 42'nin kaybolduğunu gösteriyor. Bu tur öncesi manager kopyasının SHA-256'sı o incelemenin doğruladığı §16 kaynak hash'iyle aynı; önceki kayıp kanıtı yeniden çalıştırılmadı. Yeni stderr fixture'ı exit 42 ve güvenli kategoriyle geçti.

**Kanıt:** [arındırılmış sonuç/hash/karşılaştırma](../experiments/cp5-c-startup-fix.json); kalıcı run `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-startup-fix-20260929/` (`tests.log`, `build.log`, `commands.txt`, `summary.json`, `manager-before.swift`).
**Doğrulanmadı / engel:** gerçek Codex başlangıcının kök nedeni, bu revizyonun paketli native UI davranışı ve kalan gerçek sağlayıcı kabulü. Gerçek sağlayıcı başlatılmadı; **Codex 0/4, tekrar 0; Claude ek yetki 0** değişmedi.
**Sonraki rol/adım — planner-reviewer:** madde 8 ve dar kanıtı incele; ayrı model istemsiz gerçek başlangıç gözlemi için tekrar yetkisini netleştir. C kabulü kapanmadı.


## 19. Başlangıç tanısı review ve sıfır-tur gözlem kapısı (29 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → kullanıcı / sonraki uygulayıcı.
**Yanıt:** §18, madde 8.
**Sonuç:** **Madde 8, sınanan başlangıç tanısı kapsamında kapandı.** Erken çıkış/sinyal ile yaşayan sunucunun bağlantı timeout'u ayrılıyor; iptal mevcut supervisor temizliğinden geçiyor. Gerçek Codex başlatma hatasının nedeni ve C'nin tam kabulü açık. [Kanıt](../experiments/cp5-c-startup-review.json).

**Doğrulandı:** §17'deki aynı exit-42 fixture'ı güncel manager ile bağımsız çalıştırıldı. Önceki genel soket hatasının yerine `exited during startup (exit code 42)` ve bilinmeyen çıktının gizlendiği bilgisi geldi; süre yaklaşık **0,14 sn**, lease **0**, canlı session **0**, shutdown başarılı. Dar manager + Codex runtime **21 test, exit 0**: erken stderr/sessiz çıkış/sinyal, yaşayan soketsiz timeout, gecikmiş başarı, başlangıçta Quit, çıktı kotası ve mevcut Codex davranışları geçti. Kaynak hash'leri §18'le eşleşiyor ve review boyunca değişmedi. `git diff --check` temiz; test derlemesi başarılı. Tam suite çalıştırılmadı.

**Tanı sınırı:** marker'ın public hata metnine taşınmaması kabul edildi; bounded tampon testi yakalamayı, public kategori testi gizli değer aktarılmamasını ayrı doğruluyor. Yalnız sabit kategorilerin görünmesi bilinmeyen gerçek CLI mesajının kök nedenini açıklamayabilir. Bu nedenle gerçek başlangıç sorunu çözüldü denmiyor. Paketli native UI bu revizyon için tekrar denenmedi; mevcut uygulama hata iletim yolu korunuyor. Yeni ürün kodu değişikliği yok.

**Sonraki karar — tek model istemsiz gözlem:** önceki “tekrar 0” sınırına yalnız **bir gerçek Codex başlatma gözlemi** için istisna istenir. Yetki verilirse kullanıcı uygulayıcıyı yönlendirir: bu kaynakla dev paketi yenile; mevcut izole Codex profili, ayrı deney kataloğu ve boş klasörle bir kez başlat; hata çıkış/sinyal/kategorisini veya hazır olmayı kaydet; hiçbir model istemi gönderme ve normal Quit/temizliği doğrula. Ham çıktı/kimlik bilgisi kaydetme. Sonucu §20'ye yazıp review'a dön; başarısızsa ikinci kez deneme, başarılı olsa bile dört model adımına kendiliğinden devam etme. Yetki öncesi gerçek sunucu bu tur başlatılmadı.

**Bütçe/durum:** Codex **0/4 harcandı, kalan 4**, model tekrar payı 0; Claude ek yetki 0. Bu ayrı gözlem model turu tüketmez; önceki başlatma-tekrar sınırını kendiliğinden kaldırmaz. C ve ertelenen kabul kapıları açık. Bu oturum implementer başlatmaz/mesaj göndermez.

## 20. Yetkili model istemsiz Codex başlangıç gözlemi (29 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §19; kullanıcının “bütçe iznini veriyorum … inceleyip ilerle” talimatı.
**Sonuç:** **Tek model istemsiz gerçek başlangıç gözlemi yapıldı; Ready doğrulanamadı.** Güncel kaynakla release dev paketi yenilendi ve imzası doğrulandı. Mevcut izole Codex profili, ayrı katalog ve yeni boş çalışma klasörü kullanıldı. Native proje menüsünden bir başlatma eylemi uygulandı. Profil config'i değiştirilmedi.

**Doğrulandı:** önceki app-server soket hatası tekrarlanmadı. Üretim akışının remote TUI run'ını oluşturup kimlik beklemeye ulaşması, app-server bağlantı/initialize aşamasının geçildiğinin kaynak ve katalog dayanağıdır; önceki başarısızlığın düzeldiğini veya nedenini kanıtlamaz. Native UI sonucu: `Codex could not be started: codex did not report its conversation identity in time; the start was undone`. Kart **Problem**, **Not running**, provider conversation **Not assigned yet**, Stop pasif. Katalog proje/sohbet/run/link **1/1/1/1**, provider kimliği null, bitmemiş run **0**. Run bitişi `requested`; kayıtlı wait status `1` geri alma sonrası sonuçtur, CLI'ın kendiliğinden exit code 1 verdiği diye yorumlanmadı.

**Başarısız / açık:** TUI kimliği süre içinde alınmadığı için hazır başlangıç kabulü geçmedi. Kimlik zaman aşımının nedeni **doğrulanmadı**; güven ekranı, model veya protokol uyumsuzluğu varsayılmadı. Başarısızlık sonrasında kimliği olmayan, çalışmayan Problem kartı kalması gözlendi; bu kayıt canlı hayalet süreç kanıtı değildir.

**Temizlik/kontroller:** native Cmd+Q başarılı; `quit.json` **succeeded=true, remaining=0, errors=[]**, uygulama ve TUI PID'leri kapanış sonrası yok. Kaynak hash'leri değişmedi. Paketleme build/signature başarılı; mevcut SDK arama yolu uyarıları dışında hata yok. Kod değişmediğinden kabul edilmiş 21 dar test/tam suite tekrarlanmadı. JSON/katalog tutarlılığı ve `git diff --check` kontrol edildi. Gerçek profillere deney yazmadı; yalnız üst düzey stat kaydı alındı. Ham terminal/yanıt/kimlik bilgisi saklanmadı.

**Bütçe:** ayrı başlatma gözlemi **1/1** kullanıldı; **model istemi 0**, Codex **0/4 harcandı, kalan 4, model tekrar payı 0**; Claude ek yetki 0. İkinci gerçek başlangıç veya model adımı yapılmadı.
**Kanıt:** [arındırılmış sonuç/hash/katalog/Quit özeti](../experiments/cp5-c-startup-observation.json); `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-startup-observation-20260929/` (`package.log`, `summary.json`, `commands.txt`, `catalog-before-quit.json`, `data/catalog.sqlite3`, `data/runs/`, `evidence/quit.json`). Native hata/kart gözlemi CUA üzerinden anlık yapıldı; ham ekran dosyası tutulmadı.
**Sonraki rol/adım — planner-reviewer:** kimlik zaman aşımını ve kalan Problem kartını değerlendir, gerekli tanı/uygulama işini planla. Önceki app-server hatasının kök nedeni ve gerçek sağlayıcı kabulü açık; C kapanmadı.


## 21. Kimlik beklerken gizli terminal: inceleme ve düzeltme işi (29 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → implementer.
**Yanıt:** §20 ve kullanıcının süren sorunu inceleme talimatı.
**Sonuç:** app-server bu denemede initialize aşamasını geçmiş; hata farklı aşamada, remote TUI kimliği beklenirken oluşmuş. **Madde 9 [P1, C1]: kimlik öncesi terminal etkileşimi kullanıcıya kapalı** kaynak ve bağımsız sentetik çalışmayla doğrulandı. Gerçek denemedeki TUI'nin tam olarak ne beklediği **doğrulanmadı**. Ürün kodu değişmedi, gerçek başlangıç tekrarlanmadı, model turu 0. [Kanıt](../experiments/cp5-c-identity-review.json).

**Neden:** [ConversationController.swift:142](../../Sources/LoomCatalogUI/ConversationController.swift#L142) `startConversation` tamamlanmadan terminali `adopt` etmiyor; görünüm ve endpoint/girdi bağlantısı ancak dönüşte kuruluyor. [SessionRuntime.swift:578](../../Sources/LoomCore/SessionRuntime.swift#L578) Codex run'ını kaydetmesine rağmen `waitForNewLaunch` kimliği gelene kadar bu dönüşü bekletiyor. Dolayısıyla sağlayıcı thread oluşturmadan önce giriş/güven/izin/onboarding veya başka kullanıcı girdisi beklerse terminal görünmez ve girdi alamaz. Kimlik süresi dolunca run geri alınır. Çıktının görünmeyen surface'e ulaşması bu etkileşim eksikliğini çözmez. Gerçek olayda hangi ekranın beklendiği bu kod kanıtından çıkarılamaz.

**Başarısız — bağımsız repro:** üretim CatalogModel → ConversationController → runtime/PTY/coordinator yolunda, yalnız sahte remote sağlayıcının thread oluşturmadan önce bir satır girdi beklediği wrapper kullanıldı. Bekleme marker'ı oluştu, canlı run **1**, controller terminali **0**, terminal görünümü **yok**; ardından aynı kimlik-timeout hatası ve canlı run **0**. **Olumlu kontrol:** aynı wrapper'ın girdi kapısı bypass edilince kimlik geldi, terminal **1**, hata **yok**, run canlı kaldı. İki denemenin shutdown'ı başarılı. Gerçek Codex/model kullanılmadı; bu fixture gerçek olayın ekranını taklit ettiği iddiasında değildir. Kanıt: `repro.swift`, `provider-blocked.sh`, `provider.sh`, `repro.log`, `control.log` (kontrolde `/tmp/loom-identity-review/bypass-input` dosyası vardır).

**Düzeltme kapsamı/sırası:**
1. PTY/run hazır oluşunu sağlayıcı kimliği hazır oluşundan ayır. Kimlik bekleyen run'ın terminali doğru geçici kartta hemen görünür ve kullanıcıya etkileşilebilir olsun; kimlik geldiğinde aynı run/surface korunarak normal bağlama tamamlansın. Kimlik tahmini, ekran metni çözümleyerek onay verme veya otomatik güven kabulü yok.
2. Kimlik henüz yokken görünür dürüst başlangıç durumu ve Stop/iptal/Quit çalışsın; kullanıcı etkileşiminde geçen süreyi kör bir kısa kimlik-timeout ile başarısızlık sayma. Yalnız timeout sayısını büyütmek çözüm değildir. Gerçek erken çıkış/bağlantı kaybı doğru aşamayla bildirilsin; iptal edilen run sonradan gelen kimlikle yeniden sahiplenilmesin.
3. Mevcut reservation sırası, aynı anda başlatma koruması, lease/PTY sahipliği ve `/new` eski-kart sınırı korunsun. Gecikmiş veya çakışan kimliği yanlış karta bağlama. Kimlik bekleyen başlangıcın daha sonra hata vermesi terminali ve süreçleri sahiplik dışında bırakmasın.
4. Kimlikten önce kullanıcı girdisi bekleyen fixture ile controller sınırında terminalin görünür/girdiye bağlı olduğunu, girdiden sonra aynı run'ın kimlik aldığını doğrula. Beklerken Stop/Quit, erken çıkış, geç kimlik/iptal, normal doğrudan kimlik ve mevcut new/resume akışları dar test kapsamıdır. Fixture üzerinde native girdi smoke'u da yap; tam suite gerekmez. Başarısızlığı timeout'a kadar gizleyen eski kodda regresyonun başarısızlığını göster.

**Problem kartı değerlendirmesi:** gerçek kataloğu salt okunur doğruladım: **1/1/1/1**, provider kimliği null, run `requested` ile bitmiş. Kaynak hash'leri deneyle aynı. Bu çalışmayan hata kaydı canlı hayalet süreç değildir; silme veya geçmişi gizleme işi açılmıyor. Raw wait status 1'in başlatma kök nedeni olduğu iddia edilmiyor. Önceki soket hatasının tarihsel nedeni de açık kalır.

**Sonraki rol/adım — implementer:** kullanıcı yönlendirdiğinde madde 9'u uygula, dar test/native fixture kanıtını §22'ye ekleyip review'a dön. Bu düzeltme/model kullanmayan fixture çalışması için ek model bütçesi gerekmez. Tek gerçek başlangıç gözlemi 1/1 kullanıldı; yeni gerçek sağlayıcı tekrarı bu incelemeyle yetkilendirilmedi. Codex 0/4 model turu, Claude ek yetki 0. C kabulü açık; bu oturum implementer başlatmaz/mesaj göndermez.

## 22. Kimlik öncesi etkileşim düzeltmesi (29 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §21, madde 9; kullanıcının düzeltmeyi uygulama talimatı.
**Sonuç:** **Madde 9 çözüldü, review bekliyor.** [Runtime](../../Sources/LoomCore/SessionRuntime.swift) Codex PTY/run kaydolduğunda terminal-ready callback'i veriyor; [controller](../../Sources/LoomCatalogUI/ConversationController.swift) aynı surface'i hemen bağlayıp geçici kartı seçiyor. Kimlik geldikten sonra ikinci terminal oluşturulmuyor veya kullanıcının seçimi tekrar değiştirilmiyor. [Başlık](../../Sources/LoomCatalogUI/DetailView.swift) kimlik beklerken `Starting — complete any prompts in the terminal` gösteriyor; Stop kullanılabilir.

**Bekleme/iptal:** etkileşimli callback kullanan başlangıç kısa kimlik deadline'ına bağlı değil; kullanıcının sağlayıcı istemini tamamlaması, Stop/Quit, erken çıkış veya bağlantı kaybı beklemeyi bitiriyor. Terminal bağlamayan headless çağrıların mevcut deadline'ı korunuyor. Reservation ve start-key koruması kimlik beklerken bırakılmıyor; mevcut lease/PTY sahibi değişmedi. Stop/Quit normal iptal olarak ele alınıyor, erken çıkış ve bağlantı kaybı kimlik-öncesi aşamayla bildiriliyor. Otomatik güven/onay kabulü veya terminal metninden kimlik çıkarımı yok.

**Doğrulandı — dar testler:** **34 test geçti** (core **22**, controller **12**). Yeni [controller fixture testleri](../../Tests/LoomCatalogUITests/ConversationControllerTests.swift) kimlik öncesi görünür/girdiye bağlı terminali, headless deadline sonrasında canlı beklemeyi, girdiden sonra aynı surface/run'ı, duplicate-start engelini ve beklerken Stop/Quit/erken çıkış/bağlantı kaybı temizliğini doğruluyor. [Matcher testi](../../Tests/LoomCoreTests/CodexAppServerTests.swift) iptalden sonra gelen kimliği ve sonraki reservation'ın sequence sınırını kontrol ediyor. Mevcut doğrudan new/resume, çoklu oturum, `/new` sahiplik devri ve eski kart sınırı testleri geçti. Son `swift build`, release paketleme/imza ve `git diff --check` başarılı; mevcut SDK arama yolu uyarıları sürüyor. Tam suite çalıştırılmadı.

**Doğrulandı — native fixture smoke:** ayrı katalog ve boş klasörde yalnız sahte sağlayıcı çalıştı. Kimlik null iken `BEFORE-IDENTITY` istemi terminalde görünür, Starting başlığı ve Stop düğmesi açıktı; native `continue` + Return sonrası aynı session/run/PID'ye kimlik bağlandı. Native Stop sonrası Not running/Stop pasif/Resume açık; Cmd+Q **succeeded=true, remaining=0, errors=[]**. Bitmemiş run 0, uygulama/TUI PID'leri yok. Aynı surface korunması controller testinin; native girdi ve görünürlük CUA gözleminin; aynı run/PID/kimlik geçişi iki salt okunur katalog kaydının kanıtıdır.

**Regresyon dayanağı:** §21'in [bağımsız düzeltmesiz repro'su](../experiments/cp5-c-identity-review.json) aynı girdi-öncesi davranışta canlı run 1 / terminal 0 ve timeout gösteriyor; gate bypass kontrolü başarılı. Bu tarihsel başarısızlık kanıtı korundu, ortak çalışma ağacını geri alarak tekrar çalıştırılmadı. Yeni fixture testleri ve native smoke düzeltme sonrası sonucu gösteriyor.

**Kanıt:** [sonuç ve hash'ler](../experiments/cp5-c-identity-fix.json); `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-identity-fix-20260929/` (`tests.log`, `build.log`, `package.log`, `commands.txt`, `scoped.diff`, `native-before-input.json`, `native-after-input.json`, `native/quit.json`, `data/catalog.sqlite3`, fixture wrapper/binary). Kaynakların tur öncesi kopyaları aynı run'da tutuldu.
**Doğrulanmadı:** gerçek Codex'in kimlikten önce beklediği ekran ve tarihsel başlangıç nedenleri; kalan gerçek sağlayıcı kabulü. Gerçek sağlayıcı başlatılmadı, model turu 0; Codex 0/4, gerçek başlangıç gözlemi 1/1 kullanılmış, Claude ek yetki 0 değişmedi.
**Sonraki rol/adım — planner-reviewer:** madde 9'u, etkileşimli bekleme/iptal sınırını ve dar/native kanıtı incele. Gerçek başlangıç tekrarını ayrıca planla; C kabulü kapanmadı.

## 23. Gerçek Codex: görünür terminalde dizin uyuşmazlığı (29 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** kullanıcının §22 sonrası açık “gerçek codex testi başlat” talimatı.
**Sonuç:** bir gerçek başlangıç yapıldı; terminal görünür ve native girdiye bağlı, fakat doğru proje/kimlik ön koşulu geçmedi. Başlamadan kaynak ve dev paketi hash'lerinin §22 ile eşleştiği doğrulandı. Mevcut izole Codex profiliyle ayrı katalog ve yeni boş proje klasörü kullanıldı; profil config'i değiştirilmedi.

**Doğrulandı:** gerçek `codex-cli 0.158.0` terminali açıldı. Native `/status` komutu işlendi; sağlayıcı Session kimliği gösterdi, model `GPT-6-Astra` medium, izin `Read Only (Ask for approval)`, **Directory `~`** idi. Buna karşılık Loom kataloğundaki working directory boş deney `workspace` klasörü; provider kimliği **null**, başlık **Starting** kaldı. Terminal bir güven ekranında görünmez biçimde kilitlenmedi; bu denemede giriş istemi gösteren bir güven/onboarding ekranı gözlenmedi. §22'nin görünürlük/girdi davranışı gerçek TUI'de doğrulandı; önceki denemelerin ekranı hakkında geriye dönük kesin sonuç çıkarılmadı.

**Başarısız / çıkarım:** doğru proje dizini ön koşulu başarısız. [Matcher](../../Sources/LoomCore/CodexSessionState.swift) directory eşitliği istiyor; [runtime](../../Sources/LoomCore/SessionRuntime.swift) ortak app-server'ı home directory ile başlatıyor, [remote profil](../../Sources/LoomCore/ProviderLaunchProfile.swift) yalnız `--remote` adresi veriyor. Gözlenen `~` ile proje klasörü farkının kimlik eşleşmesini engellemesi güçlü bir adaydır; bu tur `thread/started` payload'ı yakalanmadığı için kesin neden veya gerekli CLI parametresi ilan edilmedi. Model istemi yanlış dizinde gönderilmedi; yeni/devam/onay/aktif-tur kabul adımları çalıştırılmadı.

**Temizlik:** native Stop sonrası kart Not running, Stop pasif, provider kimliği atanmadı; bekleyen başlangıç kullanıcı iptaliyle temiz sonlandı. Normal Cmd+Q **succeeded=true, remaining=0, errors=[]**. Uygulama ve TUI PID'leri yok; katalog proje/sohbet/run/link **1/1/1/1**, bitmemiş run **0**.
**Kontroller/bütçe:** ürün kodu değişmedi; build/suite tekrarlanmadı. Kaynak/paket hash eşleşmesi, salt okunur katalog, Quit JSON, PID yokluğu ve whitespace kontrol edildi. Bu talimatla gerçek başlangıç **1**; **model istemi 0**, Codex **0/4 harcandı, kalan 4**; Claude ek yetki 0. İkinci başlangıç yapılmadı. Ham terminal, yanıt veya kimlik bilgisi dosyaya yazılmadı.
**Kanıt:** [arındırılmış sonuç](../experiments/cp5-c-real-after-identity.json); `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-real-after-identity-20260929/` (`summary.json`, `commands.txt`, `catalog-before-stop.json`, `data/catalog.sqlite3`, `evidence/quit.json`). Terminal ve `/status` gözlemi anlık CUA üzerinden yapıldı.
**Sonraki rol/adım — planner-reviewer:** §22 düzeltmesinin review'unu ve yeni dizin uyuşmazlığını değerlendir; remote TUI'nin proje dizinini sunucuya nasıl ilettiğini ve gelen kimlik olayını doğrulayacak dar işi planla. C kabulü ve gerçek model adımları açık.

## 24. Remote çalışma dizini düzeltmesi ve ilk gerçek model turu (29 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §23; kullanıcının “fixle devam edelim” talimatı.
**Sonuç:** **Dizin aktarımı düzeltildi ve gerçek başlangıç/model yanıtıyla doğrulandı; bütün C kabulü geçmedi.** Kurulu `codex-cli 0.158.0` yeni/resume yardımında `--cd <DIR>` desteği doğrulandı. [Remote profil](../../Sources/LoomCore/ProviderLaunchProfile.swift) artık çalışma dizinini zorunlu alıp ayrı argv elemanı olarak `--cd` ile iletiyor. [Yeni başlangıç](../../Sources/LoomCore/SessionRuntime.swift) proje dizinini, [resume](../../Sources/LoomCore/ProviderResume.swift) kayıtlı oturum dizinini geçiriyor. Ortak sunucunun home dizini değişmedi; probe çağrıları yeni profile uyarlandı.

**Doğrulandı — sentetik:** fixture remote yolunda PTY cwd'sini otomatik taşımak yerine açık `--cd` kullanılıyor; yoksa home varsayımı uygulanıyor. Bu, önceki fixture'ın dizin eksikliğini örtmesini önlüyor. macOS canonical cwd gösterimi `chdir` sonrası okunuyor. Mevcut proje/new/resume/controller akışları ve boşluk/Unicode içeren resume argümanı dahil **32 test geçti** (core 20, controller 12). `swift build`, release paketleme/imza ve `git diff --check` başarılı; SDK arama yolu uyarıları mevcut. Tam suite çalıştırılmadı. Düzeltmesiz gerçek davranışın dayanağı §23: terminal home, katalog proje, kimlik null.

**Doğrulandı — gerçek:** ayrı katalog/boş klasör ve mevcut izole Codex profiliyle tek yeni başlangıç. Terminal doğru deney klasörü için Folder access ekranı gösterdi; yalnız oluşturulan boş klasörde native devam seçildi. Ardından provider kimliği aynı karta bağlandı, Starting sonlandı. Terminal çalışma dizini proje klasörüydü. §15 tur 1 istemi native gönderildi; Working görüldü ve gerçek modelin beklenen `LOOM_C_R5` yanıtı ekranda doğrulandı. Görünen model GPT-6-Astra; ham yanıt/ekran dosyası tutulmadı.

**Başarısız / yeni açık davranış:** `/new` gönderilmediği halde ilk model turunda aynı run ikinci provider kimliğine/karta taşındı; yeni kart **Problem** oldu. Salt okunur katalog iki sohbet/bir run/iki run-session bağlantısıyla bu devri doğruluyor. Native Stop ardından **Stop not verified**, bildirilen kalan süreç **0**; doğrulanamayan provider aşamasının ayrıntısı bu tur yakalanmadı. Bunların nedeni **doğrulanmadı**; doğrudan CLI thread yaşam döngüsü veya Loom eşleme hatası diye kesinleştirilmedi. Başarısız yeni-oturum kabulü nedeniyle kalan model adımları tekrarlanmadı/çalıştırılmadı.

**Temizlik:** normal Cmd+Q başarılı, **remaining=0, errors=[]**; uygulama/TUI PID'leri yok. Tek run `applicationQuit` ile bitmiş, bitmemiş run 0. Başarılı Quit, başarısız Stop kabulünün yerine geçmez.
**Bütçe:** Codex **1/4 model turu harcandı, kalan 3, tekrar 0**; bu tur bir gerçek yeni başlangıç; Claude ek yetki 0. Profil config'i değiştirilmedi. Gerçek resume, onay ve aktif-tur Quit **doğrulanmadı**.
**Kanıt:** [arındırılmış sonuç/hash/kontrol özeti](../experiments/cp5-c-cwd-fix.json); `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-cwd-fix-20260929/` (`tests.log`, `build.log`, `package.log`, `commands.txt`, `scoped.diff`, `real-start-catalog.json`, `real-bound-catalog.json`, `real-after-turn-catalog.json`, `data/catalog.sqlite3`, `real-a/quit.json`). Gerçek terminal gözlemleri anlık CUA üzerinden; kayıtta yalnız beklenen belirteç sonucu ve yapısal kanıt var.
**Sonraki rol/adım — planner-reviewer:** §22 ve bu dizin düzeltmesini review et; ilk turdaki kimlik devri/Problem ve Stop doğrulama sonucunu inceleyip dar sonraki işi planla. C kapanmadı.


## 25. Altıncı review: etkileşim/dizin kabulü ve geçici thread devri (29 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → implementer.
**Yanıt:** §22–24; kullanıcının biriken implementasyon/fix'leri inceleme talimatı.
**Sonuç:** **Madde 9 kapandı; açık remote cwd aktarımı kabul edildi.** C bütünü kabul edilmedi. **Madde 10 [P1, C2/C5]: geçici thread kullanıcı konuşmasının yerine bağlanabiliyor** bağımsız router deneyiyle doğrulandı. Gerçek deneyin beklenmeyen devir ve Stop sonuçları ayrıca açık. [Kanıt](../experiments/cp5-c-review6.json).

### 25.1. Kapanan düzeltmeler

Terminal-ready callback'i kimlikten önce aynı surface/endpoint'i bağlar; etkileşimli bekleme Stop/Quit/erken çıkış/bağlantı kaybıyla biter, headless deadline korunur. Bağımsız controller testleri görünür terminal, native olmayan girdi yolu, aynı surface/run, beklerken iptal ve kaynak temizliğini doğruladı. §22'nin native fixture ve §23–24'ün gerçek görünür terminal gözlemleri devralındı; yeniden gerçek sağlayıcı açılmadı.

Remote profil new/resume için `--cd` değerini ayrı argv elemanı olarak geçiriyor; resume kayıtlı dizini kullanıyor, ortak sunucu cwd'si değişmiyor. Fixture artık eksik aktarımı PTY cwd'sinden örterek yanlış geçiş vermiyor. Boşluk/Unicode argümanı ve ilgili new/resume testleri geçti. §24 kaynak hash'leri mevcut kaynakla eşleşti; gerçek doğru dizin/ilk kimlik ve yanıt gözlemi deney raporuna dayanır, bağımsız model turuyla tekrarlanmadı.

### 25.2. Açık madde 10 — ephemeral thread'i kimlik devri sayma

[CodexSessionState.swift:351](../../Sources/LoomCore/CodexSessionState.swift#L351) router'ın yeni konuşma yolunda yalnız cwd ile aday arıyor; ilk launch matcher'daki `identity.ephemeral != true` koşulu burada yok. Bir bağlı run varsa aynı dizindeki `ephemeral=true` thread için `.newConversation` döndürülüyor. [Coordinator](../../Sources/LoomCore/CodexSessionCoordinator.swift#L205) bu kararla katalog kimliğini/kartı değiştirip Stop hook'larını yeni thread'e bağlıyor. Dolayısıyla yardımcı thread, görünür TUI'nin konuşması yerine geçebiliyor; eski konuşmanın olayları da artık yanlış/unmatched kalabilir. İki aynı-dizin binding varsa aynı yardımcı olay gereksiz ambiguity yaratabilir.

**Başarısız — bağımsız sentetik kanıt:** gerçek router'a önce `user-thread` binding'i, ardından aynı cwd'de `ephemeral-helper`, `ephemeral=true`, source `exec` olayı verildi. Sonuç **`newConversation(previous: user-thread, identity: ephemeral-helper)`**. Model/sağlayıcı çalışmadı. İlk eşlemenin ephemeral filtresi tek başına yeterli değil; reddedilen olay router'ın sonraki yoluna düşebiliyor.

**Gerçek kanıtın sınırı:** salt okunur katalog §24'teki **2 sohbet / 1 run / 2 bağlantı** ve son `applicationQuit` kaydını doğruluyor. Gerçek ikinci thread'in özgün `thread/started` alanları saklanmadığından, bu örnekte de ephemeral olduğu kesin ilan edilmiyor. İzole sağlayıcı metadata/log incelemesi tek başına eksik olay payload'ının yerine geçmez. Stop'un doğrulanmama nedeni de yakalanmamış; başarılı Quit bu açığı kapatmaz.

**Düzeltme/kapanış işi:**
1. Ephemeral thread'in ilk bağlama, yeni konuşma devri veya ambiguity üretmesini engelle; aynı cwd'nin tek başına yardımcı thread'i kullanıcı konuşması yaptığı varsayımını kaldır. Bilinen normal `/new` davranışını koru; kaynak/kimlik bilgisi yetersizken kalıcı yanlış devir yapma, kesin olmayan ilişkiyi görünür ve muhafazakâr ele al. Terminal metninden `/new` tahmini veya otomatik kullanıcı eylemi üretme.
2. Regresyon: ilk reservation ve bağlı run varken ephemeral olay; aynı dizinde birden fazla binding; yardımcı thread'den sonraki status/idle olayı. Kullanıcı kartı/provider kimliği/run sahibi değişmemeli, yanlış Problem/ambiguity oluşmamalı, Stop hook'u asıl thread'e bağlı kalmalı. Ephemeral olmayan geçerli `/new`, eski-kart sınırı ve resume testlerini koru. Önceki router bu regresyonu geçmemeli.
3. Gerçek beklenmeyen devir/Stop sonucunu açıklayabilmek için yalnız yapısal tanı kaydet: olay türü/sırası, thread/run/session kimliği, cwd eşleşme sonucu, ephemeral/source/originator sınıfları, routing kararı; Stop için provider prepare/completed aşaması ve güvenli RPC hata kodu/kategorisi ile süreç kalan sayısı ayrı olsun. Prompt, yanıt, token veya ham terminal/ortam içeriği kaydedilmesin. Bu kayıt modeli tekrar çalıştırmayı gerektirmez; fixture ile doğrula.
4. Sadece ilgili router/coordinator/runtime/controller/Stop regresyonlarını çalıştır. Sonucu §26'ya yazıp review'a dön. Gerçek model adımlarını başarısız yeni-oturum deneyi üzerinden otomatik sürdürme; kalan 3 tur mevcut planın resume/onay/aktif-Quit adımlarına ait, başarısız ilk adım için tekrar payı değildir.

### 25.3. Kontroller ve sonraki adım

**Doğrulandı:** bağımsız dar test **38/38** (26 core: router/profil/Codex runtime; 12 controller), test derlemesi, `git diff --check`; ilgili kaynak hash'leri ve gerçek katalog yapısı. **Başarısız:** §25.2 router repro. **Doğrulanmadı:** gerçek devrin kesin nedeni, Stop hata aşaması, gerçek resume/onay/aktif-tur Quit ve tam C. Tam suite/native/gerçek model tekrarı yapılmadı; ürün kodu değiştirilmedi.

Kalıcı kanıt: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-review6-20260929/`; [özet](../experiments/cp5-c-review6.json). **Sonraki rol/adım — implementer:** kullanıcı yönlendirdiğinde madde 10'u uygula ve Stop tanısını görünür kıl. Codex **1/4 harcandı, kalan 3, tekrar 0**; Claude ek yetki 0. Bu oturum implementer başlatmaz/mesaj göndermez; C ve D/optimizer kapanışı açık kalır.

## 26. Geçici thread filtresi ve yapısal Stop tanısı (29 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §25.2, madde 10.
**Sonuç:** **Madde 10 için düzeltme uygulandı; kabul review bekliyor.** [Router](../../Sources/LoomCore/CodexSessionState.swift) ephemeral veya `exec` kaynaklı başlangıcı eşleme/devir/ambiguity yollarından önce eliyor. İlk bağlama ve normal devir için açık `ephemeral=false` ve mevcut desteklenen `cli`/`vscode` kaynağı gerekiyor; eksik/bilinmeyen metadata, aynı dizindeki adayları belirsiz gösteriyor fakat kalıcı kimliği devretmiyor. Terminal metninden eylem çıkarılmıyor.

**Doğrulandı:** yeni regresyon eski router üzerinde üç beklentide başarısız oldu (`red.log`); düzeltmeden sonra ilk reservation, reservation ile mevcut binding, tek/iki aynı-dizin run ve yardımcı status/idle olayları geçti. Fixture'da kart/provider kimliği/run sahibi sabit, yanlış Problem/ambiguity yok; Stop hedefi asıl thread. Geçerli `/new`, eski kart sınırı ve resume korundu. İlgili **64 test geçti** (51 router/runtime/supervisor, 13 controller); `swift build`, `git diff --check` ve izlenmeyen değişen dosyaların whitespace kontrolü başarılı. Mevcut SDK arama yolu uyarıları sürüyor.

**Tanı:** [yapısal yönlendirme kaydı](../../Sources/LoomCore/CodexRoutingDiagnostics.swift) olay türü/sırası, thread/run/session kimlikleri, cwd eşleşmesi, ephemeral değeri ve sabit source/originator sınıflarıyla kararı tutuyor; ham cwd veya keyfî metadata kopyalanmıyor. Son 256 olay ve taşma sayısı saklanıyor. [Stop raporu](../../Sources/LoomCore/ManagedSession.swift) prepare/completed sonucu, hedef thread ve güvenli hata kategorisi/RPC kodunu süreç sayısından ayırıyor. Prepare başarısızlığında canlı süreçler örnekleniyor; örnekleme başarısızsa sayı bilinmiyor. Son 256 Stop tanısı sonraki başarılı temizlikte önceki hatayı kaybetmiyor. Controller hata aşamasını gösteriyor; evidence snapshot'ları ve Quit kaydı yapısal tanıyı içeriyor.

**Fixture kanıtı:** prepare RPC `-32041` run'ı canlı bırakıyor; completed RPC `-32042` sıfır kalan süreçle ayrı bir sağlayıcı hatası gösteriyor. Ham RPC mesajı ve keyfî originator değeri tanı/UI çıktısında yok. Controller aynı terminali/seçimi koruyor; JSON dışa aktarımı doğrulandı. İki eski Stop testi, ham hata metni yerine güvenli kategoriyle hatanın event state'te kalmasını doğrulayacak şekilde güncellendi.

**Kanıt:** [özet ve kaynak hash'leri](../experiments/cp5-c-ephemeral-fix.json); `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-ephemeral-fix-20260929/` (`red.log`, `tests.log`, `build.log`, `commands.txt`, `scoped.diff`, `before/`).
**Doğrulanmadı:** §24'teki gerçek ikinci thread'in özgün metadata'sı ve Stop'un tarihsel kesin nedeni; gerçek resume/onay/aktif-tur Quit ve C bütünü. Tam suite/native paket deneyi tekrarlanmadı; Quit evidence yazıcısının yeni async çağrısı derlendi, native çalıştırılmadı. Gerçek sağlayıcı/model turu **0**; Codex **1/4 harcandı, kalan 3, tekrar 0**, Claude ek yetki 0 değişmedi.
**Sonraki rol/adım — planner-reviewer:** madde 10'u, muhafazakâr metadata sınırını ve yapısal Stop/evidence değişikliklerini incele; gerçek kabulün sonraki adımını review sonrasında belirle.

## 27. Orca/Herdr explorer araştırması ve CLI/DevDay girdileri (30 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → planner-reviewer / kullanıcı.
**Yanıt:** kullanıcının yerel Orca + Herdr clone ile explorer swarm başlatma ve güncel CLI/DevDay taraması talimatları; §26 review'una araştırma girdisi.
**Sonuç:** Herdr `fb8b9e2e` yerel checkout'a alındı; mevcut Orca `2c92e5e7` üzerinden üç explorer kimlik, yaşam döngüsü ve terminal alanlarını inceledi. **27 desen/karar** kaynak, Loom karşılığı ve dar kontrol fikriyle kaydedildi. Thread→PTY korelasyonu veya OWN-1 için hazır/doğrulanmış çözüm bulunmadı. Yeni kapsam veya kabul kararı verilmedi.

**Yakın review girdileri:** aynı cwd'de ilgisiz interactive thread, pending approval'ın sibling/status olaylarıyla ilişkisi ve start iptalinde geç yanıtın kardeş oturuma etkisi. Güncel app-server belgesindeki `serverRequest/resolved` mevcut event modelinde yok; TUI'den cevaplanan isteğin Loom'da pending kalması fixture ile incelenecek adaydır, yeniden üretilmiş hata değildir. Kurulu CLI **0.158.0**, resmî 29 Eylül notları **0.159.0/0.159.1**; sürüm notları bizim kimlik/Stop hatalarının düzeldiğini kanıtlamıyor. DevDay'de SIWC OSS plan kullanımı, MCP Events ve plugin extensions gelecekte değerlendirilebilir; mevcut native TUI/auth/koordinasyon kapsamı değişmedi.

**Kanıt:** [Orca/Herdr kaynak araştırması ve öncelikler](../experiments/orca-herdr-logic-research-20260930.md), [CLI/DevDay resmi kaynakları ve sınırları](../experiments/openai-cli-devday-research-20260930.md). **Doğrulandı:** kaynak mekanizmaları, referans commit'leri, kurulu version ve resmî sayfa içerikleri. **Doğrulanmadı:** runtime kazançları, önerilen yarış senaryoları, yeni CLI davranışı ve §26 kabulü. Referans testleri/tam suite/provider/model çalıştırılmadı; CLI güncellenmedi, ürün kodu değiştirilmedi.

**Sonraki rol/adım — planner-reviewer:** §26 kabul review'unu mevcut §25.2 ölçütleriyle tamamla; yukarıdaki adayların ilgili fixture/test kapsamını kontrol et, yalnız kanıtlanan eksikleri bulgu yap. D/optimizer ölçüm adayları ve sonraki koordinasyon fikirleri araştırma kaydında kalır. Implementer başlatılmadı/mesaj gönderilmedi. Codex **1/4 harcandı, kalan 3, tekrar 0**; Claude ek yetki **0**. C açık.

## 28. Yedinci review: helper filtresi kabulü, Quit ve çözülmüş istek bulguları (30 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → implementer.
**Yanıt:** §26; kullanıcının review bekleyen işi inceleme talimatı. §27 araştırması yalnız ilgili kontrol adaylarını sağladı.
**Sonuç:** **Madde 10'un ephemeral/exec ve eksik metadata düzeltmesi kapandı; yapısal Stop/yönlendirme tanısı kabul edildi. C kabul edilmedi.** Yeni **madde 11 [P1, D3]** Quit yanıtının async geçişte bloke olması; **madde 12 [P2, C3/C4]** çözülmüş sağlayıcı isteğinin bekleme kaydında kalması. [Bağımsız kanıt](../experiments/cp5-c-review7.json).

### 28.1. Kabul edilen bölüm ve sınır

§26 kaynak hash'leri mevcut çalışma ağacıyla eşleşti. İlk reservation, bağlı run ve aynı-cwd çoklu run helper fixture'ları; kart/run/Stop hedefinin korunması; normal `/new`/resume ve belirsiz metadata testleri bağımsız geçti. Ek decoder/router deneyi `ephemeral=true, source=cli` ve `ephemeral=false, source=exec` kombinasyonlarını da unmatched doğruladı. Tanı ring'i, metadata sınıflandırması, prepare/completed RPC kategorisi ve süreç sayısının ayrı tutulması ilgili fixture'larda geçti; sonraki başarılı cleanup önceki başarısız tanıyı silmiyor.

Bu kabul, metadata filtresinden geçen her interactive thread'in belirli TUI'ye ait olduğunun genel kanıtı değildir. Aynı-cwd korelasyonunun protokol sınırı araştırma kaydında kalır; olası ilgisiz interactive thread bu tur yeni bir runtime hata olarak ilan edilmedi. Tarihsel gerçek devir/Stop nedeni ve gerçek sağlayıcı kabulü hâlâ doğrulanmadı.

### 28.2. Madde 11 — Quit yanıtını MainActor task'ına geri taşıma

**Bulgu [P1]:** [AppDelegate.swift:113–114](../../Sources/loom-app/AppDelegate.swift#L113) `requestQuit` callback'inde yeni `Task` açıyor. [TerminalRunController.swift:112–129](../../Sources/LoomTerminal/TerminalRunController.swift#L112) callback'i özellikle main queue içindeki nested run-loop'ta MainActor task çalışamadığı için common-mode perform ile teslim ediyor. Yeni task katmanı bu korumayı geri alıyor; `quitFinished` içindeki `NSApp.reply` ve başarısız Quit'in retry arayüzü nested bekleme bitene kadar ulaşamayabilir. `evidence == nil` olsa da task geçişi koşulsuz.

**Başarısız — bağımsız repro:** mevcut derlenmiş `TerminalRunController` ile main-queue bloğunda nested default-mode run-loop çalıştırıldı. Aynı başarılı synthetic shutdown raporu/doğrudan callback için yanıt **true**; AppDelegate'in yeni `Task { @MainActor ... }` bağlantısı için 1 saniye içinde yanıt **false**. Mevcut `quitReplyArrivesInsideMainQueueNestedRunLoop` ve failure/retry testleri geçti; bunlar AppDelegate'in ek task'ını kapsamadığı için yeşil kalıyor. Bu, üretim controller'ı + bağlantı şekli repro'sudur; tam native uygulama başlatılmadı.

**Düzeltme/kapanış:** async tanı toplama/yazımı ile termination reply teslimini ayır; son success/failure reply common run-loop üzerinden doğrudan ulaşmalı, nested bekleme içindeki MainActor task ilerlemesine bağlı olmamalı. Tanı kaydı korunmalı, double reply olmamalı. Regresyon yalnız controller'ı değil gerçek AppDelegate bağlantısını veya onun çıkardığı test edilebilir teslim yolunu kapsamalı; evidence açık/kapalı ve failure→retry kontrol edilmeli. Model kullanmayan izole paket Quit smoke'u da yanıt/çıkış ve sıfır kalan süreç sonucunu doğrulasın.

### 28.3. Madde 12 — sağlayıcının çözdüğü onay/input isteği temizlenmiyor

**Bulgu [P2]:** kurulu **codex-cli 0.158.0** JSON şeması `serverRequest/resolved` için `threadId` ve `requestId` tanımlıyor. [Decoder](../../Sources/LoomCore/CodexAppServer.swift#L580) bunu unknown yapıyor; [router](../../Sources/LoomCore/CodexSessionState.swift#L444) thread kimliği çıkaramadığı için unmatched bırakıyor. [Coordinator](../../Sources/LoomCore/CodexSessionCoordinator.swift#L147) pending kaydı yalnız Loom'un kendi `respond` yolu üzerinden temizliyor. Native TUI'de cevaplanan veya sağlayıcı tarafından temizlenen isteğin resolution bildirimi işlendiğinde pending state ve [runtime kart listesi](../../Sources/LoomCore/SessionRuntime.swift#L802) de temizlenmeli.

**Başarısız — bağımsız repro:** üretim decoder/router/tracker'a approval request 7, ardından şemaya uygun resolution olayı verildi. Sonuç **unknown → unmatched; pending=1**. Sonraki idle olayı `activity=turnComplete` yapıyor ama **pending=1** kalıyor; açık `requestResolved` kontrol çağrısında **pending=0** oluyor. Bu sayaç [adapter](../../Sources/LoomCore/ProviderSessionAdapters.swift#L244) üzerinden pending provider work'e ekleniyor ve otomatik idle'ı engelliyor. Güncel resmî [approval/input protokolü](https://learn.chatgpt.com/docs/app-server) resolution'ın cevap/cleanup bildirimi olduğunu destekliyor. Remote TUI'nin bu bildirimi bizim bağlantıya yayınlaması gerçek modelle tekrarlanmadı; tarihsel Stop hatasının nedeni diye sunulmuyor. Olay 0.159 yeniliği varsayılmadı; kurulu şemada mevcut.

**Düzeltme/kapanış:** resolution'ı tipli decode et, doğru thread/run ve request ID ile eşleştir; coordinator pending kaydı, tracker blocker'ı ve runtime/UI request kaydını birlikte temizle. Bu bildirim kullanıcı adına cevap veya tool başarısı değildir; yalnız pending isteğin artık açık olmadığını söyler. Duplicate/unknown ID/yanlış thread/eski run idempotent ve zararsız olmalı; aynı thread'deki başka onayı silmemeli. Loom'un kendi cevabı ile resolution yarışında çift silme veya await öncesinden kalan array index kullanımı olmamalı. Gerekli regresyon: native-TUI benzeri fixture resolution, turn interruption cleanup, iki pending request, duplicate, yanlış thread/eski run ve local respond/resolution yarışı; son snapshot ve idle blocker sonucu birlikte doğrulansın.

### 28.4. Kontroller ve devir

**Doğrulandı:** **66 ilgili test** (51 router/runtime/supervisor, 13 controller, 2 Quit controller); kurulu CLI'ın model çalıştırmayan şema üretimi; üretim modüllerine linklenen bağımsız repro derlemesi; §26 hash eşleşmesi ve `git diff --check`. Build sonucu aynı hash'li §26 kanıtından devralındı; test/repro derlemesi bağımsız yapıldı. **Başarısız:** madde 11 nested callback karşılaştırması ve madde 12 resolution işleme beklentisi. **Doğrulanmadı:** tam native Quit, gerçek provider resolution yayın yolu, tarihsel gerçek devir/Stop nedenleri ve kalan C kabulü. Tam suite veya gerçek model tekrarı yapılmadı; ürün/test kaynakları değiştirilmedi.

Kalıcı kanıt: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-review7-20260930/` (`tests.log`, `quit-tests.log`, `repro.swift`, `repro.log`, `repro-build.log`, `schema-resolution.json`, `source-sha256.json`, `commands.txt`); [özet](../experiments/cp5-c-review7.json).

**Sonraki rol/adım — implementer:** kullanıcı yönlendirdiğinde önce madde 11, sonra madde 12'yi dar kapsamda düzelt; ilgili testler ve model kullanmayan Quit fixture kanıtıyla §29'a yanıt ver. Araştırmadaki diğer performans/koordinasyon adaylarını bu revizeye ekleme. Tam suite gerekmez. Codex **1/4 harcandı, kalan 3, tekrar 0**; Claude ek yetki **0** korunur. Planner-reviewer implementer başlatmadı/mesaj göndermedi; C/D/optimizer kapanışı açık.

## 29. Quit teslimi ve çözülmüş sağlayıcı isteği temizliği (30 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §28.2–28.4, madde 11 ve 12.
**Sonuç:** **İki bulgu için düzeltme uygulandı; kabul review bekliyor.** Gerçek sağlayıcı/model çalıştırılmadı.

**Madde 11 — uygulandı:** [AppDelegate](../../Sources/loom-app/AppDelegate.swift) Quit callback'inde artık yeni MainActor task açmıyor. [TerminalRunController](../../Sources/LoomTerminal/TerminalRunController.swift) async tanı hazırlığını detached shutdown görevinde tamamlayıp son success/failure yanıtını common-mode run loop'ta senkron teslim ediyor. Evidence recorder ana aktörde yalnız gerekli referansları yakalıyor; runtime tanısını toplarken ana aktöre dönmüyor. Tek yanıt/deneme kuralı korunuyor.

**Doğrulandı — Quit:** evidence açık/kapalı, main-queue içindeki nested run loop, failure→retry ve tekrar Quit çağrısı regresyonları geçti. Düzeltmesiz dayanak §28'in bağımsız `direct=true / Task-hop=false` repro'su. İzole release paket/imza kontrolü ve gerçek uygulama bağlantısının **iki modelsiz smoke'u** başarılı: normal Quit bir denemede; zorlanan başarısızlık sonrası bağlı sheet'in Try Again eylemi ikinci denemede çıkıyor. Uygulama PID'leri yok, **remaining=0**, runtime canlı run/session listeleri boş; `quit.json`, deneme dosyaları, yapısal tanı ve `shutdown.json` korunuyor. LaunchServices/evidence komutları kullanıldı; native tuş girdisi iddiası yok. Smoke'tan sonra Quit kaynakları değişmedi; son istek-cevap test bağlantısı birleşik build/test ile kontrol edildi.

**Madde 12 — uygulandı:** [decoder](../../Sources/LoomCore/CodexAppServer.swift) `serverRequest/resolved` olayını tipli çözüyor; router thread'e, tracker istek ID'sine ve run/sıra sınırına göre işliyor. [Coordinator](../../Sources/LoomCore/CodexSessionCoordinator.swift) yalnız eşleşen isteği kaldırıyor; yerel cevap sırasında array index taşımıyor, askıya alınan yazım sonrasında aynı istek oluşumunu yeniden kontrol ediyor. Pending değişiklikleri revizyonlu tam snapshot olarak [runtime'a](../../Sources/LoomCore/SessionRuntime.swift) gidiyor; atlanan/eski snapshot çözülmüş isteği karta geri getirmiyor. Kart isteği ve başarısız cevap kaydı birlikte temizleniyor. Resolution kullanıcı adına cevap veya tur/tool başarısı üretmiyor.

**Doğrulandı — istekler:** yeni decoder/router/tracker regresyonu eski kodda **üç beklentide başarısız**, düzeltmede başarılı. Fixture'da TUI benzeri input/permissions çözümü coordinator, pending-work sayacı ve kartı temizliyor; ayrı turn completion sonrasında idle geçişi mümkün. İki pending istek, kardeş thread, duplicate/unknown ID/yanlış thread, kesilen tur temizliği, eski run/sıra ve resume'da aynı sağlayıcı ID'sinin yeniden kullanımı sınandı. Yazımı kontrollü bekleten regresyonda resolution hem başarılı hem başarısız yerel yazımla yarışıyor: kardeş istek korunuyor, hata yeniden oluşmuyor, ikinci yazım reddediliyor. Controller seçimi/terminali koruyarak çözülmüş isteği karttan kaldırıyor.

**Kontroller/kanıt:** toplam **54 farklı ilgili test geçti** (12 decoder/router/tracker, 22 Codex runtime, 14 controller, 6 terminal/Quit). `swift build`, release paketleme/imza, `git diff --check` ve değişen izlenmeyen dosyaların whitespace kontrolü başarılı; mevcut SDK arama yolu uyarıları var. [Özet ve kaynak hash'leri](../experiments/cp5-c-review7-fix.json); `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-review7-fix-20260930/` (`resolution-red.log`, `tests.log`, `final-runtime-tests.log`, `quit-tests.log`, `build.log`, `package.log`, `native-summary.json`, `native-commands.json`, `scoped.diff`, `before/`).

**Doğrulanmadı:** gerçek remote TUI'nin resolution yayın yolu, tarihsel gerçek devir/Stop nedenleri ve kalan gerçek C kabulü. Tam suite çalıştırılmadı. Codex **1/4 harcandı, kalan 3, tekrar 0**; Claude ek yetki **0** değişmedi.
**Sonraki rol/adım — planner-reviewer:** madde 11/12 düzeltmelerini, yarış/istek sahipliği sınırını ve paket Quit kanıtını incele. C/D/optimizer kapanışı açık; sonraki gerçek kabul adımı review sonrasında belirlenmeli.


## 30. Sekizinci review: madde 11/12 kabulü ve gerçek deney karar kapısı (30 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → kullanıcı / sonraki implementer.
**Yanıt:** §29; kullanıcının tamamlanan revizeyi kontrol etme talimatı.
**Sonuç:** **Madde 11 ve 12 kapandı. Bu revizede yeni engelleyici bulgu yok; C bütünü kabul edilmedi.** [Bağımsız kanıt](../experiments/cp5-c-review8.json).

**Doğrulandı:** 54 ilgili test bağımsız geçti (12 decoder/router/tracker, 22 Codex runtime, 14 controller, 6 terminal/Quit). Evidence açık/kapalı nested run-loop teslimi, tek yanıt, başarısızlık→retry; çözülmüş isteğin coordinator/tracker/karttan temizlenmesi, kardeş istek ve thread izolasyonu, eski run/sıra, aynı provider ID'sinin resume'da yeniden kullanımı ve askıda yerel cevapla başarılı/başarısız yazım yarışı geçti. Son AppDelegate callback'i senkron; async tanı hazırlığı detached görevde, teslim common-mode yolunda. Runtime revizyonu await sonrası tekrar kontrol ediyor; resolution tur/tool başarısı üretmiyor.

§29'daki 12 kaynak hash'i ve paket binary hash'i eşleşti. Native normal Quit ve başarısızlık→sheet retry komut/sonuç dosyaları incelendi: ilk başarısızlık canlı synthetic oturumu koruyor; başarılı son denemelerde remaining=0, runningSessions boş ve tanı dosyaları mevcut. Bu native smoke implementer kanıtından devralındı, yeniden çalıştırılmadı; bağımsız davranış kontrolü yukarıdaki testlerle yapıldı. Test derlemesi ve `git diff --check` başarılı; aynı kaynaklı build/paket kontrolü gereksiz tekrarlanmadı. Tam suite ve gerçek sağlayıcı/model çalıştırılmadı; ürün/test kaynakları değiştirilmedi.

**Doğrulanmadı:** gerçek remote TUI resolution yayını, tarihsel devir/Stop nedenleri, kalan gerçek C kabulü; D, OWN-1, kaynak/GPU ve optimizer kapanışı. Bütçe değişmedi: Codex **1/4 harcandı, kalan 3, tekrar 0**; Claude ek yetki **0**.

### 30.1. Sonraki adım için somut karar

§15 ve §25.2 başarısız yeni-oturum adımının otomatik tekrarını yasaklıyor. **Öneri, henüz yetki değil:** Codex için yalnız **1 ek kısa tekrar turu**; toplam üst sınır 5, daha önce harcanan 1, yeni yetki verilirse kalan 4 (1 tekrar + mevcut 3). Claude bütçesi değişmez.

Kullanıcı onaylarsa implementer, §15'in izole profil/boş çalışma dizini ve ön kontrol düzeninde önce model kullanmadan başlangıcı doğrular; ardından yeni kartta yalnız `Reply with exactly LOOM_C_R5 and nothing else.` istemini bir kez gönderir. Kart/thread/run kimliğinin sabitliği, yanıt, Ready ve Stop sonucunu; yönlendirme ring'i ve yapısal Stop aşamalarıyla birlikte kaydeder. Bu önkoşul geçerse mevcut üç tur §15 sırasıyla resume, onay ve aktif-tur Quit için kullanılabilir. Her başarısızlıkta durulur; ikinci tekrar veya ek istem yok. Onay yalnız TUI'ye gelirse Loom onay kabulü açık kalır; resolution yayını gözlenmediyse doğrulanmış sayılmaz. Kod değişmedikçe suite/build tekrarı gerekmez. Sonuçlar yeni numaralı ekte ayrı doğrulandı/başarısız/doğrulanmadı olarak review'a döner.

**Sonraki rol/adım:** kullanıcı bütçe kararından sonra implementer; bu oturum implementer başlatmaz veya mesaj göndermez. Karar gelmeden gerçek deney yürütülmez. Kanıt: `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-review8-20260930/` (`tests.log`, `hash-check.json`, `commands.txt`).


## 31. Onaylanan Codex tekrarı ve koşullu gerçek deney (30 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §30.1; kullanıcının bir ek kısa tekrar turuna açık onayı.
**Sonuç:** **Yeni oturum tekrarı, Stop, resume, `/new`, `/exit` ve normal Quit/yeniden açılış doğrulandı. Yanıtlanabilir onay yalnız TUI'ye geldiği için koşullu sıra burada durduruldu; C kabulü açık.** Ürün/test kodu değiştirilmedi.

**Ön kontrol:** izole giriş ve boş çalışma dizini doğrulandı. Kurulu CLI **0.158.0**, TUI modeli **GPT-6-Astra / medium**. CLI `untrusted` politikasını model çağrısından önce reddetti; yalnız izole profil, yazma onayını koruyan destekli `on-request / read-only` ayarına getirildi. Her yeni oturumda native `/status` doğru dizini ve **Read Only (Ask for approval)** politikasını gösterdi. Gerçek kullanıcı profillerine deney komutlarıyla yazılmadı. Profil dizinlerinin önce/sonra metadata'sı tam eşleşmedi; bu dar ölçüm eşzamanlı kullanıcı/ajan etkinliğinden ayrıştırılmadı ve profil bütünlüğü kanıtı sayılmadı.

**Doğrulandı — tekrar ve devam:** tek tekrar isteminin gerçek yanıtı native TUI'de görüldü; kart/thread/run sabit, tek kart **Ready**. Yönlendirme kaydı ek `ephemeral=true` thread'i `ignoredEphemeral` olarak eledi; ring taşması 0. Stop'un aynı thread'e ait prepare/completed aşamaları başarılı, kalan süreç 0; TUI ve ortak sunucu kapandı. Aynı karttan resume aynı thread/geçmişi yeni run ile açtı; belirteci içermeyen resume isteminden sonra yeni yanıt ve Working→Ready geçişi gözlendi. Eski scrollback/token taraması tek başına kanıt sayılmadı.

**Doğrulandı — modelsiz devam:** `/new`, aynı canlı run'ı yeni thread/karta taşıdı; eski kayıt korundu ve run bağlantısı kapandı. `/exit` sonrası canlı run/lease 0. Native Cmd+Q başarılı; aynı katalogla yeniden açılışta iki kayıt, **0 canlı run, 0 terminal, sunucu kapalı**.

**Başarısız — Loom'dan yanıtlanabilir onay kabulü:** yeni kartta planın tek `touch` istemi gönderildi. Native TUI tam test komutu için onay istedi; Loom doğru kartta **Needs approval** gösterdi, ancak `selectedRequests=[]`, ring'de approval request olayı yok ve hedef dosya oluşmadı. Bu gözlem taşıma yolunun kök nedenini veya ham protokolde ne olduğunu kanıtlamaz. TUI onayı verilmedi, ikinci istem/tekrar yapılmadı. §30.1 durma koşuluyla son model turu harcanmadı.

**Doğrulandı — temizlik:** bekleyen onay sırasında native Cmd+Q başarılı, remaining=0; ortak sunucu/lease/canlı run yok, gözlenen uygulama ve TUI PID'leri son kontrolde yok. **Doğrulanmadı:** onayın cevaplanması ve tool sonucu, gerçek `serverRequest/resolved` yayını, `sleep 40` aktif-iş Quit ve dış kontrol sürecinin korunması. Bekleyen onayda temizlik, aktif-komut Quit kabulü yerine sayılmadı. Tarihsel hatanın kesin nedeni, genel sahiplik ve C/D/optimizer kapanışı da açık.

**Kontroller/kanıt:** review edilmiş 12 kaynak hash'i deney öncesi/sonrası eşleşti. Güncel kaynaklardan release paketleme/imza başarılı; ürün kodu değişmediğinden unit/tam suite tekrarlanmadı. JSON, belge bağlantıları ve whitespace kontrol edildi. [Arındırılmış sonuç ve kimlikler](../experiments/cp5-c-real-retry.json); `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-real-retry-20260930/` (`preflight.json`, `package.log`, `commands.json`, `catalog-*.json`, `source-sha256-final.json`, `processes-final.json`, `evidence-a/`, `evidence-b/`). Native ekranlar/ham terminal kalıcı kanıta kopyalanmadı.

**Bütçe:** bu deney **3** model turu (ek tekrar + resume + onay); önceki 1 ile Codex **4/5 harcandı, kalan 1, tekrar 0**. Son tur yalnız planlanan aktif-iş Quit içindir; başarısız onay adımını yeniden deneme yetkisi değildir. Claude ek yetki **0**.
**Sonraki rol/adım — planner-reviewer:** geçen gerçek kabul maddelerini ve TUI-only onay sınırını incele; kalan onay/aktif-iş Quit yolunu mevcut yetki sınırında belirle. Kod düzeltmesi veya yeni deney kendiliğinden başlatılmadı.


## 32. Dokuzuncu review: gerçek Codex kısmi kabulü ve onay iletim açığı (30 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → implementer.
**Yanıt:** §31; kullanıcının sürdürülen deneyi kontrol etme talimatı.
**Sonuç:** **Gerçek Codex yeni oturum/Stop/resume, `/new`/`/exit` ve normal Quit/yeniden açılışın bu deneyde sınanan bölümü kabul edildi. C açık.** Yanıtlanabilir onayın Loom kartına gelmemesi **madde 13 [P2, C4] — kabul açığı** olarak izlenecek; henüz kanıtlanmış bir UI/decoder kök nedeni değildir. [Bağımsız kanıt kontrolü](../experiments/cp5-c-review9.json).

**Doğrulandı:** 12 kaynak hash'i eşleşti. Snapshot/katalog/SQLite üzerinde 12 kontrol geçti: aynı kart/thread için farklı resume run'ı; doğru thread'de başarılı prepare/completed Stop; helper thread'in elenmesiyle tutarlı kayıt; aynı run'ın `/new` sonrası yeni karta bağlanması ve eski bağlantının kapanması; `/exit` sonrası run/lease yokluğu; aynı katalog yeniden açıldığında iki kayıt ve sıfır terminal/run/server; iki Quit'in başarılı ve kalıntısız raporları; tüm katalog run'larının bitmiş olması. Native yeni yanıt ve Working geçişi §31'in deney anı gözleminden devralındı; bu review ekranı yeniden oynatmadı, `tokenPresence` değerini yeni yanıt kanıtı saymadı. Süreç yokluğu deney sonundaki `processes-final.json` kaydıdır; genel sahiplik güvencesi değildir.

**Başarısız — madde 13:** `evidence-b/state-approval-pending.json` doğru kart/run için `Needs approval`, `selectedRequests=[]`, ring taşması 0 gösteriyor; hedef dosya yok. [İstemci](../../Sources/LoomCore/CodexAppServer.swift) method+id içeren gelen zarfı server request olarak ayırıyor; [router tanısı](../../Sources/LoomCore/CodexSessionState.swift) request'leri event'lerden ayrı kaydediyor. Mevcut ring'de request görünmemesi kartın böyle bir isteği aldığına kanıt sağlamıyor. Unknown event kayıtları ham protokol içeriğini korumadığı için bağlantıya hiç gelmediği de kesin söylenemez. Onay ekranının görülmesi onayın yanıtlanması/tool sonucu değildir. TUI-only yolu mevcut §15/§30 kabulünü kendiliğinden karşılamaz.

**Doğrulanmadı:** onay cevabı/tool sonucu, gerçek resolution yayını, aktif `sleep 40` sırasında Quit ve dış kontrol sürecinin korunması; Claude onayı/aktif Quit, tarihsel hata nedeni ve C/D/OWN-1/kaynak/optimizer bütünü. Bekleyen onayda temiz Quit aktif komut kabulüne çevrilmedi. Kod değişmediğinden build/test suite tekrarlanmadı; bu tur model/sağlayıcı çalıştırılmadı. Bütçe §31 kaydına göre **Codex 4/5 harcandı, kalan 1 yalnız aktif-iş Quit, tekrar 0; Claude ek yetki 0**.

### 32.1. Sonraki iş — madde 13 için modelsiz teşhis

**Amaç/kapsam:** yanıtlanabilir isteğin hangi istemciye teslim edildiğini ve Loom sınırında kaybolup kaybolmadığını ayır. İlgili app-server istemcisi/initialize yetenekleri, remote TUI bağlantısı, router/coordinator ve dar tanı/test araçları kapsamda; ürün yolu değişikliği, CLI upgrade, otomatik TUI onayı, terminal metninden request üretme ve model tekrarı kapsam dışı.

1. Önce [CP2 G1](../CHECKPOINT-2.md#19-kabul-matrisi-sonucu) gerçek approval gözleminin dayanak düzenini bugünkü düzenle karşılaştır: CLI sürümü, initialize yetenekleri, bağlantı/abonelik ve isteği başlatan istemci. Önceki kabulü bütün sürümlere genelleme. Mevcut yerel kaynak/şema/kayıtlar yeterli değilse eksik kanıtı belirt; yeni model istemi gönderme.
2. Gelen zarf→request/event ayrımı→thread/run eşleşmesi→pending snapshot→kart yolunu izle. Gerekirse yalnız bu sınırda bounded, içeriksiz tanı ekle: sabit method sınıfı, id varlığı/türü, decode sonucu, sıra ve eşleşme; komut/prompt/params/token/ham zarf kaydetme. Amaç yeni gerçek deneyden önce hangi bağlantı katmanının gözlenebilir olduğunu belirlemek.
3. Aynı wire biçimini kullanan modelsiz fixture ile isteğin Loom'a geldiği ve yalnız diğer istemcide bulunduğu durumları ayır. Geldiğinde doğru kart/tek cevap; yalnız durum bildirildiğinde uydurma request/otomatik cevap olmaması; çözüm ve kardeş thread izolasyonu kontrol edilsin. Üretim kusuru kanıtlanırsa yalnız kök nedeni düzelt, düzeltmesiz başarısız regresyonu göster. Kanıt provider teslim sınırını işaret ederse spekülatif workaround eklemeden bulguyu review'a getir.
4. Kod değişirse build, etkilenen decoder/router/runtime/controller testleri ve whitespace kontrolü; değişmezse kaynak/kanıt karşılaştırması yeterli. Tam suite yok. §33'e belirleyici kaynak/kanıt, doğrulanan neden veya kalan bilinmez, gerekli en küçük sonraki gerçek deney önerisi yaz.

**Kapanış ölçütü:** tanı görevi, iletim sınırı kanıtla belirlendiğinde veya tam olarak hangi ek gözlemin gerektiği açıklandığında review'a döner; fixture başarısı tek başına gerçek C4'ü kapatmaz. Yeni onay tekrarı için yetki yok. Kalan aktif-Quit turu teşhis yerine harcanmaz; gerçek sıra bu review sonrasında belirlenir.

**Sonraki rol/adım — implementer:** kullanıcı yönlendirdiğinde §32.1'i uygula. Planner-reviewer implementer başlatmadı/mesaj göndermedi; kullanıcıdan şu aşamada ek model bütçesi istenmiyor.


## 33. Madde 13: modelsiz iletim teşhisi (30 Eylül 2026)

**Yazan / Muhatap:** implementer → planner-reviewer.
**Yanıt:** §32.1, madde 13.
**Sonuç:** **CP2 ile bugünkü observer bağlantısı arasındaki belirleyici fark bulundu; gerçek teslimin kesin nedeni henüz doğrulanmadı.** Modelsiz fixture iki teslim yolunu ayırdı; üretim yoluna workaround eklenmedi. Madde 13/C4 açık.

**Doğrulandı — CP2 karşılaştırması:** CP2 G1 run `32F1416E…` içinde ikinci `loom_probe` istemcisi, TUI'nin thread'ine `thread/resume` gönderiyor (`control.jsonl:2`). Aynı thread için resume cevabı (`rpc-rpc.jsonl:14`), onay isteği (`:23`, sayısal id=0) ve resolution (`:24`) gözlenmiş. Tur TUI girdisiyle başlatılmış; observer kontrolünde `turn/start` yok. Bugünkü [Loom istemcisi](../../Sources/LoomCore/CodexAppServer.swift) `thread/read`/background sorgularıyla hydrate ediyor, observer üzerinden `thread/resume` göndermiyor. TUI'nin resume çağrısı ayrı bağlantıda; yerel router binding'i sunucu aboneliği kanıtı değil. İki initialize yolunda `experimentalApi=true`; CP2 CLI **0.157.1**, CP5 **0.158.0**, sandbox ise workspaceWrite/read-only. Bu farklar nedensel olarak ayrıştırılmadı; önceki başarı tüm sürümlere genellenmedi.

**Doğrulandı — kurulu şema ve sınır:** modelsiz şema üretimi başarılı. `ThreadResumeParams` çalışan thread'e yeniden katılmayı tanımlıyor; `ThreadReadParams` geçmiş okumasını anlatıyor. Initialize şemasında genel bir approval abonelik yeteneği görünmüyor. Şema, onayın bağlantılar arasında dağıtımını veya resume sonrası bekleyen isteğin tekrar teslimini garanti etmiyor. CP2 outbound initialize wire kaydı ve gerçek TUI initialize yetenekleri eldeki kanıtta yok; observer capability bilgisi kaynak/tarihsel kaynakla destekleniyor.

**İzlenen yol:** [istemci](../../Sources/LoomCore/CodexAppServer.swift) method+id zarfını request, id'siz method'u event olarak ayırıyor; [router](../../Sources/LoomCore/CodexSessionState.swift) thread/run eşleşmesini ve unmatched request'i bounded ring'e yazıyor. [Coordinator](../../Sources/LoomCore/CodexSessionCoordinator.swift) yalnız routed/applied request'i pending snapshot'a alıyor; [runtime](../../Sources/LoomCore/SessionRuntime.swift) revizyon ve aktif run/session/thread sahipliğini kontrol ederek karta yayımlıyor. CP5 ring'inde request yok; fakat unknown event için method sınıfı/id/decode sınırı saklanmadığından gerçek bağlantıya hangi zarfın ulaştığı kesinleşmiyor. Mevcut kanıt UI/decoder kusuru göstermiyor.

**Doğrulandı — fixture:** [fake sağlayıcıya](../../Sources/loom-fake-provider/CodexFixture.swift) aynı approval zarfını yalnız turu başlatan TUI bağlantısına gönderen `approve tui-only` varyantı eklendi; durum bildirimi ortak kalıyor. [Yeni runtime testi](../../Tests/LoomCoreTests/SessionRuntimeCodexTests.swift), TUI isteği görürken doğru Loom kartında waitingForApproval ve boş request listesi bulunduğunu; otomatik cevap/uydurma istek oluşmadığını; yanlış karttan cevabın reddedildiğini; diğer istemcinin resolution'ının kardeş pending isteği silmediğini doğruluyor. Mevcut teslim edilen-istek kontrolü de doğru karttan **tek** cevapla geçti. Fixture varyantı sağlayıcının gerçek fanout kuralı diye sunulmuyor; üretim kusuru/düzeltmesi olmadığı için red regresyon iddiası yok.

**Kontroller/kanıt:** **49 test geçti** (35 decoder/router/runtime, 14 controller); `swift build` ve whitespace kontrolü başarılı. İlk test çağrısındaki Testing macro keşif hatası geliştirme rehberindeki plugin argümanıyla giderildi; mevcut SDK arama yolu uyarıları var. Tam suite çalıştırılmadı. [Arındırılmış karşılaştırma, yol izleri ve hash'ler](../experiments/cp5-c-approval-diagnosis.json); `~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-approval-diagnosis-20260930/` (`comparison.json`, `tests.log`, `build.log`, `schema/`, `commands.json`). Yalnız fixture/test değişti; CLI yükseltilmedi, terminal metninden request üretilmedi.

**Gerekli ek gözlem / en küçük deney önerisi:** önce izole tanı düzeneğinde bağlantı başına bounded, içeriksiz wire sınıflandırması hazırlanmalı: sabit method sınıfı, id varlığı/türü, decode sonucu, sıra ve eşleşme; params/komut/prompt/ham zarf yok. Review ve **yeni açık onay-turu yetkisi** sonrası tek kısa onay istemiyle observer'a teslim kaydedilebilir; aynı istek beklerken tanı istemcisinden `thread/resume` ile katılımın teslimi değiştirip değiştirmediği gözlenebilir. Bekleyen istek tekrar yayınlanmazsa negatif sonuç tek başına hipotezi çürütmez; ikinci istem gönderilmeden raporlanmalı. Bu yalnız öneridir, üretime resume ekleme kararı veya deney yetkisi değildir. Gerçek C4, resolution ve aktif-iş Quit doğrulanmadı.

**Bütçe:** bu işte model/gerçek sağlayıcı turu **0**; Codex **4/5 harcandı, kalan 1 yalnız aktif-iş Quit, tekrar 0**; Claude ek yetki **0**.
**Sonraki rol/adım — planner-reviewer:** bağlantıya katılım farkını ve fixture ayrımını incele; madde 13'ün kesin teslim kanıtı için sonraki dar tanı/deney yolunu belirle. C kabulü açık.


## 34. Onuncu review: teşhis kabulü ve ayırt edici deney hazırlığı (30 Eylül 2026)

**Yazan / Muhatap:** planner-reviewer → implementer.
**Yanıt:** §33, madde 13; kullanıcının review talimatı.
**Sonuç:** **Modelsiz teşhis ve fixture ayrımı kabul edildi; yeni kod bulgusu yok. Madde 13/C4 açık.** [Bağımsız review kanıtı](../experiments/cp5-c-review10.json).

**Doğrulandı:** altı kaynak hash'i eşleşti; değişen fixture'ın teslim/izolasyon komşularını kapsayan **23 Codex runtime testi** bağımsız geçti. TUI-only istekte kartın bekleme durumu doğru, request listesi boş; kardeş istek korunuyor, sahte/otomatik cevap yok. Pozitif kontrol gerçek kullanıcı cevabının tek yazımını doğruluyor. CP2 `control.jsonl:2` observer resume, `rpc-rpc.jsonl:14/23/24` aynı thread için resume cevabı/approval id=0/resolution bağımsız okundu; observer kontrolünde turn/start sayısı 0. Kurulu şemanın running thread'e rejoin açıklaması ve mevcut Loom'un initialize/read yolu kaynakla karşılaştırıldı. Bu kanıt bağlantıya katılım farkını doğrular; fanout nedenini doğrulamaz.

§33'ün aynı kaynaklı build ve diğer test kanıtları devralındı; tam suite, native uygulama ve gerçek sağlayıcı/model tekrarı yapılmadı. Test derlemesi ve whitespace kontrolü geçti. Ürün/test kaynakları değiştirilmedi. **Doğrulanmadı:** gerçek 0.158.0 teslim kuralı, C4/resolution ve aktif-iş Quit/dış süreç kontrolü. Codex **4/5 harcandı, kalan 1 yalnız aktif-iş Quit, tekrar 0**; Claude ek yetki **0**.

### 34.1. Sonraki iş — deney düzeneğini model harcamadan hazırla

**Amaç:** gerçek deneye geçmeden içeriksiz bağlantı tanısını ve karşılaştırma düzenini çalışır, gözden geçirilebilir hale getir. §33'te önerilen yalnız bekleyen isteğe sonradan resume yaklaşımı negatif sonuçta replay belirsizliği bırakıyor. Bunun yerine tek TUI turundan **önce** hazırlanmış iki tanı gözlemcisi kullan: aynı initialize/capability ile A yalnız read, B aynı canlı thread'e resume ile katılmış. Böylece sürüm, sandbox, thread ve tur sabitken iki bağlantının aldığı zarf karşılaştırılır. B'nin katılımının genel dağıtımı etkileyebileceği açık kalır; sonuç tek başına tüm fanout kuralına genellenmez.

**Kapsam/sıra — implementer:**
1. Mevcut probe/istemci araçlarını yeniden kullanarak izole, deneyde açıkça etkinleştirilen düzeni hazırla; ürün coordinator'ına otomatik resume veya yeni sağlayıcı yolu ekleme. Bağlantı A/B kimliği, initialize sonucu, read/resume sırası ve başarılı katılım cevabı kaydedilsin. Resume yalnız açık threadId ile; model, sandbox, approval policy veya cwd override etmesin. Resume'un salt okuma olmadığını gözet; üretim davranışı olarak etkinleştirme.
2. Bounded içeriksiz wire tanısını decode öncesi zarf sınıfı ile decode/routing sonucunu ayıracak şekilde hazırla. Sabit method allowlist/sınıfı, id varlığı/türü (0 geçerli), sequence, bağlantı ve gerekli thread/run eşleşmesi yeterli; params, komut, prompt, token, ham zarf ve keyfî method metni kaydedilmesin. Drop sayısı olsun; taşma veya kopma negatif teslim sonucunu geçersiz kılsın.
3. Modelsiz fixture ile iki bağlantı için request teslimi/teslim edilmemesi, unknown notification, sayısal id=0, resolution ve yanlış thread izolasyonunu doğrula. Başlangıç engeli/timeout'ta temiz kapanış ve içerik sızmaması kontrol edilsin. Fixture gerçek sağlayıcı kuralının kanıtı sayılmasın. Değişen araçlara build ve ilgili dar testler yeterli; tam suite gerekmez.
4. §35'e çalıştırılabilir komut/düzen, kaynak hash'leri, örnek arındırılmış çıktı ve koşullu gerçek deney planını yaz. Gerçek CLI/TUI veya model başlatma. Önce düzeneğin review'u tamamlanacak; ardından gerekiyorsa tek ek onay turu için kullanıcıdan yetki istenecek. Mevcut aktif-Quit turu bu hazırlığa/tekrara ayrılmaz.

**Koşullu gerçek deney taslağı, henüz yetki değil:** onaylanırsa bir kısa `touch` istemi, iki gözlemci hazır olduktan sonra yalnız native TUI'den verilir; iki bağlantıda teslim ve doğru thread eşleşmesi kaydedilir. Hiçbir gözlemci otomatik cevaplamaz. Request'in tanı istemcisine gelmesi Loom kartı kabulü değildir; C4'e gereken ürün değişikliği ayrıca review edilir. Olumsuz/belirsiz sonuçta ikinci istem yok, temiz kapanış ve rapor var.

**Kapanış ölçütü:** model kullanmadan çalışan, içeriksiz ve bounded karşılaştırma düzeneği; pozitif/negatif fixture kanıtı ve açık gerçek deney komutları. **Sonraki rol/adım — implementer:** kullanıcı yönlendirdiğinde §34.1. Bu oturum implementer başlatmadı/mesaj göndermedi; henüz yeni bütçe talebi yok.


## 35. Doğrudan delegasyona geçiş (30 Eylül 2026)

Kullanıcı kararıyla ana ajan planner-reviewer; implementer ve optimizer işleri doğrudan subagent brief'i ve mesajlarıyla yürütülür. [Ortak akış](../../AGENTS.md) ve [rol belgeleri](../../agents/README.md) güncellendi. Önceki bölümlerdeki dosyaya yanıt yazma ve kullanıcının implementer'ı yönlendirmesini bekleme talimatları artık uygulanmaz; geçmiş kayıtlar korunur.

Teknik konum değişmedi: [§34.1](#341-sonraki-iş--deney-düzeneğini-model-harcamadan-hazırla) kapsamındaki modelsiz iki gözlemcili tanı düzeneği sıradaki iş. Oradaki 4. adımın çıktıları (komut/düzen, hash'ler, arındırılmış örnek ve koşullu deney planı) implementer tarafından atanmış kanıt dosyası ve doğrudan raporla teslim edilir; kısa review/karar kaydını planner-reviewer tutar. Bu tur belge geçişiyle sınırlı; uygulama henüz delege edilmedi.

[§34 kabulü ve kanıtı](../experiments/cp5-c-review10.json) devralınır; madde 13/C4 ve aktif-iş Quit açık. Codex **4/5 harcandı, kalan 1 yalnız aktif-iş Quit, tekrar 0**; Claude ek yetki **0**. Yeni gerçek deney yetkisi verilmedi. Sonraki adım planner-reviewer'ın §34.1'i implementer subagent'a devretmesidir.


## 36. Kodla durum doğrulaması ve delegasyon (30 Eylül 2026)

[Kaynak ve kanıt karşılaştırması](../experiments/cp5-c-state-audit.json) güncel konumu doğruladı: §34 teşhis kaydındaki altı hash aynı. Gerçek kabulün 12 kaynağından 10'u aynı; farklı iki dosya, sonraki kabul edilmiş TUI-only fixture/test değişiklikleri. Son review'un 23 testlik başarılı logu ve gerçek deneydeki boş onay listesi/taşmasız routing kaydı yeniden okundu. Aynı girdiler için test tekrarlanmadı.

Kodda yerel binding ve read ile durum toplama var; observer resume ve iki gözlemcili hazırlık bariyeri yok. Mevcut ring decode sonrasını kaydediyor; eski genel probe ise ham RPC saklıyor. Dolayısıyla §34.1 hâlâ gerekli. Quit callback düzeltmesi ve tipli resolution yolu korunuyor; bunlar gerçek aktif-iş Quit veya C4 kabulünün yerine geçmiyor.

`cp5_c_observer_harness` implementer subagent'ına doğrudan brief verildi: aynı initialize ile A read/B resume, açık threadId, iki başarılı katılımdan sonra hazır bariyeri, opt-in sınırlı/içeriksiz zarf ve decode/routing tanısı; teslim ayrımı, id=0, unknown, resolution, yanlış thread, taşma/kopma ve hata temizliği fixture kanıtı. Yazma alanı ilgili istemci/tanı/probe/fixture ve testler; kanıt `cp5-c-observer-harness` dosyalarında. Ürün coordinator/UI davranışı ve gerçek sağlayıcı/model çalıştırma kapsam dışı. Implementer build, dar testler ve uçtan uca fixture kontrolünü yapacak; planner-reviewer diff ve belirleyici davranışı inceleyecek. §34.1'in bütçe sınırları korunur.


## 37. Modelsiz gözlemci hazırlığının kabulü (30 Eylül 2026)

§34.1 tamamlandı ve planner-reviewer tarafından kabul edildi. Implementer'ın [düzen/komutları](../experiments/cp5-c-observer-harness.md) ve [kanıtı](../experiments/cp5-c-observer-harness.json) incelendi; [bağımsız review sonucu](../experiments/cp5-c-observer-review.json) kaydedildi. Ürün coordinator'ına otomatik resume eklenmedi; yalnız açıkça etkinleştirilen probe A read/B resume bağlantılarını kullanır.

**Doğrulandı:** build ve 15 decoder/tanı testi; 10 uçtan uca fixture dalı. Planner-reviewer son kaynaklarda **23 runtime testini** bağımsız çalıştırdı; 7/7 kaynak hash'ini, hazır bariyerlerini, eşit initialize/sınırlı istek audit'ini ve 10 snapshot sonucunu ayrıca doğruladı. İki bağlantıya/yalnız B'ye/hiçbirine teslim ayrılıyor; boş, farklı veya hazırlık öncesi tur, taşma, kopma ve hazırlık hatası geçerli karşılaştırma sayılmıyor. İçeriksiz metadata ile decode ve tanıya özel production router kararı ayrılıyor. Whitespace kontrolü geçti. `comparisonWindowValid` yalnız gözlem penceresinin geçerliliğidir; onay üretildiği ayrıca native TUI'de gözlenmelidir.

**Doğrulanmadı:** gerçek sağlayıcının teslim/fanout/replay kuralı, C4 ve aktif-iş Quit. Fixture başarısı bu maddeleri kapatmaz. Bu işte gerçek CLI/TUI/model çalıştırma **0**; Codex **4/5 harcandı, kalan 1 yalnız aktif-iş Quit, tekrar 0**; Claude ek yetki **0**. C/D/OWN-1/kaynak/optimizer kapanışı açık.

### 37.1. Sonraki karar — tek ek onay turu

Hazırlık artık gerçek deneye hazır. Kullanıcıdan gereken karar, yalnız bu karşılaştırma için **1 ek Codex onay turu**, tekrar **0** yetkisidir; henüz verilmedi. [Koşullu komut düzeni](../experiments/cp5-c-observer-harness.md) kullanılacak: izole native TUI'nin açık thread'ine A/B hazır bariyerinden sonra tek kısa `touch` istemi; aynı turda TUI onay gözlemi ile A/B içeriksiz teslim kayıtlarının karşılaştırması. B katılımı salt okuma değildir ve genel dağıtımı etkileyebilir; sonuç buna göre sınırlanır. Gözlemciler cevaplamaz, ikinci istem gönderilmez. Belirsizlik/hata halinde tekrar yerine temizlik ve rapor yapılır. Kalan aktif-Quit turu buna harcanmaz. Deney sonucu planner-reviewer tarafından değerlendirildikten sonra gereken ürün değişikliği veya kalan gerçek kabul adımı belirlenir.


## 38. Tek gerçek onay turu yetkisi ve verifier delegasyonu (30 Eylül 2026)

Kullanıcı §37.1'deki **1 ek Codex onay turunu, tekrar 0** kabul etti ve doğrulamayı verifier subagent'a vermemizi istedi. Toplam Codex yetkisi **6**, harcanan **4**; bu karşılaştırmaya **1**, ayrı aktif-iş Quit'e **1** ayrıldı. Claude ek yetki **0**. Verifier rolü bu görev için açıkça yetkilendirildi.

`cp5_c_real_observer_verification` doğrudan brief ile görevlendirildi: kabul edilmiş kaynak/ikili ve izole profil ön kontrolü; native TUI'de mevcut read-only/on-request koşulu; aynı thread için A/B hazır bariyeri; tek `touch` istemi; TUI onay gözlemi ile içeriksiz A/B snapshot karşılaştırması; normal Quit ve sahip olunan süreçlerin temizliği. Kod/config/plan değişikliği, onayı kabul etme, ikinci istem ve aktif-Quit turunu kullanma kapsam dışı. Sürüm/politika/ön koşul farkı istemden önce planner-reviewer'a bildirilir. Kanıt `plans/experiments/cp5-c-real-observer-verification.json` ve yeni izole deney dizininde tutulur.

Teslim/tur korelasyonu, kayıp/kopma ve deneyin sınırları doğrulandı / başarısız / doğrulanmadı ayrımıyla raporlanacak. Gözlemci teslimi Loom C4 kabulü değildir; sonucu planner-reviewer değerlendirir. Sonraki adım verifier'ın doğrudan raporu ve kanıt review'udur.


Yürütme hazırlığı: boş native TUI için ilk A/B hazırlığı başarısız oldu; hazır bariyeri oluşmadı ve model istemi gönderilmedi. İçeriksiz snapshot aşama/kök neden ayrımını tek başına kanıtlamıyor. Deney süreçleri normal Quit ile temizlendi. Planner-reviewer, önceki izole test sohbeti `01a0f0e2-6c3b-7b63-882d-50c615238ac9` için katalogda idle ve sağlayıcı kaydında son iki turun tamamlandığını metadata ile doğruladı. Aynı tek-tur deneyi, eski katalog read-only SQLite backup ile yeni data-root'a kopyalanarak bu sohbetin native resume'u üzerinden hazırlanacak; eski cwd/profile korunacak. Taze sohbet varsayımı kaldırıldı; deneyin sınırına yazılacak. Boş sohbeti hazırlamak için ek model turu kullanılmaz; ikinci hazırlık da başarısızsa temizlenip doğrulanmadı raporlanır.


## 39. Gerçek gözlemci doğrulaması — kısmi sonuç (30 Eylül 2026)

Verifier tek yetkili istemi gönderdi; [verifier kanıtı](../experiments/cp5-c-real-observer-verification.json) ve [planner-reviewer'ın bağımsız kontrolü](../experiments/cp5-c-real-observer-review.json) kaydedildi. **Resume ile katılan B bağlantısına gerçek onay teslimi doğrulandı; C4 kapanmadı.**

Hazır bariyerinde A read/B resume aynı hedef kimlikle başarılı (sequence 6/6). Native TUI'de onay penceresi gözlendi; B'deki `turn/started` sequence 11 ve `commandExecution/requestApproval` sequence 16 aynı hedef thread/tur etiketiyle eşleşti. A'da hedef durum bildirimleri var, tur başlangıcı/onay kaydı yok. İki bağlantıda da drop/hata 0; fakat A'nın aynı-tur korelasyonu olmadığından **comparisonWindowValid=false**. Dolayısıyla B'nin pozitif teslimi kabul edilir; A/B tam negatif karşılaştırması, genel fanout/replay kuralı ve kesin kök neden doğrulanmış sayılmaz. Ana Loom'da `Needs approval` görünürken `selectedRequests=0` kaldı; onay verilmedi, hedef dosya oluşmadı.

**Bağımsız doğrulandı:** 7 kaynak hash'i, ready/snapshot alanları ve B tur/istek eşleşmesi; ana Loom'un boş istek listesi; normal Quit sonucu succeeded=true, remaining=0, liveRuns=0, lease=0, server=false, hata=0; uygulama/sunucu/TUI/probe PID'leri ve socket yok. Native onay gözlemi verifier'ın deney anı gözlemidir; planner-reviewer UI'yi yeniden oynatmadı. Kaynak değişmediği için test suite tekrarlanmadı; verifier güncel paketi derledi. Bekleyen onayda Quit, aktif-komut Quit kabulü değildir.

**Sınır:** boş yeni TUI'de hazırlık bariyeri oluşmadı ve istem gönderilmedi; başarısızlığın kesin aşaması içeriksiz kayıttan ayrışmıyor. Başarılı gözlem önceki tamamlanmış izole thread'in katalog kopyasından native resume'u ile yapıldı; sonuç ilk yeni sohbet turuna genellenmez. Temp deney alanları temizlendi, arındırılmış kanıt korundu.

**Bütçe:** bu deney **1** tur, toplam Codex **5/6 harcandı**, kalan **1 yalnız aktif-iş Quit**, tekrar **0**; Claude ek yetki **0**. C4, gerçek resolution/cevap sonucu, aktif-iş Quit ve CP5 birleşik kapanışı açık.

### 39.1. Sonraki planlama — ürün bağlantısına güvenli katılım

Planner-reviewer, B'nin doğrulanan katılım yolunun mevcut coordinator'ın başlatma/devam akışına nasıl bağlanacağını inceleyip dar uygulama planını çıkaracak. Özellikle boş yeni thread, ilk onaydan önce katılım zamanı ve bekleyen isteğin replay belirsizliği çözülmeden yalnız `resume` ekleyerek C4 kapatılmaz. Plan; otomatik tur/cevap veya ayar override üretmemeyi, doğru thread/run'a bir kez katılımı, hata/iptal/eski run izolasyonunu ve mevcut yeni/devam/Stop davranışlarını koruyan modelsiz kontrolleri kapsamalı. Bu doğrulama görevinde ürün kodu değiştirilmedi. Yeni gerçek onay tekrarı için yetki yok; kalan aktif-Quit turu bu amaçla harcanmaz.


## 40. Onay iletimi için araştırma ve uygulama planı (30 Eylül 2026)

§39.1 araştırması tamamlandı. **Seçilen dar yol: ana ürün bağlantısını aynı thread'e abone etmek; yeni boş thread'i ayrı ele almak.** Bu plan madde 13/C4'ü kapatmaz. Kullanıcının bu turdaki talebi araştırma ve planlamadır; ürün implementasyonu başlatılmadı.

### 40.1. Kanıt ve karar

[Arındırılmış araştırma kanıtı](../experiments/cp5-c-join-research.json), [Orca/Herdr raporu](../experiments/orca-herdr-logic-research-20260930.md) ve [CLI raporu](../experiments/openai-cli-devday-research-20260930.md) birlikte değerlendirildi. Explorer kaynak akışını bağımsız okudu; belirleyici bağlantı, Stop ve fixture yolları planner-reviewer tarafından da kontrol edildi.

- **Doğrulandı — eksik abonelik:** `CodexSessionCoordinator.bindResume` yerel adapter/router kaydı yapıyor; ürün yolunda `thread/resume` RPC'si yok. [Resmî App Server belgesi](https://developers.openai.com/codex/app-server), `thread/read` işleminin abonelik kurmadığını açıklıyor. §39'daki başarılı B katılımı bu düzeltme yönünü destekliyor; geçmiş A/B deneyinin korelasyon sınırı korunur.
- **Doğrulandı — boş thread engeli:** bu shell'deki `codex` artık **0.159.2**; eski deneyin **0.158.0** ikilisi de yerelde mevcut. İkisinde de ayrı geçici profil/cwd ile doğrudan `thread/start` → ikinci istemciden metadata `thread/read` başarılı, aynı boş thread'e `thread/resume` ise **-32600 / no-rollout**. 0.159.2'de `excludeTurns:true` de çözmedi; başarısız resume'lardan sonra observer `unsubscribe` sonucu `notSubscribed`, creator sonucu `unsubscribed`. Bu görev CLI yükseltmedi. [Changelog](https://developers.openai.com/codex/changelog) boş taslak/arşiv/liste değişikliklerini anlatıyor; bunlar boş observer katılımı garantisi değil.
- **Deney sınırı:** dört küçük protokol kontrolü gerçek app-server ile fakat **native TUI, auth kopyalama ve model turu olmadan** yapıldı. Önceki native hazırlık hatasının kesin sebebi böylece geriye dönük kanıtlanmış olmaz. Sahip olunan sunucular/gruplar kapandı; geçici profil/cwd kökleri kaldırıldı. Binary ve ilgili Loom kaynak hash'leri kanıtta.
- **Doğrulanmadı — ilk onay:** ilk active bildirimi geldiğinde rollout'un hazır olması, geç katılan istemciye bekleyen request'in tekrar teslimi ve başarılı katılımda native ayarların korunması. 0.159.2 experimental şemasında ayrı subscribe/pending-list/replay metodu bulunmadı; bu, resume'un kendisinin replay yapmadığını kanıtlamaz. Resmî sayfa bu garantiyi vermiyor.
- **Araştırmadan alınanlar:** Orca'nın tam thread kimliği doğrulaması, bekleyen isteğin sahipliği ve iptal/geç yanıt izolasyonu bu işin kabul ölçütüdür. `no-rollout` sonrası yeni thread açan Orca davranışı Loom'a taşınmaz. CLI raporunun eski `serverRequest/resolved` açığı mevcut kodda kapanmıştır. Herdr kaynak/terminal ölçümleri ve genel capability cache iyileştirmesi D/optimizer adayları olarak kalır.

### 40.2. Dar implementer işi — abonelik ve modelsiz kabul

**Hedef:** doğrulanmış yerel binding'e ait ürün bağlantısı aynı thread'e katılsın; gelen gerçek request doğru karta ulaşsın; katılım başarısızlığı veya iptali eski/kardeş oturumu etkilemesin. Terminalin kullanılabilirliği ile observer katılımı ayrı durumlar olsun. Kayıtlı sohbet ve yeni boş sohbet tek başarı varsayımına indirgenmesin.

**Yazma alanı:** `Sources/LoomCore/CodexAppServer.swift`, `CodexSessionCoordinator.swift`, gerekli dar runtime/reducer bağlantıları (`SessionRuntime.swift`, `CodexSessionState.swift`); `Sources/loom-fake-provider/CodexFixture.swift` ve ilgili mevcut testler. Sonraki gerçek kontrolün hazırlanması gerekiyorsa mevcut `CodexObserverHarness.swift`/smoke düzeneğinde yalnız gecikmeli katılım ve içeriksiz aşama tanısı. Yeni transport/proxy, genel cache/refactor, ürün sözleşmesi, plan/status ve gerçek model çalıştırma kapsam dışı. Kanıt dosyası `plans/experiments/cp5-c-join-implementation.json`; plan/status sahibi planner-reviewer.

1. **Önce başarısız regresyon:** fixture'da ana observer'a yalnız status gönderilsin; turn/request teslimi thread başına başarılı aboneliğe bağlı olsun. Mevcut genel broadcast yolu eksik katılımı gizliyor. Blank/no-rollout, response öncesi request, replay var/yok ve geç yanıt ayrı kontrollü fixture davranışları olsun; gerçek sağlayıcının replay kuralı diye sunulmasın.
2. **Katılım:** yerel adapter, router ve Stop hook'u kurulduktan sonra mevcut ürün client'ından yalnız `{threadId}` ile `thread/resume`. Yeni kimlik eşleşmesi, açık resume ve native `/new` geçişi giriş noktalarıdır. Cevabın thread ID'si eksiksiz ve tam eşleşmeli. Model/izin/cwd override, `thread/start`, prompt veya otomatik onay gönderilmez. `excludeTurns` bu sorunun çözümü değildir ve bu iş için yeni compatibility katmanı gerektirmez.
3. **Boş thread:** yalnız doğru thread'e ait belirli `-32600 / no-rollout` sonucu beklenen `awaitingPersistence` olarak ayrılır; diğer hatalar buna çevrilmez. Terminal/onboarding/ilk kullanıcı turu join başarısını beklemez: aksi halde ilk tur kaydı ve join birbirini bekler. İlk hedef active/waiting status geçişi yeniden katılım tetikleyebilir; bir binding için eşzamanlı tek RPC, ilk deneme dışında **en fazla iki olayla tetiklenen deneme**, yinelenen aynı status'ta yeniden deneme yok. Sonraki farklı uygun status'a kadar beklenir; timer/polling döngüsü veya otomatik model turu yok. Denemeler tükenirse doğru kartta mevcut hata kanalıyla görünür sonuç; gelen gerçek request işlenmeye devam eder. Bu üst sınır ürün retry tercihi değil, ilk dar uygulamanın sınırsız tekrar yapmasını önleyen sınırdır; farklı gerekçe varsa implementer ana ajana döner.
4. **Sıra ve sahiplik:** coordinator'da binding `(session, run, thread)` ve client ömrüne bağlı generation; aynı binding'e yinelenen olay ikinci paralel katılım yaratmaz. RPC ayrı task'ta yürür, stream tüketimini bekletmez. Cevap sırasında tracker yeniden kurulmaz, `latestSequence` ile request'lerin üstüne bariyer atılmaz; aynı thread için yinelenen `thread/started` mevcut bekleyen onayı/working bilgisini bozmamalı. Her await sonrası güncel sahiplik doğrulanır. Katılım hatası yalnız hedef karta gider; genel `codexIssue` yoluyla kardeş kartlara dağıtılmaz.
5. **Stop ve geç sonuç:** `/new`, unbind, bağlantı sonu ve Quit generation'ı geçersizleştirir. Ortak Stop hook'unun **prepare başlangıcı** katılımı da geçersizleştirmelidir; automatic idle runtime'ın `stopConversation` yolundan geçmez. Sadece `runContext != nil` kontrolü veya task cancel yeterli değildir: mevcut RPC send işi ayrık task'tadır, iptal sunucudaki katılımı geri almaz. Katılım ve unsubscribe'ın wire sırası/sonucu korunmalı; gecikmiş katılım sonrasında abonelik bırakılmamalı, yeni aynı-thread sahibinin aboneliği de eski cleanup ile kaldırılmamalı. Süresi dolmuş belirsiz işlem temizlendi sayılmaz; kardeş bağlantıları kapatmadan görünür başarısızlık kalır. Prepare başarısız olup terminal yeniden açılırsa eski generation otomatik dirilmez; kontrol edilmiş yeniden katılım veya açık bağlantı hatası gerekir.

**Modelsiz kabul matrisi:** kayıtlı resume/yenide kimlik/native `/new`; request'in join cevabından önce gelmesi; resolution ve kardeş pending korunması; eksik/yanlış cevap kimliği; no-rollout→active→katılım; hâlâ no-rollout ve retry sınırı; replay olmayan dalda sahte request olmaması; aynı cwd belirsizliği; aynı run'da yeni thread ve aynı thread'in yeni run'ı; explicit Stop/automatic idle/Quit/exit sırasında geç başarı veya hata; timeout ardından unsubscribe sırası; kardeş thread'in kesilmemesi; kullanıcı cevabının tek gönderimi. Fixtures ve mevcut testler uygun alt kümeye ayrılır; implementer önce düzeltmesiz başarısızlığı, sonra başarıyı gösterir.

**Kontroller/sahip:** implementer `swift build`, etkilenen `CodexAppServerTests`, `SessionRuntimeCodexTests`, gerektiğinde lifecycle/manager testleri ve değişirse observer smoke; whitespace. Planner-reviewer diff ve belirleyici kabul kanıtını inceler; aynı girdide geçen kontrolleri sebepsiz tekrarlamaz. UI/native kabulü fixture başarısıyla kapatılmaz.

### 40.3. İlk onayın kabul kapısı ve alternatif

Implementasyon ve modelsiz review sonrasında çalıştırılabilir **gecikmeli katılım** deneyi hazırlanmalı: boş native thread'in ilk onayı beklerken henüz katılmamış tanı bağlantısından aynı thread'e resume; katılım öncesi/sonrası request, response, resolution sırası içeriksiz metadata ile ayırt edilir. Böylece sadece sonraki tura katılım değil, zaten bekleyen ilk onayın teslimi sınanır. Ürün bağlantısının ayrı olarak onay kartını ve açık kullanıcı cevabının sonucunu doğrulaması gerekir. Native ayarlar/kimlik önce-sonra karşılaştırılır. Bir tanı istemcisindeki replay başarısı tek başına ürün kabulü değildir.

Bu deney tasarımı **yeni model yetkisi değildir**. Önce modelsiz hazırlık somutlaştırılır; gerekiyorsa dar gerçek deney bütçesi o zaman kullanıcıya sunulur. Codex **5/6 harcandı; kalan 1 yalnız aktif-iş Quit; onay tekrarı 0**, Claude ek yetki **0**. Bu araştırma **0 model turu** harcadı.

Bekleyen isteğin teslimi sağlanamıyorsa, yalnız daha hızlı/çok resume deneyerek ilk-onay kabulü verilmez. O noktada sağlayıcının desteklediği canlı-thread katılım/replay yolu gerekir. TUI başına protokol proxy'si, native bağlantıya zaten gelen request'i gözleme adayıdır; cevap yarışı, request-ID, backpressure, sahiplik ve kopma bakımından ayrı mimari kapsamdır. Loom'un önce `thread/start` yapması da TUI'nin boş thread'e katılımını kendiliğinden çözmez ve native başlangıç/ayar otoritesini değiştirir. Bu alternatifler mevcut dar implementer brief'ine dahil değildir; kaynak veya deney dar yolu elerse ayrı karar hazırlanır. C4 açık kalır.

**Plan turu sonucu:** yalnız bu plan, checkpoint/status ve araştırma kanıtı değişti; ürün/test kaynakları aynı. Bağlantı/anchor, JSON ve whitespace kontrolleri geçti; belirleyici 6 ürün kaynağının hash'i değişmedi. Ürün build/test suite'i tekrarlanmadı. Sonraki iş §40.2'nin planner-reviewer tarafından doğrudan implementer brief'ine çevrilmesidir.


## 41. CP5 kapanış görevlendirmesi ve pending replay kanıtı (30 Eylül 2026)

Kullanıcı §40.2 implementasyonunu ve CP5 bitene kadar gerekli iterasyonları yetkilendirdi. `cp5_c_join_implementation` doğrudan brief ile görevlendirildi; [birleşik kapanış sırası](CLOSURE.md) strict reviewer → optimizer → son Herdr/Orca karşılaştırmasıdır. Altın standartlar/kabul düşürülmez. [D işleri](D.md) ayrık dosya sahipliğinde paralel ilerler.

**Yeni doğrulama:** [pending replay araştırması](../experiments/cp5-c-pending-replay-research.json). Gerçek **0.159.2 app-server**, yalnız localhost'ta çalışan sahte Responses backend'iyle ve izole auth'suz profilde sınandı. Boş thread'in sentetik ilk turu gerçek `commandExecution/requestApproval` üretti; ikinci client ancak creator'da onay görüldükten sonra `thread/resume` yaptı. Bekleyen istek **aynı request ID ile ikinci client'a teslim edildi**. Genişletilmiş kontrolde ikinci client'ın test için gönderdiği `decline` sonrası iki client da resolution ve turn completion aldı; dosya oluşmadı. Başlangıç/resume yanıtlarında model/provider/approval/reviewer/cwd/sandbox değerleri eşleşti. Sunucu process grupları temizlendi.

**Sınır:** iki yerel sentetik tur, **gerçek model turu 0**. Native TUI ve Loom ürün/UI yolu bu kontrollerde çalıştırılmadı; bütün sürüm/request türleri için garanti veya C4 kabulü değildir. Ancak §40.3'ün geç katılım belirsizliği bu sürüm ve command approval için kontrollü gerçek-server kanıtına kavuştu; sentetik fixture varsayımından daha güçlüdür. Implementer'a doğrudan aktarıldı. Ürün entegrasyonu ve native kabul devam eder; mevcut sayısal gerçek-model bütçesi değiştirilmedi.


## 42. Abonelik uygulaması ve native kabul hazırlığı (30 Eylül 2026)

[Implementasyon kanıtı](../experiments/cp5-c-join-implementation.json): üyeliğe bağlı fixture eski coordinator'da 8 issue ile kırıldı. Yeni ürün yolu yerel binding/router/Stop hook'u kurduktan sonra yalnız `threadId` ile katılıyor; no-rollout denemeleri sınırlı durum geçişleriyle tetikleniyor. Gönderilmiş RPC, generation ve aynı-thread cleanup bariyerleri Stop/idle/Quit/exit sırasını koruyor. Prepare başarısızlığı gate'i serbest bırakıyor; başarılı cleanup kayıtları budanıyor, sonucu belirsiz timeout unutulmuyor.

**Doğrulandı:** implementer'ın 4 suite/55 test, ek geç-hata testi ve build'i geçti. Planner kod incelemesinde yanlış/eksik thread ID reddi, kart kapsamlı hata, request-before-response ve cleanup sırasını kontrol etti; gate'in prepare hatasında kapanması ve tamamlanmış task birikimi bu turda düzeltildi. Mevcut lifecycle testlerinin socket/cwd ve arındırılmış hata-stage beklentileri korundu. **Doğrulanmadı:** native ürün ilk-onay/resume/cevap zinciri ve gerçek-model C4 kabulü; fixture sonucu bunları kapatmaz.

Sıradaki bağımsız kabul, son paket üzerinde gerçek Codex TUI + yalnız localhost sahte Responses backend'iyle yeni sohbet → ilk onay → açık test reddi → Stop → resume → onay sırasında gizli Quit. Geçici profil/boş çalışma klasörü kullanılır; model turu 0, kişisel profil değişikliği 0. [§41](#41-cp5-kapanış-görevlendirmesi-ve-pending-replay-kanıtı-30-eylül-2026) protokol kanıtı ürün bağlantısında yeniden sınanacak. Tam CP5 kabulü ve inceleme sırası [kapanış kaydında](CLOSURE.md) korunur.
