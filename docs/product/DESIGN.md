# Design

Agent-facing UI direction for coherent BeepBeep screens.

## Thesis

BeepBeep should feel simple, reliable, integrated, and calm: closer to Apple setup flows and native utility apps than marketing UI.

## Apple-Native Baseline

Use Apple's Human Interface Guidelines as the baseline for interaction, layout, typography, motion, and accessibility.

- adopt platform conventions before custom patterns
- use native SwiftUI controls before custom controls
- use system typography, semantic colors, SF Symbols, Dynamic Type, and accessibility from the start
- use native navigation: tab bars, navigation stacks, sheets, sidebars, split views, standard gestures
- use platform materials only when they clarify hierarchy
- do not fake Apple UI with custom blur stacks, opacity overlays, neon glass, reflections, or decorative materials

The app should feel integrated with the phone: light, tactile, responsive, and unobtrusive.

## Liquid Glass And Floating Controls

Treat Liquid Glass as a native material and interaction direction, not a visual effect to imitate.

Use translucency only for surfaces that naturally float above content: navigation bars, contextual overlays, compact controls, sheets, and modal layers. Avoid glass for dense text, settings groups, long reading surfaces, full-page backgrounds, and decorative cards. Readability wins over translucency.

Floating controls should share one family:

- native SwiftUI `Material`, usually `.regularMaterial`; `.thinMaterial` only with enough contrast
- native Liquid Glass APIs such as `glassEffect` only for truly floating custom controls
- continuous circles or capsules
- neutral material edges and subtle depth
- accent color only when it communicates action
- at least 44 pt tap target on iOS

Primary conversation actions (`Ask to Talk`, `Ask Again`, `Accept`) should remain solid and unmistakable. Prefer `.buttonStyle(.borderedProminent)`, `.controlSize(.large)`, and `.buttonBorderShape(.capsule)` for enabled primary actions; use quieter native bordered styles for disabled, cooldown, or muted states. Do not custom-paint fills, outlines, blur stacks, or shadows unless native style fails a concrete product need.

Do not apply glass to every row or content group. Contact rows, settings, and text-heavy surfaces should use spacing, dividers, semantic backgrounds, or standard materials.

## Product Tone

- brand first, quietly
- utility over ornament
- one obvious action per screen
- sparse copy
- stable layouts
- no clever visuals competing with the task

## Visual Rules

- prefer integrated layouts over floating cards
- use whitespace and alignment before chrome
- keep content in a narrow readable column
- keep primary actions narrower than full screen when possible
- use muted secondary text and one prominent button style
- prefer dividers and section rhythm over boxed panels
- keep iconography simple and functional

Visual economy: remove what does not help the user act. Use spacing, alignment, type scale, weight, color, opacity, and motion before boxes, borders, badges, dividers, icons, or containers. Add visible structure only when it clarifies behavior, grouping, or state.

## Affordances

Only signify real actions. If something looks tappable, expandable, draggable, dismissible, or navigable, it should be. Status and metadata should not carry interactive signifiers.

Match signifier strength to importance. Primary actions can use strong shape, color, and size. Secondary actions keep accessible hit targets with quieter treatment. Borrow platform interaction patterns, not skins.

## User Goal And Hierarchy

Lead with the object of attention: person, place, object, document, task, or decision. Avoid restating feature/mode when context already shows it.

Use hierarchy to make the primary thing obvious, secondary things calm, and unrelated controls hidden or softened. Let empty space group and pace the interface before adding separators. Preserve physical affordance even when visual weight is low.

Prefer depth over decoration: spacing, elevation, material, scale, focus, and continuity before gradients, outlines, shadows, or saturated backgrounds.

## Progressive Disclosure

Show the minimum useful truth. Escalate detail only when it changes user action. Internal phases, retries, transports, and implementation states belong in diagnostics, logs, settings, or developer surfaces unless they materially affect what the user should do next.

Product UI needs understandable continuity, not maximal state fidelity. Smooth or absorb harmless short-lived states unless showing them prevents confusion or confirms meaningful progress.

Use motion to explain continuity, not decorate. Respect reduced-motion settings.

## Native Interaction Patterns

Prefer:

- standard navigation stacks and large-title rhythm on iPhone
- bottom tab bars for durable top-level modes
- bottom sheets for focused temporary decisions
- sidebars, split views, and resizable panels on iPad/macOS
- segmented controls, toggles, pickers, menus, lists, and swipe actions where expected
- SF Symbols for familiar actions, with accessibility labels

Avoid reinventing navigation, basic controls, gestures, scrolling, or selection without a specific defensible need.

## Density

Prefer fewer simultaneous actions, progressive disclosure, contextual controls, readable type, clear alignment, and generous rhythm. Avoid dense dashboards, always-visible toolbars, compressed labels, and text-heavy control clusters in primary UI.

## Shared Layout Tokens

Current values in `Turbo/TurboDesign.swift`:

- horizontal padding: `24`
- content max width: `360`
- primary button max width: `320`
- field corner radius: `18`

Reuse these before adding new constants. New shared values should be semantic and support native rhythm/accessibility, not custom visual skinning.

## SwiftUI Guidance

Use:

- native materials for layered surfaces
- semantic colors
- system typography and Dynamic Type
- native controls and navigation APIs
- accessibility labels, traits, and hit targets
- native transitions that preserve continuity

Avoid:

- custom fake-glass modifiers
- hardcoded blur/opacity systems
- custom controls duplicating platform controls
- fixed-size text that breaks Dynamic Type
- decorative backgrounds competing with content

## Screen Guidance

Entry screens:

- wordmark is visual anchor
- primary button near bottom safe area
- intentional negative space
- no extra labels/helper text/stacked controls unless needed

Setup screens:

- reuse splash width and spacing rhythm
- left-align copy column
- keep action area compact and obvious
- inputs feel native and quiet

Main product screens:

- favor layout over card collections
- empty states calm, not promotional
- section headers explain available action, not feature value

Contact rows:

- content, not floating controls
- use spacing, alignment, and text hierarchy before borders/chrome
- align content with section label edge
- use avatar/initials on left, display name first, handle/subtitle second
- show availability as quiet dot and label, not loud badge
- use chevron only when tapping opens focused contact surface
- do not show durable selected state in list rows

Focused contact surface:

- lead with person and one clear action
- show identity once: avatar, display name, quiet metadata row
- keep system-owned session state secondary
- present PTT escape hatch as quiet status plus compact `End`, not large card
- keep transport path labels small and subdued

Sheets:

- narrow column with section dividers
- no default card stacks
- destructive actions separated from routine actions

Copy:

- direct labels: `Add Friend`, `Continue`, `Scan`, `Share`
- avoid marketing or emotional copy
- supporting text explains behavior in one sentence

## Avoid

- full-screen card mosaics
- decorative gradients or glass effects
- multiple accent colors
- over-explaining helper text
- dense toolbars
- loud empty states
- unjustified edge-to-edge controls
- text on noisy translucent surfaces
- full-page blur
- custom navigation/gesture systems without strong reason

## AI UX Workflow

When using the `ux-design` skill or asking an AI agent to design, review, or change UI:

1. Start with the user's goal and object of attention.
2. Choose the native Apple interaction pattern.
3. Remove chrome before adding structure.
4. Use native SwiftUI controls, materials, typography, colors, and motion.
5. Keep implementation states and transport details out of primary UI unless they change action.
6. Check that visual affordances are real.
7. Prefer the calmer, simpler, more platform-native version.

Decision rule: if a screen looks more designed but less calm, clear, or native, simplify it.
