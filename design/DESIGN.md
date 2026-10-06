# Loom — görsel sözleşme

**Durum:** Tasarım ve ikonlar sabit kabul edildi ([ürün sözleşmesi](../LOOM-PRODUCT-CONTRACT.md) §3). Bu dosya, önceki `SPEC.md`'nin görsel sözleşmesini ve eski uygulamanın davranış envanterini taşır. Eski çizim kodunun, terminal motorunun veya mimarinin aynen kullanılması şart değildir.

## 1. Referanslar

Birincil hedef, kullanıcının 27 Eylül 2026 tarihli `Herdr Desktop Appshot 2026-09-27T09-44-26.434Z.png` ekidir: solda aktivite listesi, sağda geniş terminal, koyu cam pencere. Ekin özgün dosyası yerelde bulunamadı. Aşağıdaki dosyalar bunun yerine geçirilmiş farklı bir tasarım değildir; mevcut uygulamadan korunan yardımcı referanslardır:

- [Kaldırmadan önce mevcut pencere](installed-before-removal.png): aynı UI, oturumlar sonlanmışken alınan görüntü; orijinal ekteki canlı terminal içeriği yoktur.
- [Aktivite görünümü referansı](activity-view-reference.png) ve [proje görünümü referansı](project-view-reference.png): önceki yerel görsel kontroller.
- [Görsel uygulama kaynakları](legacy-code/DesktopView.swift), [pencere/menüler](legacy-code/App.swift), [çalışma göstergesi](legacy-code/WorkingIndicator.swift), [terminal sunumu](legacy-code/TerminalHost.swift): boyut ve davranış referansı; yeni mimariye taşınacak üretim kodu değildir.

## 2. Korunacak öğeler

1. Native kırmızı/sarı/yeşil pencere düğmeleri; üst solda sidebar düğmesi, klasör/saat görünüm seçimi, üç nokta menüsü.
2. Koyu, yarı saydam sidebar; opak koyu terminal paneli; ince sınır, yumuşak köşeler ve sık yerleşim.
3. Sidebar arama alanı; aktivite görünümünde Today/Thursday benzeri gün başlıkları.
4. İki satırlı konuşma kartı: üstte durum, başlık ve süre; altta solda branch, sağda proje ve renkli sağlayıcı simgesi. Seçili kartta hafif açık zemin ve ince çerçeve.
5. Sol altta proje ekleme, sağ altta ayarlar. Ayarlanabilir sidebar; alanın çoğu terminale ayrılır.
6. Terminal üstünde renkli sağlayıcı simgesi, konuşma başlığı ve sağda üç nokta. Terminal metni gerçek CLI arayüzüdür; yeni bir chat arayüzüyle değiştirilmez.
7. Mevcut koç simgesi korunur: [ICNS](../assets/Loom.icns), [PNG](../assets/Loom.png), [SVG](../assets/Loom.svg), [ham işaret](../assets/Loom-mark.svg), [menü çubuğu işareti](../assets/Loom-menubar.svg). Dosyalar yeniden çizilmeden kopyalandı. Sağlayıcı simgeleri [assets/harness](../assets/harness), orijinalleri ve kaynakları [assets/brand](../assets/brand/README.md) altındadır.
8. macOS Hareketi Azalt ve Saydamlığı Azalt tercihlerine uyum sürer.

## 3. Ölçüler ve renkler

Kaynak koddan alınan başlangıç ölçüleri: sidebar varsayılan 300 pt, aralık 220–520 pt; minimum terminal genişliği 480 pt; üst çubuk 52 pt; pencere ilk boyutu 1220×780, minimum 780×500; panel dış boşluğu 8 pt, köşe yarıçapı 10 pt. Bunlar pt değerleridir; Retina ekran görüntüsünün piksel ölçüleriyle karıştırılmaz.

Kaynak renkleri (RGB): sidebar `(0.043, 0.055, 0.086)`, terminal paneli `(0.114, 0.110, 0.133)`, vurgu `(0.53, 0.57, 0.81)`, ana metin `(0.88, 0.86, 0.92)`, ikincil metin `(0.46, 0.48, 0.55)`. Cam malzeme, arka plan ve opacity son görünümü etkiler; bu değerler tek başına ekran görüntüsündeki rengi garanti etmez.

Görsel kabul: referansla aynı pencere boyutu ve ölçek altında karşılaştırma; sidebar, tipografi, simge, cam ve terminal geometrisi kontrolü.

## 4. Eski uygulamanın davranış envanteri

Bu bölüm Herdr Desktop'ta bulunan davranışları, tasarımdaki öğelerin ne işe yaradığını anlamak ve v1 kapsamını planlamak için listeler. **Loom gereksinimi değildir;** her satır ayrıca kapsama alınmalıdır. [Ürün sözleşmesiyle](../LOOM-PRODUCT-CONTRACT.md) çelişen satırlarda sözleşme esas alınır.

| Alan | Mevcut davranış | Sınır / önemli ayrım |
| --- | --- | --- |
| Sağlayıcılar | Claude Code, Codex, OpenCode, Antigravity ve normal shell | Yerel CLI kurulumlarını ve mevcut girişlerini kullanır; model backend'i veya API anahtarı yönetmez. |
| Projeler | Klasör ekle, daralt/genişlet, sürükleyerek sırala, boş projeyi kaldır | Konuşması bulunan proje önce boşaltılmalıdır. Proje kaldırmak proje dosyalarını silmez. |
| Projesiz çalışma | Home dizininde yeni oturum; `Sessions` grubu | Grup boşken gizlenebilir. |
| Yeni oturum | Sağlayıcı seçerek proje içinde veya projesiz başlat | Eksik CLI devre dışı görünür; başlatma hatası bildirilir. |
| Görünüm seçimi | Projeye göre gruplama veya son aktiviteye göre gün grupları | Proje içi liste oluşturulma zamanına göre sabittir; seçim satırı yukarı taşımaz. Aktivite görünümü son aktiviteye göre sıralar. |
| Kart metaverisi | Başlık, sağlayıcı, proje, branch, göreli süre | Süre son çalışma başlangıcından türetilir; token/çalışma süresi ölçümü değildir. |
| Branch | `.git/HEAD` ve worktree gitdir üzerinden branch bilgisi | Git subprocess'i çalıştırmaz. Oturum olayları ve uygulama öne gelişiyle yenilenir. |
| Arama | Başlık, sağlayıcı ve ilgili çocuk görevlerde arama | Arama kutusu mevcut kodda 8'den fazla konuşmada görünür. Tam transkript araması değildir. |
| Oturum değiştirme | Canlı terminali göster; normal girdi, çıktı, resize, scroll ve seçim | Her canlı oturum kendi PTY/terminal tamponunu taşır. |
| Geçmişten devam | Native kimliği bilinen konuşmayı sağlayıcının resume komutuyla aç | Uygulama açılırken otomatik süreç başlatılmaz. Geçmiş ana konuşmaya tıklamak resume başlatabilir; kimlik yoksa devam edemez. Shell yeni süreç olarak açılır. |
| Kimlik değişimi | `/new` sonrası eski konuşmayı tarihçede koru, yeni native kimliği ayrı kaydet | Terminalin çalışma kimliği ile sağlayıcının konuşma kimliği farklıdır. |
| Yeniden adlandırma | Özel başlık ata; sonraki otomatik başlıkla ezme | Mevcut metin sınırı 160 karakter. |
| Durum | Çalışıyor, giriş/onay bekliyor, boşta/bitmiş, sonlanmış/geçmiş | Mevcut hook kapsamı bütün sağlayıcı geçişlerini garanti etmez. Durum, süreç canlılığı ve okunmamışlık aynı şey değildir. |
| Dikkat işaretleri | Çalışma animasyonu, turuncu bekleme, bakılmamış bitiş için mavi nokta | Seçili ve görünür konuşma okundu sayılır. Hata ayrı uygulama mesajıdır. |
| Dock / menü çubuğu | Dikkat gerektiren oturum sayısı ve oturuma geçiş listesi | Liste ilk 12 kaydı gösterir. Model çağrısı yoktur. |
| Claude çocuk görevleri | Uygulama içinden başlatılan yeni `claude -p` görevini ana konuşmanın altında göster; sayaç ve aç/kapat | Tüm sağlayıcılara yayılan genel subagent sistemi değildir. Çalışan görev bulunduğu süreçten taşınmaz. |
| Çocuk transkripti | Yerel Claude transkriptini oku; bitince `Resume in Terminal` | Görünüm sınırlı son metni okur (800 KB / son 120 giriş); sınırsız dosya yüklemez. |
| Dosya bırakma | Finder'dan birden çok dosya/klasör yolunu prompta alıntılı ekle | Enter göndermez; dosya yükleme servisi değildir. |
| Konuşma yolu | Claude/Codex satırını terminale sürükle, çift tıkla veya menüden geçmiş yolunu kopyala | Native kimlik ve mevcut yerel dosya gerektirir; içeriği otomatik prompta eklemez. |
| Metin/görsel paste | Çok satırlı bracketed paste; yalnızca görsel panoda ise Cmd+V'yi Ctrl+V'ye aktar | Görseli okuma CLI desteğine bağlıdır. |
| Bağlantılar | HTTP(S) ve mevcut yerel dosya bağlantısını aç | Rastgele URL scheme çalıştırmaz. |
| Durdur | İlgili terminal ve ilişkili çocukları durdur, kapanmayı doğrula | PID doğum kimliğiyle kontrol; TERM ardından sınırlı bekleme ve gerektiğinde KILL. Bağımsız Unix session açan kaçak çocuklar bir risktir. |
| Listeden sil | Oturumu/alt görevlerini durdurup katalogdan çıkar | Sağlayıcının sohbet dosyalarını silmekle aynı işlem değildir. |
| Kalıcı sil | Desteklenen Claude konuşma ve alt görev yerel dosyalarını sil | Ortak history.jsonl ve bulut kopyaları kalır. Codex/OpenCode'da silmenin yayılımı belirsiz olduğundan sunulmaz; Antigravity kendi silme ekranına yönlendirilir. |
| Pencere kapatma | Pencere kapanır; uygulama ve işler çalışmayı sürdürür | Quit ile farklıdır. |
| Uygulamadan çıkış | Sahip olunan terminal/çocukları durdur, bekleyen katalog işlemlerini bitir, kaydet | Kapanma doğrulanamıyorsa hata verir; başka uygulamaların süreçlerini öldürmemelidir. |
| Katalog | Proje, başlık, provider/native kimlik, sıra, seçili kayıt ve ayarları kalıcı tut | Bozuk katalog üzerine yazılmaz. Sağlayıcıların tüm geçmişi otomatik içe alınmaz. |
| Ayarlar | Terminal fontu 11–20 pt; sağlayıcı kurulum durumu | Hesap/usage yönetimi yoktur. Sidebar genişliği mevcut kodda yeniden açılışta 300 pt olur. |
| Erişilebilirlik | Native pencere, klavye kısayolları, anlamlı kontrol etiketleri, hareket/saydamlık tercihleri | Tam erişilebilirlik denetimi yapıldığı iddia edilmez. |
| Tanılama | Son eklenen Performance menüsü: CPU/bellek gösterimi, 5 sn örnekleme, JSONL, manuel sorun işareti, aç/kapat, 20 MiB döndürme | Bu uygulama da kaldırılıyor. GPU ölçmez; kısa süreç/sıçramaları kaçırır. Loom'un tanılama tasarımı olarak kabul edilmiş değildir. |

Kısayollar: Cmd+O proje ekle; Cmd+N yeni konuşma; Ctrl+Cmd+S sidebar; Cmd+, ayarlar; Cmd+W pencere; Cmd+Q uygulamadan çıkış; standart macOS kopyala/yapıştır/tümünü seç ve tam ekran kısayolları.

## 5. Durum dili (5 Ekim 2026, kullanıcı kararı)

Kullanıcı paket G geri bildirimiyle §2'deki bazı öğeleri değiştirdi ([UI planı](../plans/cp5/UI.md)). Bunlar §2 ile çeliştiğinde bu bölüm geçerlidir.

- Durum göstergeleri Unpeel tarzında küçük ve renklidir: çalışıyor = küçük noktaların dikdörtgen çevresinde birbirini izlediği animasyon; onay/girdi bekliyor = turuncu nokta; bakılmamış bitiş = renkli nokta; hata = kırmızı işaret; boşta = gösterge yok. Bu dil sidebar, başlık ve diğer durum yüzeylerinde tutarlı kullanılır. Animasyon render sunucusunda çalışan küçük bir katman animasyonudur; [sözleşme §10](../LOOM-PRODUCT-CONTRACT.md#10-kaynak-ve-performans-kabulü) gereği gizli veya etkin olmayan pencerede ve sidebar kapalıyken durağandır. Kullanıcı kararıyla (6 Ekim 2026) bu küçük gösterge, macOS'un kendi küçük ilerleme göstergeleri gibi Hareketi Azalt açıkken de döner; diğer hareketler §2.8'e uyar.
- Proje satırında sohbet sayısı gösterilmez; projedeki bir sohbet dikkat istiyor veya bakılmamış bitiş taşıyorsa renkli nokta görünür.
- Proje görünümünde kart proje adını tekrarlamaz; aktivite görünümünde gösterir.
- Proje satırının sağ tık menüsü yeni Claude / Codex sohbeti başlatabilir.
- Sidebar camı duvar kâğıdı rengini belirgin biçimde sızdırmaz; koyu ton baskındır.
- Üst navbar düzeni ayrıca konuşulacak; bu karar onu değiştirmez.
