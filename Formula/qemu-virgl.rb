class QemuVirgl < Formula
  desc "QEMU (aarch64) with venus Vulkan-on-Metal GPU acceleration"
  homepage "https://www.qemu.org/"
  # Dummy url: utmapp's submit/macos-venus branch is force-pushed, so the pinned
  # revision is fetched by SHA in `install`.
  url "https://github.com/baxtor/homebrew-qemu-virgl/archive/refs/heads/master.tar.gz"
  version "2026.06.01"
  license "GPL-2.0-only"

  def self.sha256(_)
    nil
  end

  depends_on "libtool"     => :build
  depends_on "meson"       => :build
  depends_on "ninja"       => :build
  depends_on "pkg-config"  => :build
  depends_on "python@3.13" => :build
  depends_on arch: :arm64

  depends_on "dtc"
  depends_on "glib"
  depends_on "gnutls"
  depends_on "jpeg-turbo"
  depends_on "libpng"
  depends_on "libslirp"
  depends_on "libssh"
  depends_on "libusb"
  depends_on "lzo"
  depends_on "ncurses"
  depends_on "nettle"
  depends_on "pixman"
  depends_on "baxtor/qemu-virgl/libangle"
  depends_on "baxtor/qemu-virgl/libepoxy-angle"
  depends_on "baxtor/qemu-virgl/molten-vk-venus"
  depends_on "baxtor/qemu-virgl/virglrenderer"
  depends_on "snappy"
  depends_on "spice-protocol"
  depends_on "spice-server"
  depends_on "vulkan-loader"

  def install
    sha = "f714f0e3370e8b4858a249ebaf6522f19b2fd97f"
    system "git", "init", "-q", "repo"
    system "git", "-C", "repo", "fetch", "--depth", "1",
           "https://github.com/utmapp/qemu.git", sha
    system "git", "-C", "repo", "checkout", "-q", "FETCH_HEAD"

    ENV["LIBTOOL"] = "glibtool"
    ENV["PYTHON"] = Formula["python@3.13"].opt_bin/"python3.13"

    angle = Formula["baxtor/qemu-virgl/libangle"]
    epoxy = Formula["baxtor/qemu-virgl/libepoxy-angle"]
    virgl = Formula["baxtor/qemu-virgl/virglrenderer"]
    ENV.prepend_path "PKG_CONFIG_PATH", "#{epoxy.opt_lib}/pkgconfig"
    ENV.prepend_path "PKG_CONFIG_PATH", "#{virgl.opt_lib}/pkgconfig"

    # Build flags follow the proven workflow "Build QEMU" step. ANGLE is reached
    # via @rpath (its dylib ids are @rpath/lib*.dylib); bake the rpath so any
    # direct ANGLE reference resolves. virgl/epoxy/loader resolve via their
    # Homebrew-relocated absolute install names.
    cd "repo" do
      system "./configure",
             "--prefix=#{prefix}",
             "--target-list=aarch64-softmmu,ppc-softmmu,x86_64-softmmu",
             "--enable-cocoa",
             "--enable-opengl",
             "--enable-virglrenderer",
             "--enable-slirp",
             "--enable-curses",
             "--enable-libssh",
             "--enable-fdt=system",
             "--disable-gtk",
             "--disable-sdl",
             "--disable-guest-agent",
             "--smbd=#{HOMEBREW_PREFIX}/sbin/samba-dot-org-smbd",
             "--extra-cflags=-I#{angle.opt_include}",
             "--extra-ldflags=-L#{angle.opt_lib}",
             "--extra-ldflags=-Wl,-rpath,#{angle.opt_lib}"
      system "make", "-j#{ENV.make_jobs}", "install"
    end

    # No install_name_tool surgery: Homebrew relocates the linked epoxy/virgl/
    # loader/glib/... install names and re-signs on bottle pour.

    # Wrap ONLY the system emulator so the Vulkan loader finds the MoltenVK ICD
    # and ANGLE uses Metal. These are non-DYLD vars, so they survive `sudo`
    # (vmnet); the loader itself is linked, so no DYLD_* is needed. qemu-img and
    # the other tools never touch Vulkan/Metal and stay unwrapped.
    #
    # molten-vk-venus ships its ICD keg-private under share/ (the shared etc path
    # collides with homebrew-core molten-vk), so point VK_ICD_FILENAMES at it via
    # opt_prefix; the ICD's relative library_path resolves to that keg's libMoltenVK.
    mvk = Formula["baxtor/qemu-virgl/molten-vk-venus"]
    libexec.install bin/"qemu-system-aarch64"
    (bin/"qemu-system-aarch64").write_env_script libexec/"qemu-system-aarch64",
      VK_ICD_FILENAMES:       "#{mvk.opt_prefix}/share/vulkan/icd.d/MoltenVK_icd.json",
      ANGLE_DEFAULT_PLATFORM: "metal",
      MVK_ALLOW_METAL_EVENTS: "1"
  end

  def caveats
    <<~EOS
      qemu-system-aarch64 is a wrapper that sets VK_ICD_FILENAMES (MoltenVK) and
      ANGLE/Metal env so venus works without DYLD_* (which SIP strips under sudo).

      Shared (vmnet) networking needs root, and `sudo` resets PATH, so invoke the
      absolute path:
        sudo "$(brew --prefix)/bin/qemu-system-aarch64" \\
          -machine virt,accel=hvf -cpu host -m 8G \\
          -device virtio-gpu-gl-pci,venus=true,hostmem=8G,blob=true \\
          -display cocoa,gl=es [other options]
    EOS
  end

  test do
    assert_match "QEMU", shell_output("#{bin}/qemu-system-aarch64 --version")
    assert_match "QEMU", shell_output("#{bin}/qemu-system-x86_64 --version")
    assert_match "QEMU", shell_output("#{bin}/qemu-system-ppc --version")
    assert_match "QEMU", shell_output("#{bin}/qemu-img --version")
    system "#{bin}/qemu-system-aarch64", "-accel", "help"
    system "#{bin}/qemu-system-x86_64", "-accel", "help"
    system "#{bin}/qemu-system-ppc", "-accel", "help"
  end
end
