class Apidog < Formula
  desc "API design, development, and documentation platform"
  homepage "https://apidog.com"
  license "Freeware"

  on_macos do
    on_arm do
      url "https://file-assets.apidog.com/download/Apidog-macOS-arm64-latest.zip"
      sha256 "ff1a8340d7a0c5f7a834e58034fbf178ab48b4dcba63616775e3b44a41194235"
    end
    on_intel do
      url "https://file-assets.apidog.com/download/Apidog-macOS-latest.zip"
      sha256 "5bb209bdf438421030d19f745c186936844b398528acf7051224cdeb61f02019"
    end

    version "2.8.49"

    def install
      system "unzip", "-q", pkgfiles.first
      dmg = Dir["*.dmg"].first
      system "hdiutil", "attach", "-nobrowse", "-mountpoint", "#{var}/mount", dmg
      mv "#{var}/mount/Apidog.app", libexec
      system "hdiutil", "detach", "#{var}/mount"
      appdir.install libexec/"Apidog.app"
    end
  end

  on_linux do
    on_arm do
      url "https://file-assets.apidog.com/download/Apidog-linux-arm64-deb-latest.zip"
      sha256 "547766178492ed59f51f9e262f167b09a45c59ae883c816258ed273fadb71dd9"
    end
    on_intel do
      url "https://file-assets.apidog.com/download/Apidog-linux-deb-latest.zip"
      sha256 "0e89c76c1eb5a4941fe0aeb44145f90d572c15f52a03368752f746ebc661fab5"
    end

    version "2.8.49"

    def install
      system "unzip", "-q", pkgfiles.first
      deb = Dir["*.deb"].first
      system "dpkg", "-x", deb, "."
      bin.install "usr/bin/apidog" if File.exist?("usr/bin/apidog")
    end
  end
end
