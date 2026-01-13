class Sed < Formula
  desc "GPU-accelerated sed utility using Metal and Vulkan"
  homepage "https://github.com/e-jerk/sed"
  version "0.1.0"
  license "GPL-3.0-or-later"

  on_macos do
    on_arm do
      url "https://github.com/e-jerk/sed/releases/download/v#{version}/sed-macos-arm64-v#{version}.tar.gz"
      sha256 "0cdfd8a476046d3bc3b0b773cf2b99e0ca501221a3398abb107722d500805c56" # macos-arm64
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/e-jerk/sed/releases/download/v#{version}/sed-linux-arm64-v#{version}.tar.gz"
      sha256 "49f4e957ad924213db20b0a10ef2820abc462b3033190284e8528bd7f05cec93" # linux-arm64
    end
    on_intel do
      url "https://github.com/e-jerk/sed/releases/download/v#{version}/sed-linux-amd64-v#{version}.tar.gz"
      sha256 "3d60c268ff2e13b312182c423d30266a2a9081359ea1e837cce4c8a59b834941" # linux-amd64
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
