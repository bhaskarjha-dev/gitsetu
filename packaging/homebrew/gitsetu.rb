class Gitsetu < Formula
  desc "Zero-trust multi-account Git identity orchestrator"
  homepage "https://gitsetu.bhaskarjha.dev"
  url "https://github.com/bhaskarjha-dev/gitsetu/releases/download/v1.0.0/gitsetu-1.0.0.tar.gz"
  sha256 "af0a75748e5c55a71bf8007daff4966b56db6fab0ce3d201ed06e5737f9a28a5"
  license "MIT"

  depends_on "bash"

  def install
    libexec.install "lib"
    libexec.install "gitsetu"

    (bin/"gitsetu").write <<~EOS
      #!/usr/bin/env bash
      exec "#{libexec}/gitsetu" "$@"
    EOS

    bin.install_symlink bin/"gitsetu" => "git-setu"

    bash_completion.install "lib/completion.sh" => "gitsetu"
  end

  test do
    assert_match "gitsetu v1.0.0", shell_output("#{bin}/gitsetu --version")
    assert_match "gitsetu v1.0.0", shell_output("#{bin}/git-setu --version")
  end
end
