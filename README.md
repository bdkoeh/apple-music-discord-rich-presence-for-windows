# Apple Music → Discord Rich Presence for Windows

Show what you're playing in the **Apple Music app for Windows** on your Discord profile, the same way Discord's
built-in Spotify integration does:

- **Listening to *Song - Artist*** next to your name (or **Listening to Apple Music**, your choice)
- song title, artist and album
- album artwork
- a live progress bar (elapsed and remaining time)
- a **Listen on Apple Music** button that opens the song for anyone who clicks it
- clears automatically when you pause or close Apple Music

It's a single PowerShell script that runs on the **Windows PowerShell 5.1 already built into Windows 10 and 11**.
There's no installer, no Node/Python/.NET runtime, no background service and no account linking.

---

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Setup](#setup)
- [Running it](#running-it)
- [Start automatically at login](#start-automatically-at-login)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Privacy](#privacy)
- [FAQ](#faq)
- [License](#license)

## How it works

```
Apple Music app ──► Windows media session ──► AppleMusicRPC.ps1 ──► Discord desktop app (local IPC pipe)
  (the same "now playing" info shown         │
   in the volume flyout)                     └──► iTunes Search API (album art + song link)
```

1. **Reads now playing.** Windows exposes the current track of any media app through the
   *Global System Media Transport Controls* API. That's what drives the media flyout over the volume overlay.
   The script reads the title, artist, album, play/pause state and position from it.
   Apple Music for Windows reports artist and album in a single "Artist — Album" field, and the script splits them apart.
2. **Finds artwork.** The media session doesn't provide a public image URL, so the script looks the track up with Apple's public
   [iTunes Search API](https://performance-partners.apple.com/search-api) (no API key) and gets the 512×512 album art
   and the track's `music.apple.com` link. Results are cached for the session.
3. **Updates Discord.** The script talks to the Discord desktop client over its local named pipe (`\\.\pipe\discord-ipc-0`)
   using the standard Rich Presence protocol. It sends a *Listening* activity (`type: 2`) with start/end timestamps
   so Discord draws the progress bar.
4. **Only sends changes.** It checks every 2 seconds but only updates Discord when the song, play state or position
   actually changes (for example after a seek). That keeps it within Discord's rate limits.

## Requirements

- Windows 10 or 11
- [Apple Music for Windows](https://apps.microsoft.com/detail/9pfhdd62mxs1) (Microsoft Store). iTunes also works if
  it publishes to the Windows media session.
- The **Discord desktop app**. Rich Presence doesn't work with Discord in a web browser.
- A free Discord *application*, used only for its ID and display name (see below)

## Setup

### 1. Get the code

```powershell
git clone https://github.com/bdkoeh/apple-music-discord-rich-presence-for-windows.git
cd apple-music-discord-rich-presence-for-windows
```

You can also download the ZIP from GitHub and extract it anywhere.

### 2. Create a Discord application

The name of this application is what Discord shows after "Listening to".

1. Open the [Discord Developer Portal](https://discord.com/developers/applications) and click **New Application**.
2. Name it **Apple Music** and create it.
3. On **General Information**, copy the **Application ID**.
4. *(Optional)* Under **Rich Presence → Art Assets**, upload an Apple Music logo with the key `applemusic`.
   It's used as a small badge on the album art if you set `smallImage` (see [Configuration](#configuration)).

### 3. Create your config

Copy the example config and paste in your Application ID:

```powershell
Copy-Item config.example.json config.json
notepad config.json
```

```json
{
  "clientId": "123456789012345678"
}
```

`config.json` is listed in `.gitignore`, so your ID won't be committed by accident.

### 4. Enable activity sharing in Discord

**User Settings → Activity Privacy →** turn on **Share your detected activities with others**.

## Running it

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AppleMusicRPC.ps1
```

Play a song in Apple Music. Within a couple of seconds you'll see:

```
[11:51:03] Apple Music -> Discord Rich Presence running. Ctrl+C to stop.
[11:51:04] Connected to Discord as yourname
[11:51:04] Playing: Song Title - Artist
```

Press **Ctrl+C** to stop. Your Discord status clears when the script exits.

**Debug mode.** `-Once` prints what the script detects and the exact payload it would send to Discord, then exits.
It doesn't need a config:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AppleMusicRPC.ps1 -Once
```

## Start automatically at login

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Install-Startup.ps1
```

This adds a shortcut to your Startup folder that runs the script with no visible window each time you sign in.
To remove it:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Install-Startup.ps1 -Remove
```

To stop a hidden copy that's already running, open Task Manager and end the `Windows PowerShell` process
that's running `AppleMusicRPC.ps1`, or run:

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object CommandLine -like '*AppleMusicRPC.ps1*' |
  ForEach-Object { Stop-Process -Id $_.ProcessId }
```

## Configuration

All settings live in `config.json`. Only `clientId` is required.

| Key | Default | Description |
|---|---|---|
| `clientId` | — | Your Discord Application ID. **Required.** Can also be set with the `DISCORD_CLIENT_ID` environment variable. |
| `statusDisplay` | `"song-artist"` | What appears next to your name in the member list and DMs. `"song-artist"` shows **Listening to Song - Artist**, `"song"` shows the song title, `"artist"` shows the artist, and `"app"` shows **Listening to Apple Music** (your Discord application's name). The full card on your profile shows everything in every mode. |
| `pollSeconds` | `2` | How often to check what Apple Music is playing. |
| `showWhenPaused` | `false` | `false` clears your status when paused, like Spotify. `true` keeps it with "(paused)" and no progress bar. |
| `showButton` | `true` | Show the **Listen on Apple Music** button. |
| `smallImage` | `""` | Art Asset key (for example `applemusic`) for a small badge in the corner of the album art. |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Set your Discord Application ID as clientId` | `config.json` is missing or still has the placeholder. See [Setup step 3](#3-create-your-config). |
| `Discord rejected the connection: Invalid Client ID` | The ID is wrong. Copy the **Application ID** (not the public key or a secret) again. |
| Script runs but nothing ever says "Connected" | The Discord *desktop* app isn't running, or it's running as administrator while the script isn't. Run both as your normal user. |
| Connected, but nothing shows on your profile | Turn on **Activity Privacy → Share your detected activities with others**. Restarting Discord also helps sometimes. |
| `-Once` prints nothing | Apple Music isn't playing anything, or hasn't registered with the Windows media controls yet. Press play and try again. |
| No album art | The iTunes Search API couldn't find a match (common for uploaded or very obscure tracks). The status still shows without art. |
| You don't see the button | Discord doesn't show Rich Presence buttons on your own profile. Other people see it. |
| Status lags a few seconds behind | Expected. Discord rate-limits presence updates, so changes are batched. |
| Script window closes immediately | Run it from an open PowerShell window to see the error. If scripts are blocked, the `-ExecutionPolicy Bypass` flag covers it. |

## Privacy

- Everything runs locally. The script only talks to:
  - the Discord app on your own PC, through its local pipe
  - `itunes.apple.com`, to look up artwork. Each request contains only the artist and song title.
- Nothing is logged to disk, and no data is sent anywhere else.
- Your status is visible to anyone who can see your Discord activity, the same as with Spotify.

## FAQ

**Does this work on macOS?**
No, it uses Windows-only APIs. On macOS, look for a Rich Presence tool built for the macOS Music app.

**Does it work with Apple Music in a browser (music.apple.com)?**
Partly. Chromium browsers publish to the Windows media session too, but the script only watches the Apple Music and
iTunes apps. You could change the `SourceAppUserModelId` filter in `Get-NowPlaying` to include your browser.

**Why is a Discord application needed?**
Discord's Rich Presence requires every activity to belong to an application. The application's name becomes the
"Listening to ___" text. You don't need a bot, a token or any permissions, only the public ID.

**Will this get my Discord account in trouble?**
No. It uses Discord's official, documented local Rich Presence interface, the same one games and
music players use.

**Does it use much CPU or memory?**
No. It sleeps between checks. Expect about 0% CPU and roughly 60 MB of memory, which is mostly PowerShell itself.

## License

[MIT](LICENSE)

*Not affiliated with Apple or Discord. Apple Music is a trademark of Apple Inc. Discord is a trademark of Discord Inc.*
