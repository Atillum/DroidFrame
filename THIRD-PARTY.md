# Сторонние компоненты

## scrcpy 5.0.1

Genymobile, Apache License 2.0. Официальные бинарные сборки, ADB и зависимости взяты из https://github.com/Genymobile/scrcpy/releases/tag/v5.0.1 . Файлы поставки и лицензии сохраняются в `deps/scrcpy` (Windows) или `Contents/Resources/scrcpy` (Mac). Исходники и инструкции сборки: https://github.com/Genymobile/scrcpy/tree/v5.0.1 . Scrcpy использует SDL, FFmpeg, libusb и Android Platform Tools; их лицензии не заменяются лицензией DroidFrame. См. официальные инструкции сборки и происхождение зависимостей в https://github.com/Genymobile/scrcpy/tree/v5.0.1/doc . Иконка scrcpy используется из этой же официальной поставки.

## FFmpeg 8.0 и x264

FFmpeg n8.0 / commit `140fd653aed8cad774f991ba083e2d01e86420c7`, x264 commit `31e19f92f00c7003fa115047ce50978bc98c3a0d`. Минимальная отдельная сборка включает libx264, поэтому распространяется по GPL v2 or later. Полные исходные архивы, лицензии, конфигурация и сценарий сборки находятся в `deps/ffmpeg/{Sources,Licenses}` на Windows или `Contents/Resources/ffmpeg/{Sources,Licenses}` на Mac. Встроенный FFmpeg запускается отдельным процессом. Проекты: https://ffmpeg.org/ и https://www.videolan.org/developers/x264.html .

Исходники и автоматизация собственной сборки: `scripts/build-ffmpeg.sh` в этом репозитории. Ссылки и SHA-256 фиксированы. При изменении компонентов сохраните соответствующие исходники, лицензии и сценарии сборки в распространяемом архиве.

## .NET 10

Windows-сборка включает среду .NET / Windows Desktop Runtime. Лицензии и third-party notices Microsoft поставляются вместе с self-contained publish. Исходники: https://github.com/dotnet/runtime и https://github.com/dotnet/winforms . Основная лицензия — MIT. Системные компоненты ОС не включаются в приложение.
