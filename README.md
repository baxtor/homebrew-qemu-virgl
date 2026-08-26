# qemu-virgl: QEMU for Apple Silicon with GPU acceleration

Homebrew tap building `qemu-system-aarch64` with **venus (Vulkan-on-Metal)** and **OpenGL
(ANGLE/Metal)** guest GPU acceleration, from the utmapp venus stack (ANGLE, libepoxy,
virglrenderer, MoltenVK). **Apple Silicon (arm64) only.**

## Install

Needs **full Xcode** and **Homebrew**. ANGLE and MoltenVK build via `xcodebuild` (not just
Command Line Tools), so run `sudo xcodebuild -license accept`.

```sh
brew tap s3rj1k/qemu-virgl
brew install s3rj1k/qemu-virgl/qemu-virgl
```

Builds the `keg_only` venus stack (`libangle`, `libepoxy-angle`, `virglrenderer`,
`molten-vk-venus`). `qemu-system-aarch64` is wrapped to find the MoltenVK ICD and select Metal.

## Run

`vmnet` networking needs root, and `sudo` resets `PATH`, so launch via the **absolute path**.
The acceleration flags are `-device virtio-gpu-gl-pci,venus=true,…` and `-display cocoa,gl=es`.

`-accel hvf,ipa-granule-size=4096` is **required** for venus. The guest allocates venus
blob resources in 4 KiB multiples (e.g. `0x21000`), but HVF defaults to the 16 KiB host
page size and refuses to map a region whose size is not a multiple of the granule
(`accel/hvf/hvf-all.c`). The unmapped region then faults and trips `assert(isv)` in
`target/arm/hvf/hvf.c`, aborting QEMU as soon as a guest actually uses Vulkan. A 4 KiB
IPA granule (macOS 26 `hv_vm_config_set_ipa_granule`) makes those mappings legal.
Note this must be `-accel hvf,…`; the granule cannot be set via `-machine accel=hvf`.

```sh
# One-time setup: a disk, a writable copy of the UEFI vars, and an arm64 Linux ISO.
qemu-img create -f qcow2 disk.qcow2 64G
cp "$(brew --prefix)/share/qemu/edk2-aarch64-code.fd" .
cp "$(brew --prefix)/share/qemu/edk2-arm-vars.fd" .
curl -LO https://cdimage.ubuntu.com/releases/25.10/release/ubuntu-25.10-desktop-arm64.iso

# Boot (drop -cdrom/-boot d once installed):
sudo "$(brew --prefix)/bin/qemu-system-aarch64" \
  -machine virt -accel hvf,ipa-granule-size=4096 -cpu host -smp 4 -m 8G \
  -device virtio-gpu-gl-pci,venus=true,hostmem=8G,blob=true \
  -display cocoa,gl=es \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -device virtio-net-pci,netdev=net -netdev vmnet-shared,id=net \
  -drive if=pflash,format=raw,file=./edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,file=./edk2-arm-vars.fd \
  -drive if=virtio,format=qcow2,file=./disk.qcow2 \
  -chardev qemu-vdagent,id=spice,name=vdagent,clipboard=on \
  -device virtio-serial-pci \
  -device virtserialport,chardev=spice,name=com.redhat.spice.0 \
  -cdrom ubuntu-25.10-desktop-arm64.iso -boot d
```

Release the mouse with **Ctrl-Alt-G**. Clipboard works once the guest runs `spice-vdagent`.

## Verify

Inside a booted Linux guest (needs a venus-capable Mesa, such as the patched Mesa from the
upstream venus notes on Ubuntu 25.10):

```sh
glxinfo | grep -E "OpenGL renderer|direct rendering"   # → virgl (ANGLE … Metal), direct rendering: Yes
vulkaninfo --summary                                   # → a venus / virtio-gpu Vulkan device
vkcube
```

## Troubleshooting

- **`vmnet` networking fails**: needs root. Run under `sudo` with the absolute binary path,
  and use `vmnet-shared` (the supported macOS backend), not `-netdev user`.
- **GPU not accelerated**: use `virtio-gpu-gl-pci` (not `virtio-gpu-pci`) and `-display cocoa,gl=es`.
- **"Addressing limited to 32 bits"**: remove `highmem=off` or lower `-m`.
