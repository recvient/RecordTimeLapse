# Record TimeLapse

Лёгкое menu-bar приложение для macOS (Apple Silicon, macOS 14–27), которое снимает **длинные таймлапсы экрана** — 12, 24, 48 часов — и **не падает при сохранении**.

Управление полностью из трея. Захват — **событийный** (`SCStream` с `minimumFrameInterval`): WindowServer присылает кадр только когда экран реально изменился, статичные периоды не стоят ни батареи, ни места. Кодирование — **потоковое и zero-copy**, память постоянна независимо от длины записи.

---

## Почему старое приложение крашило Mac, а это — нет

`Screen-TimeLapse-Lite` складывал **все кадры в оперативную память** и кодировал видео в самом конце. 12 часов по кадру в секунду ≈ 43 200 несжатых кадров 1080p ≈ **сотни гигабайт RAM** → зависание и краш. Костыль «сохранять каждые 2 часа» давал кучу файлов.

Здесь конвейер другой — **O(1) по памяти и zero-copy**:

```
SCStream (minimumFrameInterval = интервал, 420v, idle-suppression)
  → кадр приходит ТОЛЬКО когда экран изменился (IOSurface, без копий)
  → adaptor.append(buffer) → AVAssetWriter (аппаратный HEVC) → диск
  → буфер сразу возвращается системе
```

В любой момент «живёт» ровно **один** кадр, и CPU не трогает пиксели вообще: GPU захватывает и конвертирует в YUV, медиа-движок кодирует. Память для 1 часа и для 48 часов — одинаковая. Сжатые байты пишутся на диск непрерывно, как в эталонном опенсорс-аналоге [`wkaisertexas/ScreenTimeLapse` (TimeLapze)](https://github.com/wkaisertexas/ScreenTimeLapse).

Скорость таймлапса задаётся **только** частотой вывода: `длина видео = число кадров / FPS`. 12 ч при кадре каждые 2 с и 30 fps → **≈ 12-минутный ролик**, и это не зависит от интервала съёмки.

---

## Сборка и запуск

Нужен Xcode / Command Line Tools (Swift 6+).

```bash
cd "Record Time Laps"
./Scripts/build_app.sh --install   # собирает, подписывает и кладёт в /Applications
```

После этого приложение запускается как обычное — **⌘Space → «Record TimeLapse»** (Spotlight) или из папки «Программы». Без `--install` сборка остаётся в `dist/RecordTimeLapse.app`.

Первый запуск: **System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording** → включить Record TimeLapse → переоткрыть приложение. Иконка `record.circle` появится справа в строке меню.

> **Про подпись.** Скрипт подписывает стабильным сертификатом (`Apple Development` / `Developer ID`), который находит автоматически. Это важно: разрешение Screen Recording привязано к (bundle id + сертификат). Ad-hoc подпись (`-`) меняет хеш при каждой сборке и **сбрасывает разрешение** — скрипт об этом предупредит, если стабильного сертификата нет. Свой можно задать через `SIGN_ID="..." ./Scripts/build_app.sh`.

Тесты: `swift test`. Открыть в Xcode: `open Package.swift`.

---

## Управление (трей)

- **Start / Stop & Save** — старт и финализация со сшивкой сегментов в один файл.
- **Pause / Resume** — ручная пауза.
- Живая статистика: кадры, активное время, прогноз длины видео, размер на диске.
- **Reveal Last Video**, **Open Output Folder**, **Settings…**, **Quit** (перед выходом корректно финализирует запись).

Готовые ролики: `~/Movies/RecordTimeLapse/` (папку можно сменить в настройках).

---

## Настройки

**Capture**
- *Capture every* — интервал съёмки: 0.5 / 1 / 2 / 5 / 10 / 30 / 60 с.
- *Display* — какой монитор (по умолчанию основной).
- *Resolution* — потолок по длинной стороне (по умолчанию 2560; даунскейл на GPU экономит батарею и место).
- *Show mouse cursor*.

**Output**
- *Output frame rate* — 15 / 24 / 30 / 60 fps (задаёт скорость таймлапса).
- *Codec* — HEVC (малый размер) или H.264 (максимальная совместимость).
- *Checkpoint every* — как часто (минут реального времени) запись «запечатывается» в самостоятельный файл-чекпоинт; при сбое всё до последнего чекпоинта восстанавливается автоматически. На выходе всегда один файл.
- *Save to* — папка вывода.

**General**
- *Pause when the screen sleeps or locks* — пауза при сне/локскрине (по умолчанию вкл.), чтобы не писать чёрные кадры. Видео продолжается бесшовно.
- *Keep Mac awake while recording* — писать непрерывно сквозь простой (тяжелее для батареи; по умолчанию выкл.).
- *Launch at login*.

---

## Устойчивость на 12+ часов

- **Сегменты.** Каждые N минут писатель ротируется: завершённый сегмент — валидный самостоятельный файл. Краш теряет максимум последний незавершённый сегмент.
- **Movie fragments.** `movieFragmentInterval = 10 с` — даже оборванный `.mov` остаётся проигрываемым.
- **Восстановление.** При старте `RecoveryManager` находит сегменты прерванной сессии в `Application Support/RecordTimeLapse/sessions` и сшивает их в `Recovered …mov`.
- **Сон/лок/блокировка.** `NSWorkspace` + DistributedNotificationCenter → авто-пауза/возобновление. Таймлайн по индексу кадра, поэтому после паузы видео продолжается без разрыва.
- **Смена дисплея.** Отключили монитор / сменили масштаб — холст кодировщика фиксирован, кадры вписываются с letterbox (writer пересоздать нельзя).
- **Диск.** Ниже ~2 ГБ свободного — чистая остановка с сохранением.
- **Энергия.** Событийный `SCStream`: процесс вообще не просыпается между кадрами — WindowServer сам присылает кадр, и только если экран изменился (idle-suppression, WWDC22). Статичный экран = ноль работы у всего конвейера. Захват сразу в 420v (−62.5% трафика памяти vs BGRA), zero-copy в энкодер, QoS `.utility` (E-ядра), таймеры с tolerance, `beginActivity` против App Nap с разрешённым сном системы. Статичные периоды автоматически пропускаются в итоговом видео.

---

## Архитектура

```
RecordTimeLapseApp ─ MenuBarExtra(.window) + Settings        точка входа (SwiftUI)
AppDelegate        ─ .accessory, восстановление при старте
RecordingCoordinator (@MainActor)                            «мозг»: машина состояний, owns всё
├─ CaptureEngine        SCStream (событийная доставка кадров, idle-suppression)
├─ DisplayProvider      SCShareableContent → SCContentFilter/SCStreamConfiguration (420v, холст)
├─ PermissionService    CGPreflight/CGRequest + SCShareableContent
├─ SegmentManager       ротация сегментов, manifest, Stitcher (passthrough)
│  └─ TimelapseEncoder  AVAssetWriter + пул из 1 буфера  ← фикс памяти
│     └─ PixelBufferRenderer  CGImage → BGRA CVPixelBuffer, letterbox
├─ PowerStateObserver   сон/лок → пауза/возобновление
├─ DiskSpaceMonitor     порог свободного места
└─ RecoveryManager      сшивка сегментов после краша
```

Состояния: `idle → recording ⇄ paused → finalizing → idle`.

---

## Источники

Архитектура опирается на разбор реальных опенсорс-аналогов и документацию Apple:

- [wkaisertexas/ScreenTimeLapse (TimeLapze)](https://github.com/wkaisertexas/ScreenTimeLapse) — главный аналог: потоковая запись CMSampleBuffer в `AVAssetWriterInput`, константная память.
- [wulkano/Aperture](https://github.com/wulkano/Aperture) — зрелая обёртка ScreenCaptureKit→диск (движок Kap).
- [acj/TimeLapseBuilder-Swift](https://github.com/acj/TimeLapseBuilder-Swift) — канонический паттерн writer/input/adaptor + пул буферов (но он на 32ARGB; здесь — 32BGRA, нативный для энкодера).
- Apple: [AVAssetWriterInputPixelBufferAdaptor](https://developer.apple.com/documentation/avfoundation/avassetwriterinputpixelbufferadaptor) · [movieFragmentInterval](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval) · [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager) · [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).
