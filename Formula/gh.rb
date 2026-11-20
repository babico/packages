class Gh < Formula
  desc "GitHub's official command line tool"
  homepage "https://cli.github.com"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/cli/cli/releases/download/v2.96.0/gh_2.96.0_macOS_arm64.zip"
      sha256 "f23a0c37d963aacc3bed703ccbd59b41c5ca22101fab7f00eb2b7cad23aba463"
    end
    on_intel do
      url "https://github.com/cli/cli/releases/download/v2.96.0/gh_2.96.0_macOS_amd64.zip"
      sha256 "4bd449df9ad639391bc62b8032546f0fe9edcd8526e06682a4f88abd8c5d163c"
    end

    version "2.96.0"

    def install
      system "unzip", "-q", pkgfiles.first
      bin.install Dir["*/gh"].first
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/cli/cli/releases/download/v2.96.0/gh_2.96.0_linux_armv6.deb"
      sha256 "3391bd860facbe320a32d82dd52ab96a725c7e1668b16fc6f4cb2b04c85c7b2f"
    end
    on_intel do
      url "https://github.com/cli/cli/releases/download/v2.96.0/gh_2.96.0_linux_amd64.deb"
      sha256 "11a731f4e0ca8c3db96ef6d2cc404dcab3d78247ce0e07c53e07117e7627d6a1"
    end

    version "2.96.0"

    def install
      system "dpkg", "-x", pkgfiles.first, "."
      bin.install "usr/bin/gh"
    end
  end
end
