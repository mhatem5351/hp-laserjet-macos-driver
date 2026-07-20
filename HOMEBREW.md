# Installing via Homebrew

`hp-laserjet-mac-driver` ships a Homebrew formula so you can install and update
it with `brew`. Because the driver installs a **setuid-root** USB pusher, a
per-user **launchd** agent, and a Print-dialog **PDF Service**, installation is
two steps: `brew` stages the files, then a bundled installer does the privileged
setup.

## Install

```bash
# 1. Add the tap (points Homebrew at this GitLab repo)
brew tap pauyedin/hp-laserjet https://gitlab.com/pauyedin/hp-laserjet-mac-driver

# 2. Install the formula (pulls in ghostscript, libusb, poppler)
brew install hp-laserjet-mac-driver

# 3. Finish setup — the caveats printed by step 2 tell you to run:
hp-laserjet-install
#   (equivalently: "$(brew --prefix hp-laserjet-mac-driver)/libexec/install.sh")
```

Step 3 prompts for your password: it builds `foo2zjs`/`foo2xqx` and `fwload`,
obtains the firmware blobs, installs the setuid-root `fwload` into
`/usr/local/share/foo2zjs`, loads the launchd watcher, and installs the PDF
Service.

Then print from any app: **Cmd+P → PDF ▾ (bottom-left) → "Print on HP LaserJet"**.

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

When cutting a release, update `Formula/hp-laserjet-mac-driver.rb`:

1. **Tag the release** and push the tag:

   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```

2. **Update `url` and `version`** in the formula to match the tag. GitLab serves
   a source tarball for any tag at:

   ```
   https://gitlab.com/pauyedin/hp-laserjet-mac-driver/-/archive/v1.0.0/hp-laserjet-mac-driver-v1.0.0.tar.gz
   ```

3. **Compute the tarball `sha256`** and replace the `REPLACE_ME` placeholder in
   the formula. Either let Homebrew fetch it:

   ```bash
   brew fetch --build-from-source ./Formula/hp-laserjet-mac-driver.rb
   # prints the SHA-256 of the downloaded tarball
   ```

   or download and hash it directly:

   ```bash
   curl -fsSL -o /tmp/hpljd.tar.gz \
     "https://gitlab.com/pauyedin/hp-laserjet-mac-driver/-/archive/v1.0.0/hp-laserjet-mac-driver-v1.0.0.tar.gz"
   shasum -a 256 /tmp/hpljd.tar.gz
   ```

   > **Do not commit the formula with `sha256 "REPLACE_ME"`** — `brew install`
   > refuses a checksum mismatch, so the placeholder must be replaced before the
   > release is usable.

4. **Syntax-check** the formula and audit it:

   ```bash
   ruby -c Formula/hp-laserjet-mac-driver.rb
   brew audit --strict --formula ./Formula/hp-laserjet-mac-driver.rb
   brew install --build-from-source ./Formula/hp-laserjet-mac-driver.rb
   brew test hp-laserjet-mac-driver
   ```

5. Commit the formula bump on the release, so `brew` users pick it up on their
   next `brew update`.
