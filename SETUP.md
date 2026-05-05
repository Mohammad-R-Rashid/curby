# Curby Project Setup Guide

This guide outlines all the dependencies and steps required to run the **Curby** project on a new device.

## 1. Project Overview
Curby is a multi-platform project consisting of:
- **iOS App**: Built with SwiftUI and Mapbox Maps SDK.
- **Backend**: Built with TypeScript, Cloudflare Workers, and Supabase.
- **Utility Scripts**: Python scripts for data testing and UI automation.

---

## 2. Python Utility Scripts
Used for testing APIs and automating UI updates.
- **Requirement**: Python 3.9+
- **Installation**:
  ```bash
  pip install -r requirements.txt
  ```

---

## 3. iOS Application (SwiftUI)
To run the mobile app on another Mac:
- **Requirement**: macOS (latest), Xcode 15+
- **External Dependencies (Managed via Swift Package Manager)**:
  - **Mapbox Maps SDK**: `https://github.com/mapbox/mapbox-maps-ios.git` (v11.0.0+)
  - **Phosphor Icons**: `https://github.com/phosphor-icons/swift` (v2.1.0+)
- **Setup**:
  1. Open `curby.xcodeproj` in Xcode.
  2. Wait for Swift Packages to resolve automatically.
  3. Ensure you have a valid `MapboxAccessToken` in your `Info.plist` or `~/.netrc`.

---

## 4. Backend (Cloudflare Workers & Supabase)
To deploy or run the backend:
- **Requirements**:
  - Node.js 18+
  - `pnpm` (Corepack or `npm install -g pnpm`)
  - `wrangler` CLI (Cloudflare Workers tool)
- **Setup**:
  ```bash
  cd backend
  pnpm install
  ```
- **Deployment**:
  Ensure you have a `.env` file in the `backend` directory with:
  - `SUPABASE_URL`
  - `SUPABASE_SECRET_KEY`
  - `MAPBOX_ACCESS_TOKEN`
  
  Run the deploy script:
  ```bash
  chmod +x scripts/deploy.sh
  ./scripts/deploy.sh
  ```

---

## 5. Summary of System Requirements
| Component | Language/Tech | Manager |
| :--- | :--- | :--- |
| **Mobile** | Swift / SwiftUI | Xcode / SPM |
| **Backend** | TypeScript | Node.js / pnpm |
| **Scripts** | Python 3 | pip |
| **Database** | PostgreSQL | Supabase |
| **Edge Logic**| JavaScript/TS | Cloudflare Workers |

---

> [!TIP]
> If you are moving to a new Mac, ensure you also copy your `.env` files and `.netrc` (for Mapbox) as these are typically ignored by Git.
