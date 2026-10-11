# FILLR application icon

`fillr.icon` is the editable Apple Icon Composer project. `needle-affinity-finished.af` is the official needle and black circular pivot source; export it as `needle-affinity-finished.svg` in Affinity after editing it. `build_fillr_layers.py` generates the transparent gauge layers, including the FILLR label, and calls `build_needle_assets.py` to preserve the official needle/pivot relationship through one uniform scale and rotation. The original overall design reference is `../DMC FILLR ICON.png`.

The icon's facet shades and gray outline around the solid black pivot are defined in `build_needle_assets.py`; these change the presentation without changing the approved Affinity geometry. The gray outline is outside the original circle. The housing, face, and bezel use concentric rounded corners. Icon Composer positions align the bottoms of FILLR and 4/4 and move the pump with the title.

The gauge contents are uniformly enlarged by approximately 7% and centered to leave about 71 px of clearance on all four sides of the inner dial at 1024 px. The shared layout transform is stored in the content layers' Icon Composer positions. `icon_artwork.py` applies that same transform to the packaged animation axle and probe point, preserving the exact needle/pivot relationship.

The checked-in platform assets are:

- `FILLR-Default-1024.png`: Icon Composer's Default appearance export, retained as the source for the macOS `.icns` compatibility asset.
- `FILLR.icns`: macOS 13+ application bundle icon, produced by `build_fillr_icns.py` from the Icon Composer export.
- `FILLR.ico`: Windows executable and window icon, produced by `build_platform_icons.py` from the Icon Composer layers.
- `linux/hicolor/*/apps/com.tlolabs.fillr.png`: Linux AppImage and icon theme sizes, produced by `build_platform_icons.py` from the Icon Composer layers. The filename matches FILLR's Linux desktop identity.
- `DockIcon/`: generated animation layers and axle geometry, also produced by `build_platform_icons.py`. Keeping these ready to package avoids adding image-generation dependencies to an ordinary app build.

After editing the Affinity source, export its SVG and run `python3 assets/icons/build_needle_assets.py`. After changing any icon artwork, regenerate the Default 1024 px export in Icon Composer, then run `python3 assets/icons/build_fillr_icns.py` and `python3 assets/icons/build_platform_icons.py`. The artwork generator scripts require Pillow; the macOS `.icns` generator also requires `iconutil`.

While the native macOS app is running, `DockIconController` composites the ten
raster layers and rotates the official needle from empty to full using the collected
footage divided by the configured total. Both macOS build scripts package those
layers through `script/package_macos_icons.sh`. `icon_artwork.py` respects visible vector facets and layer positions from Icon Composer, while `needle-layout.json` supplies the same black-circle center to the animation. Finder keeps the static `.icns`.
On every launch the needle sweeps empty → full → empty, then moves to the latest
footage progress. The opening sweep runs once per app process, including when a
saved download folder is restored; additional windows do not restart it.
Use **File → Preview Icon Animation** to replay the sweep. The preview does not
change footage or settings.
Reduce Motion shows the endpoints without interpolating between them.

To launch the sweep without restoring the saved download folder:

```sh
./script/build_and_run.sh --preview-icon
```

The packaged artwork, opening sweep, live animation timer, and restoration of progress received
during a preview can be checked with:

```sh
xcrun swiftc -parse-as-library native/macos/Sources/FILLR/Services/DockIconController.swift native/macos/Tests/DockIconChecks.swift -o dist/dock-icon-checks
mkdir -p dist/dock-icon-preview
dist/dock-icon-checks dist/FILLR.app/Contents/Resources dist/dock-icon-preview
```
