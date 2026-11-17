# Privacy Policy — Phoenicx SSH

_Last updated: 17 November 2026_

Phoenicx SSH ("the app") is an SSH terminal and server-monitoring app for Android and Windows, made by Hanson ([phoenicx.org](https://phoenicx.org)). This policy explains what the app does with your information.

## The short version

**The app does not collect, sell or share any personal data. There are no accounts, no analytics, no ads and no tracking.** Everything you enter stays on your device. The app only talks to the servers that you add yourself.

## Information you enter

To connect to your servers you can save:

- server names, addresses (IP or hostname), ports and usernames
- passwords, private keys and key passphrases
- your own saved commands and app settings

This information is **stored only on your device**, encrypted with AES-256-GCM. The encryption key is kept in the Android Keystore (on Android) or protected by Windows DPAPI (on Windows). It is never sent to the developer or to anyone else.

## Network connections

The app connects **only** to the SSH servers you add, using the encrypted SSH protocol. Terminal input and output, and the server statistics shown in the monitor (CPU, memory, network, disk, processes, Docker containers), travel directly between your device and **your own server**. The developer has no servers involved and never receives this data.

When you add a server, the app shows the server's host-key fingerprint and remembers it on your device, to protect you from impostor servers.

## Backup files

If you use **Export**, the app creates a backup file containing your saved servers (and, if you choose, their passwords and keys) and your saved commands. The file is saved **where you choose**. If you set a backup password, the file is encrypted with AES-256-GCM. You decide where this file goes; the developer never receives it.

## Permissions (Android)

- **Internet / network state** — to connect to your SSH servers.
- **Notifications and foreground service** — to show a small notification while SSH sessions are open, which keeps your sessions connected when the screen is off or the app is in the background. It stops when you close your last session.
- **Wake lock / Wi-Fi lock** — optional (Settings), keeps connections alive while the screen is off.

The app does not access your contacts, location, camera, microphone, photos or other apps' data. Files (such as key files and backups) are only opened when you pick them yourself.

## Children

The app is a technical tool for managing servers and is not directed at children.

## Data deletion

All data lives on your device. Uninstalling the app (or clearing its storage) deletes it completely. Delete any backup files you exported yourself.

## Changes

If this policy changes, the updated version will be published at this address with a new date.

## Contact

Hanson — [hanson.in@outlook.com](mailto:hanson.in@outlook.com) — [phoenicx.org](https://phoenicx.org)
