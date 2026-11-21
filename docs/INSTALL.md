# Installing Harbor on an iPhone with LiveContainer

Harbor is an unsigned app that you import into **LiveContainer**. It runs the
Windows ARM64 build of Claude Code through Wine, so it needs **JIT**, which on
iOS 26 and later (iPhone 15, iOS 27) means an attached debugger that runs
Harbor's JIT script.

## What you need

- iPhone with LiveContainer already working in **JIT-less mode** (LiveContainer
  requires its certificate setup on iOS 26+; see LiveContainer's own guide).
- **StikDebug** set up for this iPhone (pairing file imported) and
  **LocalDevVPN** connected. This is the same JIT setup LiveContainer uses for
  “Launch with JIT”.
- In LiveContainer's settings, **JIT Enabler** set to **StikDebug** (or
  StikDebug-in-LC). Only these forward a launch script.
- About 1 GB of free storage (the app, Claude Code, Git and the Wine prefix).

## 1. Get the IPA and the JIT script

From the repository's **Releases** page, download:

- `Harbor.ipa`, and check it against the SHA-256 printed in the release notes
  (`shasum -a 256 Harbor.ipa`).
- `harbor-jit.js`, the debugger script. It is also inside the app: on the
  setup screen open “How to enable JIT” → **Export the JIT script**.

Save both to the Files app.

## 2. Import into LiveContainer

1. Open LiveContainer, tap **+**, and pick `Harbor.ipa`.
2. Long-press Harbor → **Settings**:
   - turn on **Launch with JIT**;
   - next to **JIT Launch Script**, tap **Select** and choose `harbor-jit.js`.
3. Leave the other options at their defaults. Harbor does not need
   **Helper Process Support** (everything runs in one process).

## 3. Launch

1. Make sure LocalDevVPN is connected.
2. Tap Harbor in LiveContainer. LiveContainer asks StikDebug to attach with
   the script; StikDebug may open briefly and return.
3. Harbor's setup screen shows **JIT is on · JIT memory is ready** once the
   debugger has prepared Harbor's JIT memory and detached. This happens
   automatically within a few seconds of the debugger attaching.

If the setup screen says **JIT is off**, either launch again from LiveContainer
with “Launch with JIT”, or tap **Enable with StikDebug** in “How to enable
JIT”, which asks StikDebug to attach to the running copy (by process ID) with
the bundled script.

If it says **JIT is on, but without Harbor's script**, JIT was enabled by a
flow that did not run the script (for example from StikDebug's own app list).
Relaunch from LiveContainer with the script selected.

## 4. First-run setup

1. **Tools**: tap **Download**. Harbor downloads the latest Claude Code
   (`win32-arm64/claude.exe`, about 370 MB) from Anthropic's release server and
   checks it against the release manifest's SHA-256, then Git for Windows
   (MinGit 2.56.1 ARM64, busybox variant, about 30 MB) from GitHub, checked
   against its published SHA-256. Keep Harbor open while it downloads.
2. **Sign in**: tap **Sign in** → **Start sign-in**. Claude Code makes a
   sign-in link; tap **Open the sign-in page**, sign in with your Claude
   account in Safari, copy the code it shows, come back and paste it, then
   **Continue**. The token is stored in the Keychain (inside LiveContainer: in
   LiveContainer's keychain group) and is never shown. If you already have a
   token from `claude setup-token` on a computer, paste it under “Already have
   a token?” instead.
3. Tap **Start**.

## Daily use

- Launch Harbor from LiveContainer **with JIT** every time (the JIT memory
  lives only as long as the app process).
- Harbor reopens your most recent session. The sidebar button (iPhone) or the
  sidebar (iPad) lists sessions; the pencil starts a new one.
- Claude works in `C:\workspace` inside the Wine prefix. It always runs with
  permissions bypassed; there are no permission prompts.
- **Stop** interrupts the current turn.
- While Claude is working, Harbor keeps running in the background for the time
  set in Settings (default 10 minutes), by playing silence.
- **Diagnostics** (gauge button) shows JIT, memory, CPU, the running Windows
  processes and the latest log lines, with a share button for the log.

## Troubleshooting

| Symptom | What to do |
|---|---|
| “JIT is off” | Launch from LiveContainer with “Launch with JIT”; check LocalDevVPN is connected and StikDebug has a pairing file. |
| “the debugger did not prepare a JIT region” | The selected JIT script is not Harbor's. Select `harbor-jit.js` again in LiveContainer's app settings. |
| Download fails verification | Retry; if it persists, the release server changed the file after the manifest was written. |
| Claude stops with an error code | Diagnostics → **Share the log**. |
| Low memory | Diagnostics shows the footprint and the limit; “Increased memory limit” must show a raised limit (LiveContainer's signing grants it). |

## Updating

- **Claude Code**: Settings → **Update Claude Code** downloads the newest
  release (verified the same way). The version the CI self-test last passed with
  is shown there.
- **Harbor**: import the new IPA into LiveContainer over the old one; the
  data container (prefix, sessions, sign-in) is kept.

## Building from source

Everything Apple-side is built by GitHub Actions on macOS runners
(`.github/workflows/build.yml`): the Wine unix-side static libraries for device
and simulator, the aarch64-windows DLL farm, the app, the unsigned IPA, the
simulator self-test and the UI screenshot tests. Results are committed to the
`ci-results` branch.
