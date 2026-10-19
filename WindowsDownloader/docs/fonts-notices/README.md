# Bundled subtitle fonts

These unmodified fonts are supplied only as part of Feather Downloader. Each font remains under the SIL Open Font License 1.1. The fonts are not installed into the operating system. Preserve these notices and font metadata when redistributing.

Total regular font payload: 17,628,716 bytes.

The sources are the official notofonts repositories/release archives. Every shipped font and license is pinned by SHA-256 in `vendor/win-x64/fonts/fonts-manifest.json`. No font was renamed, subsetted or otherwise modified.

## Rendering integration

- Packaged font directory: `resources/tools/fonts` (`vendor/win-x64/fonts` in the development tree).
- Default subtitle family: `Noto Sans CJK SC`.
- Additional loaded fallback families: `Noto Sans`, `Noto Sans Arabic`, `Noto Sans Devanagari`, `Noto Sans Thai`.
- Pass the font directory explicitly to libass through the subtitle filter's `fontsdir` argument. Do not depend on Chinese fonts being installed in Windows.
- `glyph-coverage.json` confirms cmap mappings for 18 short language samples. It does not promise every Unicode character or validate runtime fallback/complex-script shaping.

## NotoSansCJKsc-Regular.otf
- Family: Noto Sans CJK SC
- Copyright: © 2014-2021 Adobe (http://www.adobe.com/).
- Version: Version 2.004;hotconv 1.0.118;makeotfexe 2.5.65603
- Official source: https://raw.githubusercontent.com/notofonts/noto-cjk/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf
- Repository commit: f8d157532fbfaeda587e826d4cd5b21a49186f7c
- Shipped SHA-256: 2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b
- License: [NotoSansCJK-OFL.txt](NotoSansCJK-OFL.txt)
- Original archive member: Direct raw font file

## NotoSans-Regular.ttf
- Family: Noto Sans
- Copyright: Copyright 2015-2021 Google LLC. All Rights Reserved.
- Version: Version 2.008; ttfautohint (v1.8) -l 8 -r 50 -G 200 -x 14 -D latn -f none -a qsq -X ""
- Official source: https://raw.githubusercontent.com/notofonts/noto-fonts/ffebf8c1ee449e544955a7e813c54f9b73848eac/hinted/ttf/NotoSans/NotoSans-Regular.ttf
- Repository commit: ffebf8c1ee449e544955a7e813c54f9b73848eac
- Shipped SHA-256: b85c38ecea8a7cfb39c24e395a4007474fa5a4fc864f6ee33309eb4948d232d5
- License: [NotoSans-OFL.txt](NotoSans-OFL.txt)
- Original archive member: Direct raw font file

## NotoSansArabic-Regular.ttf
- Family: Noto Sans Arabic
- Copyright: Copyright 2022 The Noto Project Authors (https://github.com/notofonts/arabic)
- Version: Version 2.013; ttfautohint (v1.8.4.16-eb64)
- Official source: https://github.com/notofonts/arabic/releases/download/NotoSansArabic-v2.013/NotoSansArabic-v2.013.zip
- Repository commit: 1b2b7e5c6ce3ab4d50681c854892325530084c35
- Shipped SHA-256: 7ed3fe069312aceac454f17cf613a30f95271d6ed7ce58005ed4d016bd3823d7
- License: [NotoSansArabic-OFL.txt](NotoSansArabic-OFL.txt)
- Original archive member: NotoSansArabic/full/ttf/NotoSansArabic-Regular.ttf

## NotoSansDevanagari-Regular.ttf
- Family: Noto Sans Devanagari
- Copyright: Copyright 2022 The Noto Project Authors (https://github.com/notofonts/devanagari)
- Version: Version 2.007; ttfautohint (v1.8.4.16-eb64)
- Official source: https://github.com/notofonts/devanagari/releases/download/NotoSansDevanagari-v2.007/NotoSansDevanagari-v2.007.zip
- Repository commit: e123d230c160ebe949d731cc19017cdb354180d1
- Shipped SHA-256: 573e525d9f4923d34645fe752475419f45f8dec5a8e43f3e83c5c5f43d1f2ff9
- License: [NotoSansDevanagari-OFL.txt](NotoSansDevanagari-OFL.txt)
- Original archive member: NotoSansDevanagari/full/ttf/NotoSansDevanagari-Regular.ttf

## NotoSansThai-Regular.ttf
- Family: Noto Sans Thai
- Copyright: Copyright 2022 The Noto Project Authors (https://github.com/notofonts/thai)
- Version: Version 2.002; ttfautohint (v1.8.4.7-5d5b)
- Official source: https://github.com/notofonts/thai/releases/download/NotoSansThai-v2.002/NotoSansThai-v2.002.zip
- Repository commit: f8b482c158650260bba5d5edba9da3e8bb7185b4
- Shipped SHA-256: 2101faa471942570d506a394df7da555d15246c7814c7522c63d4fa85b0d8d88
- License: [NotoSansThai-OFL.txt](NotoSansThai-OFL.txt)
- Original archive member: NotoSansThai/full/ttf/NotoSansThai-Regular.ttf
