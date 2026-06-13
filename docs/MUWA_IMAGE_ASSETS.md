# Muwa Image Asset Inventory

This inventory lists the product image resources used by Muwa. The app icon,
product logo, agent avatars, creation art, and feature illustrations have been
replaced with frog visuals. Compatibility-sensitive asset names are intentionally
kept as `muwa-*` where Swift code loads them dynamically.

## App Shell

| Area | Resource |
| --- | --- |
| App icon | `App/Muwa/Assets.xcassets/AppIcon.appiconset/icon_16.png` |
| App icon | `App/Muwa/Assets.xcassets/AppIcon.appiconset/icon_32.png` |
| App icon | `App/Muwa/Assets.xcassets/AppIcon.appiconset/icon_32@2x.png` |
| App icon | `App/Muwa/Assets.xcassets/AppIcon.appiconset/icon_64.png` |
| App icon | `App/Muwa/Assets.xcassets/AppIcon.appiconset/icon_128.png` |
| App icon | `App/Muwa/Assets.xcassets/AppIcon.appiconset/icon_256.png` |
| App icon | `App/Muwa/Assets.xcassets/AppIcon.appiconset/icon_256@2x.png` |
| App icon | `App/Muwa/Assets.xcassets/AppIcon.appiconset/icon_512.png` |
| App icon | `App/Muwa/Assets.xcassets/AppIcon.appiconset/icon_512@2x.png` |
| App icon | `App/Muwa/Assets.xcassets/AppIcon.appiconset/icon_1024.png` |
| Icon source | `App/Muwa/muwa-app-icon.icon/Assets/Muwa Frog Icon.png` |
| DMG background | `assets/dmg-bg.tiff` |

## Product Logo

| Area | Resource |
| --- | --- |
| App glyph | `App/Muwa/Assets.xcassets/osaurus.imageset/muwa-squircle.svg` |
| App logo | `App/Muwa/Assets.xcassets/muwa-logo.imageset/muwa-logo-black.svg` |
| App wordmark | `App/Muwa/Assets.xcassets/muwa-logo-wordmark.imageset/muwa-logo-wordmark.svg` |
| Core logo | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-logo.imageset/muwa-logo-black.svg` |
| Core wordmark | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-logo-wordmark.imageset/muwa-logo-wordmark.svg` |

## Agent Avatars

These frog avatars are loaded dynamically by `AgentAvatarView`,
`NativeMessageCellView`, and shared avatar components using the
`muwa-avatar-{color}` naming pattern.

| Color | Resources |
| --- | --- |
| Blue | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-avatar-blue.imageset/muwa-avatar-blue@1x.png`, `@2x.png`, `@3x.png` |
| Green | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-avatar-green.imageset/muwa-avatar-green@1x.png`, `@2x.png`, `@3x.png` |
| Orange | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-avatar-orange.imageset/muwa-avatar-orange@1x.png`, `@2x.png`, `@3x.png` |
| Purple | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-avatar-purple.imageset/muwa-avatar-purple@1x.png`, `@2x.png`, `@3x.png` |
| Red | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-avatar-red.imageset/muwa-avatar-red@1x.png`, `@2x.png`, `@3x.png` |
| Yellow | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-avatar-yellow.imageset/muwa-avatar-yellow@1x.png`, `@2x.png`, `@3x.png` |

## Agent Creation Art

These frog creation illustrations are loaded dynamically by `AgentAvatarView`
using the `muwa-{color}-create` naming pattern. The yellow asset folder
currently has a typo and is named `muwa-yellow-create.imageset`.

| Color | Resources |
| --- | --- |
| Blue | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-blue-create.imageset/muwa-blue-create@1x.png`, `@2x.png`, `@3x.png` |
| Green | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-green-create.imageset/muwa-green-create@1x.png`, `@2x.png`, `@3x.png` |
| Orange | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-orange-create.imageset/muwa-orange-create@1x.png`, `@2x.png`, `@3x.png` |
| Purple | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-purple-create.imageset/muwa-purple-create@1x.png`, `@2x.png`, `@3x.png` |
| Red | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-red-create.imageset/muwa-red-create@1x.png`, `@2x.png`, `@3x.png` |
| Yellow | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-yellow-create.imageset/muwa-yellow-create@1x.png`, `@2x.png`, `@3x.png` |

## Feature Illustrations

| Area | Resources |
| --- | --- |
| Main | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-main.imageset/muwa-main@1x.png`, `@2x.png`, `@3x.png` |
| Identity | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-identity.imageset/muwa-identity@1x.png`, `@2x.png`, `@3x.png` |
| Built | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-built.imageset/muwa-built@1x.png`, `@2x.png`, `@3x.png` |
| Brain | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-brain.imageset/muwa-brain@1x.png`, `@2x.png`, `@3x.png` |
| Data | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-data.imageset/muwa-data@1x.png`, `@2x.png`, `@3x.png` |
| Tool | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-tool.imageset/muwa-tool@1x.png`, `@2x.png`, `@3x.png` |
| Sandbox | `Packages/MuwaCore/Resources/Assets.xcassets/muwa-sandbox.imageset/muwa-sandbox@1x.png`, `@2x.png`, `@3x.png` |

## Generated Illustration Sources

| Area | Resource |
| --- | --- |
| Frog atlas source | `scripts/assets/generated/muwa-frog-atlas-transparent.png` |
| Red create source | `scripts/assets/generated/muwa-red-create-transparent.png` |
| Apply script | `scripts/assets/apply_muwa_generated_frog_atlas.py` |

## Other Product Image Resources

| Area | Resource |
| --- | --- |
| Venice keys illustration | `App/Muwa/Assets.xcassets/venice-keys.imageset/venice-keys.svg` |

## Code References

- `Packages/MuwaCore/AppDelegate.swift` loads the status bar glyph with `NSImage(named: "osaurus")`.
- `Packages/MuwaCore/Views/Agent/AgentAvatarView.swift` maps avatar colors to `muwa-avatar-{color}` and creation art to `muwa-{color}-create`.
- `Packages/MuwaCore/Views/Chat/NativeMessageCellView.swift` loads chat avatars with `muwa-avatar-{color}`.
- `Packages/MuwaCore/Views/Common/SharedHeaderComponents.swift` loads shared avatars with `muwa-avatar-{color}`.
- `Packages/MuwaCore/Views/Theme/ThemeEditorView.swift` falls back to `muwa-avatar-green`.
