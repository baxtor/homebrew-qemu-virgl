class Virglrenderer < Formula
  desc "Venus (Vulkan-on-Metal) backend for the VirGL renderer in qemu-virgl"
  homepage "https://github.com/utmapp/virglrenderer"
  # Dummy url: the pinned commit lives on a force-pushed branch; the exact
  # revision is fetched by SHA in `install`.
  url "https://github.com/baxtor/homebrew-qemu-virgl/archive/refs/heads/master.tar.gz"
  version "2026.06.01"
  license "MIT"

  def self.sha256(_)
    nil
  end

  keg_only "venus-enabled build conflicts with homebrew-core virglrenderer"

  depends_on "libyaml" => :build # pyyaml resource builds its C ext against libyaml
  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "pkg-config" => :build
  depends_on "python@3.13" => :build
  depends_on arch: :arm64
  depends_on "baxtor/qemu-virgl/libangle"
  depends_on "baxtor/qemu-virgl/libepoxy-angle"
  depends_on "vulkan-headers"
  depends_on "vulkan-loader"

  resource "pyyaml" do
    url "https://files.pythonhosted.org/packages/54/ed/79a089b6be93607fa5cdaedf301d7dfb23af5f25c398d5ead2525b063e17/pyyaml-6.0.2.tar.gz"
    sha256 "d584d9ec91ad65861cc08d42e834324ef890a082e591037abe114850ff7bbc3e"
  end

  def install
    python3 = Formula["python@3.13"].opt_bin/"python3.13"
    venv = buildpath/"venv"
    system python3, "-m", "venv", venv
    resource("pyyaml").stage { system venv/"bin/python", "-m", "pip", "install", "." }
    ENV["PYTHON"] = venv/"bin/python"
    ENV.prepend_path "PYTHONPATH", venv/"lib/python3.13/site-packages"

    sha = "d48a2d0d9a722fffd3f92c83e71d9426a4892a66"
    system "git", "init", "-q", "repo"
    system "git", "-C", "repo", "fetch", "--depth", "1",
           "https://github.com/utmapp/virglrenderer.git", sha
    system "git", "-C", "repo", "checkout", "-q", "FETCH_HEAD"

    angle = Formula["baxtor/qemu-virgl/libangle"]
    epoxy = Formula["baxtor/qemu-virgl/libepoxy-angle"]
    cd "repo" do
      # -Dvulkan-dload=false LINKS the Khronos loader (dependency('vulkan') from the
      # vulkan-loader keg); dyld resolves libvulkan at load via Homebrew's relocatable
      # install name, so NO venus dlopen patch is needed here (unlike the standalone
      # bundle, where the loader is dlopen'd and DYLD_* is stripped under sudo).
      # venus runs through the render-server proxy. The default 'process' worker fork-execs
      # a separate virgl_render_server binary at the baked RENDER_SERVER_EXEC_PATH, which
      # doesn't survive Homebrew relocation (and fork-exec is fragile on macOS) -> proxy
      # init fails ("failed to initialize venus renderer") before any Vulkan/MoltenVK call.
      # 'thread' runs the render server in-process (no fork/exec/separate binary).
      system "meson", "setup", "build", *std_meson_args,
             "-Dvenus=true",
             "-Drender-server-worker=thread",
             "-Dcheck-gl-errors=false",
             "-Dc_std=gnu2x",
             "-Dvulkan-dload=false",
             "-Dc_args=-I#{angle.opt_include}",
             "--pkg-config-path=#{epoxy.opt_lib}/pkgconfig"
      system "meson", "compile", "-C", "build"
      system "meson", "install", "-C", "build"
    end
  end

  test do
    # venus must be linked against the Vulkan loader (not dlopen'd) on this tap.
    assert_match "libvulkan", shell_output("otool -L #{lib}/libvirglrenderer.1.dylib")
  end
end
