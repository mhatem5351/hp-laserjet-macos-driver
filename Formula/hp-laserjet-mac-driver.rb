# hp-laserjet-mac-driver Homebrew formula.
#
# WHY THIS IS A TWO-STEP INSTALL:
#   The driver needs a *setuid-root* USB pusher (fwload), a per-user launchd
#   agent, and a Print-dialog PDF Service. `brew install` runs unprivileged and
#   must not prompt for a password or drop setuid binaries, so the formula only
#   stages the repo contents into the Cellar. The privileged/user-context work
#   (sudo, setuid, launchd, PDF Service) is done by the bundled install.sh, which
#   the `caveats` block tells the user to run once after `brew install`.
#
# MAINTAINER RELEASE CHECKLIST (see HOMEBREW.md for full details):
#   1. Tag a release, e.g.  git tag v1.0.0 && git push origin v1.0.0
#   2. Point `url` at that tag's source tarball (below) and bump `version`.
#   3. Compute the tarball checksum and replace the REPLACE_ME sha256:
#        brew fetch --build-from-source ./Formula/hp-laserjet-mac-driver.rb
#      or download the tarball and run `shasum -a 256 <file>`.
class HpLaserjetMacDriver < Formula
  desc "Non-CUPS macOS driver for host-based (GDI) HP LaserJet printers"
  homepage "https://gitlab.com/pauyedin/hp-laserjet-mac-driver"

  # MAINTAINER: on each release, update the tag in this URL and the version
  # below to match, then refresh the sha256. GitLab serves a source tarball at
  # this path for any tag.
  url "https://gitlab.com/pauyedin/hp-laserjet-mac-driver/-/archive/v1.0.0/hp-laserjet-mac-driver-v1.0.0.tar.gz"
  version "1.0.0"
  # MAINTAINER: REPLACE_ME with the real tarball checksum before release.
  # Do not ship this formula with the placeholder — `brew install` will refuse
  # a mismatched checksum. Compute it with `shasum -a 256` (see HOMEBREW.md).
  sha256 "REPLACE_ME"

  license "GPL-2.0-only"

  depends_on "ghostscript"
  depends_on "libusb"
  depends_on "poppler"
  depends_on :macos

  def install
    # Stage the whole repo so the bundled install.sh can build + install with
    # the correct sudo/setuid/launchd steps. install.sh keys off its own
    # directory ($HERE), so keep the tree intact under libexec.
    libexec.install Dir["*"]

    # Convenience: a thin wrapper on PATH that runs the privileged installer.
    (bin/"hp-laserjet-install").write <<~SH
      #!/bin/bash
      exec "#{libexec}/install.sh" "$@"
    SH
    chmod 0755, bin/"hp-laserjet-install"

    # Ship the docs where `brew` users expect them.
    docs = ["README.md", "CHANGELOG.md", "HOMEBREW.md"].select { |f| File.exist?(f) }
    doc.install(docs) unless docs.empty?
  end

  def caveats
    <<~EOS
      This formula only stages the driver files. It cannot install the
      setuid-root USB pusher, the launchd agent, or the Print-dialog PDF
      Service, because those require sudo and per-user setup that must not run
      inside `brew install`.

      To finish installation, run the bundled installer once (it will prompt
      for your password):

        #{opt_bin}/hp-laserjet-install

      (equivalently: "#{opt_libexec}/install.sh")

      Then print from any app:
        Cmd+P -> PDF v (bottom-left) -> "Print on HP LaserJet"

      To uninstall the driver's system pieces before `brew uninstall`:
        "#{opt_libexec}/uninstall.sh"
    EOS
  end

  test do
    # Lightweight checks only — no printer, no sudo, no build.
    # The installer and the sources brew staged must be present.
    assert_predicate libexec/"install.sh", :exist?, "bundled install.sh missing"
    assert_predicate bin/"hp-laserjet-install", :executable?

    # The USB pusher source and the raster-converter tarball must be shipped so
    # `install.sh` can build them (foo2zjs/foo2xqx from the vendored tarball,
    # fwload from src/fwload.c).
    assert_predicate libexec/"src/fwload.c", :exist?, "fwload.c source missing"
    assert_predicate libexec/"vendor/foo2zjs-src.tar.gz", :exist?, "foo2zjs source tarball missing"

    # install.sh names both drivers; assert the build tooling references them.
    installer = (libexec/"install.sh").read
    assert_match "foo2zjs", installer
    assert_match "foo2xqx", installer
    assert_match "fwload", installer
  end
end
