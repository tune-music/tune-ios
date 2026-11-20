# Tune для iOS

Нативный клиент Яндекс Музыки на SwiftUI: «Моя волна», лайки, плейлисты, поиск, тексты,
«Без цензуры» по списку FckCensor и скачивание треков для игры без сети.

## Установка

Нужен SideStore или AltStore (для первой установки самого магазина понадобится компьютер).

**С обновлениями одной кнопкой.** Добавьте источник в SideStore или AltStore
(Sources → «+») и установите Tune из него:

```
https://github.com/tune-music/tune-ios/releases/latest/download/altstore.json
```

Когда выйдет новая сборка, в магазине появится кнопка Update.

**Файлом.** Скачайте на iPhone
[Tune.ipa](https://github.com/tune-music/tune-ios/releases/latest/download/Tune.ipa)
и откройте его в SideStore или AltStore: «My Apps» → «+».

Обновление ставится поверх старой версии: скачанная музыка и вход сохраняются.
Музыка пропадает, только если удалить приложение.

### Tune Dev

Ветка `dev` собирает отдельное приложение `dev.tune.music.dev` с отдельным виджетом. Оно устанавливается рядом с обычной Tune; аккаунт и загрузки в Dev нужно настроить заново. Для локальной сборки используйте схему `Tune` и конфигурацию `Dev`. Для частного HTTPS-хоста адрес своей ленты можно указать через `TUNE_DEV_SOURCE_URL` при сборке.

Пуш в `dev` запускает проверку в Actions, но ничего не публикует по умолчанию. Если включить публичную публикацию переменной `TUNE_DEV_PUBLIC=true`, prerelease `dev` получает отдельный IPA и `altstore-dev.json` для AltStore Classic или SideStore. Стабильный источник это не меняет.

## Сборка

Сборку делает GitHub Actions (`.github/workflows/build.yml`) на каждый push; сборка из `main` попадает в релиз `latest`.
На Mac то же самое:

```bash
brew install xcodegen
xcodegen generate && open Tune.xcodeproj
```

Для CarPlay выберите схему **Tune-CarPlay** и укажите свою команду в **Signing & Capabilities**. Профиль подписи для `dev.tune.music` должен содержать разрешение CarPlay Audio. Если у вашей команды зарегистрирован другой Bundle ID, укажите его для приложения и расширения виджета. [Разрешения CarPlay](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)

Схема **Tune** используется для релиза AltStore. Для проверки интерфейса CarPlay на Mac можно выбрать схему **Tune-CarPlay** и открыть внешний дисплей CarPlay в iOS Simulator. [Симулятор CarPlay](https://developer.apple.com/documentation/carplay/using-the-carplay-simulator)

## Где что лежит

- `Tune/Core/API.swift` — запросы к API Яндекс Музыки.
- `Tune/Core/Player.swift` — плеер: очередь, фон, экран блокировки, волна.
- `Tune/Core/Downloads.swift` — скачанные треки (`Application Support/Tune/Tracks`).
- `Tune/Core/Uncensor.swift` — список FckCensor и подмены.
- `Tune/UI` — экраны.
