# Curby Project Guide

## Build Commands
- **iOS App**: Open `curby.xcodeproj` in Xcode or use `xcodebuild -project curby.xcodeproj -scheme curby -destination 'platform=iOS Simulator,name=iPhone 15' build`
- **Backend**: `cd backend && pnpm install && pnpm run build`
- **Backend Deployment**: `./scripts/deploy.sh` (ensure `.env` is configured)
- **Python Scripts**: `pip install -r requirements.txt`

## Test Commands
- **iOS Tests**: `xcodebuild test -project curby.xcodeproj -scheme curby -destination 'platform=iOS Simulator,name=iPhone 15'`
- **Python Tests**: Run individual scripts like `python3 update_parking_ui.py` (check script headers for usage)

## Code Style & Guidelines
- **Swift/SwiftUI**:
  - Follow Apple's Swift API Design Guidelines.
  - Use `MainActor` for UI-related classes and functions.
  - Prefer `@Observable` (Observation framework) for state management.
  - UI components should be modular and reusable.
  - Map components use Mapbox Maps SDK v11+.
- **Backend (TypeScript/Cloudflare)**:
  - Use functional patterns where possible.
  - Adhere to Cloudflare Workers and Durable Objects best practices.
  - Use `pnpm` for dependency management.
- **Python**:
  - Use PEP 8 styling.
  - Use type hinting for clarity.

## Project Structure
- `curby/`: Main iOS application source code.
- `backend/`: Cloudflare Workers and Supabase configuration.
- `scripts/`: Deployment and utility scripts.
- `curbyTests/` & `curbyUITests/`: iOS test suites.
