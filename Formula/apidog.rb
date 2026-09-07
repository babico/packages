class Apidog < Formula
  desc "API design, development, and documentation platform"
  homepage "https://apidog.com"
  license "Freeware"

  on_macos do
    on_arm do
      url "https://file-assets.apidog.com/download/Apidog-macOS-arm64-latest.zip"
      sha256 "3a601e904bc215b943f3e770d9c275c19d8d6feea1ed80a2e574b96110a7ad74"
    end
    on_intel do
      url "https://file-assets.apidog.com/download/Apidog-macOS-latest.zip"
      sha256 "70960dd74f73b58a02be8962229659c5940cc71a015362a6ae26fa55e72385b1"
    end

    version "2.8.46"

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
      sha256 "d561c7edc9e1dd0917e33d492406726668e13b8cb0bded86f67ec60fd8a440ab"
    end
    on_intel do
      url "https://file-assets.apidog.com/download/Apidog-linux-deb-latest.zip"
      sha256 "16e625183a02c6891df87474cbcf48969fd29ae2241a74e1fb9a9708e1fab6bf"
    end

    version "2.8.46"

    def install
      system "unzip", "-q", pkgfiles.first
      deb = Dir["*.deb"].first
      system "dpkg", "-x", deb, "."
      bin.install "usr/bin/apidog" if File.exist?("usr/bin/apidog")
    end
  end
end
