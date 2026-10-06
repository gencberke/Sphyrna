# CP5 birleşik kapanış

## Yetki ve hedef

30 Eylül 2026 kullanıcı görevlendirmesi: CP5 tamamlanana kadar implementasyon, kabul kontrolleri ve gerekli revizyonlar planner-reviewer tarafından doğrudan delege edilerek sürdürülecek. Altın standartlar ve uygulama gereksinimleri korunacak. Önce bütüncül **strict reviewer**, sonra **optimizer**, bu ikisinin bulguları kapandıktan sonra **explorer ile Herdr/Orca session karşılaştırması** yapılacak. İncelemelerden doğan düzeltmelerin etkilenen kabulü yeniden doğrulanacak.

İlk tercih mevcut çekirdeği güvenilir hale getirmek. Gereken güvenilirlik sağlanamıyorsa Herdr tabanına geçiş; hangi kabulü çözdüğü, hangisini çözmediği, aktarım maliyeti ve korunacak ürün davranışlarıyla değerlendirilecek. Bir referans uygulamanın varlığı güvenilirlik kanıtı değildir. Varsayımsal garantiler, sahte başarılı kapanış veya kabul ölçütlerini daraltma yok.

## İş sırası

1. [C §40.2](C.md#402-dar-implementer-işi--abonelik-ve-modelsiz-kabul): Codex ürün aboneliği, boş-thread akışı, iptal ve modelsiz regresyonlar. Implementer `cp5_c_join_implementation`; ortak Swift build/test sahibi başlangıçta bu ajan.
2. C gerçek sağlayıcı kabulü ve A/D kalan ürün/kaynak kabulü. `cp5_closure_inventory` kod/kanıt envanterini, `cp5_ownership_feasibility` OWN-1 uygulanabilirliğini salt okunur inceler. Bunlar kapanıştaki nihai karşılaştırma veya strict review yerine geçmez.
3. Son kaynaklar üzerinde bütüncül strict review: veri ve kimlik akışı, yaşam döngüsü, eşzamanlılık/iptal, hata/toparlanma, modül sınırları ve kabul kanıtı.
4. Strict bulguları kapandıktan sonra optimizer: üst üste birikmiş mantık, kopya sorumluluk, bakım maliyeti ve ölçülmüş kaynak kullanımı. Sırf üslup için refactor yapılmaz.
5. Son durumda Herdr/Orca session karşılaştırması; kalan temel açık varsa migration kararı. A/B/C/D kabul matrisiyle planner-reviewer kapanış kararı.

## Korunan açık kapılar

- C4: ilk yeni Codex onayı, geç katılım/replay, kullanıcı yanıtı ve gerçek sonuç; Claude onayı; iki sağlayıcıda gereken aktif-iş Quit kanıtı.
- A/D: tasarım/girdi/erişilebilirlik, görünür/gizli terminal, ölçek/uzun kullanım, GPU ve kaynak bütçeleri, imza/izin sürekliliği, çökme ayrımı.
- OWN-1: normal Stop/Quit sonrası sahip olunan tüm işleri kapatma ve dış süreçlere dokunmama birlikte sağlanmalı. Endpoint Security gibi dış yetki gerektiren adaylar yalnız mevcut yetkiyle değerlendirilecek.
- Önceki sayısal model bütçesi kaydı: Codex 6/6 harcandı, kalan 0 (son tur aktif-iş Quit); onay tekrarı 0, Claude ek 0. Bu kapsam genişlemesinden keyfî yeni sayısal bütçe türetilmez; modelsiz uygulama/kabul ilerlerken gereken gerçek deney somutlaştırılır.

Güncel konumun tek kaynağı [STATUS.md](../../STATUS.md). Bu dosya ajan mesaj dökümü veya ikinci durum kaydı değildir; birleşik kabul/inceleme sonuçları burada kısa olarak tutulacak.

## İlk kapanış envanteri

- D1'de font/Settings/Cmd+,, Finder drop, ham yerel link ve branch eksikleri doğrulandı; `cp5_d_product` implementer'ı görevlendirildi. Ortak build başlangıçta C implementer'ında, D kod editi paralel.
- [C §41](C.md#41-cp5-kapanış-görevlendirmesi-ve-pending-replay-kanıtı-30-eylül-2026): gerçek sunucu + yerel sahte model ile geç katılımda pending approval replay ve resolution doğrulandı; native ürün kabulü değildir.
- [OWN-1 yerel capability sonucu](../experiments/cp5-own-capability-research.json): descendants API çağrısı `ERR_NOT_ENTITLED`, geçerli code-signing kimliği 0. API/root/TCC ayrımı ve sudo uyumu hâlâ kapı; bu inceleme tam sahipliği sağlamadı. Mevcut ledger'ın coalition'ı bağımsız sahiplik tohumu sayması ayrıca dış süreç güvenliği açısından incelenecek. Ürün standartları daraltılmadı.

- [GPU capability sonucu](../experiments/cp5-gpu-capability-research.json): mevcut kullanıcı yetkisiyle IOReport cihaz toplam enerji/residency ve ioreg kullanım yüzdesi okunuyor. Loom/WindowServer ayrıştırması ve D5 matrisi doğrulanmadı; bu veri CPU yerine GPU ölçümüne olanak verir, tek başına ürün kabulü değildir.

## Bütüncül strict review ve revizyonlar

Bağımsız salt okunur inceleme dört somut yarış buldu; planner-reviewer belirleyici kaynakları doğruladı. Ajan oturumu sınırı nedeniyle yeni strict-reviewer rolü açılamadı; ürüne yazmamış mevcut explorer'a strict inceleme brief'i verildi. Bu kayıt ayrı bir strict-reviewer model çalıştırıldığı iddiası değildir.

| Bulgu | Etki ve revizyon | Kanıt / kabul |
| --- | --- | --- |
| SR-CLAUDE-1 | Eski veya child hook aktif konuşmanın kimlik/durumunu değiştirebiliyor; duplicate SessionStart durumu sıfırlıyor. Aktif kimlik/child/source guard, meşru A→B→resume A korunması, yedi hook'un bounded synchronous aktarımı ve FIFO seri alımı uygulanıyor. Sıra için yeni ACK protokolü gerekmiyor; tek consumer ilk deliver'ı await ediyor. | Mevcut kodda deterministik regresyon başarısız; düzeltmeden sonra dört suite/49 test geçti, bağımsız affected review açık. |
| SR-IDLE-2 | Coalesced event'te turnComplete/runStarted kaybolunca idle timer yeniden kurulmayabiliyor. Son full snapshot'ın ilgili alanları esas alınacak. | Mevcut kodda deterministik regresyon başarısız; düzeltmeden sonra dört suite/49 test geçti, bağımsız affected review açık. |
| SR-STOP-ID-3 | Stop ile identity adoption/catalog await yarışında yeni owner canlı kalabiliyor veya runtime geri dirilebiliyor. Transition tamamlanmasını sınırlı bekleme, güncel owner ile cleanup ve deadline'da dürüst hata. | Mevcut kodda iki yönlü yarış ve bounded shutdown regresyonları başarısız; düzeltmeden sonra dört suite/49 test geçti, bağımsız affected review açık. |
| SR-APPROVAL-4 | Aynı pending raw request ID replay'i occurrence kilidini yenileyip iki cevap gönderebiliyor. Pending replay idempotent; başarılı yazı sonrası resolution'a kadar tekrar kapalı, resolution sonrası ID reuse açık. | [Regresyon önce 4 assertion başarısız, sonra ilgili 3 test başarılı](../experiments/cp5-c-join-implementation.json); bağımsız re-review hash eşleşmesi ve kaynak/test incelemesiyle başarılı; son birleşik suite/paket açık. |

D sahibinin Claude/idle/Stop için ilk 8 testinde 45 assertion başarısızlığı kaydedildi (`/tmp/loom-strict-red.log`); test başarısızlığı düzeltme kabulü değildir. Birleşik son suite ve paket henüz bu revizyonları doğrulamadı.

[Strict revizyon kanıtı](../experiments/cp5-strict-fixes.json): son dar kontrol paketi 52 core, 4 terminal, 24 UI ve 23 runtime testiyle geçti; build, whitespace ve vendor patch kontrolü başarılı. Planner-reviewer 21 kaynak/test hash'ini ve belirleyici overflow/Stop timeout kodunu bağımsız eşleştirdi. SR-CLAUDE-1 ve SR-IDLE-2 için bağımsız affected kaynak incelemesi kapanış önerdi. SR-STOP-ID-3b'deki eksik timeout raporu önce üç assertion ile başarısız, düzeltmeden sonra başarılı; SR-HOOK-DROP-5 önce dört assertion ile başarısız, düzeltmeden sonra başarılı. Bu iki takip revizyonunun bağımsız affected review'u ve son birleşik/native kabul açık.

Komşu runtime testindeki ham sağlayıcı hata metni beklentisi, mevcut redaction/category sözleşmesine aykırıydı; sabit `providerError` kategorisi, sinyal gönderilmemesi, kartta hata ve başarılı tekrar doğrulanacak şekilde düzeltildi. Ürün hata içeriği genişletilmedi veya başarısız Stop beklentisi kaldırılmadı.

Bağımsız takip incelemesi SR-STOP-ID-3b ve SR-HOOK-DROP-5 için altı ilgili kaynak/test ve altı log hash'ini eşleştirdi; yeni somut blocker bulmadı. Planner-reviewer bu iki kod bulgusunu kapattı; zorlanmış sample-failure testi yok, ilgili dal statik doğrulandı. Son birleşik/native kabul ayrı açık kalır.

## Native Codex zinciri — yerel sahte model

[Native kabul kanıtı](../experiments/cp5-c-native-local-acceptance.json): gerçek Codex 0.159.2 TUI + paketlenmiş Loom ile yeni konuşma → cevaplanabilir onay → ret/turnComplete → Stop → aynı kartta Resume → ikinci onay → gizli pencere → normal Quit başarılı. İki sentetik tur, gerçek model turu 0; normal Quit kalan sahip olunan kayıt 0, uygulama kapandı. Sonuç eski paket hash'ine bağlı; strict revizyonlarından sonraki paket için yeniden kabul gerekli. Gerçek uzak model ve OWN-1'in izlenemeyen kaçak çocuk güvencesi bu deneyle kapanmadı.

### Strict takip sınırları

- **SR-HOOK-DROP-5:** FIFO sıralaması kayıpsız teslim sağlamıyor. 1024 bekleyen delta aşılırsa `AsyncStream.yield` düşürme sonucu sessiz kalıyor. Kaybolan envelope'un run'ını kalıcı güvenilmez/unknown yapan, görünür hata ve otomatik idle engeli taşıyan dar revizyon görevlendirildi. Olağan yükte bu taşma yaşandığı iddia edilmiyor; deterministik taşma kontrolü gerekli.
- OWN-1'in coalition-only seed riski yeniden kaynakla doğrulandı: boot/resource ID ve başlangıçta tek üye gözlemi ömür boyu münhasırlık kanıtı değil. Bu önceki OWN-1 bulgusudur; yeni dış süreç öldürme deneyi yapılmadı, kabul edilmiş §3 policy sessizce değiştirilmedi. PID birthtime/UID kontrolü ile `kill` arasındaki teorik reuse aralığı da atomik garanti diye sunulmuyor; yerelde yeniden üretilmedi ve bağımsız yeni refactor kapsamı açılmadı.
- D1 cam açığı: mevcut opacity rengi gerçek native material değildi. Sidebar material + koyu tint, opak terminal ve Reduce Transparency'de material kaldırılması onaylandı. Sistem tercihlerine dokunmayan evidence-only cam/opak seçimi ölçümde etkin modu kaydedecek.

## Native Claude ret akışı — yeni engelleyici bulgu

[SR-CLAUDE-DENY-6 kanıtı](../experiments/cp5-claude-native-denial-research.json): gerçek Claude Code 2.1.284 TUI + localhost sahte modelde PermissionRequest Loom'da doğru göründü; terminalde **No** seçilince CLI girişe döndü fakat Loom 180 saniye `Needs approval` kaldı. Aynı native session/PID için resmi `claude agents --json` çıktısı `idle` döndürdü. Bir sentetik tur, gerçek model 0; normal Quit kalan 0 ve uygulama kapandı.

Güncel [hook sözleşmesi](https://code.claude.com/docs/en/hooks), `Stop`'un kullanıcı kesintisinde çalışmadığını ve `PermissionDenied`'in manuel ret için olmadığını açıklıyor. Eski paketle bulunduğu için son paket doğrulaması da gerekli; zamanlayıcıyla idle varsayımı veya terminal metni regex'i çözüm sayılmayacak. `claude agents --json` durumunun yapılandırılmış kaynağı ve olay tabanlı abonelik imkânı araştırılıyor; kimlik/nesil doğrulaması korunacak.

İzole gerçek CLI deneyi, kendi PID/session kaydında `waiting → busy → idle` geçişini ve vnode write bildirimlerini doğruladı. [Kalıcı kanıt](</Users/gencberke/Library/Application Support/Loom-Dev/probe/runs/cp5-claude-registry-5361222b-43d1-47b5-be70-11e0d36b8cc2/result.json>): remote model 0, denied dosya oluşmadı, kendi süreçlerinin temizliği bağımsız doğrulandı. Registry özel CLI implementasyonudur; public ve kararlı şema iddiası yok.

Dar düzeltme: yalnız managed leader PID/doğum/UID, çalışma dizini, run/aktif konuşma ve watcher nesli eşleşen bounded metadata snapshot'ı değişim bildirimiyle oku. Gecikmiş tüketici için hook'un kaynak `sentAt` watermark'ından yeni `idle`, mevcut sayıları koruyarak yalnız `waitingForInput` üretir. Başarı/turnComplete veya sıfır arka plan işi çıkarılmaz; otomatik idle engeli sürer. Eşit milisaniye, geri giden/gelecek saat, uyumsuz veya bounded retry sonrasında bozuk veri dürüst unknown ve görünür hata olur. Başlangıçta dosyanın henüz oluşmaması normaldir. Sürüm sabitleme, CLI polling, transcript veya terminal metni ayrıştırma yok.

## D ölçüm ve native arayüz hazırlığı

[Ölçüm düzeneği](../experiments/cp5-d-measurement-harness.json): gerçek surface/PTY havuzu, bağımsız byte/footer oracle, tekil komut ACK, PID doğum kontrolü ve weak nesne sayımı kısa denemelerden geçti. Seçili view'in bırakılmaması önce weak1 ile yakalandı; evidence köprüsünde first responder temizliği sonrası weak0 doğrulandı. Uzun koşular, 100 çevrim, Metal/örtülü/GPU matrisi henüz kabul edilmedi.

[Native D1 kısmi kabulü](../experiments/cp5-d-native-ui.json): ayrı sabit debug probe paketinde Cmd+,/dişli, 11–20 pt mevcut/yeni terminal ve kalıcılık, proje/aktivite görünümü, sidebar kısayolu, 1220×780 ve 780×500 düzeni, cam/opak görünüm ve yeniden açılışta sıfır otomatik sağlayıcı doğrulandı. Gerçek Finder drag, link açma ve sistem hareket tercihi değişimi native olarak doğrulanmadı; bu kayıt final release veya tam D1 kabulü değildir.

## Son birleşik kontroller ve saat dilimi regresyonu

[Birleşik suite](../experiments/cp5-final-combined.json): 28 suite içinde 271 test geçti. Bu koşudan sonra planner-reviewer gerçek CLI kayıt örneğini OS doğum zamanıyla karşılaştırarak UTC açığını buldu: Claude `procStart` değerini `LC_ALL=C,TZ=UTC` ile üretirken okuyucu yerel saat dilimini kullanıyordu. Dinamik test fixture'ı aynı hatayı taşıdığı için önceki testler bunu yakalamamıştı. Sabit gerçek kayıt ve epoch ile bağımsız regresyon önce başarısız oldu; UTC revizyonu ve affected kontroller ayrı kaydedilecek. Native final paket kabulü bunun ardından yapılacak.

Ölçüm oracle'ında yalnız kesin ESRCH süreç yokluğu sayılır; kısa cevap veya izin/sorgu hatası başarısız ölçümdür. Negatif EPERM regresyonu ve kendi canlı/sonlanmış çocuk kontrolleri geçti. GPU sampler cihaz toplamını `CLOCK_UPTIME_RAW` ile kaydeder; uygulama uptime ile hizalanır. Bunlar ölçüm doğruluğu revizyonlarıdır; uzun kullanım veya Loom/WindowServer GPU bütçesi kabulü değildir.

UTC revizyonu 35 registry/runtime testi ve build'den geçti; bağımsız affected inceleme kaynak/log hashlerini eşleştirdi. Strict kod bulguları kapatıldı. `8a83845…` release paketinde [Claude native zinciri](../experiments/cp5-claude-native-final.json) dört yerel sentetik turla Escape, ret, aynı kartta Resume, ikinci ret, clear kimlik değişimi ve gizli Quit'i doğruladı. [Codex native zinciri](../experiments/cp5-c-native-final.json) iki yerel sentetik turla ilk cevaplanabilir onay, ret/completion, Resume ve gizli Quit'i doğruladı. Uzak model turu 0; bu kayıtlar uzak model bütçesi ve OWN-1 kabulünü değiştirmez.

[Birleşik fake-provider kabulü](../experiments/cp5-final-combined.json) son pakette 22 kontrolden geçti; başlatma sırasında Quit, gizli aktif iş, dış kontrol sürecinin korunması, zorlanmış başarısız Quit/tekrar ve yeniden açılışta no-autostart dahil. [D6 crash kanıtı](../experiments/cp5-d-crash-acceptance.json) son release ve düzeltilmiş PID oracle ile SIGKILL/SIGABRT başına 14 kontrolden geçti.

## Optimizer incelemesi

Strict kaynak incelemesi ve native zincirlerin ardından optimizer görevlendirildi. İlk somut revizyon **OPT-Quit**: `SessionRuntime.shutdown` gözlemciyi iptal etmeden önce bitmiş run kayıtlarını kesin olarak uzlaştırmıyor. Bir Claude run kapanıp diğer run nedeniyle Quit başarısız olduğunda bitmiş run'ın registry izleyicisi kalabiliyor. Dar düzeltme ve deterministik gecikmiş-observer regresyonu görevlendirildi; canlı başarısız run'ın retry bilgisi korunacak.

İki yapısal takip henüz kapanış engeli sayılmadı: ömür boyunca dokunulan session metadata haritasının birikmesi ve aynı sayfadaki ortak Git yolunun tekrar okunması. Bitmiş metadata hâlâ okunmamış bitiş/hata bilgisi taşıyabilir; kör budama ürün kaybıdır. 100 çevrimli terminal havuzu provider/runtime metadata haritalarının tamamını sınamaz. Sayısal kaynak kabulü ile bu sınırlar ayrı değerlendirilecek.

OPT-Quit düzeltmesi bitmiş run’ları her shutdown sonucunda uzlaştırıyor; başarısız Quit’in canlı run’ını yeniden denemeye koruyor. Gözlemci başlamadan gerçek watcher FD’lerini ölçen regresyon eski kodda dört cleanup assertion ile başarısız, yeni kodda başarılı oldu. Etkilenen 69 test ve bağımsız kaynak/log incelemesi geçti; [kanıt](../experiments/cp5-optimizer-fix.json). Son birleşik koşuda watcher testinin ortak geçici klasör kaynaklı izolasyon açığı da ayrıldı; yalnız test fixture’ı düzeltildikten sonra **274 test / 28 suite** geçti. Son paket ve ölçümler bu kaynak durumu üzerinde sürüyor.

Son `3268bac…` release paketinde C sentetik native kabulü **22/22** tekrar geçti. [Gerçek Codex aktif-iş Quit](../experiments/cp5-c-real-active-quit-final.json) tek yetkili uzak turla doğrulandı: Working durumunda gerçek `sleep 40` PID/doğumu canlıyken normal Quit; app, TUI, server ve komut doğumları yok, runtime/lease 0, dış kontrol canlı. Codex bütçesi **6/6**, kalan 0. Bu dar başarı OWN-1 kaçak süreç garantisini veya ayrı ilk-onay kabulünü kapatmaz.

## CPU ölçüm birimi düzeltmesi

Planner-reviewer son kaynak incelemesinde `proc_pid_rusage` Mach tick değerlerinin nanosaniye diye etiketlendiğini buldu. Bağımsız kendi-süreç `getrusage`/CPU clock kalibrasyonu bu hostta 125/3 dönüşümü gerektiğini gösterdi. [CPU birim düzeltmesi](../experiments/cp5-cpu-unit-fix.json): bağımsız regresyon RED→GREEN, 10 ilgili test, strict C derlemesi, aritmetik sınırlar ve build geçti; bağımsız affected inceleme üç kaynak ve 12 artifact hash’ini doğruladı. Eski wrapper kaynaklı CPU kabul rakamları doğrulanmamış sayılır; sayılar sonradan çarpılıp kabul edilmedi. Bellek/byte/render alanları değişmedi.

`b24ed027…` yeni release paketi strict imza doğrulamasından geçti. Önceki native yaşam döngüsü/arayüz kanıtları kendi hash’leriyle korunuyor; revizyon yalnız ölçüm birimindedir. Son uzun kaynak matrisi bu yeni pakette yürütülüyor.

## Ayrı strict-reviewer ile son bütüncül inceleme

Önceki oturum sınırı kalkınca gerçek `strict-reviewer` rolünde ayrı bir ajan, son kaynakları bağımsız ve salt okunur inceledi. Optimizer’ın nihai ölçüm değerlendirmesi bu incelemenin revizyonlarından sonra tamamlanacak.

| Bulgu | Etki ve doğrulama |
| --- | --- |
| SR-CODEX-INIT-7 | Eşzamanlı ilk Codex başlangıçlarında kurulum await’leri iki coordinator/consumer oluşturabiliyor; deterministik regresyonda ikinci kartın yanıtlanabilir onayı ve sonucu kayboldu. |
| SR-CODEX-MATCH-8 | Aynı dizindeki bağlı A’nın duplicate `thread/started` olayı bekleyen B rezervasyonunu tüketiyor; dar router regresyonu eski kodda başarısız. |
| SR-ADOPT-TARGET-9 | Resume kimlik devrinin catalog await’i sırasında hedef sohbet launch/adoption için ayrılmıyor; ikinci canlı run karttan kopabilir. Kaynakta planner-reviewer doğruladı; deterministik davranış kabulü hazırlanıyor. |
| SR-STOP-RETRY-10 | Provider completed temizliği hata verdiğinde process0 olsa da failed report kalırken run siliniyor; Stop retry ve Resume birlikte kapanıyor. Kaynakta doğrulandı; belirsiz join bariyerini bypass etmeden toparlanma tasarlanıyor. |

[İki uzun kaynak koşusu](../experiments/cp5-d-resource-final.json) CPU birimi düzeltilmiş `b24ed027…` pakette 600’er saniye geçerli: tekli +3,5625 MiB, onlu −3,1875 MiB ilk/son dakika median farkı; son beş dakikada sürekli büyüme yok. Byte oracle, weak nesne0 ve kayıtlı süreç0 doğrulandı. Bu terminal havuzu kabulü provider/runtime metadata ömrünü kapsamaz; kalan kaynak matrisi revizyonların ortak build/test slotu bitince devam edecek.

SR7/SR8 kaynak bulguları kapatıldı: planner-reviewer dört kaynak ve dokuz artifact hash’ini, gerçek RED/GREEN loglarını ve final patch’leri bağımsız doğruladı; ayrı strict-reviewer kaynak/test davranışını inceledi. [Dört dar ve 75 affected test kanıtı](../experiments/cp5-codex-final-strict-fixes.json) başarılı; son birleşik/native kabul ayrı açık. Strict inceleme ayrıca Stop süreç örneklemesinin başarısızlığını boş liste sayarak retry sahipliğini kaybettiği yolu doğruladı; SR10 revizyonu bilinmeyen sayıyı sıfırdan ayırmalı ve runtime/hook’u korumalı.

SR9 için hedef reservation/defer düzeltmesi ve iki regresyon geçti; planner-reviewer üç kaynak/dört log hash’ini ve 47 affected test sonucunu doğruladı. Ayrı strict affected review SR10 ile birlikte yapılacak. [Resume fanout araştırması](../experiments/cp5-codex-resume-fanout-research.json), kurulu gerçek Codex sunucusunda loaded/abonelikleri bırakılmış/cold persisted resume için ilgisiz gözlemciye `thread/started` çoğalmasını üretmedi; native TUI sıralaması veya gelecek sürümler için garanti sayılmadı, spekülatif katman eklenmedi.

SR10’un aynı retry/sahiplik invariant’ı terminal kapanışı ve durable katalog yazısını da kapsıyor; timeout pending yazıyı unutturamaz. Ayrı strict kaynak incelemesi Stop prepare beklerken Quit’in aynı run’ı silmesi ve geç Stop’un eski runtime’ı yeniden ekleyip başarılı Quit üzerine hata yazması yarışını doğruladı. Tek finalizer sahipliği ve iki yönde admission, mevcut gate ile deterministik regresyon kapsamında düzeltilecek; ürün kabulü daraltılmadı.

SR10 coordinator alt parçası main ve ayrı strict affected incelemesinden geçti: üç kaynak/12 artifact hash’i, gerçek RED7→GREEN3 ve true-timeout/no-RPC kanıtı doğrulandı. [Kayıt](../experiments/cp5-codex-final-strict-fixes.json). Supervisor birleşik regresyonu eski kaynakta RED19 idi; son revizyonda dar Stop/Quit/katalog/sampling kontrolleri ve 145 affected test geçti. Kaynak donduruldu; supervisor son strict kabulü, optimizer kaynak incelemesi ve final paket/kaynak kabulü ayrıdır.

Son strict affected incelemesi SR10 için tek ek P1 buldu: prepare başarılı olsa da süreç sayımı tamamen başarısızken yaşayan TUI yeni iş üretebilir; retry eski prepare sonucunu kullanınca yeni sunucu işini durdurmadan başarı verebilir. Provider iş durdurması, üretici süreçlerin sıfırı doğrulanana kadar yeniden yapılacak; join drain idempotent kalacak ve belirsiz bariyer atlanmayacak. Tamamlanmış provider/katalog aşamaları yeniden tüketilmeyecek.

Aynı dondurulmuş kaynakta tam suite **290 test / 28 suite** çalıştı; tek başarısızlık app-server başlangıcı iptalinde internal run'ın tutulmasıydı. Sonraki global shutdown geçti. [Birleşik kanıt](../experiments/cp5-final-combined.json) başarısız sonucu koruyor; başlangıç cleanup'ının hata/sahiplik aktarımı implementer tarafından inceleniyor. Native ve kaynak matrisi ürün kaynakları tekrar sabitlenince devam edecek.

SR10 son revizyonları main ve ayrı strict tarafından kabul edildi. Provider üreticisi sıfır olmadan prepare kanıtı saklanmıyor; sıfırdan sonra gate/unsubscribe öncesi sunucu işi yeniden doğrulanıp durduruluyor. Başarısız app-server başlangıç temizliği internal handle'ını koruyor. Gerçek RED→GREEN8, 109 affected test ve build geçti; C3/D4 kaynak ve kalıcı log hash'leri bağımsız eşleşti. [Son strict kararı](../experiments/cp5-final-strict-review.json) bu deltada engelleyici bulgu bırakmadı; native kabul ayrı açık. Son optimizer kaynak incelemesi ve tam suite başlatıldı.

[Son optimizer kaynak incelemesi](../experiments/cp5-final-optimizer.json) yeni engel bulmadı. Metadata ömrü ve ortak Git yolu tekrar okuması ölçülmemiş, engelleyici olmayan takipler olarak kaldı; okunmamış bitiş/hata/retry verisini kaybettiren budama yapılmadı. Kaynak matrisi sonrasında ölçüm değerlendirmesi tamamlanacak. Son tam suite'in tek lifecycle hatası erken test bariyeriydi: run silinmesinden sonra meşru timer reschedule hâlâ sürebiliyordu. İç completion sayacıyla test gerçek değerlendirme sonunu bekliyor; ürün zamanlaması ve duplicate snapshot no-work oracle değişmedi. Main iki kaynak/sekiz artifact hash'ini ve dar patch'i doğruladı; lifecycle12/build geçti, tam suite yeniden sürüyor.

Son sabit release `0415fb…` için tam **293 test / 28 suite** ve **22 native kabul** geçti. Son kaynak matrisinde iki 60 saniyelik gizli koşu geçerli; iki gizli boş-uygulama koşusunda pencere kendiliğinden açıldığı, bir görünür koşuda örtüldüğü için bu üçü dışlandı. Kullanıcı gizli koşulara dokunmadığını ve şu anda başka işte olduğu için Loom'u önde tutamayacağını bildirdi. Pencere ölçümleri durduruldu; çalışan app/probe yok. Yalnız evidence caller tanılaması hazırlanıyor, kök neden doğrulanmış değil.

[Optimizer son değerlendirmesi](../experiments/cp5-final-optimizer.json) mevcut geçerli koşularda yeni kaynak engeli göstermedi; tekrar/dağılım/GPU/bütçe eksiklerini kapatmadı. Ardından [Herdr/Orca explorer karşılaştırması](../experiments/cp5-final-herdr-orca.json) tamamlandı. Yeni agent thread sınırı nedeniyle mevcut explorer ajanı optimizer sonrası ayrı görevle kullanıldı. Main Herdr'ın `getsid` → sabit PID listesi → HUP/TERM/KILL zincirini ve Loom'un gözlenmemiş kaçış oracle'ını bağımsız okudu: Herdr'a geçiş OWN-1 çözümü olarak kanıtlanmıyor. Mevcut Loom çekirdeğini koruma ve dar davranış/test desenlerini alma önerisi benimsendi; migration veya §3 değişimi yapılmadı.

[Pencere caller tanılaması](../experiments/cp5-visibility-caller-trace.json) yalnız evidence modunda bounded çağrı/Apple Event zarf metadata'sı ekliyor. Main kaynak/snapshot ve 15 artifact/ack hash'ini doğruladı; offline build/diffcheck geçti. Normal pencere akışı değişmedi. Kullanıcının işi bölünmedi; app/paket çalıştırılmadı, kabul edilmiş `0415fb…` binary aynen korundu. Güncel kaynak bu tanılama deltasını içerir; runtime kök neden ve düzeltme iddiası yok.

## Son ölçüm sonucu ve kullanıcı durdurması

Kullanıcının yeniden verdiği görünür pencere izniyle [kaynak matrisi](../experiments/cp5-d-resource-final.json) **40/40** geçerli koşuya tamamlandı. [Gecikme](../experiments/cp5-latency-final.json) iki renderer’da **2.000 örnek / sıfır timeout**; p95 medyanları CoreGraphics18,759ms ve Metal20,015ms. Gecikme düzeneğinin yanlış terminal yüzeyi bağlantısı evidence-only düzeltilip ayrı8a4a01fd pakette doğrulandı; kabul0415 paketi korunuyor. Optimizer gerçek sonuçları bağımsız yeniden hesapladı, yeni ölçülmüş blocker bulmadı. Metadata/Git takipleri engelleyici değil ve ölçülmemiş kalıyor.

[GPU](../experiments/cp5-gpu-final.json) görünür4 geçerli; örtülü4 doğrulanmadı. Tam örtülme sağlanamadığı için başlayan denemeler dışlandı; son deneme kullanıcı durdurmasıyla sonlandırıldı. Kullanıcı tüm çalışmayı durdurdu. Test Finder penceresi kapatıldı, app normal Quit ile kalan0 raporladı, kendi GPU sampler’ı durduruldu ve Loom/ölçüm süreçlerinin kalmadığı kontrol edildi. Yeni çalışma başlatılmayacak. CP5 kapanmadı; OWN1, ek sağlayıcı bütçesi, imza/izin ve kalan kabul sınırları korunuyor.

## OWN-1 yeni aday: run başına coalition kapsamı (2 Ekim 2026)

Kullanıcı devam etmeyi ve OWN-1'e yeniden bakmayı istedi. [Run kapsamı araştırması](../experiments/cp5-own-run-scope-research.json) modelsiz ve sağlayıcısız yapıldı. Loom coalition oluşturamıyor ve çocuğunu başka coalition'a koyamıyor (EPERM, XNU kapısı). LaunchServices ile açılan AppKit'siz ~1 MB yardımcı ise her açılışta yeni ve tek üyeli bir coalition alıyor. Bu yardımcının altında `setsid` ve çift fork ile launchd'ye geçen işaretsiz `/bin/sleep` yardımcı çıktıktan sonra da aynı coalition'da kalıyor. `p_orig_ppidversion` fork anındaki ebeveyni exec ve yeniden ebeveynlenmeden sonra da koruyor. Bu alan launchd'nin başlattığı üyeleri (yardımcı, Apple XPC örnekleri) çatallanmış işten ayırıyor.

Dondur→kimliği yeniden doğrula→öldür döngüsü, sinyalleri yok sayıp sürekli yeniden çatallanan ve 3 saniyede 1.729 süreç üreten kaçağı temizledi. Bu döngü launchd üyelerine hiç sinyal göndermiyor. Metal XPC örneği istemcisi gidince launchd tarafından kapatıldı; dış kontrol süreci etkilenmedi. LaunchServices/launchd'ye devredilen iş (`open`, `launchctl`) yapısı gereği run kapsamı dışındadır.

Bu bir mimari aday; ürün kodu değişmedi. Benimsenmesi için kullanıcı kararı gerekiyor: sözleşme §3/§6'da coalition rolünün değişmesi, Codex ortak sunucusunda oturum başına kapsam ve Loom çökünce yardımcının davranışı. Herdr/Orca güncel kaynakları ve son CLI sürümleri (Claude Code 2.1.287, Codex 0.160.0) bu açığı kapatan bir mekanizma göstermedi.

Kullanıcı aynı gün üç kararla adayı benimsedi: run kapsamı, oturum başına Codex sunucusu ve Loom çökünce yardımcının run'ı durdurması. Sözleşme §3/§6 güncellendi. Uygulama ve kabul [OWN planında](OWN.md) izlenir. Bulunan yeni kısıt: korumalı klasör (TCC) izinleri run yardımcısına atfedilir.

## Son yetki ve kabul — 3 Ekim 2026

Kullanıcı sabit imza, host dahil kaynak/GPU ölçümleri, kalan native kabul ve belgelerin uzlaştırılmasını istedi; önceki durdurma ve sayısal model sayacı kayıtları tarihsel kalır. Aktif plan [FINAL-ACCEPTANCE](FINAL-ACCEPTANCE.md), güncel konum [STATUS](../../STATUS.md).

[Son imzalı/native kabul](../experiments/cp5-final-signed-native.json): yerel imza ve Belgeler TCC sürekliliği, 322 test, canlı compiler XPC şartlı OWN-A4, paket C Quit10/çökme13/C23, gerçek Claude native No ve Reduce Motion doğrulandı. Son optimizer kaynak incelemesi yapıldı; GPU başlangıç hazırlığı zamanlaması bulgusu düzeltildi ve kaynakta kapandı.

Yeni [kaynak43](../experiments/cp5-final-runscope-resource.json) ve [gecikme2000](../experiments/cp5-final-runscope-latency.json) geçerli; optimizer ham toplamları ve host dahil uzun büyümeyi doğruladı. [GPU](../experiments/cp5-final-runscope-gpu.json) dört görünür hücre geçerli, dört örtülü hücre native foreground araç sınırında açık. Finder drop/link dispatch ve [sayısal bütçe önerisi](RESOURCE-BUDGET-PROPOSAL.md) kullanıcı hareketi/kararı bekler. CP5 tamamlanmadı; ölçülmeyen veya tek hücreden çıkarılamayan GPU maliyeti başarı sayılmaz.


[CPU/Codex kaynak kabulü](../experiments/cp5-cpu40-source.json) ve [son ölçülen D](../experiments/cp5-cpu40-optimization.json): kare dirty işleri, Codex idle polling/deadline işleri ve yanlış başarılı onay yanıtı düzeltildi; ptrace fixture cleanup'ı ownership oracle'ları korunarak bounded yapıldı. Astra/high review ve birleşik334 geçti. D23/23 koşul geçerli, gecikme2000/timeout0 ve bütün cleanup0; yoğun CPU medyan CG%44,812 / Metal%45,455 ile %40 tavanı başarısız. [ASCII adayı](../experiments/cp5-ascii-render-optimization.json) kaynak review ve yeni birleşik334'ten geçti; imzası/runtime kazancı Mac kilidinde doğrulanmadı, kurulu D korundu. Gerçek Codex modelsiz idle/Stop ayrıştırması çalıştırılmadı. C native/GPU/uzun kanıtları tarihsel paket kapsamını korur; Finder/link/örtülüGPU4 kullanıcı tarafından ertelenmiştir. Güncel iş [FINAL-ACCEPTANCE](FINAL-ACCEPTANCE.md); CP5 açık.

## Checkpoint optimizer (5 Ekim 2026, Opus 5.5 / xhigh, salt okunur; UI dışı alan)

Rapor kaynağı: optimizer subagent'ının doğrudan raporu (UI dosyaları implementer'larda olduğundan kapsam dışı; UI diff'i ayrı turda). Planner-reviewer F1'i bağımsız doğruladı: yedeklenen 20 sentetik kayıt (cwd `$HOME`, 30 Eylül ve 2 Ekim'de 5–7'lik kümeler) ile `scripts/cp5-a-acceptance.sh`'in `--evidence` verip `--data-root` vermemesi ve `dataRoot()`'un yalnız ikisi birlikteyken izole kök kullanması örtüşüyor.

| ID | Bulgu | Karar |
| --- | --- | --- |
| F1 (+S3) | `--evidence` tek başına izolasyon sağlamıyor; A betiği varsayılan kataloga yazıyor; `--data-root` evidence olmadan sessizce yok sayılıyor | **Engelleyici**, kararlı sürüm öncesi |
| F2 | Kalıcı alt süreçli (MCP vb.) çalışan sohbette idle değerlendirmesi 5 sn'de bir sonsuza dek tekrarlanıyor (tam süreç tablosu + SQLite + yayın) | Kararlı sürüm öncesi |
| F3 + F5 | Claude registry `~`/`~/.claude` olaylarında her oturum için tam süreç taraması ve değişmeyen durum yayını; hub eşit durumu da yayınlıyor | Kararlı sürüm öncesi |
| F4 | Gizli/detached terminalde her PTY okuması ana thread'e görev gönderiyor (yama 5 kapsamı) | Kararlı sürüm öncesi |
| F7 | Paket betiği kurulu uygulamayı yerinde siliyor/imzalıyor; çalışırken veya imza yarıda kalınca bozuk kalabilir | Kararlı sürüm öncesi |
| F6, F8–F10, S1 (kısmen F3'te), S2, S4 | Procargs taraması, açılışta bütün oturumlar, oturum başı birikim, boş env host, tek PID için tam tablo, elle async kilit, SessionRuntime boyutu | Kararlı sürüm sonrası |

Ek: evidence komut kanalı sistem geneli (eşzamanlı örnekler çapraz konuşuyor) — F1/S3 ile birlikte düzeltilir. P3 için son teste eklenecek senaryo: akış sürerken oturum değiştirme ve Cmd+W/yeniden açma sonrası bayat satır yok.

## Checkpoint optimizer, ikinci tur: UI diff (5 Ekim 2026, Opus 5.5 / xhigh, salt okunur)

Liste düzeyinde sürekli yeniden hesaplama yok (tek `TimelineView` yalnız gösterge canvas'ını yeniler). Kararlar:

| ID | Bulgu | Karar |
| --- | --- | --- |
| B1 | Gösterge yalnız görünmezken duruyor; sözleşme §10 "gizli veya etkin olmayan pencerede" durmasını istiyor | Sözleşmeye uyulur (DESIGN §5 düzeltildi); O-4 |
| B2 | Daraltılmış projenin noktası arama sonrası satır budanınca kayboluyor | O-4, regresyon testiyle |
| R2 / S1 | Sidebar kapalıyken gösterge dönebilir; aynı pencere için üç ayrı durum kaynağı; tam ekranda sidebar başlığı boşluk ayırıyor | O-4: durum modelden (görünür+etkin, tam ekran, sidebar kapalı), probe'lar kalkar |
| S2 | `.focusEffectDisabled()` + odak çizimi olmayan stil: klavye odağı görünmüyor | O-4: stilde ince odak halkası |
| S3 | Başlık sabitleri/renk tekrarları, ölü sabit, detay başlığında farklı düğme stili | O-4: ucuz kısımlar; tam `WindowChrome` navbar konuşmasına |
| U1 | Daraltılmış projeden başlatılan sohbet görünmüyor | O-4: başlatınca proje açılır |
| W1 | Otomatik pencere sekmeleri kapalı değil | O-4 |
| R1 | Gösterge uyanma maliyeti ölçülmedi; matris ayırt etmiyor | Son teste hücre eklenir |
| — | Toolbar bandında başlık kontrollerinin hit-test'i doğrulanmadı | O-4 evidence + son paket kullanıcı kontrolü |

## Checkpoint optimizer, üçüncü tur: kapanış (6 Ekim 2026, Opus 5.5 / xhigh, salt okunur)

Kapsam: 2. turdan sonra gelen ve optimizer görmemiş değişiklikler. Önceki bulguların düzeltmeleri: O-1..O-4 ve S2-b. Ayrıca UA-5/UA-6 render sunucusu göstergesi, P3-S aynı satır atlama ve kutu çizimi renk önbelleği, testteki sınırlı teardown beklemesi. Önceki bulguların her biri kapandı / kısmen / açık olarak işaretlenir. Sonuç: **kapanışı engelleyen bulgu yok.** F1, S3 (1. tur), F2, F3, F4, F5, F7, B1, B2, R2/S1, S2, U1 ve W1 kapandı; S3 (2. tur) kısmen kapandı, iki ölü sabit kaldı. Evidence kanalı da kapandı. UA-5/UA-6 gösterge yaşam döngüsü ve P3-S aynı satır atlama doğru bulundu: bayat piksel yolu açılmıyor, karşılaştırma maliyeti ölçülü. Planner-reviewer S-A, S-B ve test notlarını kaynakta doğruladı.

| ID | Bulgu | Karar |
| --- | --- | --- |
| S-A | LOOM-VENDOR'da iki madde 11; güncelleme listesinde aynı satır atlama yaması yok | Düzeltildi (6 Ekim): madde 12, listeye eklendi |
| Test | `TestProcessReaping` sinyali `isRunning` kontrolsüz gönderiyor; P3 testinde `P3DBG` print'leri ve tekrarlı satır | Düzeltildi (yalnız test; test derlemesi geçti) |
| S-B | `CatalogTheme.accent` ve `CatalogTheme.sidebarWidthRange` ölü | Kararlı sürüm sonrası: ürün kodu, davranış değişmez, doğrulanmış paket I yeniden üretilmez |
| S-C | `ChromeButtonStyle` örnek başı `@State` ve bildirim aboneliği | Kararlı sürüm sonrası (sadeleştirme) |
| R-A | Göstergenin WindowServer (render sunucusu) maliyeti ölçülmedi; app tarafı ≈%0,005 | Ölçüm açığı, engelleyici değil: kullanıcı bilgisayarı kullanmadığında dönen/durağan WindowServer CPU farkı ölçülür; anlamlıysa animasyona 10 fps `preferredFrameRateRange` |

İncelenmeyen alanlar optimizer raporunda: Codex, navbar, ertelenenler, `EvidenceResourcePool`, loom-probe, run-host, Metal, Settings.

## CP5 closure (6 Oct 2026)

**Closed by user decision** ("CP5'i kapatalım, stabiliz"; [D-23](../../DECISIONS.md)). Basis: package I verified (release suite 377/377 with one intended known issue; CPU40 passed, stream1 total 25.4–25.6 %; spinner1 12.6–14.7 %; hidden 3.5 %; p95 ~20 ms; working indicator ≈0.005 %; real Claude 11/11 — [PERF](PERF.md#son-paket-doğrulaması-6-ekim-2026-paket-i)), optimizer pass 3 with no blocking finding (above), and the user using the app as stable.

- **Codex-only items** are moved to the [Codex backlog](CODEX-BACKLOG.md) (O-02 resolved).
- **Resource budgets beyond CPU40** (O-01) do not block CP5; they move to roadmap stage R (release readiness).
- **Carried forward, not blockers:** R-A (WindowServer cost of the indicator) and S-B (dead theme constants, removed by the theme rewrite) to stage I; S-C and the post-stable optimizer items (F6, F8–F10, S2, S4) to stage F; Finder drop/links, occluded GPU cells, Metal fast path and the spinner layer split stay deferred (O-07).
- The user's eye check of package I was not recorded item by item; the user reported the app stable in daily use.
