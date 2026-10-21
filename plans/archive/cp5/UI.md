# CP5 UI — kullanıcı geri bildirimiyle cila ve kararlı sürüm (5 Ekim 2026)

## Hedef

Kullanıcı paket G'yi elle denedi ve [geri bildirim](#geri-bildirim-5-ekim-2026) verdi. Hedef: bu maddeleri kapatmak, checkpoint optimizer'ını çalıştırmak, ardından tek bir son büyük testten geçmiş, her açılışta aynı davranan kararlı bir paket. Kullanıcı yol boyunca bulunan **kesin** UI/UX, kod ve optimizasyon iyileştirmelerini yapma yetkisi verdi. Belirsiz tasarım tercihleri ve navbar (madde 6) kullanıcıyla konuşulur.

## Geri bildirim (5 Ekim 2026)

1. Sidebar düğmesinin ikonu bozuk (mavi dolgu gibi görünüyor).
2. Sidebar kapalıyken terminal arayüzü ile native pencere düğmeleri çakışıyor.
3. Proje satırına sağ tıkta yeni Claude / Codex sohbeti başlatma seçenekleri.
4. Proje görünümünde kartın sağ altındaki proje adı gereksiz (kart zaten projenin altında).
5. Durum göstergeleri Unpeel'e yaklaşsın: renkli nokta, küçük noktaların dikdörtgen üzerinde birbirini izlediği dönen gösterge vb. Bu bir tasarım ilkesi olur.
6. Üst navbar daha oturaklı olmalı — **konuşulacak, bu turda değişmez.**
7. Terminal renkleri soluk.
8. Proje adının yanındaki sohbet sayısı kaldırılır; bakılmamış bitiş/dikkat varsa renkli nokta yeter.
9. Genel olarak daha sağlam/high-end deneyim; basit noktalarda takılmamak.
10. Sidebar üzerinde mavi parlama (cam malzemeden duvar kâğıdı rengi sızıyor).

## Kararlar

- Maddeler 1–5, 7, 8, 10 bu turda uygulanır; 9 bu maddelerin kalitesiyle ve kesin küçük düzeltmelerle karşılanır; 6 ertelenir.
- Durum dili (madde 5, [tasarım sözleşmesi §5](../../design/DESIGN.md#4-status-language)): çalışıyor = noktaların dikdörtgen çevresinde izlediği animasyon; onay/girdi bekliyor = turuncu nokta; bakılmamış bitiş = renkli nokta; hata = kırmızı. Animasyon düşük kare hızında, pencere görünmezken durur, Hareketi Azalt'ta durağan.
- Codex geliştirmesi duraklatılmış olsa da sağ tık menüsünde mevcut Codex başlatma yolu sunulur (yeni Codex davranışı yazılmaz).
- Sıra: U-A (sidebar) ve U-B (terminal paneli) paralel → planner-reviewer review → optimizer (Opus 5.5 / xhigh, salt okunur) → düzeltmeler → paket → [son büyük test](PERF.md#son-büyük-test-geliştirmeler-bitti-kullanıcı-başlatacak). Kullanıcı 5 Ekim'de son testi onayladı.

## İşler

| ID | İş | Sahip / yazma alanı | Durum |
| --- | --- | --- | --- |
| U-A | Madde 1, 3, 4, 5, 8, 10 | Implementer A: `Sources/LoomCatalogUI/*` (DetailView hariç), `Tests/LoomCatalogUITests/*` | implementasyon |
| U-B | Madde 2, 7; DetailView başlığının yeni durum diline uyumu | Implementer B: `Sources/LoomCatalogUI/DetailView.swift`, `Sources/LoomTerminal/*`, `Sources/loom-app/*` (gerekirse), `Tests/LoomTerminalTests/*` yeni dosya | implementasyon |
| U-C | Test betiklerinin varsayılan dev kataloguna sentetik kayıt yazması | Optimizer F1 ([kapanış kaydı](CLOSURE.md#checkpoint-optimizer-5-ekim-2026-opus-55--xhigh-salt-okunur-ui-dışı-alan)); O-1'de düzeltilir | bekliyor |
| O-1 | F1+S3+evidence kanalı, F7 | Implementer: `AppDelegate.swift`, `DevelopmentEvidence.swift`, `scripts/*` | kabul |
| O-2 | F2, F3, F5 | Implementer: LoomCore lifecycle/hub/registry | kabul |
| O-3 | F4 | Implementer: SwiftTerm FrameDriver yaması | kabul |
| O-4 | UI optimizer ikinci tur: B1, B2, R2/S1, S2, S3 (ucuz), U1, W1, başlık hit-test | Implementer: `Sources/LoomCatalogUI/*`, `Sources/LoomTerminal/TerminalTheme.swift`, `AppDelegate.swift` pencere kısmı, UI testleri | implementasyon |
| Z | Optimizer (Opus 5.5/xhigh, salt okunur; UI dışı alan şimdi, UI diff'i sonra), düzeltmeler, paket, son büyük test | Planner-reviewer | optimizer çalışıyor |

## Kabul

- Her madde için evidence `screenshot` ile önce/sonra görüntü (1220×780 ve minimum boyut; sidebar açık/kapalı; terminal canlı/değil).
- Animasyonlu gösterge: görünmez/örtülü pencerede çizim yok, Hareketi Azalt'ta animasyon yok; CPU maliyeti son testte ölçülür.
- Mevcut UI/terminal testleri korunur; ağır test yok (son teste).

## Sonuçlar

**U-A kaynak kabulü (5 Ekim; testler + evidence görüntüleri, gerçek pencere görünümü kullanıcıda).** Sidebar düğmeleri `ChromeButtonStyle` (açık renk, monochrome sembol, hover/pressed) ve `.focusEffectDisabled()`; mavi dolgunun olası nedeni açılışta odaklanan plain düğmenin macOS 27 focus efekti (B ile aynı gözlem, gerçek pencerede doğrulanmadı). Cam üstü koyu ton 0,55→0,86. Proje satırı sağ tık: yeni Claude/Codex (mevcut başlatma yolu; footer ve proje menüsü aynı bileşen). Proje görünümünde kart proje adını ve varsayılan başlıkta proje adını tekrar etmez. Sohbet sayısı yerine proje noktası (kırmızı > turuncu > mavi), bellekteki canlı durumlardan; daraltılmış/yüklenmemiş projede de görünür. Durum dili: çalışıyor = dikdörtgen çevresinde 8 noktalı kuyruklu takip, 10 fps; pencere görünmez/minimize/uygulama gizli ve Hareketi Azalt'ta durur. Sidebar başlık satırı merkezi üstten 34 pt (pencere düğmeleriyle hizalı). `LoomCatalogUITests` 47/47. Görüntüler: probe `runs/ui-a/{before,after}/ev/`. Kullanıcının tartabileceği: `.ready` artık gösterge çizmiyor; hata kırmızı nokta (şekil yok). Not: madde 4'te kullanıcının paket G görüntüsünde proje görünümü kartında proje adı görünüyordu; mevcut kod göstermiyor ve test ediyor, son pakette kullanıcı gözüyle kontrol edilir.

**U-B kaynak kabulü (5 Ekim; testler + gerçek pencere görüntüleri).** Pencere düğmeleri başlık merkez çizgisine (üstten 34 pt, soldan 22 pt) `WindowButtonsPositioner` ile yerleştirilir; sidebar kapalıyken başlık düğmeler için yer ayırır, tam ekranda ayırmaz. Soluk renk nedeni: 256 renk paleti `.base16Lab` ile 16 renge/ön plana karıştırılıyordu ve 16 renk Terminal.app paletiydi; `.xterm` 256 strateji + VS Code Dark+ 16 renk + ön plan (232,230,238), vendor değişmedi (`TerminalTheme.swift`, regresyon testi düzeltmesiz düşer). Sağlayıcı ortamına `COLORTERM=truecolor`. Başlıkta ortak `IndicatorView`. Direct/attributed piksel testleri geçti. Görüntüler: probe `runs/ui-b/{before,after}/main/real-*.png`. UB-2 (5 Ekim): elle taşınan düğmeler titlebar görünümünün dışında kalıp alt yarıda tıklanmıyordu (hitTest header'a düştü); positioner kaldırıldı, boş `NSToolbar` `.unified` + ayırıcısız titlebar ile AppKit düğmeleri üstten 26 pt'de ortalar; düğmeler tüm durumlarda container içinde ve hitTest merkez/kenarlarda düğmeyi bulur. Detay başlık satırı 36 pt, merkez 26 pt; sidebar başlığı da 26 pt'ye alınıyor (UA-3). Fare hover/tıklama son pakette kullanıcı gözüyle.

Evidence komut kanalı sistem geneli dağıtık bildirim olduğundan eşzamanlı evidence örnekleri birbirinin komutlarını alıyor (yalnız geliştirme aracı; düzeltme optimizer bulgularıyla birlikte planlanır).

**O-3 / F4 kaynak kabulü (5 Ekim).** Görünürlük askıdayken dirty-only olaylar `FrameDriverSignal`'de kilit altında tutulur, PTY okuması main-actor görevi planlamaz; askıdan çıkışta bayrak kapatılır ve biriken durum senkron tüketilip tek kare çizilir (bayraktan önceki olaylar tüketimle, sonrakiler normal teslimatla alınır; kayıp yok). Immediate/display-link/shutdown teslimatı sürer. Test: gizliyken 1000 `markDirty` → 0 teslimat, gösterince tek kare; düzeltmesiz düşer. Terminal suite'leri 20/20; yama yığını 11→1 ters uygulanır. Yama `patches/swiftterm-suspended-signal-retention.patch` (LOOM-VENDOR madde 11). Gerçek uyanma ölçümü son testte (gizli stream1 `packageIdleWakeups`).

**UA-3 (5 Ekim).** Sidebar başlık satırı merkezi yeniden 26 pt (toolbar düğmeleriyle aynı satır), toggle x≈86'da; toolbar sidebar içeriğini itmiyor, ayırıcı/arka plan eklemiyor. `LoomCatalogUITests` 47/47. Planner-reviewer son görüntüyü inceledi (`runs/ui-a/after/ev/screenshot-projects-1220x780.window.png`): hiza, proje noktası, sayı yok, kartlarda proje adı yok, çalışıyor göstergesi görünür. U-A/U-B kaynak düzeyinde kabul; gerçek pencere (mavi dolgu, cam sızıntısı, hover) son pakette kullanıcı gözüyle.

**O-1 / F1+S3+F7 kaynak kabulü (5 Ekim).** Seçenekler yeni `LoomLaunchOptions` hedefinde bir kez ayrıştırılır: evidence modu her zaman izole kök (`--data-root` ya da `<evidence>/data`); `--data-root` tek başına veya değersiz bayrak kataloğu açmaz (görünür başlangıç hatası), varsayılan köke asla düşmez (`LoomLaunchOptionsTests` 5/5). A betiği dahil bütün sürücüler `--data-root` geçer. Komut kanalı evidence dizininin gerçek yolunun SHA-256 önekiyle örneğe özgü; normal uygulama abone olmaz (iki eşzamanlı örnek ve eski global ad canlı denendi). Paket betiği hedefin yanında geçici dizinde birleştirir/imzalar, `codesign --verify --deep --strict` sonrası takas eder; hedef yoldan çalışan süreç varsa build öncesi ve takas öncesi reddeder (exit 3); geçersiz kimlikte mevcut paket değişmez. Varsayılan katalog evidence koşusunda boyut/mtime olarak değişmedi. Not: son paketleme için kullanıcının kurulu Loom Dev'i kapalı olmalı (betik bilerek reddeder).

**O-2 / F2+F3+F5 kaynak kabulü (5 Ekim).** F2: idle yeniden kontrolü yalnız `nonBaselineDescendants` tek engelken kurulur; 5→10→…→300 sn geri çekilme, durum değişiminde sıfırlanır; olay güdümlü engelde zamanlayıcı yok. F5: hub saf durum olaylarında eşit sonuçta erken döner (sequence artmaz; run start/end/detached/snapshot her zaman yayınlanır). Duplicate anlamı incelendi: `turnComplete` tekrarı zaten yok sayılıyordu; `/clear` sonrası yeni oturumun durumu work-state yayınıyla dolduğu için dedupe supervisor'da değil hub'da oturum başınadır. F3: registry üst/config dizinini yalnız alt dizin yokken izler; tek PID kontrolü (`loom_process_for_pid`, `ProcessTable.record(pid:)`); vnode okumasında değişmeyen parmak izi okunmaz, hook kaynaklı okuma her zaman okur; statik kilitli `DateFormatter`. Beş yeni regresyon testi düzeltmesiz düşer; LoomCore/UI hedefli suite'ler geçti; C `-Wall -Wextra -Werror` temiz. Dört eski test davranış gereği güncellendi. Bilinen sınır: config dizini yeniden adlandırılırsa eski inode izlenir. Gerçek zamanlı aralıklar ve CPU kazancı son testte.

**O-4 kaynak kabulü (5 Ekim).** Gösterge yalnız pencere etkin ve sidebar açıkken döner (sözleşme §10); pencere durumu ve tam ekran AppDelegate'ten modele yazılır, satır başı probe'lar kaldırıldı; tam ekranda sidebar başlığı boşluk ayırmaz. B2 regresyon testi düzeltmesiz düştü. Başlatma projeyi açar (U1). Detay başlık düğmeleri ortak chrome stilinde, odak halkası (S2; açılışta görünmemesi için klavye navigasyonu koşulu S2-b'de). Tema/geometri sabitleri tek yerde. Otomatik pencere sekmeleri kapalı. Hit-test: başlık kontrolleri sidebar açık/kapalı 1220×780'de SwiftUI hosting view'a, trafik ışıkları kendi düğmelerine düşer (`runs/ui-a/after/ev/buttons-*.json`). `LoomCatalogUITests` 50/50.

S2-b (5 Ekim): odak halkası yalnız klavye navigasyonu açık ve düğme odaktayken çizilir (fare kullanıcısında açılışta halka yok); `LoomCatalogUITests` 51/51.

**Birleşik release suite (5 Ekim, planner-reviewer).** `git diff --check` temiz; `swift build -c release` + `swift test -c release`: 37 + 5 + 280 + 51 = **373/373** geçti, tek beklenen known issue (`droppedDirtyRowIsDetected`, kasıtlı). P3 pencere kompozit testi ekran kilitsizken geçti. Log: probe `runs/final-suite-20261005.log`. PERF-R1 düzeltmesi sonrası tam suite açığı da kapandı.

**UA-5 (6 Ekim).** Son testte "gösterge dönmüyor" bulgusunun nedeni kablolama değil: bu Mac'te sistem Hareketi Azalt açık (`com.apple.universalaccess reduceMotion = 1`), gösterge tasarım gereği durağandı. Override ile açıldığında ek bulgu: SwiftUI `TimelineView` (10 fps) her tikte bütün sidebar görünüm grafiğini yeniden değerlendiriyor, ~%10 app CPU ve ~73 kesme uyanması/sn. Düzeltme: `ChaseDots` 8 `CALayer` noktası ve ayrık `CAKeyframeAnimation` opaklık animasyonu; animasyon render sunucusunda, uygulama uyanmaz (canlı ölçüm: aktif + dönerken app %0,003, 0,33 uyanma/sn; pasif pencerede ve sidebar kapalıyken durur). Evidence için `reduce-motion:<on|off|system>` override ve snapshot alanları. Gerçek `SidebarView`'ı pencerede barındıran kablolama testleri; `LoomCatalogUITests` 54/54. Açık kullanıcı kararı: Hareketi Azalt açıkken çalışıyor göstergesi dönsün mü.

Kullanıcı kararı (6 Ekim): küçük çalışıyor göstergesi Hareketi Azalt açıkken de döner (DESIGN §5 güncellendi); UA-6 uyguluyor.

**UA-6 (6 Ekim).** Gösterge yalnız durum çalışıyor ve `indicatorsAnimate` (pencere etkin/görünür, sidebar satırında sidebar açık) iken döner; Hareketi Azalt kapısı ve `reduce-motion:` override kaldırıldı. Gerçek `SidebarView`'ı pencerede barındıran test bu Mac'te Hareketi Azalt açıkken animasyonun aktifte döndüğünü, pasif/kapalı sidebar'da durduğunu gösterir; `LoomCatalogUITests` 53/53. Canlı doğrulama son pakette.

**Son paket I ve birleşik release suite (6 Ekim, planner-reviewer).** Paket I = H + UA-5/UA-6 + P3-S (app `80de9038…`, hook `6a2dd9ef…`, test-child `705e387f…`; deep-strict doğrulandı; H `packages/cp5-H-final-test` arşivde). İlk suite denemesi `requestsAreNotDelayedByTheReadersPollInterval` teardown'ında takıldı: test `Process`'i SIGKILL sonrası sınırsız `waitUntilExit()` ile bekliyordu, pid başka yerde reap edilince Foundation çıkışı görmüyor (yalnız test; ürün `Process`/`waitpid(-1)` kullanmıyor). Düzeltme yalnız testlerde: `Tests/LoomCoreTests/TestProcessReaping.swift` sinyal + `kill(pid,0)` yoklamalı 5 sn sınırlı bekleme, üç teardown'da kullanılır. Yeniden: `swift build -c release` + `swift test -c release`: 39 + 5 + 280 + 53 = **377/377** geçti, tek beklenen known issue; takılma yok. Log: probe `runs/cp5-final2-20261006/release-suite.log`. Varsayılan katalog boyut/mtime değişmedi. Kalan: paket I'da kısa ölçüm matrisi, canlı gösterge maliyeti ve gerçek Claude kontrolü; Loom penceresi ekranda olmalı, kullanıcı bilgisayarı kullanmadığında koşulur (6 Ekim kullanıcı isteği).

**Superseded entries (6 Oct 2026, English).** The task table above is historical: U-A, U-B, UB-2, UA-3, O-1…O-4, S2-b, UA-5 and UA-6 are accepted, and U-C was fixed by O-1. The 34 pt / 22 pt button placement and `WindowButtonsPositioner` in U-A/U-B are superseded by UB-2 and UA-3 (empty unified `NSToolbar`, 26 pt centerline). The Reduce Motion gate in the plan text and in UA-5 is superseded by the user decision of 6 Oct (UA-6, [D-12](../../DECISIONS.md)). The current UI rules are in [design/DESIGN.md](../../design/DESIGN.md) and the surfaces in [design/UI-MAP.md](../../design/UI-MAP.md).
