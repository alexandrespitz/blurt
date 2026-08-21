# Third-party notices

Blurt (MIT) stands on the following work.

## FluidAudio

<https://github.com/FluidInference/FluidAudio> — Apache License 2.0, pinned
at v0.15.5. The Swift SDK that runs the speech model on Core ML and the Apple
Neural Engine, and the only component in the app that touches the network
(the one-time model download). The full licence text ships with the package
checkout.

## parakeet-tdt-0.6b-v3 (the speech model)

Created by NVIDIA, published at
<https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3> under CC-BY-4.0 per its
model card: a 600M-parameter FastConformer-TDT model covering 25 European
languages with automatic language identification. Blurt is named in its
honour — the app was called Parakeet until the model needed its name back.

**The model is not bundled with Blurt.** The app downloads the Core ML
conversion published at
<https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml> directly
to the user's machine on first run. That conversion repository's licence
metadata and README are not fully consistent with each other; distribution
of the *weights* is between the user, Hugging Face, and those repositories —
Blurt redistributes no model files. Anyone forking Blurt into a product that
bundles weights should resolve licensing with those authors first.

## Apple frameworks

AVFoundation, Core ML, AppKit, SwiftUI, ApplicationServices,
ServiceManagement and FoundationModels are used under the Apple SDK licence
that ships with Xcode.
