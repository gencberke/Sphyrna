# CP5 OWN — run başına sahiplik kapsamı

## Karar (2 Ekim 2026, kullanıcı)

[Run kapsamı araştırması](../experiments/cp5-own-run-scope-research.json) sonrası kullanıcı üç karar verdi:

1. **Run kapsamı benimsenir.** Her yönetilen run, LaunchServices ile açılan AppKit'siz `LoomRunHost` yardımcısının yeni resource coalition'ında başlar. Loom'un kendi uygulama coalition'ı artık sahiplik tohumu değildir; bu gruba Apple XPC servisleri sonradan katılıyor. Kapsam kurulamazsa oturum normal başlatılmaz ve görünür hata verilir. Sözleşme §3/§6 buna göre güncellenir.
2. **Codex oturum başına sunucu.** Her canlı Codex oturumunun app-server'ı ve TUI'si aynı run kapsamındadır. Tek oturum Stop'u, o oturumun bütün çatallanmış işini kapsar.
3. **Loom çökerse yardımcı run'ı durdurur.** Yardımcı, Loom bağlantısı onay vermeden koparsa kendi kapsamındaki çatallanmış işi temizleyip çıkar.

## Mekanizma

- **Kapsam:** Yardımcının coalition ID'si. Kimlik doğrulaması şunlarla yapılır: peer UID/PID, yürütülebilir yol, launchd'nin başlatmış olması (`orig_ppidversion`) ve el sıkışmada tek üye olmak.
- **Çatallanmış iş:** Kapsamdaki üyelerden `orig_ppidversion` değeri launchd'ninkinden farklı olanlar. Bu değer fork anında atanır; exec ve yeniden ebeveynlenmede değişmez (XNU `kern_fork.c`).
- **Launchd üyeleri:** Yardımcının kendisi ve Apple XPC örnekleri. Bunlara sinyal gönderilmez. Yardımcı protokolle kapanır, XPC örneklerini launchd kapatır. Başarı için kapsamın tamamen boşalması gerekir.
- **Durdurma:** Mevcut HUP→TERM→KILL yükseltmesi korunur. KILL aşamasında üyeler önce dondurulur, sonra kimlik yeniden doğrulanıp öldürülür. Kapsamın son run'ı bitince yardımcıya çıkış komutu gider ve kapsamın boşaldığı sınırlı sürede doğrulanır. Bu süre dolarsa dürüst hata verilir ve tekrar deneme açık kalır.
- **Kapsam dışı (yapısı gereği):** LaunchServices/launchd'ye devredilen iş (`open -a`, `launchctl`, `brew services`, Docker daemon işleri). Başka UID'ye geçmiş süreçler (ör. `sudo`) durdurulamazsa başarısızlık olarak raporlanır.

## Dilimler

| Dilim | Teslim | Sahip |
| --- | --- | --- |
| OWN-A | C soy/coalition sorguları ve üye sinyali; `loom-run-host` C yardımcısı; Swift `RunScope` istemcisi; `ProcessSupervisor` entegrasyonu (PTY slave aktarımı, host'tan exit durumu, kapsam boşaltma, ledger kapsam kaydı, uygulama coalition tohumunun kaldırılması); ortam çözümü ve yardımcı komutların kapsamda çalışması. | planner (kullanıcı ataması: implementer-planner) |
| OWN-B | Oturum başına Codex app-server: TUI ve sunucu aynı kapsamda; tek oturum Stop raporu sunucu kapanışını içerir. | OWN-A sonrası |
| OWN-C | Paketleme (`Contents/Helpers/LoomRunHost.app`), uygulama bağlantısı, native kabul betikleri, sözleşme §3/§6 metni. | OWN-A sonrası |

## Kabul ölçütleri

| ID | Senaryo | Kabul |
| --- | --- | --- |
| OWN-A1 | Kaçak işaretsiz süreç | `setsid` ile çift fork yapıp exec eden işaretsiz Apple binary, Stop ve Quit sonrasında yaşamıyor. Mevcut `documentsUnobservedAppleEscapeBoundary` testi tersine çevrilir; düzeltme olmadan başarısız olmalıdır. |
| OWN-A2 | Adversarial çatallanma | Sinyalleri yok sayıp sürekli yeniden çatallanan fixture, deadline içinde sıfıra iniyor; kapsam dışındaki kontrol süreci yaşıyor ve ona sinyal gönderilmiyor. |
| OWN-A3 | İki oturum | A'nın Stop'u B'nin kapsamına dokunmuyor; Quit ikisini de boşaltıyor. |
| OWN-A4 | Launchd üyesi | Run'ın istediği XPC örneğine sinyal gönderilmiyor; istemci gidince kapsam boşalıyor. Boşalmazsa Stop başarısız ve tekrar denenebilir. |
| OWN-A5 | Kapsam hatası | Yardımcı açılamazsa, el sıkışma zaman aşımına uğrarsa veya kapsam taze değilse launch hata verir. Hayalet run ve süreç kalmaz; tekrar deneme çalışır. |
| OWN-A6 | Çökme | Loom SIGKILL ile ölünce yardımcı kendi kapsamını boşaltıp çıkıyor. Sonraki açılış kayıtlı kapsamı doğruluyor ve otomatik sohbet başlatmıyor. |
| OWN-A7 | Regresyon | Mevcut süreç, yaşam döngüsü, terminal ve runtime suite'leri geçer. Tam suite OWN-C sonunda çalışır. |
| OWN-B1 | Codex tek oturum | Oturum Stop'u TUI'yi, sunucuyu ve sunucunun kaçan komutlarını kapatıyor; diğer Codex oturumu çalışmaya devam ediyor. |
| OWN-C1 | Native | Paketlenmiş uygulamada A1, A3, A6 ve fake-provider 22 kontrolü yeniden geçer. Gerçek model turu kullanılmaz. |

## OWN-A sonucu (2 Ekim 2026)

**Uygulandı:**
- `Sources/CLoomPOSIX/RunScope.c`: soy/coalition sorgusu; `(pid, id_version, coalition)` doğrulamalı sinyal; dondur→öldür boşaltma; SCM_RIGHTS çerçeveleme; peer kimliği.
- `Sources/loom-run-host/main.c`: LaunchServices yardımcısı. PTY veya stdio ile çocuk başlatır, exit durumunu bildirir; Loom bağlantısı EXIT olmadan koparsa kapsamın çatallanmış işini durdurur.
- `Sources/LoomCore/RunScope.swift`: launcher ve el sıkışma doğrulaması. Doğrulananlar: aynı UID, launchd tarafından başlatılmış olma, beklenen yol, uygulamadan farklı ve tek üyeli coalition.
- `ProcessSupervisor` entegrasyonu:
  - kapsamlı launch;
  - son run'ın örneklemesine coalition'ın çatallanmış üyeleri girer;
  - KILL öncesi dondurma;
  - terminal bitince kapsam serbest bırakma ve boşluk doğrulaması;
  - ledger'a kapsam kaydı;
  - Quit'te boşta ve kurtarılmış kapsamların ele alınması;
  - uygulama coalition tohumunun kapatılması.
- Ortam kabuğu uygulama ömrü boyunca bir kapsamda, tek seferlik yardımcı komutlar çağrı başına kapsamda çalışır. Kapsam modunda PID/süreç grubu sinyali gönderilmez; yardımcının reap ettiği PID yeniden kullanılmış olabilir.

**Doğrulandı:**
- [RunScopeTests](../../Tests/LoomCoreTests/RunScopeTests.swift) 7/7: A1 kaçak, A3 iki kapsam, A2 adversarial çatallanma ve dış kontrol, A5 eksik yardımcı, A6 bağlantı kopması, kabuk başlangıç kaçağı, tek seferlik yardımcı.
- RED: son run'ın coalition taraması kapatılınca A1 testi 4 beklentide başarısız. Stop dürüstçe başarısız oldu, kaçak canlı kaldı, kapsam boşalmadı.
- Tam suite 298/298, geride süreç yok. C katmanı `-Wall -Wextra -Werror` ile temiz.

**Bulunan kısıt (TCC):** Run yardımcısı ayrı ve kendinden sorumlu bir uygulamadır. `~/Documents` altındaki bir binary'yi çalıştıran kapsam çocuğu, yardımcı adına Belgeler izni beklerken dyld `open()` içinde kilitlendi; ilk test 10 dakika takıldı. Kapsamlı testler fixture'ları geçici dizinden çalıştırır. Ürün etkisi: korumalı klasör izinleri yardımcıya atfedilir, kalıcı izin için sabit imza gerekir. Native kabul paketi Belgeler dışında olmalıdır.

**Doğrulanmadı:** A4 Apple XPC üyesi (yalnız araştırma deneyinde), ürün paketinde native A1/A3/A6 ve 22 kontrol, sudo/başka UID, gerçek Claude/Codex süreç ağaçları.

## OWN-B sonucu (2 Ekim 2026)

**Uygulandı (implementer):**
- `SessionRuntime` her canlı Codex run'ı için ayrı `CodexServer` tutar: manager, benzersiz soket, kapsam, client, coordinator ve onay durumu.
- Sunucu ve TUI aynı kapsamda başlar. Stop önce TUI'yi (provider hook'ları sunucu ayaktayken), sonra sunucuyu durdurur. Kapsamın son run'ı sunucu olduğu için tarama ve serbest bırakma orada yapılır.
- Teardown hatası kullanıcının kartında `stopFailure` olarak görünür ve rapor başarısız döner. Başarısız sunucu tekrar deneme için tutulur. Resume ve Quit önce teardown'ı yeniden dener.
- Fixture: `LOOM_FAKE_CODEX_SERVER_ESCAPE` sunucudan `POSIX_SPAWN_SETSID` ile işaretsiz `/bin/sleep` kaçırır.

**Değişen test beklentileri:** Ortak sunucu varsayan dört test oturum başına modele çevrildi; amaçları korundu (doğru karta onay, kardeşin etkilenmemesi, kurulum iptalinde kalıntı olmaması).
- Yardımcı olay testi artık yalnız gönderen TUI'nin sunucusunu görür.
- Aynı klasörde `/new` belirsizliği runtime üzerinden artık oluşmuyor: her sunucu kendi TUI'sinin thread'ini görür. Belirsizlik mantığı `CodexAppServerTests` birim testinde kalır.

**Doğrulandı (implementer, ayrı scratch build):** 5 suite / 99 test. OWN-B1 kapsamsız ve gerçek run host'lu iki varyantla geçti: A'nın Stop'u A'nın TUI, sunucu, kaçak ve kapsamını bitirdi; B çalışmaya devam etti; B'nin onayı cevaplandı.

**Planner review:** Durdurma sırası, teardown yeniden denemesi, kapsam serbest bırakma koşulu ve Quit sırası kaynakta doğrulandı. Birleşik suite ve native kabul OWN-C'de.

**Doğrulanmadı:** Sunucu stop/kapsam serbest bırakma hatasının yayın yolu testte zorlanmadı. Doğal TUI çıkışından sonra `/clear` ile taşınmış run'da hata, eski karta yayınlanır.

## OWN-C sonucu (2 Ekim 2026)

- **Paketleme ve uygulama:**
  - `package-dev-app.sh` yardımcıyı `Contents/Helpers/LoomRunHost.app` olarak paketler ve imzalar.
  - Uygulama her supervisor'ı kapsam launcher'ıyla kurar. Yardımcı yoksa görünür uyarı verir ve başlatmalar hata verir.
  - Release derlemesi ve C kabul fixture'ları `LOOM_SCRATCH_PATH` ile Belgeler dışında üretilebilir. Checkout içindeki release derlemesinde `dsymutil`, `~/Documents/.../.build` içinde `opendir` beklerken 20 dakika takıldı; scratch dışarı alınınca derleme tamamlandı.
- **Birleşik suite:** 301 test geçti, kalıntı yok.
- **[Native kabul](../experiments/cp5-own-native.json), Belgeler dışındaki ad-hoc pakette:**
  - OWN-A1 normal Quit: 9/9.
  - OWN-A6 SIGKILL: 12/12. Yardımcı kapsamı boşalttı; önceki D6 kanıtında çökme sonrası canlı kalan fixture artık kalmıyor.
  - C sentetik kabulü (C1–C5, D3; oturum başına Codex sunucusu): 22/22.
- **Kalan:**
  - Gerçek CLI süreç ağaçlarıyla kabul için model bütçesi gerekir.
  - Kaynak matrisi ve gecikme, run yardımcılarıyla yeniden ölçülmeli. Sağlayıcı süreçleri artık uygulamanın değil yardımcının çocuğudur.
  - Sabit imzayla TCC izin sürekliliği doğrulanmalı.
  - A4 ürün içi XPC üyesi doğrulanmadı.
  - Optimizer incelemesi yapılmadı (checkpoint kapanışı öncesi zorunlu).

## Son imzalı kabul — 3 Ekim 2026

Önceki kalan listesinin güncel karşılığı [FINAL-ACCEPTANCE](FINAL-ACCEPTANCE.md) ve [son imzalı/native kanıttadır](../experiments/cp5-final-signed-native.json). Sabit yerel kimlik kuruldu; app ve host aynı leaf sertifikasına bağlı, yanlış signer reddediliyor. Farklı app/host binary hash'li iki paket arasında Belgeler erişimi yeniden izin istemedi.

OWN-A4 artık yalnız araştırma sonucu değildir: ürün RunScope yolunda canlı, yeni compiler XPC görülmesi şartıyla iki tekrar ve tam suite geçti; Apple XPC'ye sinyal gönderilmedi, istemci durunca kapsam boşaldı. Paket C'de Quit 10/10, SIGKILL/yeniden açılış 13/13 ve C sentetik kabulü 23/23. Tam suite 322/322. Önceki gerçek Claude/Codex 17/17 kaydı korunur; aynı kaynakların yeni imzalı paketinde gerçek Claude native No ayrıca geçti.

Host dahil [43 kaynak koşusu](../experiments/cp5-final-runscope-resource.json) ve [2000 gecikme örneği](../experiments/cp5-final-runscope-latency.json) geçerli; iki 600 sn yükte sürekli büyüme yok, bütün çıkışlarda host/kapsam kalıntısı 0. Son optimizer kaynak incelemesi tamamlandı; GPU hazırlık zamanlaması bulgusu düzeltildi. Optimizer bu kaynak/gecikme toplamlarını ham veriden doğruladı. GPU dört görünür hücre geçti; dört örtülü hücre, Finder/link native kabulü ve sayısal ürün bütçeleri [son kabulde](FINAL-ACCEPTANCE.md) açık. Başka UID ve LaunchServices/launchd'ye devredilen işin kapsam sınırları değişmedi.


[CPU/Codex kaynak kabulü](../experiments/cp5-cpu40-source.json) ve [son ölçülen D](../experiments/cp5-cpu40-optimization.json): kare dirty işleri, Codex idle polling/deadline işleri ve yanlış başarılı onay yanıtı düzeltildi; ptrace fixture cleanup'ı ownership oracle'ları korunarak bounded yapıldı. Astra/high review ve birleşik334 geçti. D23/23 koşul geçerli, gecikme2000/timeout0 ve bütün cleanup0; yoğun CPU medyan CG%44,812 / Metal%45,455 ile %40 tavanı başarısız. [ASCII adayı](../experiments/cp5-ascii-render-optimization.json) kaynak review ve yeni birleşik334'ten geçti; imzası/runtime kazancı Mac kilidinde doğrulanmadı, kurulu D korundu. Gerçek Codex modelsiz idle/Stop ayrıştırması çalıştırılmadı. C native/GPU/uzun kanıtları tarihsel paket kapsamını korur; Finder/link/örtülüGPU4 kullanıcı tarafından ertelenmiştir. Güncel iş [FINAL-ACCEPTANCE](FINAL-ACCEPTANCE.md); CP5 açık.
