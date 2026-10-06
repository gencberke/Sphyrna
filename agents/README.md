# Loom ajan rolleri

Ortak başlangıç, doğrudan delegasyon ve kayıt kuralları [AGENTS.md](../AGENTS.md) dosyasındadır. Güncel iş [STATUS.md](../STATUS.md), teknik çalışma bilgileri [DEVELOPMENT.md](../DEVELOPMENT.md) içindedir.

| Rol | Sorumluluk |
| --- | --- |
| [Planner-reviewer](reviewer.md) | Ana ajan; planlar, subagent'ları görevlendirir, sonuçları review eder ve kalıcı kayıtları günceller. |
| [Implementer](implementer.md) | Brief kapsamındaki işi uygular, kontrolleri yapar ve sonucu doğrudan planner-reviewer'a döner. |
| [Optimizer](optimizer.md) | `gpt-6-astra` / `high` veya Claude Code'da Opus 5.5 / `xhigh`; checkpoint sonunda kod yapısını, bakım kolaylığını ve kaynak tüketimini inceler; bulgularını doğrudan planner-reviewer'a döner. |

Planner-reviewer ile subagent'lar mesajla haberleşir; slice dosyaları yazışma kuyruğu değildir. `reviewer.md` mevcut referansları korumak için aynı dosya adını kullanır; rolün adı planner-reviewer'dır.
