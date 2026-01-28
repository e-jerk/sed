class Sed < Formula
  desc "GPU-accelerated sed utility (Metal on macOS, Vulkan on Linux)"
  homepage "https://github.com/e-jerk/sed"
  version "0.2.0"
  license "Unlicense"

  on_macos do
    on_arm do
      url "https://github.com/e-jerk/sed/releases/download/v#{version}/sed-macos-arm64-v#{version}.tar.gz"
      sha256 "PLACEHOLDER_SHA256_MACOS_ARM64" # macos-arm64
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/e-jerk/sed/releases/download/v#{version}/sed-linux-arm64-v#{version}.tar.gz"
      sha256 "PLACEHOLDER_SHA256_LINUX_ARM64" # linux-arm64
    end
    on_intel do
      url "https://github.com/e-jerk/sed/releases/download/v#{version}/sed-linux-amd64-v#{version}.tar.gz"
      sha256 "PLACEHOLDER_SHA256_LINUX_AMD64" # linux-amd64
    end
    depends_on "vulkan-loader"
  end

  def install
    bin.install "sed"
  end

  test do
    system "#{bin}/sed", "--help"
  end
end
