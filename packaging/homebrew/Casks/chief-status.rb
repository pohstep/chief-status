cask "chief-status" do
  version "1.5.0"

  # SHA-256 of Chief-Status-1.5.0.dmg. Nothing is released yet, so this stays a placeholder.
  sha256 "REPLACE_WITH_SHA256"
  url "https://github.com/pohstep/chief-status/releases/download/v#{version}/Chief-Status-#{version}.dmg"

  name "Chief Status"
  desc "Menu bar status for the AI bots you run"
  homepage "https://github.com/pohstep/chief-status"

  depends_on macos: ">= :ventura"

  app "Chief Status.app"

  zap trash: [
    "~/Library/Application Support/Chief Status",
    "~/Library/Preferences/com.chiefstatus.menubar.plist",
  ]

  caveats <<~EOS
    Chief Status is not signed with an Apple developer account.
    The first time macOS blocks it, allow it once:

      Open Anyway in System Settings → Privacy & Security

    Or, in Terminal:

      xattr -dr com.apple.quarantine "/Applications/Chief Status.app"
  EOS
end
