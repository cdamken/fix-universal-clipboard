# fix-universal-clipboard

Repairs Apple **Universal Clipboard** on macOS when copy/paste between your iPhone or iPad and your Mac silently stops working.

No sudo. Nothing installed. No settings changed.

## The problem

You copy something on your iPhone, press <kbd>Cmd</kbd>+<kbd>V</kbd> on the Mac, and get the *previous* clipboard contents instead. Or nothing at all. Everything looks correctly configured: Handoff is on, both devices share an iCloud account, Bluetooth and Wi-Fi are up. Other Continuity features still work, so the phone is clearly reachable.

The cause is usually one of three user-level daemons on the Mac stuck in a bad state:

| Daemon | What it does |
| --- | --- |
| `pboard` | The pasteboard (clipboard) server |
| `useractivityd` | Handoff, which Universal Clipboard is built on |
| `sharingd` | Continuity: AirDrop, Handoff, Universal Clipboard |

Nothing surfaces an error when one of them wedges, which is why the failure is so quiet. Restarting them clears the state, and `launchd` brings all three back immediately, so there is nothing to turn back on afterwards.

## Usage

Clone it into a directory you own. Creating one under your home directory always works:

```bash
mkdir -p ~/src && cd ~/src
git clone https://github.com/cdamken/fix-universal-clipboard.git
cd fix-universal-clipboard
./fix-universal-clipboard.sh
```

> Do not run `git clone` from inside a system directory such as `/usr/local/bin` or `/opt/homebrew/bin`. Git cannot create a folder there without root and fails with `could not create work tree dir 'fix-universal-clipboard': Permission denied`, which then makes the following `cd` and `./fix-universal-clipboard.sh` fail too.

Run the diagnostics without changing anything:

```bash
./fix-universal-clipboard.sh --check
```

### Install it as a command

To call it from anywhere instead of `cd`-ing into the repo each time, symlink it into a directory on your `PATH`:

```bash
mkdir -p ~/bin
ln -sf ~/src/fix-universal-clipboard/fix-universal-clipboard.sh ~/bin/fix-universal-clipboard
```

If `~/bin` is not on your `PATH` yet, add it and reload the shell:

```bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Then, from any directory:

```bash
fix-universal-clipboard --check
fix-universal-clipboard
```

Because the symlink points at the clone, `git pull` inside the repo updates the command too.

### Options

| Option | Effect |
| --- | --- |
| `--check` | Run the diagnostics only. Changes nothing. |
| `--no-save` | Do not preserve the current clipboard contents. |
| `-h`, `--help` | Show usage. |
| `--version` | Show the version. |

## What it checks

Before restarting anything, the script verifies every Mac-side requirement of Universal Clipboard and tells you which one is missing:

- Handoff enabled, both advertising and receiving (`ActivityAdvertisingAllowed` / `ActivityReceivingAllowed`)
- Bluetooth on, used to discover the nearby device
- Wi-Fi radio on; the transfer itself runs over AWDL peer to peer, so the two devices do not have to share a network
- `awdl0` up, the peer-to-peer link that carries the payload
- An iCloud account signed in, which both devices must share
- Whether each of the three daemons is running

Findings are advisory. The repair runs regardless, because a stuck daemon usually looks perfectly healthy.

## Testing it afterwards

1. On the iPhone or iPad, copy a short piece of plain text.
2. Within two minutes, press <kbd>Cmd</kbd>+<kbd>V</kbd> on the Mac. The clipboard expires on its own.

**Test by actually pasting.** Do not reach for `pbpaste` to check whether it worked: it reads the local pasteboard only and does not pull in the remote clipboard, so it reports an empty clipboard even while Universal Clipboard is working fine. This is an easy way to misdiagnose the problem as unfixed.

Prefer plain text for the test. Copying from a browser drags HTML along and muddies the result.

## Clipboard preservation

Restarting `pboard` drops whatever is on the clipboard, so the script stashes the plain text and restores it when the daemons are back. Styled text, images and files are **not** preserved. Use `--no-save` to skip this.

## What it cannot do

Universal Clipboard needs both devices healthy, and this script only touches the Mac. If it does not help, the iPhone side needs attention:

- **Settings → General → AirPlay & Continuity → Handoff**: turn it off and back on.
- Keep the device unlocked and nearby while you copy. It only advertises the clipboard while awake.
- **Restart the iPhone.** iOS exposes no clipboard reset, so a restart is the only way to clear its side.
- Confirm both devices are signed in to the same iCloud account.
- **Settings → General → VPN & Device Management**: a work or MDM profile on the phone can block the clipboard between devices even when the iCloud account is shared.

## Which step actually fixes it

If you want to know which side was at fault, run this script first and test before touching the phone. If the Mac-side restart is enough, you have your answer, and next time you can skip straight to it.

## Requirements

macOS. Tested on macOS 26 (Tahoe). The three daemons and the `defaults` keys it reads have been stable across many macOS releases, so it should work well beyond that.

## License

MIT. See [LICENSE](LICENSE).
