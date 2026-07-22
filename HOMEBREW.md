# Installing via Homebrew

`hp-laserjet-mac-driver` ships a Homebrew formula so you can install and update
it with `brew`. Because the driver installs a **setuid-root** USB pusher, a
per-user **launchd** agent, and a Print-dialog **PDF Service**, installation is
two steps: `brew` stages the files, then a bundled installer does the privileged
setup.

## Install

One copy-paste line:

```bash
brew tap pauyedin/hp-laserjet https://gitlab.com/pauyedin/homebrew-hp-laserjet && brew install hp-laserjet-mac-driver && hp-laserjet-install
```

Three stages, `&&`-chained so they run in order:

1. **`brew tap pauyedin/hp-laserjet …`** — points Homebrew at the tap repo. Only
   needed **once**; after that a bare `brew install hp-laserjet-mac-driver`
   resolves the formula from the tap.
2. **`brew install hp-laserjet-mac-driver`** — stages the driver into the Cellar
   and pulls in `ghostscript`, `libusb`, `poppler`.
3. **`hp-laserjet-install`** — runs the bundled `install.sh` and prompts for your
   password: it builds `foo2zjs`/`foo2xqx` and `fwload`, obtains the firmware
   blobs, installs the setuid-root `fwload` into `/usr/local/share/foo2zjs`, loads
   the launchd watcher, and installs the PDF Service. (Equivalently:
   `"$(brew --prefix hp-laserjet-mac-driver)/libexec/install.sh"`.)

Then print from any app: **Cmd+P → PDF ▾ (bottom-left) → "Print on HP LaserJet"**.

### Does `brew install` work without the tap?

Only if the formula were accepted into **`homebrew/core`** — and it won't be. A
macOS-only, setuid-root printer driver whose install is finished by a bundled
`install.sh` (via `caveats`) does not meet homebrew-core's policy (no
sudo/setuid, no external installers, broad platform support). So a bare
`brew install hp-laserjet-mac-driver` with no tap will not find this formula;
the tap above is the supported route.

## Why two steps (setuid / sudo cannot run inside `brew`)

`brew install` runs **unprivileged** and is not allowed to prompt for a password
or drop setuid binaries. But this driver requires all three of:

- a **setuid-root** `fwload` — the user-context launchd agent must be able to
  claim the printer's USB interface;
- a **per-user launchd agent** under `~/Library/LaunchAgents`;
- a **PDF Service** under `~/Library/PDF Services`.

None of that belongs in a Cellar-only, sandbox-friendly `brew install`. So the
formula only stages the repo under `libexec`, and the bundled `install.sh` (run
once, with `sudo`) does the privileged and per-user work. `brew upgrade` restages
the files; re-run `hp-laserjet-install` to re-apply.

## Uninstall

```bash
# Remove the driver's system pieces first (setuid binary, launchd agent, PDF Service):
"$(brew --prefix hp-laserjet-mac-driver)/libexec/uninstall.sh"

# Then remove the staged files:
brew uninstall hp-laserjet-mac-driver
brew untap pauyedin/hp-laserjet
```

## Maintainer release checklist

The formula lives in a **separate tap repo**,
[`pauyedin/homebrew-hp-laserjet`](https://gitlab.com/pauyedin/homebrew-hp-laserjet)
(Homebrew requires a tap repo named `homebrew-<tap>`). A copy is kept in this
repo under `Formula/` for reference/CI; the copy `brew` actually uses is the one
in the tap repo. On each release, update **both** (or update the tap and copy it
here).

> **⚠️ The tap repo MUST be public.** `homebrew-hp-laserjet` was created via
> push-to-create, which makes it **private** by default. While it is private,
> `brew tap pauyedin/hp-laserjet https://gitlab.com/pauyedin/homebrew-hp-laserjet`
> fails over HTTPS with `fatal: could not read Password for
> 'https://gitlab.com'` (git prompts for credentials on a repo it can't see).
> Fix it once, in the GitLab UI: **Settings → General → Visibility, project
> features, permissions → Project visibility → Public → Save changes.** This is
> a GitLab-side setting no script or formula can change; verify anonymous access
> with `git ls-remote https://gitlab.com/pauyedin/homebrew-hp-laserjet` (no
> credential prompt = public).

1. **Tag the release** in this project repo and push the tag:

   ```bash
   git tag v0.1
   git push origin v0.1
   ```

2. **Update `url`** in the formula to point at that tag's source tarball. GitLab
   serves a source tarball for any tag at:

   ```
   https://gitlab.com/pauyedin/hp-laserjet-mac-driver/-/archive/v0.1/hp-laserjet-mac-driver-v0.1.tar.gz
   ```

   (No explicit `version` line is needed — `brew` scans it from the URL.)

3. **Compute the tarball `sha256`** and set it in the formula:

   ```bash
   curl -fsSL -o /tmp/hpljd.tar.gz \
     "https://gitlab.com/pauyedin/hp-laserjet-mac-driver/-/archive/v0.1/hp-laserjet-mac-driver-v0.1.tar.gz"
   shasum -a 256 /tmp/hpljd.tar.gz
   ```

4. **Syntax-check, audit, install and test** against the tap:

   ```bash
   ruby -c Formula/hp-laserjet-mac-driver.rb
   brew audit --strict --formula pauyedin/hp-laserjet/hp-laserjet-mac-driver
   brew install --build-from-source pauyedin/hp-laserjet/hp-laserjet-mac-driver
   brew test hp-laserjet-mac-driver
   ```

5. **Commit the formula bump in the tap repo** and push it, so `brew` users pick
   it up on their next `brew update`. Copy the same formula into this repo's
   `Formula/` for reference.
