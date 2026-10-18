# Homebrew cask

This folder is the recipe for installing the release disk image. It is not the tap itself.

Copy `Casks/chief-status.rb` into the public repo `pohstep/homebrew-tap` (that repo is separate from this one). Its `sha256` must match `Chief-Status-1.4.0.dmg` on the GitHub release. For a new release, put in the checksum that `./packaging/make-dmg.sh` prints.

The old `--HEAD` formula, which rebuilt the app from source, is gone. The cask installs the `.dmg`.

On a Mac, once the tap has the cask:

```bash
brew tap pohstep/tap
brew install --cask chief-status
```

`brew tap pohstep/tap` reads `github.com/pohstep/homebrew-tap`. The cask puts **Chief Status** in `/Applications`. It does not build with `swiftc`.

The app is unsigned. The cask's caveat says how to allow it: **Open Anyway** in **System Settings → Privacy & Security**, or:

```bash
xattr -dr com.apple.quarantine "/Applications/Chief Status.app"
```

`./install.sh` in a checkout of this repo still builds and installs into `~/Applications`, with or without Homebrew.
