class QemuVirgl < Formula
  desc "QEMU (aarch64) with venus Vulkan-on-Metal GPU acceleration"
  homepage "https://www.qemu.org/"
  # Dummy url: utmapp's submit/macos-venus branch is force-pushed, so the pinned
  # revision is fetched by SHA in `install`.
  url "https://github.com/baxtor/homebrew-qemu-virgl/archive/refs/heads/master.tar.gz"
  version "2026.08.29"
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

  depends_on "baxtor/qemu-virgl/libangle"
  depends_on "baxtor/qemu-virgl/libepoxy-angle"
  depends_on "baxtor/qemu-virgl/molten-vk-venus"
  depends_on "baxtor/qemu-virgl/virglrenderer"
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

    # Make the GL/Metal scanout layers track the view instead of the guest
    # scanout size. dpy_gl_scanout_texture() only fires on guest mode changes,
    # so a window resize otherwise leaves the layer at its old guest-sized
    # frame: part of the view is uncovered (stale/white rectangles) and
    # zoom-to-fit / full-screen cannot scale. Mirrors
    # patches/qemu/qemu-cocoa-scanout-fit-to-view.patch (used by CI).
    # Non-block inreplace RAISES if a pattern is missing, so a QEMU bump that
    # moves this code fails the build instead of silently dropping the fix.
    cd "repo" do
      mtl_scale = "        [self.metalLayer setContentsScale:[[self window] backingScaleFactor]];"
      inreplace "ui/cocoa.m", mtl_scale,
                [mtl_scale, "        [self.metalLayer setFrame:[self bounds]];"].join("\n")

      gl_scale = "        [self.glLayer setContentsScale:[[self window] backingScaleFactor]];"
      inreplace "ui/cocoa.m", "#{gl_scale}\n#ifdef USE_METAL",
                [gl_scale,
                 "        [self.glLayer setFrame:[self bounds]];",
                 "#ifdef USE_METAL"].join("\n")

      mtl_frame = "        self.metalLayer.frame = CGRectMake"
      inreplace "ui/cocoa.m",
                "#{mtl_frame}(0, 0, size.width / scale, size.height / scale);",
                ["        self.metalLayer.frame = self.bounds;",
                 "        self.metalLayer.magnificationFilter =",
                 "            qatomic_read(&zoom_interpolation) ? kCAFilterLinear : " \
                 "kCAFilterNearest;"].join("\n")

      inreplace "ui/cocoa.m",
                "            cocoaView.glLayer.frame = CGRectMake(0, 0, w / scale, h / scale);",
                "            cocoaView.glLayer.frame = cocoaView.bounds;"
    end

    ENV["LIBTOOL"] = "glibtool"
    ENV["PYTHON"] = formula_opt_bin("python@3.13")/"python3.13"

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
      # No --target-list: build every target this QEMU supports (system emulators
      # for all architectures). Omitting the flag rather than enumerating targets
      # means new upstream targets are picked up automatically.
      system "./configure",
             "--prefix=#{prefix}",
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

    # Wrap EVERY system emulator so the Vulkan loader finds the MoltenVK ICD and
    # ANGLE uses Metal. These are non-DYLD vars, so they survive `sudo` (vmnet);
    # the loader itself is linked, so no DYLD_* is needed. qemu-img and the other
    # non-emulator tools never touch Vulkan/Metal and stay unwrapped.
    #
    # All emulators, not just aarch64: ANGLE_DEFAULT_PLATFORM is needed by ANY
    # target driving virtio-gpu-gl through the virgl GL (vrend) path, not just by
    # venus. ppc matters here specifically -- it runs AmigaOS4, whose virtio-gpu
    # driver uses that GL path -- and an unwrapped emulator fails silently.
    #
    # molten-vk-venus ships its ICD keg-private under share/ (the shared etc path
    # collides with homebrew-core molten-vk), so point VK_ICD_FILENAMES at it via
    # opt_prefix; the ICD's relative library_path resolves to that keg's libMoltenVK.
    mvk = Formula["baxtor/qemu-virgl/molten-vk-venus"]
    gpu_env = {
      VK_ICD_FILENAMES:       "#{mvk.opt_prefix}/share/vulkan/icd.d/MoltenVK_icd.json",
      ANGLE_DEFAULT_PLATFORM: "metal",
      MVK_ALLOW_METAL_EVENTS: "1",
    }
    emulators = Dir["#{bin}/qemu-system-*"].map { |f| File.basename(f) }
    odie "no qemu-system-* binaries found to wrap" if emulators.empty?
    emulators.each do |emu|
      libexec.install bin/emu
      (bin/emu).write_env_script libexec/emu, gpu_env
    end
  end

  def caveats
    <<~EOS
      qemu-system-aarch64 is a wrapper that sets VK_ICD_FILENAMES (MoltenVK) and
      ANGLE/Metal env so venus works without DYLD_* (which SIP strips under sudo).

      venus REQUIRES -accel hvf,ipa-granule-size=4096. The guest allocates venus
      blobs in 4K multiples, but HVF defaults to the 16K host page size and refuses
      to map a region whose size is not a granule multiple; the unmapped region then
      faults and aborts QEMU (assert(isv) in target/arm/hvf/hvf.c) the moment a guest
      uses Vulkan. The granule cannot be set via -machine accel=hvf.

      Shared (vmnet) networking needs root, and `sudo` resets PATH, so invoke the
      absolute path:
        sudo "$(brew --prefix)/bin/qemu-system-aarch64" \\
          -machine virt -accel hvf,ipa-granule-size=4096 -cpu host -m 8G \\
          -device virtio-gpu-gl-pci,venus=true,hostmem=8G,blob=true \\
          -display cocoa,gl=es [other options]
    EOS
  end

  test do
    # Built with no --target-list, so the full set of system emulators must be
    # present -- not just the three the tap used to build.
    emulators = Dir["#{bin}/qemu-system-*"].map { |f| File.basename(f) }
    assert_operator emulators.count, :>=, 20,
                    "expected all QEMU targets, got #{emulators.count}: #{emulators.join(", ")}"

    assert_match "QEMU", shell_output("#{bin}/qemu-img --version")
    emulators.each do |emu|
      assert_match "QEMU", shell_output("#{bin}/#{emu} --version")
    end

    # aarch64 is the wrapped, venus-enabled binary; spot-check accelerators.
    system "#{bin}/qemu-system-aarch64", "-accel", "help"
    system "#{bin}/qemu-system-x86_64", "-accel", "help"
    system "#{bin}/qemu-system-ppc", "-accel", "help"
  end
end
