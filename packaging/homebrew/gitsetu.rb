class Gitsetu < Formula
  desc "Zero-trust multi-account Git identity orchestrator"
  homepage "https://gitsetu.bhaskarjha.dev"
  url "https://github.com/bhaskarjha-dev/gitsetu/archive/refs/tags/v1.0.0.tar.gz"
  license "MIT"

  depends_on "bash" => :recommended

  def install
    pkgshare.install "lib"
    pkgshare.install "gitsetu"

    (bin/"gitsetu").write <<~EOS
      #!/usr/bin/env bash
      exec "#{pkgshare}/gitsetu" "$@"
    EOS

    bin.install_symlink bin/"gitsetu" => "git-setu"
  end

  test do
    assert_match "gitsetu v1.0.0", shell_output("#{bin}/gitsetu --version")
    assert_match "gitsetu v1.0.0", shell_output("#{bin}/git-setu --version")
  end
end
