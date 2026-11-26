class Gh < Formula
  desc "GitHub's official command line tool"
  homepage "https://cli.github.com"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/cli/cli/releases/download/v2.106.0/gh_2.106.0_macOS_arm64.zip"
      sha256 "22b2b723dfbc69b6022b1b08604ff51c0db5aa8b6774b4ced1a47b8413a995d6"
    end
    on_intel do
      url "https://github.com/cli/cli/releases/download/v2.106.0/gh_2.106.0_macOS_amd64.zip"
      sha256 "f43a04a5ffe0717e2e39d7591cbc50db24c6c38d09d0ea4998be27cd197758e3"
    end

    version "2.106.0"

    def install
      system "unzip", "-q", pkgfiles.first
      bin.install Dir["*/gh"].first
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/cli/cli/releases/download/v2.106.0/gh_2.106.0_linux_armv6.deb"
      sha256 "e72ae739debe125c82d588be287ae6ccc44118ff0bbae31d8fafe9ff33eef3f2"
    end
    on_intel do
      url "https://github.com/cli/cli/releases/download/v2.106.0/gh_2.106.0_linux_amd64.deb"
      sha256 "d76d387b8fe7619b9b7bfdf40883fa2b38f6e80cf773a3f4b1fcd5e8070ab346"
    end

    version "2.106.0"

    def install
      system "dpkg", "-x", pkgfiles.first, "."
      bin.install "usr/bin/gh"
    end
  end
end
