# vlswmplayer для iOS

Порт десктопного плеера: поиск в SoundCloud, воспроизведение, лайки, кеш.
Только чёрный и белый, только прямые углы.

- iPhone 7, iOS 15.8.7 (arm64), Dopamine
- SwiftUI + AVPlayer, без сторонних библиотек

## Сборка

Собирается в GitHub Actions на macOS-раннере: `.github/workflows/build.yml`.
Готовый файл — в артефактах запуска (`VLSWMPlayer-ipa` → `VLSWMPlayer.ipa`).

Локально (нужен macOS с Xcode):

```bash
brew install xcodegen ldid
xcodegen generate
xcodebuild -project VLSWMPlayer.xcodeproj -scheme VLSWMPlayer \
  -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO
```

## Установка на джейлбрейк

1. Поставь **AppSync Unified** (репозиторий Karen's Repo, rootless-версия).
2. Скинь `VLSWMPlayer.ipa` на телефон (AirDrop, Filza, SCP).
3. Открой в Filza и установи, либо из терминала: `appinst VLSWMPlayer.ipa`.

Без джейлбрейка — через Sideloadly с бесплатным сертификатом (живёт 7 дней).

## Управление

- Строка списка — играть трек.
- `|<` / `>|` — предыдущий / следующий.
- Центральная кнопка — пауза и продолжение.
- Полоса под обложкой — перемотка перетаскиванием.
- `VOL` — громкость приложения.
- Вкладка `LIKES` — избранное, `*` у лайкнутых.
- Кнопка `+` / `*` на панели плеера — поставить или снять лайк у текущего трека.

## Кеш

- Первое прослушивание: играет поток, параллельно качается файл в `Documents/tracks/`.
- Повторный запуск играет с диска.
- Прогрессивные треки качаются как есть, HLS — склейкой сегментов в один файл.
- Очистка: удалить приложение или папку `Documents/tracks` через Filza.

## Ограничения

- `client_id` SoundCloud берётся из константы и обновляется парсингом сайта при 401.
- DRM-треки (`*-encrypted-hls`) отфильтровываются.
- Фоновое воспроизведение включено (`UIBackgroundModes: audio`), но на джейлбрейке
  поведение зависит от твиков.
