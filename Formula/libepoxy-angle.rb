class LibepoxyAngle < Formula
  desc "Libepoxy GL dispatch built for ANGLE/EGL (qemu-virgl venus)"
  homepage "https://github.com/utmapp/libepoxy"
  # Dummy url: the pinned commit lives on a force-pushed branch and is NOT
  # reachable from the branch tip, so Homebrew's git strategy can't fetch it.
  # The exact revision is fetched by SHA in `install` (GitHub allows fetching a
  # reachable SHA directly).
  url "https://github.com/baxtor/homebrew-qemu-virgl/archive/refs/heads/master.tar.gz"
  version "2026.08.26"
  license "MIT"

  def self.sha256(_)
    nil
  end

  keg_only "venus-private libepoxy variant linked against ANGLE"

  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "pkg-config" => :build
  depends_on arch: :arm64
  depends_on "baxtor/qemu-virgl/libangle"

  def install
    sha = "bf98587477fe68d07b93319ece7b40a7d0e2eabe"
    system "git", "init", "-q", "repo"
    system "git", "-C", "repo", "fetch", "--depth", "1",
           "https://github.com/utmapp/libepoxy.git", sha
    system "git", "-C", "repo", "checkout", "-q", "FETCH_HEAD"

    angle = Formula["baxtor/qemu-virgl/libangle"]
    cd "repo" do
      # Load ANGLE EGL/GLES via @rpath instead of the macOS framework path, so it
      # works under sudo (SIP strips DYLD_FRAMEWORK_PATH). @rpath resolves against
      # this dylib's own LC_RPATH, baked to the libangle keg below.
      # Non-block inreplace RAISES if the pattern isn't found, so a silently-unpatched
      # libepoxy can never ship (the block form's gsub! no-ops silently on a miss).
      inreplace "src/dispatch_common.c",
                '#define EGL_LIB "EGL.framework/Versions/Current/EGL"',
                '#define EGL_LIB "@rpath/libEGL.dylib"'
      inreplace "src/dispatch_common.c",
                '#define GLES1_LIB "GLESv1_CM.framework/Versions/Current/GLESv1_CM"',
                '#define GLES1_LIB "@rpath/libGLESv1_CM.dylib"'
      inreplace "src/dispatch_common.c",
                '#define GLES2_LIB "GLESv2.framework/Versions/Current/GLESv2"',
                '#define GLES2_LIB "@rpath/libGLESv2.dylib"'

      system "meson", "setup", "build", *std_meson_args,
             "-Degl=yes", "-Dx11=false", "-Dtests=false",
             "-Dc_args=-I#{angle.opt_include}",
             "-Dc_link_args=-L#{angle.opt_lib}"
      system "meson", "compile", "-C", "build"
      system "meson", "install", "-C", "build"
    end

    # Bake an LC_RPATH to libangle's keg so the @rpath dlopens resolve; re-sign
    # (editing the Mach-O voids the arm64 signature).
    dylib = lib/"libepoxy.0.dylib"
    rpath = angle.opt_lib.to_s
    MachO::Tools.add_rpath(dylib.to_s, rpath) unless MachO.open(dylib.to_s).rpaths.include?(rpath)
    system "codesign", "--sign", "-", "--force", dylib
  end

  test do
    assert_match Formula["baxtor/qemu-virgl/libangle"].opt_lib.to_s,
                 shell_output("otool -l #{lib}/libepoxy.0.dylib")
  end
end
