# Tune для iOS

Нативный клиент Яндекс Музыки для iPhone и iPad на SwiftUI.

[Сайт](https://tune-music.github.io/tune/) · [Скачать Tune.ipa](https://github.com/tune-music/tune-ios/releases/latest/download/Tune.ipa) · [Источник AltStore](https://github.com/tune-music/tune-ios/releases/latest/download/altstore.json)

## Возможности

- **Главная и каталог:** «Моя волна», рекомендации, альбомы, исполнители, плейлисты и «Мне нравится».
- **Поиск:** быстрый поиск по трекам, альбомам, исполнителям и плейлистам.
- **Плеер:** очередь воспроизведения, синхронные тексты, фоновое воспроизведение и управление с экрана блокировки.
- **Без цензуры:** оригинальные версии треков по открытому списку FckCensor.
- **Офлайн-библиотека:** скачивание треков для прослушивания без сети.
- **Интеграция с iOS:** виджет и поддержка CarPlay.

## Установка

Нужен SideStore или AltStore (для первой установки самого магазина понадобится компьютер).

**С обновлениями одной кнопкой.** Добавьте источник в SideStore или AltStore (Sources → «+») и установите Tune из него:

```text
https://github.com/tune-music/tune-ios/releases/latest/download/altstore.json
```

Когда выйдет новая сборка, в магазине появится кнопка Update.

**Файлом.** Скачайте на iPhone [Tune.ipa](https://github.com/tune-music/tune-ios/releases/latest/download/Tune.ipa) и откройте его в SideStore или AltStore: «My Apps» → «+».

Обновление ставится поверх старой версии: скачанная музыка и вход сохраняются. Музыка пропадает, только если удалить приложение.

## Сборка

Сборку делает GitHub Actions (`.github/workflows/build.yml`) на каждый push; сборка из `main` попадает в релиз `latest`. На Mac то же самое:

```bash
brew install xcodegen
xcodegen generate && open Tune.xcodeproj
```

Для CarPlay выберите схему **Tune-CarPlay** и укажите свою команду в **Signing & Capabilities**. Профиль подписи для `dev.tune.music` должен содержать разрешение CarPlay Audio. Если у вашей команды зарегистрирован другой Bundle ID, укажите его для приложения и расширения виджета. [Разрешения CarPlay](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)

Схема **Tune** используется для релиза AltStore. Для проверки интерфейса CarPlay на Mac можно выбрать схему **Tune-CarPlay** и открыть внешний дисплей CarPlay в iOS Simulator. [Симулятор CarPlay](https://developer.apple.com/documentation/carplay/using-the-carplay-simulator)

## Структура проекта

- `Tune/Core/API.swift` — запросы к API Яндекс Музыки.
- `Tune/Core/Player.swift` — плеер: очередь, фон, экран блокировки, волна.
- `Tune/Core/Downloads.swift` — скачанные треки (`Application Support/Tune/Tracks`).
- `Tune/Core/Uncensor.swift` — список FckCensor и подмены.
- `Tune/UI` — экраны.

---

<sub>Tune — независимый проект, не связанный с Яндексом. «Яндекс Музыка» — товарный знак ООО «Яндекс».</sub>
