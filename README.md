# Unarchive (MacOS Silicon)

Mac app for opening and packing archives. Native, Apple Silicon, macOS 14 or later.

Made by [Shambhala222](https://github.com/Shambhala222).

It reads RAR (split volumes and encrypted RAR 5 included), ZIP, 7z, TAR, GZ, BZ2, XZ, ISO, CAB, LHA and a few others. You can look through the contents, extract, drag files into Finder, and create ZIP, 7z or TAR.

RAR goes through UnRAR. 7z extract uses 7-Zip. Everything else uses The Unarchiver. Archive Utility is left out of it on purpose.

## Install

Grab the latest `.dmg` from [Releases](https://github.com/Shambhala222/Unarchive/releases), drop Unarchive into Applications.

The build is ad-hoc signed. First launch: right-click the app, choose Open.

Under **Unarchive → Settings** you can pick language and appearance. **File → Use Unarchive for Archives** makes it the default for RAR / ZIP / 7z and similar.

## Build

Homebrew is needed for the engines:

```bash
brew install unar sevenzip
brew install --cask rar
```

Then:

```bash
git clone https://github.com/Shambhala222/Unarchive.git
cd Unarchive
chmod +x Scripts/build.sh
./Scripts/build.sh
```

That produces `dist/Unarchive.app` and `~/Downloads/Unarchive.dmg`. If Unarchive is not running, the script also copies it to `/Applications`.

## License

MIT for the app itself. UnRAR, 7-Zip and The Unarchiver ship inside the bundle with their own licenses. Not affiliated with WinRAR or RARLAB.
