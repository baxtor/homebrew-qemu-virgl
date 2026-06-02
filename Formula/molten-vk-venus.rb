class MoltenVkVenus < Formula
  desc "MoltenVK (utmapp fork, KHR_external_semaphore_fd) for qemu-virgl venus"
  homepage "https://github.com/utmapp/MoltenVK"
  # Dummy url: the pinned commit lives on a force-pushed branch; the exact
  # revision is fetched by SHA in `install`.
  url "https://github.com/s3rj1k/homebrew-qemu-virgl/archive/refs/heads/master.tar.gz"
  version "2026.06.01"
  license "Apache-2.0"

  def self.sha256(_)
    nil
  end

  # Distinct name + keg_only: must not collide with homebrew-core `molten-vk`,
  # which lacks the KHR_external_semaphore_fd support venus requires on macOS.
  keg_only "venus-specific MoltenVK fork; conflicts with homebrew-core molten-vk"

  depends_on "cmake" => :build
  depends_on "python@3.13" => :build
  depends_on xcode: ["12.0", :build]
  depends_on arch: :arm64

  def install
    sha = "111c14f3abf5c00118fc7a5b00c92d7abbf40f62"
    system "git", "init", "-q", "repo"
    system "git", "-C", "repo", "fetch", "--depth", "1",
           "https://github.com/utmapp/MoltenVK.git", sha
    system "git", "-C", "repo", "checkout", "-q", "FETCH_HEAD"

    cd "repo" do
      # fetchDependencies clones MoltenVK's externals (SPIRV-Cross, glslang, …)
      # over the network — mirrors the workflow. (Won't pass `brew audit --strict`'s
      # no-network-in-install rule; expected for this venus fork.)
      system "./fetchDependencies", "--macos"
      system "make", "macos"

      pkg = %w[Package/Latest/MoltenVK Package/Release/MoltenVK].find { |d| File.directory?(d) }
      odie "MoltenVK package dir not found after build" unless pkg

      lib.install "#{pkg}/dylib/macOS/libMoltenVK.dylib"
      (include/"MoltenVK").install Dir["#{pkg}/include/MoltenVK/*"] if Dir.exist?("#{pkg}/include/MoltenVK")

      # ICD manifest, installed KEG-PRIVATE under share/ (NOT the shared etc/, whose
      # well-known vulkan/icd.d/MoltenVK_icd.json path collides with homebrew-core
      # molten-vk and would break `keg_only` isolation + `brew install vulkan-tools`).
      # library_path is made relative to the ICD so it resolves to this keg's
      # lib/libMoltenVK.dylib regardless of version; the qemu wrapper points
      # VK_ICD_FILENAMES at it via molten-vk-venus's opt_prefix.
      icd_dir = share/"vulkan/icd.d"
      icd_dir.install "#{pkg}/dylib/macOS/MoltenVK_icd.json"
      inreplace icd_dir/"MoltenVK_icd.json", %r{"\.?/?libMoltenVK\.dylib"},
                "\"#{(lib/"libMoltenVK.dylib").relative_path_from(icd_dir)}\""
    end

    # `make macos` can leave the dylib without a usable signature; ad-hoc sign so
    # the Vulkan loader can dlopen it under SIP.
    system "codesign", "--sign", "-", "--force", lib/"libMoltenVK.dylib"
  end

  test do
    assert_path_exists share/"vulkan/icd.d/MoltenVK_icd.json"
    assert_match "libMoltenVK", (share/"vulkan/icd.d/MoltenVK_icd.json").read
  end
end
