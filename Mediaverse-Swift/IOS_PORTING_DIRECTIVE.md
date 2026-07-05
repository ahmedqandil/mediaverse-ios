# iOS Porting Directive

For every feature in this iOS app:

- Use `/Users/ahmedqandil/Dropbox/Mac (2)/Claude/Projects/Mediaverse/docs` as the requirements source of truth.
- Use `/Users/ahmedqandil/Dropbox/Mac (2)/mediaverse` as the web implementation source of truth.
- Pause first and map the source-of-truth logic from the web repo and backend.
- Build to exactly match the backend contracts and mobile web behavior.
- Study required APIs, components, dependencies, navigation, links, analytics, animations, interactions, states, responses, and edge cases before implementation.
- Do not skip any functional or non-functional requirement.
- Do not change the backend unless explicitly requested.
- Preserve the web design language and behavior while using native iOS standards where appropriate.
- If something is missing, trace dependencies and structure the native implementation to support them without breaking existing behavior.
- Implement one feature at a time, with validation after each meaningful step.
- After every UI build or UI change, run a design/style parity check against the corresponding mobile web implementation before marking the work done. Check layout, spacing, typography, colors, visual hierarchy, states, animations, navigation, interactions, text fit, and mobile behavior.
- For upload and creator/backstage flows, destination and playlist selection must mirror the mobile web lookup/search controls. Do not replace lookup-style destination or playlist selectors with simple flat pickers unless the corresponding web implementation does.
