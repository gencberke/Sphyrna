# CP5 son kabul — 3 Ekim 2026

## Hedef ve yetki

Kullanıcı sabit imza kimliği kurulmasını, son run-host mimarisinde kaynak/gecikme/GPU ölçümlerini, kalan native kabulleri ve son turda belgelerin güncellenmesini istedi. Planner-reviewer işleri doğrudan delege eder; birleşik kontrolleri ve kabulü kendisi yürütür. Commit/push/PR yetkisi yok.

Başlangıç dayanağı (bu tur öncesi): [HOLISTIC](HOLISTIC.md) son kabulü (321 test, C23, gerçek CLI17); mevcut paket app `4ff7781e…`, host `11ee787d…`. Önceki kaynak40/gecikme2000 kanıtı run-host öncesidir; yeni mimariye genellenmez.

## Sıra ve sahiplik

1. Sabit **yerel geliştirme** imzası: kullanıcı login keychain'inde `Loom Dev Code Signing`; güven yalnız code-signing politikasında. Özel anahtar repo/log/kanıta girmez. Main kurar; implementer paket scriptini hazırlar. Güçlü host owner requirement ve farklı derleme sonrası TCC sürekliliği kabul edilir.
2. Ayrık hazırlık: ölçüm implementer'ı kaynak/GPU betiklerini ve gerekirse evidence havuzunu; native implementer'ı yeni kabul yardımcılarını ve OWN-A4 fixture/testini sahiplenir. Aynı anda foreground test/build yok.
3. Main birleşik build/test, son imzalı paket, native Stop/Quit/çökme ve kalan D1/Claude ret/OWN-A4 kontrollerini yürütür. Başarısız veya denenmemiş davranış açık kalır.
4. Kaynak/gecikme matrisi, uzun kullanım ve görünür/örtülü GPU son sabit paket üzerinde ölçülür. Bağımsız byte, PID doğum, kapsam üyeleri, weak nesne ve görünürlük oracle'ları zorunlu. İlgisiz build/provider işi ölçüme karışmaz.
5. Son optimizer ölçüm değerlendirmesi, gerekli affected kabul ve belge uzlaştırması. Sayısal ürün bütçeleri ölçüm sonuçlarıyla somutlaştırılır; kullanıcı kabul etmeden onaylanmış sayılmaz.

## Kapanış ölçütleri ve açıklar

- Sabit kimlik ve imzalı ana uygulama/host; host doğru signer'ı kabul eder, yanlış owner'ı reddeder. TCC ilk izin gerekiyorsa kullanıcı macOS istemini bir kez yanıtlar; yeniden imzalı farklı binary'de erişim tekrar istemez.
- Son kaynak durumu ilgili suite ve birleşik suite'ten geçer; native ve gerçek sağlayıcı sonuçları paket hash'iyle kayıtlıdır.
- Finder çoklu drop/no-Enter, HTTP(S)/yerel link, Reduce Motion; son tracker'da gerçek manual denial; OWN-A4 XPC üyelerine sinyal gönderilmeme ve kapsam boşluğu.
- Kaynak/gecikme/uzun kullanım sonuçları hostları içerir. GPU cihaz toplamı ile PID attribution ayrı tutulur; mevcut araç attribution vermiyorsa D5 bütçe kapısı kapanmış sayılmaz.
- [OWN](OWN.md), [D](D.md), [HOLISTIC](HOLISTIC.md), [CLOSURE](CLOSURE.md), [checkpoint haritası](../CHECKPOINT-5.md) ve [STATUS](../../STATUS.md) son sonuçlarla tutarlıdır; tarihsel kayıt korunur.

## Sonuç

Sabit yerel `Loom Dev Code Signing` kimliği kuruldu; app ve host aynı leaf sertifikasına bağlıdır. Yanlış signer reddedildi. Farklı app/host hash'li A/B paketleri arasında Belgeler erişimi tekrar izin istemedi. Bu kanıt bu Mac'teki iki farklı paket ve Belgeler erişimi içindir; bütün macOS izinlerine genellenmez. [İmza kanıtı](../experiments/cp5-stable-signing.json).

Son paket C: app `0e64c4c0…`, host `aedb4389…`, fixture `b9ab6e7e…`. [Birleşik/native kanıt](../experiments/cp5-final-signed-native.json): tam suite 322/322; canlı compiler XPC şartlı OWN-A4 iki tekrar ve suite'te geçti, Apple XPC'ye sinyal gönderilmedi. Paket C normal Quit 10/10, SIGKILL/yeniden açılış 13/13 ve C sentetik kabulü 23/23. Gerçek Claude 2.1.287 / Haiku 4.5'in ilk `touch` isteği native No ile reddedildi; aynı run Waiting for you durumuna döndü, marker oluşmadı. Native tracker sayımları/arka plan korunumu bu ret koşusunda görünür değildi. Reduce Motion native kare farkı paket B'de kayıtlıdır, başlangıç tercihi geri yüklendi; son capture inactive olduğundan çalışma sırasındaki activation kaynak pulse gate'inden çıkarılmıştır.

[Host dahil kaynak](../experiments/cp5-final-runscope-resource.json) 43/43, [gecikme](../experiments/cp5-final-runscope-latency.json) 10×200 / sıfır timeout geçti. Beş koşu p95 medyanı CG 20,4405 ms / Metal 18,6997 ms; fiziksel ekranı ölçmez. Boş görünür uygulama medyan 29,81 MiB / CPU %0,097; görünür 1 MiB/sn CG 110,14 MiB / CPU %40,823. Footprint app PID + fixture + run-scope üyeleri/hostları toplamıdır; run kapsamı dışı Apple UI XPC hariçtir. İki 600 sn yükte host dahil ilk/son dakika medyan farkı −0,96875 / +0,046875 MiB, sürekli büyüme yok. Bütün koşul temizliği başarılıdır. Optimizer 766 ham sample ve 2565 fixture kimlik gözleminden toplamları bağımsız yeniden hesapladı; eski app-only büyüme açığı kapandı.

[GPU](../experiments/cp5-final-runscope-gpu.json) dört görünür koşul geçerli: cam/opak × boşta/çıktı, 60 sn ve ortak aralıktaki tam cihaz bucket'ları. App+bağlı sistem XPC coalition toplamı boşta 0, yoğun çıktıda 90,037 / 91,720 GPU ms/sn. Bu yüzde kullanım veya exclusive app-PID değildir. WindowServer coalition ve IOReport bütün masaüstünü içerir; GPUPH güç durumu residency'si engine utilization değildir. Aktif Metal 20 sn kalibrasyonu pozitif delta verdi; renderer karşılaştırması sayılmaz. Tüm üyeler census, doğum ve Apple kimliğiyle sınıflanır; dar Safari helper profili resource içeriğini doğrulamaz ve bu sınır raporda açıktır. İlk singleton varsayımı ve geçersiz denemeler kabulden dışlandı.

Dört örtülü GPU koşulu doğrulanmadı: Finder Fill/Raise/menu/click hareketlerine rağmen Loom'un native oracle'ı `windowOcclusionVisible=true` kaldı. Üç başlangıç denemesi geçersiz sayılıp temiz kapandı. Finder çoklu drop/no-Enter, dört linkin native Cmd-click açılışı ve örtülü GPU için gerçek kullanıcı hareketi gerekir; CUA drag/modifier-click/foreground sınırı nedeniyle başarı yazılmaz.

## Güncel kaynak sonucu ve kalan iş

[CPU/Codex kaynak kabulü](../experiments/cp5-cpu40-source.json) dört ürün düzeltmesini kapsar: kare arası dirty işaretleri birleştirilir; Codex socket 250 ms idle polling yerine readiness olayı bekler; tamamlanmış RPC deadline işleri iptal edilir; unbind/stop ile onay kaydının temizlenmesi başarılı yanıt sayılmaz. Ptrace test fixture teardown'ı ownership oracle'larını koruyan bounded POSIX cleanup ile onarıldı. Astra/high kaynak review ve birleşik 334/334 geçti.

[Sabit imzalı paket D ölçümü](../experiments/cp5-cpu40-optimization.json): app `8318fa10…` / host `33e7acbb…`; **23/23 koşul geçerli, CPU %40 başarısız**. Beşer görünür yoğun koşuda app/fixture/helper ayrı hesaplandı. Toplam medyan CG %44,812 (43,485–45,374), Metal %45,455 (45,138–46,802); app medyanları %31,529 / %33,309, helper medyanı 0. Ayrı bileşen medyanları toplanarak toplam türetilmez. Yaklaşık 60 draw/sn ve 1 MiB/sn yük korundu. App PID evidence SHA audit maliyetini içerir; bu maliyet ayrıca ölçülmedi ve tahminen çıkarılmaz. Tarihsel C ile D aynı anda/interleaved ölçülmediğinden artış belirli kaynak değişikliğine nedensel regresyon olarak atanmaz.

D gizli yoğun koşuda çizim/frame 0; boş görünür uygulama tek gözlemde %0,0889 / medyan 29,59 MiB. 100 çevrimde byte/footer/engine eşitliği, weak release ve kayıtlı süreç/host kalıntısı 0. Çevrim öncesi/sonrası app footprint C'de 31,97→93,47 MiB, D'de 31,30→93,38 MiB; bu uç değerler yeni D leak veya genel bellek platosu kanıtı değildir. Gecikme 2000 örnek / 0 timeout, koşu p95 medyanları CG 18,627 / Metal 18,363 ms; fiziksel ekran ölçülmez. Astra/high 156 kaynak örneği, 100 çevrim ve 2000 gecikme toplamını bağımsız doğruladı.

[Dar ASCII renderer adayı](../experiments/cp5-ascii-render-optimization.json), aynı nihai karakterin önceden hesaplanmış ilk scalar'ı ≤0xFF olduğunda zaten false dönen Unicode helper çağrısını atlar. CG/Metal ortak yoludur; FPS, fixture, SHA, hücre/FE0E/fallback/bidi ve sahiplik güvenceleri korunur. Astra/high kaynak eşdeğerliğini doğruladı; terminal24 ve yeni birleşik334 geçti. Doğrudan FE0E test kapsamı yok. Yeni adayın final imzası ve runtime kazancı **doğrulanmadı**: Mac yeniden kilitlendi; imzalama çağrısı SecurityServer'da bekliyordu, kök neden yalnız bu örnekten belirlenmedi. Kendi bekleyen signer çağrısı kimlik kontrolüyle sonlandırıldı, aday saklandı; kurulu D deep/strict doğrulaması geçti ve Loom/runhost süreçleri kalmadı.

- Kullanıcı Finder çoklu drop/link dispatch ve dört örtülü GPU koşulunu sonraya bıraktı; açık kalırlar. C native/GPU/uzun kullanım kanıtı kendi paket kapsamını korur, yeni adaya aktarılmaz.
- Sıradaki iş: Mac manuel açıldığında ASCII adayını aynı sabit kimlikle paketle/doğrula; aynı byte/FPS/ownership oracle'larıyla beşer CPU koşusu ve etkilenen kaynak/gecikme kontrolleri. Hazırlanmış controller hash'leri final paketle freeze edilir. Sonra gerçek Codex modelsiz idle/Stop; native TUI ile Loom'un eklediği app-server maliyeti ayrı sunulur. Eşzamanlı build/provider/GPU işi yok.
- Kullanıcı yoğun terminal CPU tavanını %40 yaptı; bunun tutulması tek başına minimal Loom ek yükünü kanıtlamaz. Ek app-server native binary olsa da entegrasyon maliyetinden çıkarılmaz; §3 mimarisi korunur. [Diğer kaynak bütçeleri](RESOURCE-BUDGET-PROPOSAL.md) ve GPU sayısal eşiği kullanıcı kararı bekler.
- [Son optimizer kaydı](../experiments/cp5-final-optimizer-signed.json): zorunlu model `gpt-6-astra` / `high`; kaynak ve D sayısal review tamamlandı. Son aday runtime kabulü ve açık native/GPU/bütçe kapıları tamamlanmadan CP5 kapanmaz.

OWN/D/HOLISTIC/CLOSURE, checkpoint haritası ve STATUS bu sonuçlara bağlanır; tarihsel kayıtlar korunur. Commit/push/PR yapılmadı.
