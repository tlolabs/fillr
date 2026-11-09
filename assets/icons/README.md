# FILLR application icon

`fillr-clean.icon` is the default **DMC-12** editable Apple Icon Composer project, duplicated from `fillr.icon` with the color-bar status scale removed. `fillr.icon` is **Gradient**, with a continuous red → orange → yellow → green scale. `fillr-macos.icon` is **6 Colors**, with the six-color Apple palette. In the macOS app, **Settings → General → App icon** provides thumbnail selection; **File → App Icon** offers the same choices. The choice is saved between launches. Finder uses the static DMC-12 default. Existing resource filenames and saved identifiers remain stable.

The app's default accent is Apple green (`#61BB46`). Main-window and floating-overlay progress bars use the selected icon's color progression, mapped to fixed positions along the full track.

`needle-affinity-finished.af` is the official needle and black circular pivot source; export it as `needle-affinity-finished.svg` in Affinity after editing it. `build_fillr_layers.py` generates shared transparent gauge artwork in all three projects, including the FILLR label, and calls `build_needle_assets.py` to preserve the official needle/pivot relationship through one uniform scale and rotation. Regeneration preserves each project's layer visibility, layout, and distinct color-scale palette. The original overall design reference is `../DMC FILLR ICON.png`.

The icon's facet shades and gray outline around the solid black pivot are defined in `build_needle_assets.py`; these change the presentation without changing the approved Affinity geometry. The gray outline is outside the original circle. The housing, face, and bezel use concentric rounded corners. Icon Composer positions align the bottoms of FILLR and 4/4 and move the pump with the title.

The gauge contents are uniformly enlarged by approximately 7% and centered to leave about 71 px of clearance on all four sides of the inner dial at 1024 px. The shared layout transform is stored in the content layers' Icon Composer positions. `icon_artwork.py` applies that same transform to the packaged animation axle and probe point, preserving the exact needle/pivot relationship.

The white minor ticks bisect the labeled intervals: 0 → 1/2 uses 42°, 21°, 0°, and 1/2 → 4/4 uses 0°, −23.5°, −47°. Run `python3 assets/icons/build_fillr_layers.py --ticks-only` to regenerate just this shared layer in all Composer projects.

`status-scale-palettes.json` records the printed hexadecimal colors from `Apple 6 Colors.jpg`: green `#61BB46`, yellow `#FDB827`, orange `#F5821F`, red `#E03A3E`, purple `#963D97`, and blue `#009DDC`. Gradient has four equal progress bands, from red at 0 to green at full. 6 Colors has six equal progress bands: blue, purple, and red below half; orange, yellow, and green above half. Both scales form one unbroken arc from radius 421 to 451 around the official axle, with narrow smoothstep blends spanning 0.06 progress at each boundary. They use the same unequal half-sweep mapping as the needle. Run `python3 assets/icons/build_fillr_layers.py --scales-only` to update only the two colored projects' status layers.

The checked-in platform assets are:

- `FILLR-Default-1024.png`: `fillr-clean.icon`'s Default appearance export, retained as the source for the macOS `.icns` compatibility asset.
- `FILLR-Classic-1024.png` and `FILLR-MacOS-1024.png`: Classic and Mac OS Default appearance exports from Icon Composer.
- `FILLR.icns`, `FILLR-Classic.icns`, and `FILLR-MacOS.icns`: macOS 13+ default and alternate icons, produced by `build_fillr_icns.py` from their respective Icon Composer exports.
- `FILLR.ico`: Windows executable and window icon, produced by `build_platform_icons.py` from the Clean Icon Composer layers.
- `linux/hicolor/*/apps/com.tlolabs.fillr.png`: Linux AppImage and icon theme sizes, produced by `build_platform_icons.py` from the Clean Icon Composer layers. The filename matches FILLR's Linux desktop identity.
- `DockIcon/`, `DockIconClassic/`, and `DockIconMacOS/`: generated animation layers and axle geometry for all variants, also produced by `build_platform_icons.py`. The Clean variant retains a transparent status-scale PNG slot. Keeping these ready to package avoids adding image-generation dependencies to an ordinary app build.

After editing the Affinity source, export its SVG and run `python3 assets/icons/build_needle_assets.py`. After changing shared icon artwork, regenerate all three 1024 px Default appearance exports in Icon Composer: Clean as `FILLR-Default-1024.png`, Classic as `FILLR-Classic-1024.png`, and Mac OS as `FILLR-MacOS-1024.png`. Then run `python3 assets/icons/build_fillr_icns.py` and `python3 assets/icons/build_platform_icons.py`. The artwork generator scripts require Pillow; the macOS `.icns` generator also requires `iconutil`. Run `python3 assets/icons/test_icon_artwork.py` to check variant differences, regenerated Dock layers, platform images, and ICNS/export integrity.

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
