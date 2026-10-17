class Apidog < Formula
  desc "API design, development, and documentation platform"
  homepage "https://apidog.com"
  license "Freeware"

  on_macos do
    on_arm do
      url "https://file-assets.apidog.com/download/Apidog-macOS-arm64-latest.zip"
      sha256 "91c59ab8e62081473f7700897531bf5db341bbe85898ef82138370baa475794d"
    end
    on_intel do
      url "https://file-assets.apidog.com/download/Apidog-macOS-latest.zip"
      sha256 "12eee29107309b478a612d967c9e0284e2207513cd99b4fa91ddd7da7d5f9bf9"
    end

    version "2.8.51"

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
      sha256 "5ad0980a516dac4b29824f5f772366270fd1bcac0337f39de27b157cba0bf34f"
    end
    on_intel do
      url "https://file-assets.apidog.com/download/Apidog-linux-deb-latest.zip"
      sha256 "d23c2ce97902741f364b1c62d7d3789934b798a7752676931c72f80d5ff1c6b4"
    end

    version "2.8.51"

    def install
      system "unzip", "-q", pkgfiles.first
      deb = Dir["*.deb"].first
      system "dpkg", "-x", deb, "."
      bin.install "usr/bin/apidog" if File.exist?("usr/bin/apidog")
    end
  end
end
