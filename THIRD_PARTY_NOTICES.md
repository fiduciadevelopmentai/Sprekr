# Third-party notices

Sprekr will preserve all required source, binary, model, and font notices in distributed artifacts. This list is maintained as dependencies are added.

| Component | Use | License / attribution |
| --- | --- | --- |
| FluidAudio `v0.15.5` | Local Core ML audio runtime | Apache-2.0; source: https://github.com/FluidInference/FluidAudio |
| NVIDIA Parakeet TDT 0.6B v3 | Upstream multilingual ASR model | CC-BY-4.0. Attribute NVIDIA and link to https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3. |
| FluidInference Parakeet TDT v3 Core ML conversion | Apple Core ML model artifacts | Model repository metadata declares `license: cc-by-4.0`; preserve upstream attribution and model card. https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml |
| Onest `1.000` | Body, controls, navigation, labels, and compact status text | SIL Open Font License 1.1; copyright Simpals. The unmodified Regular, Medium, and Bold OpenType files come from the official `1.000` release. Exact license copy: `Resources/Licenses/Onest-OFL.txt`; source: https://github.com/simpals/onest/tree/1.000. |
| Crimson Text | Editorial headings and primary metrics | SIL Open Font License 1.1. The unmodified Regular TrueType file is bundled from the official Google Fonts repository. Exact license copy: `Resources/Licenses/CrimsonText-OFL.txt`; source: https://github.com/google/fonts/tree/main/ofl/crimsontext. |
| Lucide Static `1.24.0` | Eight locally subsetted navigation/status glyphs | ISC; source: https://github.com/lucide-icons/lucide. The app bundles only the required glyphs in `Resources/Fonts/Lucide.ttf`; exact license copy at `Resources/Licenses/Lucide-ISC.txt`. |
| BE UI Loader pattern | Motion reference adapted to the native SwiftUI `Canvas` implementation for the Flow Bar dot-matrix loader | MIT; copyright © 2026 Saurabh Chauhan; source: https://github.com/starc007/ui-components/blob/main/components/motion/loader.tsx. Exact license copy at `Resources/Licenses/BEUI-LICENSE.txt`. |

No NVIDIA API or hosted inference service is used. Model use is local after download.
