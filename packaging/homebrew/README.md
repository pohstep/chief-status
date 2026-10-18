# Homebrew tap

Chief Status is built on the Mac by `install.sh`. This formula wraps that script. It does not ship a prebuilt app.

The tap is a separate repository, `pohstep/homebrew-tap`. Create that public repo yourself, then copy this formula in. Do not put the formula only inside chief-status and expect `brew install` to find it.

From a folder next to your chief-status checkout:

```bash
mkdir -p homebrew-tap/Formula
cp packaging/homebrew/Formula/chief-status.rb homebrew-tap/Formula/
cd homebrew-tap
git init
git add Formula/chief-status.rb
git commit -m "Add the Chief Status formula"
```

Create the public GitHub repo `pohstep/homebrew-tap`, then:

```bash
git remote add origin https://github.com/pohstep/homebrew-tap.git
git branch -M main
git push -u origin main
```

On the Mac:

```bash
brew tap pohstep/tap
brew install --HEAD pohstep/tap/chief-status
chief-status
```

`brew tap pohstep/tap` reads `github.com/pohstep/homebrew-tap`. `--HEAD` clones `github.com/pohstep/chief-status` and runs `install.sh` from the formula, which still builds with `swiftc` into `~/Applications` and still installs the login item.

To pass the feed address:

```bash
chief-status https://chief-status.<your-subdomain>.workers.dev/status
```

`./install.sh` in a git checkout keeps working, with or without Homebrew.

After you tag a release, replace the `head` line in the formula with the commented `url` and `sha256`, push that change to `pohstep/homebrew-tap`, and install with:

```bash
brew install pohstep/tap/chief-status
```
