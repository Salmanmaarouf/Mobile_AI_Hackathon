# Not in the build

`ImagePresentationComponent.Spatial3DImage.swift.txt` was sitting in `Sources/`
and was wired into the app target's **Resources** build phase, so it was being
copied into the bundle on every build. It has been removed from the Xcode
project and parked here.

It is the Apple-native `ImagePresentationComponent.Spatial3DImage` path, which
runs the conversion on the Neural Engine. That hardware does not exist in the
Simulator, which is why this project uses the custom `DepthMesh` + REST
inpainting pipeline instead. Keep it here as a reference for the on-device
build; do not add it back to the target.
