class Sed < Formula
  desc "GPU-accelerated sed utility using Metal and Vulkan"
  homepage "https://github.com/e-jerk/sed"
  version "0.2.0"
  license "GPL-3.0-or-later"

  on_macos do
    on_arm do
      url "https://github.com/e-jerk/sed/releases/download/v#{version}/sed-macos-arm64-v#{version}.tar.gz"
      sha256 "e5e4c62a22f13c553cc5b8803c55587fffd95217ee65e741e7a48efa14c44f99" # macos-arm64
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/e-jerk/sed/releases/download/v#{version}/sed-linux-arm64-v#{version}.tar.gz"
      sha256 "eafb39a1c7fd532395bab74225b547c2d64406599cf59a420e2e37da55fcd936" # linux-arm64
    end
    on_intel do
      url "https://github.com/e-jerk/sed/releases/download/v#{version}/sed-linux-amd64-v#{version}.tar.gz"
      sha256 "839ce6d53a2753058547ecca6d6b577273b764d69e50603a99c2657230366d20" # linux-amd64
    end
    depends_on "vulkan-loader"
  end

  depends_on "molten-vk" => :recommended if OS.mac?

  def install
    bin.install "sed"
  end

  test do
    system "#{bin}/sed", "--help"
  end
end
