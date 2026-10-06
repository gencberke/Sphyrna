# CP5 D — girdi, görünüm ve birleşik kabul

## Hedef

[CP5 D1–D6](../CHECKPOINT-5.md#kabul-ölçütleri) ve ertelenmiş A kaynak kabulünü tamamlamak. C abonelik işiyle ayrık dosya sahipliğinde ilerler; birleşik kaynak kabulü son kaynak durumunda yapılır. [Görsel sözleşmenin](../../design/DESIGN.md) eski uygulama envanteri kendiliğinden ek ürün kapsamı değildir; bu iş CP5'te açıkça bırakılan font/ayarlar, branch ve temel terminal girdileriyle sınırlıdır.

## D1 ürün işi

- Terminal fontu 11–20 pt; kalıcı tercih, Settings/Cmd+, ve mevcut/yeni canlı yüzeylere uygulama. Hesap/usage yönetimi eklenmez.
- Finder dosya/klasör drop: birden çok yolu shell için doğru alıntıla, mevcut sıralı terminal girdisiyle aktar, Enter gönderme. Mevcut bracketed paste/görsel pano davranışını koru.
- HTTP(S) ve mevcut yerel dosya linkleri; ham mutlak yol/OSC8 file URL kabulü, rastgele scheme çalıştırmama.
- Proje kartında branch; normal repo/worktree HEAD kaynağı, detached/unavailable dürüst sonuç. Her frame git komutu/polling yok.
- 52 pt üst çubuk, korunmuş ikon/cam/panel geometrisi; iki görünüm 1220×780 ve 780×500 native kabulü. Reduce Motion/Transparency ve anlamlı erişilebilirlik etiketleri.

Sahip: D ürün implementer'ı — `Sources/LoomCatalogUI`, `Sources/LoomTerminal/TerminalSurface.swift`, `Sources/LoomTerminal/TerminalRunController.swift`, `Sources/loom-app/AppDelegate.swift` ve ilgili UI/terminal testleri. C core/fixture sahibi ayrı. Gereken core şema değişikliği önce planner-reviewer'a bildirilir.

## A/D ölçüm ve kabul düzeneği

Mevcut `cp5-a-measure.sh` tek terminalin 6 senaryosunu ölçüyor; 90 saniyelik toplam fixture yükü 600 saniyelik sürekli yük değildir. Mevcut geçersiz görünür örneklerden son renderer/kaynak kararı çıkarılmaz.

- 0/1/10/50 sentetik terminal; 100 yaşam çevrimi; 10 dakika sürekli yük ve dakika başı footprint/tampon/yaşayan kaynak sayımı. 10 terminal × 100 KiB/sn ve 20 MiB burst için kayıp/kapanış doğrulaması.
- Görünür/örtülü/gizli; cam/opak × boşta/çıktı; renderer karşılaştırması; feed/girdi gecikmesi. GPU mevcut güvenilir sayaçla ayrı ölçülür; CPU veya frame sayısı GPU diye sunulmaz.
- Eksik snapshot, değişmiş görünürlük, kopmuş yük/ölçüm veya süreç temizliği hatası geçersiz sonuç/nonzero exit üretir. Ölçüm aracı maliyeti ayrılır. Kendi fixture süreçleri dışında sinyal yok.
- Son paketle native Cmd+W/yeniden açılış, başarısız Quit/retry, crash/Force Quit ve no-autostart ayrı kabul. Normal Quit sonucu crash'e genellenmez.

Sahip: ölçüm implementer'ı — ölçüm betikleri, ayrık yeni probe/acceptance kaynakları, `DevelopmentEvidence.swift` ve gerekli paket hedefi. `AppDelegate.swift`/terminal yüzeyi ortak yazılmaz; gereken bağlantı planner-reviewer üzerinden dosya sahibine gider. İlk teslim hazırlık/smoke; uzun ölçümler son kaynaklar ve sabit ekran koşullarında planner-reviewer tarafından başlatılır.

### Son koşu matrisi

- A'nın altı temel senaryosu: 0 terminal / 1 boş terminal / 1 MiB/sn çıktı × görünür / gizli; 10 sn ısınma + 60 sn örnek, beş tekrar. Yeni D sürücüsünün digest ve kimlik oracle'ı kullanılır; eski A betiği yalnız ayrı input→draw gecikmesini sağlar.
- Renderer karşılaştırması aynı görünür 1 MiB/sn girdide beşer tekrar; actual renderer snapshot'ı istekle eşleşmezse koşu geçersizdir. Her renderer için yeniden bütün ilgisiz kabul matrisi tekrarlanmaz.
- 10/50 boş terminal, 10 × 100 KiB/sn yük, 20 MiB burst, 100 çevrim; sonra tamponlar dolduktan sonra tekli ve onlu yükte 600 sn. Bunlar sınır/uzun kullanım doğrulamasıdır; tek koşudan göreli performans kazancı çıkarılmaz.
- Cam/opak × boşta/çıktı × görünür/örtülü GPU matrisi cihaz toplamı ve ayrı sınıflanmış coalition sayaçları olarak kaydedilir. Tek gözlemden kazanç iddiası kurulmaz; nicel karşılaştırma gerekiyorsa o eşleşen hücrelerde beş tekrar yapılır. Coalition GPU, exclusive app-PID/WindowServer attribution değildir; sınırlar son kanıtta korunur.
- Ölçüm sırasında kaynaklar sabit, başka build/test veya CLI/model deneyi yoktur. Uzun koşulardan önce kısa native/işlevsel kontroller tamamlanır; başarısız ölçüm geçerli sayıyla karıştırılmaz.

## Kontroller ve kapanış

Her implementer kendi dar regresyonlarını ve build'i koordineli yapar; tek ortak build/test sahibi aynı anda çalışır. Son tam suite/native kabul ve ölçüm sonuçları [CLOSURE.md](CLOSURE.md) içinde bağlanır. Kaynak sayıları başlangıç hedefleriyle karşılaştırılabilir fakat kullanıcı tarafından kabul edilmiş ürün bütçesi diye sunulmaz. Kalıcı imza/izin sürekliliği ve OWN-1 dış kapıları açıkça korunur. Strict reviewer → optimizer → son Herdr/Orca karşılaştırması sırası değişmez.

## Son imzalı kaynak/native kabul — 3 Ekim 2026

Güncel iş [FINAL-ACCEPTANCE](FINAL-ACCEPTANCE.md). [İmzalı/native kanıt](../experiments/cp5-final-signed-native.json): Reduce Motion kapalı/açık native kare farkı doğrulandı, başlangıç tercihleri geri yüklendi; gerçek Claude ilk Bash isteği native No ile reddedildi. OWN-A4 ve paket C Quit/çökme/C23 kontrolleri geçti. Finder çoklu drop/no-Enter ve dört linkin native açılışı, CUA drag/modifier-click sınırı nedeniyle doğrulanmadı; render ve birim testi native dispatch yerine sayılmaz.

Yeni kaynak/gecikme matrisi [53/53 geçerli koşu](../experiments/cp5-final-runscope-resource.json): 35 tekrarlı temel/renderer, 6 sınır/araç, 2 uzun yük, 10×200 gecikme. CPU/footprint toplamı app PID + sentetik fixture + run-scope üyeleri/hostlarıdır; run kapsamı dışındaki Apple UI XPC dahil değildir. WindowServer tüm istemcilerle ayrı raporlanır. Uzun yük büyümesi app-only dakika özetinden değil host dahil ham toplamdan hesaplanır.

GPU collector, Loom resource coalition'ındaki üç bilinen Apple UI XPC türünü tam canonical yol, Apple kimliği ve taze doğum kimliğiyle sınıflar; hiçbir üyeyi/sayacı çıkarmaz. Safari helper'ın Apple custom-omit zarfı nedeniyle yalnız code/sealed-Info kimliği doğrulanır, resource içeriği doğrulanmaz; bu dar istisna ve sınırı metadata'da açıktır. Diğer iki yardımcı strict code+resources doğrulanır. Hazırlık imza kontrolünden sonra CPU/GPU baseline yeniden okunur. Okunabilir sıfır GPU deltası donanım accounting desteği kanıtı değildir; device-total mod attribution yokluğunu açık tutar. Aktif Metal kalibrasyonunda app+XPC GPU sayacı pozitif delta üretti; accounting okuması bu koşulda doğrulandı. [Final GPU kanıtında](../experiments/cp5-final-runscope-gpu.json) dört görünür hücre geçerli; dört örtülü hücre native foreground araç sınırında açık. App+XPC yoğun çıktı 90,037/91,720 GPU ms/sn, idle 0; tek gözlemlerden cam/opak veya renderer kazancı çıkarılmaz. [Kaynak bütçesi önerisi](RESOURCE-BUDGET-PROPOSAL.md) kullanıcı kararı bekler; GPU bütçesi açık kalır.


[CPU/Codex kaynak kabulü](../experiments/cp5-cpu40-source.json) ve [son ölçülen D](../experiments/cp5-cpu40-optimization.json): kare dirty işleri, Codex idle polling/deadline işleri ve yanlış başarılı onay yanıtı düzeltildi; ptrace fixture cleanup'ı ownership oracle'ları korunarak bounded yapıldı. Astra/high review ve birleşik334 geçti. D23/23 koşul geçerli, gecikme2000/timeout0 ve bütün cleanup0; yoğun CPU medyan CG%44,812 / Metal%45,455 ile %40 tavanı başarısız. [ASCII adayı](../experiments/cp5-ascii-render-optimization.json) kaynak review ve yeni birleşik334'ten geçti; imzası/runtime kazancı Mac kilidinde doğrulanmadı, kurulu D korundu. Gerçek Codex modelsiz idle/Stop ayrıştırması çalıştırılmadı. C native/GPU/uzun kanıtları tarihsel paket kapsamını korur; Finder/link/örtülüGPU4 kullanıcı tarafından ertelenmiştir. Güncel iş [FINAL-ACCEPTANCE](FINAL-ACCEPTANCE.md); CP5 açık.
