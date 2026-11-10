# Tune для iOS

Нативный клиент Яндекс Музыки на SwiftUI: «Моя волна», лайки, плейлисты, поиск, тексты,
«Без цензуры» по списку FckCensor и скачивание треков для игры без сети.

## Установка через SideStore

1. Один раз поставьте [SideStore](https://sidestore.io) — для первой установки нужен компьютер.
   Дальше он сам продлевает подпись на телефоне раз в 7 дней.
2. Скачайте на iPhone [Tune.ipa](https://github.com/tune-music/tune-ios/releases/latest/download/Tune.ipa).
3. В SideStore: «My Apps» → «+» → выберите `Tune.ipa`.

Обновление ставится так же, поверх старой версии: скачанная музыка и вход сохраняются.
Музыка пропадает, только если удалить приложение.

## Сборка

Сборку делает GitHub Actions (`.github/workflows/build.yml`) на каждый push; сборка из `main` попадает в релиз `latest`.
На Mac то же самое:

```bash
brew install xcodegen
xcodegen generate && open Tune.xcodeproj
```

## Где что лежит

- `Tune/Core/API.swift` — запросы к API Яндекс Музыки.
- `Tune/Core/Player.swift` — плеер: очередь, фон, экран блокировки, волна.
- `Tune/Core/Downloads.swift` — скачанные треки (`Application Support/Tune/Tracks`).
- `Tune/Core/Uncensor.swift` — список FckCensor и подмены.
- `Tune/UI` — экраны.
