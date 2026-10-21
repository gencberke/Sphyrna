# CP5 ilk kaynak bütçesi önerisi — 3 Ekim 2026

**Durum: yoğun terminal CPU tavanı %40 olarak kullanıcı tarafından belirlendi; diğer sayısal öneriler onaysız.** Bu öneri sözleşme §10'daki sayısal boşluğu son imzalı run-host paketinin ölçümleriyle somutlaştırır. Kapsam ilk pencere ve sentetik terminal düzeneğidir; gerçek Claude/Codex model işi için mutlak maliyet garantisi değildir.

## Kapsam ve yöntem

Mac14,2 / Apple M2 / 16 GiB / macOS 27.0.1; release paket C, 1220×780 pt. CPU %100 bir mantıksal çekirdektir. CPU/physical footprint toplamı app PID + sentetik fixture + run-scope üyeleri/hostlarıdır; run kapsamı dışındaki Apple UI XPC hariçtir. Süreç footprint toplamı paylaşılan sayfaları tekilleştirmez. Bu tanım değiştirilirse mevcut eşikler yeni tanıma otomatik aktarılmaz.

Temel karşılaştırma: 10 sn ısınma + 60 sn ölçüm, beş tekrar. Aşağıdaki bellek tavanları bütün ölçüm örneklerinin en yüksek toplamına uygulanır; CPU tavanları her koşunun ölçüm aralığı ortalamasına uygulanır. Sınır/uzun yükler tek koşudur, göreli performans kazancı kanıtı değildir.

## Önerilen ilk eşikler

| Koşul | Öneri | Paket C referansı |
| --- | --- | --- |
| Boş uygulama, görünür/gizli | CPU ≤%1; footprint ≤40 MiB | en yüksek CPU %0,101; peak 31,90 MiB |
| Bir boş sentetik terminal, görünür/gizli | CPU ≤%1; footprint ≤80 MiB | en yüksek CPU %0,122; peak 64,37 MiB |
| 1 MiB/sn tek terminal, görünür (CG/Metal) | CPU ≤%40 (kullanıcı kararı); footprint ≤130 MiB (öneri) | en yüksek CPU %43,477; peak 111,04 MiB |
| 1 MiB/sn tek terminal, gizli | CPU ≤%30; footprint ≤60 MiB; çizim 0 | en yüksek CPU %23,169; peak 42,60 MiB; çizim 0 |
| 10 boş sentetik terminal | CPU ≤%1; footprint ≤160 MiB | CPU %0,158; peak 126,62 MiB |
| 50 boş sentetik terminal | CPU ≤%1; footprint ≤450 MiB | CPU %0,334; peak 397,46 MiB |
| 10 × 100 KiB/sn, tek görünür terminal | CPU ≤%60; footprint ≤230 MiB | CPU %47,621; peak 191,30 MiB |
| Girdi → tamamlanmış terminal çizimi | her koşu p95 ≤100 ms; timeout 0 | CG p95 20,189–20,852 ms; Metal 18,421–18,886 ms; 2000 örnek, 0 timeout |
| 600 sn sürekli tekli/onlu yük | ilk/son dakika medyan farkı ≤10 MiB; son 5 medyanda sürekli büyüme yok | host dahil −0,96875 / +0,046875 MiB; büyüme yok |
| 100 aç/kapat çevrimi ve bütün çıkışlar | terminal/sink/endpoint/kuyruk başlangıca döner; kayıtlı fixture/scope/host kalıntısı 0 | doğrulandı |

Girdi gecikmesi PTY echo'sundan sonraki tamamlanan terminal draw callback'ine kadardır; compositor/fiziksel ekran gecikmesi değildir. 100 ms ilk mühendislik hedefi korunur. 10.000 kayıt sayfalama kabulü eski B kanıtında kalır; bu terminal matrisi onu yeniden ölçmez.

## Loom ek yükü ve CPU kararı

Kullanıcı %50 önerisini %40'a indirdi ve Loom'un kendi kaynak yükünün minimum olmasını istedi. %40 tavanın tutulması tek başına minimal ek yük kanıtı değildir. App/host, sentetik fixture/gerçek TUI, Loom'un eklediği native app-server ve evidence maliyeti ayrı gösterilir. Fixture yükünü veya FPS'yi azaltmak ürün optimizasyonu sayılmaz. Ek app-server native binary olsa da entegrasyon yüküne dahildir; §3 mimarisi değişmedi. Checkpoint optimizer zorunlu `gpt-6-astra` / `high`.

[Son ölçülen paket D](../experiments/cp5-cpu40-optimization.json), beşer görünür 1 MiB/sn koşuda CPU tavanını karşılamadı:

| Renderer | App medyanı | Fixture medyanı | Toplam medyanı / aralık |
| --- | --- | --- | --- |
| CoreGraphics | %31,529 | %12,306 | %44,812 / 43,485–45,374 |
| Metal | %33,309 | %12,007 | %45,455 / 45,138–46,802 |

Helper medyanı 0; app SHA audit maliyetini içerir, ölçülmeden çıkarılmaz. Toplam her koşunun bileşenlerinden hesaplanır; ayrı medyanlar toplanmaz. Yaklaşık 60 draw/sn korundu. C–D interleaved değildir; sayısal artış belirli değişikliğe nedensel olarak atanamaz. 23 koşul valid/cleanup0; gizli çizim0 ve çevrim100 geçti. Gecikme2000/sıfır timeout, p95 medyan CG18,627 / Metal18,363ms. D boş uygulama tek gözlemde %0,0889 / medyan29,59MiB; karşılaştırmalı kazanç değildir.

[Kaynak düzeltmeleri](../experiments/cp5-cpu40-source.json) ve [ASCII adayı](../experiments/cp5-ascii-render-optimization.json) Astra/high review'dan geçti; son birleşik334/334. ASCII adayının final imzası/runtime kazancı Mac kilidi nedeniyle doğrulanmadı; kurulu D korundu. Gerçek Codex modelsiz idle/Stop ve TUI/ek app-server maliyet ayrımı hazırlanmış, çalıştırılmamıştır. C100 çevrim app footprint31,97→93,47MiB, D31,30→93,38MiB; weak release0 tek başına bellek platosu sayılmaz. Eski C10dakika büyüme kanıtı yeni adaya aktarılmaz.

## GPU karar sınırı

[Final GPU kanıtında](../experiments/cp5-final-runscope-gpu.json) dört görünür hücre geçerli; dört örtülü hücreyi kullanıcı sonraya bıraktı. Sayısal GPU bütçesi onaysızdır. Coalition GPU nanosecond deltası / saniye, GPU ms/sn olarak sunulur; yüzde kullanım değildir. Uygulama coalition'ı bütün sınıflanmış sistem XPC üyelerini içerir. WindowServer coalition ve cihaz IOReport sayaçları tüm masaüstünü içerir; onların mutlak sayıları Loom'a ait bütçe gibi onaylanamaz. IOReport enerji sayaçları modellemedir.

Aktif Metal kalibrasyonu pozitif app+XPC GPU deltası verdi. Okunabilir sıfır delta tek başına accounting desteği kanıtı sayılmaz. App+XPC ilk regresyon eşikleri, final matris ve optimizer incelemesiyle somutlaştırılacak; ölçülmeyen exclusive app-PID/WindowServer etkisi açık sınır olarak korunur.

## Karar ve dayanak

Kullanıcı diğer kapsam/eşikleri de kabul ederse ilk CP5 sentetik kaynak bütçesi kayda geçirilir; kapsam dışındaki gerçek sağlayıcı maliyeti veya exclusive GPU attribution kapanmış sayılmaz. Daha düşük eşik seçilirse hangi koşulun optimize edileceği ve etkilenen kabul ayrıca belirlenir. CPU %40 kararı sözleşme §10'a işlendi. Diğer öneriler kendiliğinden ürün kararı veya §3 değişikliği değildir.

- [Host dahil kaynak](../experiments/cp5-final-runscope-resource.json)
- [Gecikme](../experiments/cp5-final-runscope-latency.json)
- [Son kabul](FINAL-ACCEPTANCE.md)
