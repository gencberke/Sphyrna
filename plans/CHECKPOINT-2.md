# Checkpoint 2 — Durum ve devam

**Tarih:** 27 Eylül 2026  
**Durum:** Plan onaylandı; uygulanmadı. Bu checkpoint'ten sonra ilk pencere gelir (sözleşme §3, checkpoint sırası).  
**Dayanak:** [Ürün sözleşmesi](../LOOM-PRODUCT-CONTRACT.md) §4, §9 ve §11'deki 2. checkpoint; [CP1](CHECKPOINT-1.md) §12.4 ve kod review'ı.

## 1. Amaç

Loom, yönettiği her oturumu kalıcı olarak bilir ve oturumun ne yaptığını belirli bir kaynaktan gösterir. Boşta kalan oturumu güvenle kapatır (idle) ve aynı sohbetten devam ettirir. Uygulama kapanıp açıldığında sohbetler kaybolmaz.

Arayüz bu checkpoint'te yok; çekirdek, `loom-probe` ve testlerle çalışılır.

**Kapsam dışı:** terminal motoru ve pencere (sonraki parça), silme ve otomatik temizlik, oturumlar arası görev devri, side chat.

## 2. Önce: çekirdeğin yapısal hazırlığı

CP1 kodu dikkatli yazılmış ve iyi test edilmiş, doğruluk hatası yok. Ancak uzun süre açık kalacak ve birden çok oturum yönetecek bir uygulama için üç yapısal eksik var. CP2'nin geri kalanı bunlara dayandığı için ilk iş bunlardır.

| # | Sorun (CP1 kodu) | Beklenen |
| --- | --- | --- |
| S1 | Oturum kavramı yok: `ShutdownCoordinator` düz bir `PTYProcess` listesi tutuyor; yalnızca bütün süreçler kapatılabiliyor. Ledger oturum bazında değil. | `ManagedSession`: Loom oturum kimliği ↔ sağlayıcı sohbet kimliği ↔ o anki çalıştırma (PTY, lider kimliği, torunlar). Tek oturumu durdurma ve yokluğunu doğrulama API'si. Tam çıkış, bütün oturumların üzerinde aynı sözleşmeyi uygular. |
| S2 | Her şey `@MainActor` üzerinde ve senkron: ortam çözümlemesi 30 sn'ye, kapanış yaklaşık 1 sn'ye kadar ana iş parçacığını bekletiyor. PTY çıktısı ve süreç çıkışı yoklamayla izleniyor (probe'da 5 ms'lik döngü). | Süreç ve IO işleri ayrı bir actor'da, async API ile. PTY okuma ve süreç çıkışı olay tabanlı (`DispatchSource` read / process exit). Hiçbir yaşam döngüsü işlemi ana iş parçacığını bloklamaz. |
| S3 | Her `sample()` sistemdeki bütün süreçleri tarıyor: her süreç için 1 MiB'lık `KERN_PROCARGS2` ve coalition okuması yapıyor, ledger JSON'unu her seferinde yeniden yazıyor. `descendants` ve `sessionLeaders` hiç küçülmüyor. Ortam çözümlemesi sırasında bu tarama 20 ms'de bir yapılıyor. | Ölen kimlikler ayıklanır. Ledger yalnızca değişince yazılır. İşaret okuması yalnızca yeni PID'lerde yapılır; tam tarama çıkış ve kurtarmaya bırakılır. Periyodik örnekleme olaylara bağlanır ve düşük frekansla sınırlanır; frekans ölçülerek seçilir. |
| S4 | Adlandırma ve hata tipleri: `ShutdownCoordinator` artık launch, örnekleme, ortam ve kapanışı birlikte yapıyor. Hatalar çoğunlukla `LoomError.message(String)`. | Sorumluluğu anlatan bir ad (örneğin `ProcessSupervisor`). Arayüzün ayırt etmesi gereken durumlar için tipli hatalar: ortam zaman aşımı, desteklenmeyen shell, sağlayıcı geçmişi yok vb. |

Kabul:

- CP1 testleri ve A9a–A9f matrisi aynen geçer.
- Tek oturum durdurma, diğer oturumlara dokunmadan sıfır kalıntıyla doğrulanır.
- 10 boşta oturumda Loom'un kendi CPU kullanımı ve uyanma sayısı ölçülüp kaydedilir.
- Sentetik uzun çalışma (binlerce kısa ömürlü torun) sonrasında ledger boyutu yaşayan süreç sayısıyla sınırlı kalır.
- Ortam çözümlemesi ve kapanış sırasında ana iş parçacığı bloklanmaz.

## 3. Codex yolu (G1, karar verildi)

**Kullanıcı kararı:** Yol (a), yani Loom'a ait app-server + remote TUI. CP1 örnekleminde yol (b)'ye göre yaklaşık 110 MiB ek sabit bellek maliyeti var; oturum durumunun doğrudan görülmesi karşılığında kabul edildi (sözleşme §3).

Yol (a)'da durum akışı (`thread/status/changed`, onay ve girdi bekleme), arka plan terminalleri listesi ve onay çözülmesi doğrudan görülür. Bu checkpoint'te çözülecekler:

- **Eşleşme:** Aynı sunucuda aynı anda açılan TUI'lerde `thread/started` ↔ PTY eşleşmesi sağlanmalı. Ya başlatmalar sıraya alınır ya da ayırt edici bir alan bulunur.
- **İstemci:** Probe'daki senkron ve tipsiz RPC istemcisi ürün kodu değildir. Core'da tipli, async bir app-server istemcisi yazılır; bilinmeyen alan ve olaylara toleranslıdır.
- **Sunucu yaşam döngüsü:** Sunucu ilk Codex oturumunda başlar. Aktif Codex oturumu kalmayınca kapanır; tam çıkışta sahiplik sözleşmesine tabidir.
- **Koşul:** Yol (a) beklenen görünürlüğü sağlamazsa (T1–T3, I1) bu rapor edilir ve karar yeniden değerlendirilir. Yol (b) adayları (`notify`, OSC 9 bildirimleri) ancak o durumda incelenir.

## 4. Kimlik ve anlık durum

**Claude:** Kimlik başlangıçta `--session-id` ile atanır. Durum, `--settings` ile yalnızca o oturuma verilen hook'lardan gelir. Kullanıcının ayar dosyalarına yazılmaz.

| Olay | Kullanım |
| --- | --- |
| `SessionStart` (`source`: startup / resume / clear / compact / fork) | Sohbet kimliği ve kimlik değişimi |
| `UserPromptSubmit` | Çalışıyor; son kullanım zamanı |
| `Stop` | Tur bitti; `last_assistant_message` |
| `StopFailure` | Hata (API hatası türüyle) |
| `Notification` (`permission_prompt`, `idle_prompt`) / `PermissionRequest` | Onay veya girdi bekleniyor |
| `SessionEnd` | Oturum bitti (neden ile) |

- **Hook taşıma yolu:** İki aday ölçümle seçilir. Seçim ölçütleri: olay başına maliyet, Claude'u yavaşlatmama, yalnızca Loom oturumlarının yazabilmesi.
  - async `command` hook + küçük bir `loom-hook` yardımcısı → Loom'un Unix soketi.
  - `http` hook → `127.0.0.1` + oturum token'ı.
- **Eşleşme:** Hook süreci Claude'un ortamını, dolayısıyla `LOOM_SESSION_ID`'yi taşır; olay ile oturum eşleşmesi kesindir.

**Codex:** Yol (a) olayları; eşleşme ve istemci §3'te.

**Kurallar:**

- Yaşam döngüsü, ajanın anlık durumu, süreç durumu ve ekrandaki seçim ayrı alanlardır (sözleşme §4.2).
- Eski bir çalıştırmadan gelen olay, yeni çalıştırmanın durumunu değiştirmez; olaylar çalıştırma kimliğiyle eşlenir.
- Bilinmeyen bir olaydan "bitti", "onaylandı" ya da "kapandı" sonucu çıkarılmaz; durum "bilinmiyor" olur.

**Yeni sohbet komutları (G2, karar verildi):** Claude `/clear` ya da Codex `/new` sonrası yeni sohbet ayrı bir kayıt olur; eski kayıt korunur (sözleşme §3). Yeni kayıt aynı çalıştırmaya (PTY) bağlıdır; eski kayıt o andan itibaren çalışmayan bir geçmiş sohbet olur.

## 5. Katalog

- SQLite: sistemdeki `libsqlite3`, ek bağımlılık yok. WAL modu ve şema sürümü.
- En az şu tablolar:
  - `sessions`: Loom kimliği, sağlayıcı, sağlayıcı sohbet kimliği, çalışma dizini, başlık, oluşturma ve son kullanım zamanı, yaşam döngüsü, sabitleme.
  - `runs`: çalıştırma kimliği, oturum, lider süreç kimliği, başlangıç, bitiş ve nedeni.
  - Kimlik değişimleri (G2'ye göre).
- Sohbet içeriği saklanmaz.
- Bozuk katalogun üzerine yazılmaz.
- Geliştirme verisi ayrı dizinde tutulur.
- Katalog yazımı ile kapanış yarışmaz: kapanış ve silme sırasında bekleyen yazımlar tamamlanır.

## 6. Yaşam döngüsü ve idle

- **Durumlar:** `active` / `idle` / `stale` (sözleşme §4.1). `last_used_at`, son kullanıcı promptu ya da bilinçli görüntülemedir. Görüntüleme için arayüz gelene kadar test kancası kullanılır.
- **Idle geçişi** (sözleşme §4.3): Varsayılan 1 saat; testte saniyeler. Sessizlik koşulları:
  - tur yok,
  - onay veya girdi beklenmiyor,
  - teslim bekleyen iş yok,
  - "yerleşik yardımcılar" dışında torun yok. Oturum başında başlayan MCP sunucuları gibi süreçler yerleşik sayılır; sonradan başlayan shell ya da komut oturumu meşgul yapar. Bu süreç tabanlı kontrol sağlayıcıdan bağımsızdır.

  Koşul sağlanmazsa geçiş ertelenir ve neden kaydedilir.
- **Kapatma:** Kontrollü kapanış yapılır; torunlar dahil yokluk doğrulanır ve ancak ondan sonra `idle` yazılır.
- **Garanti sınırı:** Coalition tek oturumu ayırt edemez. Oturumdan kaçmış işaretsiz bir süreç idle'da yakalanmayabilir; tam çıkışta yakalanır. Idle garanti metni buna göre yazılır.
- **Codex yol (a):** TUI kapanır. Sunucudaki thread en fazla 30 dk bellekte kalır (kabul edildi). Aktif Codex oturumu kalmayınca sunucu kapanır.
- **Stale:** 15 gün sonra yalnızca sınıflandırılır; temizlik ve silme sonraki parçadadır.

## 7. Devam (resume)

- **Komutlar:** Claude: `--resume <id>`, aynı başlatma profili (agent view kapalı, `--settings`) ve aynı çalışma dizini. Codex: `resume <id>` (yol b) ya da `resume <id> --remote` (yol a).
- **Başarısız devam:** Sessizce yeni sohbet açılmaz (sözleşme §4.3). Sağlayıcı geçmişi yoksa (örneğin Claude'un 30 günlük temizliğinden sonra) durum "sağlayıcı geçmişi bulunamadı" olur.
- **Aynı sohbetin iki kez açılması:** Loom içinde engellenir. Sohbetin Loom dışında açık olduğu tespit edilebiliyorsa (Claude `claude agents --json`, Codex yazıcı kilidi) uyarı verilir; tespit yöntemi doğrulanacak.
- **Çalışma dizini bağımlılığı:** Resume'un çalışma dizinine bağlı olup olmadığı doğrulanacak.

## 8. Quit süresi ve bütünlük

CP1'de Claude ve remote Codex TUI, 0,4 sn'lik `SIGHUP` süresinde kapanmadı ve `SIGTERM` gerekti.

- Her sağlayıcının `SIGHUP` sonrası kendiliğinden kapanma süresi, boşta ve çalışırken ölçülür.
- Sağlayıcı süreçlerine tanınan süre buna göre ayarlanır; toplam Quit süresi kaydedilir.

## 9. Senaryolar ve kabul

| # | Senaryo | Beklenen |
| --- | --- | --- |
| S1–S4 | §2 | §2'deki kabul maddeleri. |
| G1 | Yol (a) görünürlüğü | Durum, onay ve arka plan terminali olayları gerçek TUI yanında doğru geliyor. Eksik varsa rapor edilir ve karar yeniden değerlendirilir. |
| I1 | Claude ve Codex yeni oturumu | Sağlayıcı kimliği katalogda; Loom oturumuyla kesin eşleşme. Codex'te eşzamanlı iki başlatmada da doğru eşleşme. |
| I2 | `/clear` / `/new` | Yeni sohbet ayrı kayıt; eski sohbet kaybolmaz ve aynı sohbetten devam ettirilebilir. |
| T1 | Prompt → çalışıyor → tur bitti | Durum geçişleri doğru kaynaktan; son yanıt alınabiliyor. |
| T2 | Onay isteyen komut | "Onay bekleniyor"; kullanıcı yanıtlayınca çalışıyor ya da bitti. |
| T3 | API hatası / çökme / bilinmeyen olay | Hata ya da "bilinmiyor"; yanlış başarı yok. |
| T4 | Eski çalıştırmadan gecikmiş olay | Yeni çalıştırmanın durumu değişmez. |
| L1 | Boşta oturum, süre doldu | Kontrollü kapanış, yokluk doğrulaması, `idle`; diğer oturumlar etkilenmez. |
| L2 | Arka plan komutu veya bekleyen onay varken süre doldu | Idle ertelenir; neden kaydedilir. |
| L3 | Kapanış sırasında yeni prompt | Prompt kaybolmaz; ikinci süreç başlamaz. |
| L4 | Stale sınıflandırması | 15 gün (test saati) sonra `stale`; görüntüleme durumu değiştirmez (sözleşme §3). |
| R1 | Idle → yeni prompt | Aynı sohbetten devam; kimlik ve çalışma dizini korunur. |
| R2 | Loom kapanıp açılır | Katalog yerinde; seçilen sohbet aynı sohbetten açılır; otomatik süreç başlatılmaz. |
| R3 | Sağlayıcı geçmişi yok | "Sağlayıcı geçmişi bulunamadı"; yeni sohbet açılmaz. |
| Q1 | Aktif tur sırasında Quit → yeniden açılış → resume | Son tamamlanmış tur kayıtta; sohbet açılıyor. Her iki sağlayıcı. |

Her sonuç **doğrulandı / başarısız / doğrulanmadı** olarak, komut ve kanıtla bu dosyaya yazılır. Deneyler izole profillerde yapılır.

## 10. Uygulama sırası

1. S1–S4 ve CP1 regresyonu.
2. Katalog.
3. Claude kimlik ve durum (hook taşıma yolu ölçümüyle).
4. Codex yol (a): tipli async app-server istemcisi, sunucu yaşam döngüsü, eşzamanlı başlatma eşleşmesi, kimlik ve durum.
5. Idle, stale sınıflandırması, resume.
6. Quit süresi ölçümü ve Q1.
7. Sonuç raporu ve sözleşme güncellemesi (§4, §6).

## 11. Kullanıcıdan gerekenler

- G1 ve G2 kararları verildi (sözleşme §3). Yol (a) beklenen görünürlüğü sağlamazsa yeniden karar gerekir.
- **Model turları:** Tahmini 20–30 kısa tur, izole profillerde ve düşük maliyet ayarlarıyla.

## 12. Riskler

- `--settings` ile verilen hook'ların interaktif oturumda çalışması belgelenmiş ama Loom akışında sınanmadı.
- Codex app-server protokolü "experimental" etiketli; alan ve olaylar kurulu sürümün ürettiği şemayla sınanmalı, bilinmeyenlere toleranslı olunmalı.
- Resume'un çalışma dizinine bağımlılığı ve sağlayıcıların kendi saklama politikaları.
- Süreç tabanlı sessizlik kontrolü, yerleşik yardımcıları yanlış sınıflandırabilir. Sınıflandırma kuralı testle sabitlenmeli.
