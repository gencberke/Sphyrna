# CP5/C modelsiz gözlemci düzeneği

Kaynak hash'leri, son çalışmanın mutlak log/çıktı yolları ve 10 fixture sonucu [JSON kanıtında](cp5-c-observer-harness.json). Gerçek sağlayıcı/model çalıştırılmadı; C4 açık.

## Çalıştırma

Repo kökünde `swift build`, sonra `python3 scripts/cp5-c-observer-smoke.py`. Betik yalnız `.build/debug/loom-fake-provider` ve `loom-probe` çalıştırır, kendi geçici Unix socket'ini ve izole state dizinini oluşturur. Hazır bariyerini bekleyen dış fixture sürücüsü test turunu üretir; gözlemciler tur başlatmaz/cevaplamaz. Betik kendi süreçlerini kapatıp bekler. Ham RPC/TUI logu yazılmaz; snapshot ve sabit boolean fixture audit'i kalır.

15 dar test: `swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib --filter 'CodexWireDiagnosticsTests|CodexAppServerTests'`.

## Koşullu gerçek deney — yürütülmedi, yeni açık yetki gerekir

Mevcut izole app-server socket'i ve native TUI'nin açık thread kimliği deney sahibi tarafından belirlenir. Bu araç sağlayıcı/TUI başlatmaz ve istem göndermez. Resume katılımı salt okuma değildir; yalnız aşağıdaki B bağlantısının `threadId` parametresiyle yapılır. A/B initialize clientInfo ve experimentalApi capability aynıdır; yerel A/B etiketleri sağlayıcıya iletilmez.

```sh
# SOCKET ve THREAD_ID mevcut izole deneyden açıkça doldurulmalıdır.
SOCKET='/path/to/existing/isolated/socket'
THREAD_ID='explicit-existing-thread-id'
RUN_DIR="$HOME/Library/Application Support/Loom-Dev/probe/runs/observer-$(uuidgen)"
.build/debug/loom-probe codex-observers --enable-content-free-diagnostics "$SOCKET" "$THREAD_ID" "$RUN_DIR" 120
```

Komut ayrı terminalde açık kalırken `RUN_DIR/ready.json` oluşması beklenir. Bu dosyanın `ready`, `AInitialized`, `BInitialized`, `AReadMatched`, `BResumeMatched` alanları true olmadan native TUI'de tur başlatılmaz. Dosyanın ASequence/BSequence alanları hazır bariyeridir. Yetki verilirse bu bariyerden sonra yalnız native TUI'de bir kısa `touch` istemi gönderilir. Gözlemciler `turn/start`, cevap, model/sandbox/approval/cwd override göndermez. İkinci istem/tekrar yoktur.

Native TUI'de aynı turda onay istendiği ayrıca içeriksiz olarak gözlenmelidir. Yalnız timer'ın bitmesi veya `comparisonWindowValid=true` gerçek onay isteğinin üretildiğini kanıtlamaz. Bu alan yalnız kayıpsız tamamlanmış, hazır bariyeri sonrası aynı tek hedef turu gören ve tur etiketleri uyumlu pencereyi gösterir. A/B hedef request kayıtları ile bu bağımsız TUI gözlemi birlikte yorumlanır. Boş/farklı/pre-ready tur, kopma, timeout, decode/protokol hatası veya herhangi bir bounded drop olumsuz teslim çıkarımını geçersiz kılar. Son snapshot planlı bağlantı kapatmalarından önce alınır; planlı kapanış pencereyi geçersiz kılmaz. Belirsiz sonuç yeni istem yetkisi değildir.

## Arındırılmış çıktı ve sınırlar

```json
{"ready":true,"AInitialized":true,"BInitialized":true,"AReadMatched":true,"BResumeMatched":true,"ASequence":2,"BSequence":2}
```

```json
{"sequence":4,"connection":"B","envelope":"request","method":"item/commandExecution/requestApproval","idType":"number","threadMatch":true,"turnLabel":"<16-hex-correlation-label>","decode":"request","routing":"target-run"}
```

Sayısal 0 request olarak decode edilir; id'nin değeri kayda girmez. Bilinmeyen method `other`, typed decoder sonucu `unknown-event` olur. Thread kimliği yalnız yerel karşılaştırmada, tur kimliği SHA256'nin ilk 8 byte'ı ile A/B korelasyonunda kullanılır; ham değerler yazılmaz. Sequence tüm gelen zarf sırasıdır; decoder'ın inbound sırası ayrı olarak mevcut router'a verilir. `target-run/unmatched` gerçek `CodexSessionRouter` kararlarıdır, yalnız tanı binding'ine aittir; ürün coordinator'ının kabul edildiği anlamına gelmez.

Fixture audit'i iki initialize payload'ının eşitliğini ve yalnız initialize/initialized/A-read/B-resume gönderildiğini doğrular. `both`, `resume-only`, `neither` teslim ayrımlarını; unknown notification, id=0, resolution ve yanlış thread izolasyonunu doğrular. `empty`, `different-turn`, `pre-turn`, `flood`, `disconnect`, `mismatch`, `timeout` geçerli negatif sonucu engeller. Fixture'ın resolution üretmesi ve fanout biçimi gerçek sağlayıcı kuralının kanıtı değildir. B katılımının genel dağıtımı etkilemesi açık kalır; sonuç tüm fanout/replay kuralına genellenmez.
