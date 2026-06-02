class Libangle < Formula
  desc "ANGLE (OpenGL ES over Metal) from utmapp/WebKit, for qemu-virgl venus"
  homepage "https://github.com/utmapp/WebKit"
  # Dummy url: the real source is a sparse, blobless checkout of WebKit done in
  # `install` (the full WebKit repo is far too large for a normal git url/bottle
  # fetch). The pinned WEBKIT_SHA below is the real, reproducible input.
  url "https://github.com/s3rj1k/homebrew-qemu-virgl/archive/refs/heads/master.tar.gz"
  version "2026.06.01"
  license "BSD-3-Clause"

  # Dummy url has no stable checksum (master tarball changes per commit).
  def self.sha256(_)
    nil
  end

  keg_only "venus-private ANGLE EGL/GLESv2 would shadow system GL"

  depends_on "ccache" => :build
  depends_on xcode: ["12.0", :build]
  depends_on arch: :arm64

  def install
    webkit_sha = "ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10"

    # Sparse, blobless WebKit checkout — only ANGLE (+ build config) — mirroring
    # the build-qemu-vulkan-macos.yaml workflow. Avoids a multi-GB full clone.
    system "git", "clone", "--filter=tree:0", "--no-checkout",
           "https://github.com/utmapp/WebKit.git", "webkit"
    system "git", "-C", "webkit", "sparse-checkout", "init"
    system "git", "-C", "webkit", "sparse-checkout", "set",
           "Source/ThirdParty/ANGLE", "Configurations", "Tools/ccache"
    system "git", "-C", "webkit", "-c", "advice.detachedHead=false",
           "checkout", webkit_sha

    angle = buildpath/"webkit/Source/ThirdParty/ANGLE"
    cd angle do
      # ANGLE's libEGL loads its GLESv2 backend via OpenSystemLibraryAndGetError("GLESv2"),
      # but its macOS branch builds "GLESv2.framework/Versions/Current/GLESv2" and searches
      # SystemDir — and we build ANGLE as plain dylibs, so that dlopen fails ("Error loading
      # EGL entry points") and qemu segfaults under `-display cocoa,gl=es`. Make it load
      # lib<name>.dylib via the caller's searchType (ModuleDir => next to libEGL) instead.
      # Two short inreplaces (each raises if unmatched; Homebrew forbids rubocop:disable, and
      # the full source lines exceed the line-length limit).
      inreplace "src/common/system_utils.cpp",
                'std::string(libraryName) + ".framework/Versions/Current/" + std::string(libraryName)',
                '"lib" + std::string(libraryName) + ".dylib"'
      inreplace "src/common/system_utils.cpp",
                "SearchType::SystemDir, errorOut);",
                "searchType, errorOut);"

      # Flags copied verbatim from the workflow "Build ANGLE" step.
      xcodebuild "archive",
                 "-archivePath", buildpath/"ANGLE",
                 "-scheme", "ANGLE",
                 "-sdk", "macosx",
                 "-arch", "arm64",
                 "-configuration", "Release",
                 "WEBCORE_LIBRARY_DIR=/usr/local/lib",
                 "NORMAL_UMBRELLA_FRAMEWORKS_DIR=",
                 "CODE_SIGNING_ALLOWED=NO",
                 "MACOSX_DEPLOYMENT_TARGET=11.0",
                 "GCC_TREAT_WARNINGS_AS_ERRORS=NO"
    end

    products = buildpath/"ANGLE.xcarchive/Products/usr/local/lib"
    lib.install Dir["#{products}/*.dylib"]
    include.install Dir["#{angle}/include/*"]

    # Archived dylibs carry id "/WebCore.framework/Frameworks/lib*.dylib"
    # (EGL-dynamic.xcconfig DYLIB_INSTALL_NAME_BASE with an empty umbrella dir).
    # Strip those bogus paths: rewrite the ANGLE->ANGLE interdeps off
    # /WebCore.framework via ruby-macho, then re-sign (editing the Mach-O voids
    # the mandatory arm64 ad-hoc signature). The @rpath dylib id is intent only —
    # Homebrew relocates dylib ids to the opt path on install. That's fine:
    # libepoxy's dlopen("@rpath/libEGL.dylib") resolves via libepoxy's OWN
    # LC_RPATH (baked in libepoxy-angle.rb), not via ANGLE's id; an opt-path id
    # also dedupes the dlopen'd vs linked instance of each ANGLE dylib.
    dylibs = Dir["#{lib}/*.dylib"].map { |f| File.basename(f) }
    dylibs.each do |name|
      f = lib/name
      MachO::Tools.change_dylib_id(f.to_s, "@rpath/#{name}")
      # change_install_name raises if the old name isn't linked, so only rewrite
      # the WebCore.framework interdeps this dylib actually references.
      linked = MachO.open(f.to_s).linked_dylibs
      dylibs.each do |dep|
        old = "/WebCore.framework/Frameworks/#{dep}"
        MachO::Tools.change_install_name(f.to_s, old, "@rpath/#{dep}") if linked.include?(old)
      end
      system "codesign", "--sign", "-", "--force", f
    end
  end

  test do
    assert_path_exists lib/"libEGL.dylib"
    # Homebrew relocates the dylib id to this keg's opt path (overriding the
    # `-id @rpath/...` from install), so assert the real post-install state: no
    # bogus /WebCore.framework path survives, and the id resolves into the keg.
    refute_match %r{/WebCore\.framework/}, shell_output("otool -L #{lib}/libEGL.dylib")
    assert_match opt_lib.to_s, shell_output("otool -D #{lib}/libEGL.dylib")
  end
end
