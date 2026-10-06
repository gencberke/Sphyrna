# CP5 C — gerçek sağlayıcı kabul düzeneği (hazırlandı, çalıştırılmadı)

Durum: **dar Claude yeni/devam deneyi tamamlandı ve [C §14](../cp5/C.md#14-beşinci-review-dar-gerçek-claude-kabulü-29-eylül-2026) ile kabul edildi.** Haiku 2/2 tur harcandı, kalan 0; **Codex 4 kısa tur onaylı, harcanan 0, tekrar payı 0**. Claude araç onayı/aktif turda Quit ve gerçek Codex kabulü açık. Uygulanacak sıra yalnız Codex A2 → A4 → C1 → C2; [C §15](../cp5/C.md#15-codex-deney-yetkisi-ve-uygulama-sırası-29-eylül-2026) yetki ve yürütme sınırlarını belirler. Aşağıdaki geniş matris kalan kabul tasarımıdır, bütçe yetkisi değildir. İzolasyon ve kanıt kuralları korunur.

## Ön koşullar (model turu harcamaz)

1. **İzole profiller** (gerçek `~/.claude` ve `~/.codex` kullanılmaz):
   - Claude: `~/Library/Application Support/Loom-Dev/probe/claude-config`
   - Codex: `~/.loom-dev/codex-home` (Darwin `sun_path` sınırı nedeniyle kısa yol)
   - Çalışma klasörü: `~/Library/Application Support/Loom-Dev/probe/workspace`; uygulamada proje olarak eklenir (`add-project:`).
2. **Giriş:** her izole profilde bir kez oturum açılır (`CLAUDE_CONFIG_DIR=<dizin> claude`, `CODEX_HOME=<dizin> codex login`). Giriş bilgisi kayda girmez.
3. **Onayı zorlayan ilke** (aksi halde `touch` onay üretmeyebilir; bu yüzden ön doğrulama şart):
   - Claude: `claude-config/settings.json` içinde `{"permissions": {"ask": ["Bash(touch:*)"]}}` ve Bash için `allow` kuralı yok. Ön doğrulama (0 tur): TUI açıkken `/permissions` ile kuralın göründüğü izlenir.
   - Codex: `codex-home/config.toml` içinde `approval_policy = "untrusted"` ve `sandbox_mode = "workspace-write"`. Ön doğrulama (0 tur): TUI açılış durum satırında politika görülür.
   - Ön doğrulama başarısızsa senaryo başlatılmaz; bütçe harcanmadan düzeltilir.
4. **Kanıt ilkesi:** uygulama `--fake-providers` olmadan `--evidence` ile açıldığında `snapshot` ham terminal metni, kart başlığı ve istek metni **yazmaz**; yalnız `--evidence-tokens A,B` ile verilen belirteçlerin terminalde bulunup bulunmadığını (`tokenPresence`) yazar. `screenshot:` bu modda kapalıdır. Gerçek `~/.claude` ve `~/.codex` için deney öncesi/sonrası yalnız `stat` (mtime, boyut) karşılaştırılır.

## Açılış komutu (LaunchServices; `--fake-providers` YOK)

```sh
RUN="$HOME/Library/Application Support/Loom-Dev/probe/runs/cp5-c-real-$(date +%Y%m%dT%H%M%S)"
open -a "<çıktı>/Loom Dev.app" --env LOOM_FORCE_COALITION_FAILURE=1 --args \
  --evidence "$RUN/evidence-<n>" --data-root "$RUN/data" \
  --claude-config "$HOME/Library/Application Support/Loom-Dev/probe/claude-config" \
  --codex-home "$HOME/.loom-dev/codex-home" \
  --evidence-tokens LOOM_C_R1,LOOM_C_R5,approved,DONE
```

Komutlar `scripts/cp5-c-acceptance.sh` içindeki `send_command`/`snap`/`until_` yardımcılarıyla gönderilir. `type:<oturum>:<metin>` terminal delegesi yoluyla yazar (yerel tuş olayı değildir). Kimlikler (`<C>`, `<X>`) her kimlik değişiminden sonra **son `snapshot`'tan yeniden okunur** (`conversationTerminals[].owner`); eski kimlikle yazılan komut yeni terminale ulaşmaz.

## Sıra (tek uygulama oturumları; toplam 8 tur)

Oturum A (uygulama açılışı 1):

| Adım | Komutlar / tam istem | Beklenen kanıt | Tur |
| --- | --- | --- | --- |
| A1 (R1) | `start:claude:<workspace>`; `type:<C>:Reply with exactly LOOM_C_R1 and nothing else.` | terminal cwd = workspace; kart Ready/Finished; `LOOM_C_R1` belirteci var; `providerConversationID` atanmış; katalog satırı projeye bağlı | 1 |
| A2 (R5) | `start:codex:<workspace>`; `type:<X>:Reply with exactly LOOM_C_R5 and nothing else.` | aynısı Codex için; `codexServerRunning=true`, katalogda sunucu kartı yok | 1 |
| A3 (R2) | `stop:<C>`; `resume:<C>`; `type:<C>:What exact token did you reply with earlier in this conversation? Reply with only that token.` | aynı kart/kimlik, `sessions` sayısı sabit; `LOOM_C_R1` belirteci **yeni** terminalde | 1 |
| A4 (R6) | `stop:<X>`; `resume:<X>`; aynı soru istemi | aynı thread; `LOOM_C_R5` belirteci; son lease kapanınca sunucu kapandı, resume'da yeniden açıldı | 1 |
| A5 (R9) | `type:<C>:/clear` → yeni `<C'>`; `type:<X>:/new` → yeni `<X'>` (ikisi de canlıyken); `stop:<C'>`; `<X'>` girdisi sürer (istemsiz: yalnız `snapshot` ile canlılık); `type:<X'>:/exit` | yeni kart/eski kart/proje ilişkisi (`run_sessions` sayımı); diğer oturum sürdü; `/exit` sonrası lease 0, süreç yok | 0 |

Oturum A sonunda `quit` (boşta, kart Idle/History); ardından Oturum B için uygulama yeniden açılır (aynı `data`): **yeniden açılış kanıtı:** kartlar geri, çocuk/PTY/sağlayıcı süreci 0.

Oturum B (açılış 2): Claude onayı ve aktif-tur Quit

| Adım | Komutlar / tam istem | Beklenen kanıt | Tur |
| --- | --- | --- | --- |
| B1 (R3) | `start:claude:<workspace>` → `<C3>`; `type:<C3>:Use the Bash tool to run exactly this command and nothing else: touch loom-c-approval.txt` — onayı **kullanıcı** Claude'un kendi izin arayüzünde verir (elle adım) | kart `Needs approval` → `Working`/`Ready`; `loom-c-approval.txt` oluştu; `userRequests` boş kalır (Loom yanıt üretmez); reddedilseydi dosya olmazdı (ret yolu ek tur gerektirir, kapsam dışı) | 1 |
| B2 (R4) | aynı oturumda `type:<C3>:Use the Bash tool to run exactly: sleep 40 and then reply DONE.`; kart `Working` iken `quit` | `quit.json` `succeeded=true`, `remaining=0`; sağlayıcı ve `sleep` süreçleri 0; dış kontrol süreci (`sleep 600`) yaşıyor | 1 |

Oturum C (açılış 3): Codex onayı ve aktif-tur Quit

| Adım | Komutlar / tam istem | Beklenen kanıt | Tur |
| --- | --- | --- | --- |
| C1 (R7) | `start:codex:<workspace>` → `<X3>`; `type:<X3>:Run exactly this shell command and nothing else: touch loom-c-approval-codex.txt`; sonra `snapshot` | **Loom'a geldiyse:** doğru kartta bekleyen istek (`selectedRequests` 1, `answerable`), `Needs approval`; `answer:<X3>:accept` → dosya oluşur, istek kapanır, ikinci `answer` reddedilir. **Loom'a gelmediyse:** `selectedRequests` boş, TUI'de görünür; bu sonuç "iletilmedi" diye kaydedilir ve onay TUI'de kullanıcıyla verilir (Loom düğmesi kanıtlanmış sayılmaz) | 1 |
| C2 (R8) | aynı oturumda `type:<X3>:Run exactly this shell command and wait for it: sleep 40. Then reply DONE.`; kart `Working` iken `quit` | R4 ile aynı; sunucu ve TUI süreçleri 0 | 1 |

Toplam: A1 + A2 + A3 + A4 + B1 + B2 + C1 + C2 = **8 tur**. Yeniden deneme payı yok; bir adım başarısız olursa yeniden çalıştırmak bütçe dışıdır ve ayrı karar ister. Oturum B/C, `<C3>`/`<X3>` oturumlarını taze başlattığı için A5'in kimlik devrinden etkilenmez.

## Kaydedilecek kanıt

Her adımda `snapshot` (durum, kart göstergesi, istek sayısı/türü, `tokenPresence`), `procs` (çocuk/PTY/sağlayıcı sayısı), `quit.json`; katalog için salt okunur SQLite sayımları (`sessions`, `runs`, `run_sessions`). Kaynak/ikili özeti `source-and-binary.txt`. Transkript, token, ortam değeri, terminal metni ve model çıktısı kayda **girmez**.

## Sınırlar

- Codex sunucu isteklerinin Loom koordinatörünün bağlantısına da iletildiği varsayımı (plan §2.2.6) gerçek Codex ile doğrulanmadı; TUI'de görünmesi Loom düğmesinin çalıştığını kanıtlamaz (C1 iki sonucu da tanımlar).
- Sahte sağlayıcılar gerçek TUI'nin izin ekranlarını, güven istemlerini veya gerçek hook yükü biçimini taklit etmez. Claude `permissions.ask` sözdizimi ve Codex `config.toml` anahtarları yukarıdaki ön doğrulamayla (0 tur) teyit edilmelidir.
- `/bin/sleep` gibi Apple platform ikilileri ortam işaretçisi taşımaz; kalıcı arka plan işinin lider çıkışından sonra izlenmesi OWN-1 kapsamındadır ve burada kanıtlanmaz.
