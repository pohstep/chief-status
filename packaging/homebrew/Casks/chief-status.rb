cask "chief-status" do
  version "1.5.0"

  # SHA-256 of Chief-Status-1.5.0.dmg on the v1.5.0 release.
  sha256 "09963100ddba0a8b0c01f97dcc8f9e23c1de85deaf91323cc71e13f4eb70263e"
  url "https://github.com/pohstep/chief-status/releases/download/v#{version}/Chief-Status-#{version}.dmg"

  name "Chief Status"
  desc "Menu bar status for the AI bots you run"
  homepage "https://github.com/pohstep/chief-status"

  depends_on macos: ">= :ventura"

  app "Chief Status.app"

  # Quit the app first, then remove it.
  uninstall quit: "com.chiefstatus.menubar"

  zap trash: [
    "~/Library/Application Support/Chief Status",
    "~/Library/Preferences/com.chiefstatus.menubar.plist",
  ]

  caveats <<~EOS
    Chief Status is not signed with an Apple developer account.
    The first time macOS blocks it, allow it once.

    macOS 15 or newer: System Settings → Privacy & Security → Open Anyway.

    macOS 13 or 14: in Applications, right-click Chief Status, choose Open, then Open again.

    Or, in Terminal:

      xattr -dr com.apple.quarantine "/Applications/Chief Status.app"
  EOS
end
