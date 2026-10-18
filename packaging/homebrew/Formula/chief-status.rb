class ChiefStatus < Formula
  desc "Menu bar status for the AI agents you run"
  homepage "https://github.com/pohstep/chief-status"
  license "MIT"

  # Install from the main branch until a tagged release exists.
  # After tagging v1.3.0, you can switch this formula to a tarball:
  #   url "https://github.com/pohstep/chief-status/archive/refs/tags/v1.3.0.tar.gz"
  #   sha256 "<sha256 of that tarball>"
  # and drop the `head` line. Until then, install with --HEAD.
  head "https://github.com/pohstep/chief-status.git", branch: "main"

  depends_on macos: :ventura

  def install
    libexec.install "install.sh", "uninstall.sh"
    libexec.install "menubar"
    (bin/"chief-status").write <<~SH
      #!/bin/bash
      cd "#{libexec}" || exit 1
      exec ./install.sh "$@"
    SH
    chmod 0755, bin/"chief-status"
  end

  def caveats
    <<~EOS
      Chief Status builds with the Swift compiler from the Xcode Command Line
      Tools and installs the app into ~/Applications. A checkout can still be
      installed with ./install.sh.

      Click the menu bar face and paste your feed address, or pass it here:

        chief-status https://chief-status.<your-subdomain>.workers.dev/status
    EOS
  end

  test do
    assert_predicate bin/"chief-status", :exist?
    assert_match "install.sh", (bin/"chief-status").read
  end
end
