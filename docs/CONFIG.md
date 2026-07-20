# Configuration

`hp-laserjet-watcher.sh` runs with sensible defaults and needs no configuration.
Two optional mechanisms let you change its behaviour: a persistent **user config
file** and a per-job **`.opts` sidecar**.

With neither present, the watcher behaves exactly as it always has — the config
layer is purely additive.

## User config file

Path: `~/.config/hp-laserjet/config`
(override with the `HP_LASERJET_CONFIG` environment variable).

It is a plain `KEY=value` shell fragment, sourced by the watcher at startup. The
watcher runs unsandboxed as your user, so sourcing a file you own crosses no
privilege boundary — treat it like any other dotfile under your control. Keep it
to simple assignments; anything valid in `sh` is executed.

Create the directory and file:

```sh
mkdir -p ~/.config/hp-laserjet
cat > ~/.config/hp-laserjet/config <<'EOF'
PAPER=auto
# DENSITY=3
DEFAULT_COPIES=1
NOTIFY=all
EOF
```

### Keys

| Key              | Values              | Default | Meaning                                                        |
|------------------|---------------------|---------|----------------------------------------------------------------|
| `PAPER`          | `letter` \| `a4` \| `auto` | `auto`  | Paper size. `auto` detects A4 vs US Letter from the PDF page height (current behaviour). |
| `DENSITY`        | integer, or unset   | unset   | Print density. When unset, no density flag is passed and the driver default is used. |
| `DEFAULT_COPIES` | integer ≥ 1         | `1`     | Default number of copies per job when a job does not specify its own. |
| `NOTIFY`         | `all` \| `errors` \| `none` | `all` | macOS notifications on job completion (see below). |

An unrecognised or empty `PAPER` value falls back to `auto`; an empty
`DEFAULT_COPIES` falls back to `1`; an unrecognised or empty `NOTIFY` falls back
to `all`.

> **Note:** As of this release these keys are read into the watcher but not all
> are acted on yet — `PAPER=auto`, `DENSITY` unset and `DEFAULT_COPIES=1` (the
> defaults) reproduce today's behaviour exactly. `NOTIFY` is fully acted on.
> Later features consume the rest.

### `NOTIFY` — completion notifications

The watcher runs from a launchd *user agent*, so it can post a Notification
Center banner via `osascript`. `NOTIFY` selects what is posted:

| Value    | Posts                                                              |
|----------|-------------------------------------------------------------------|
| `all`    | Success (`Printed on <PID> (<driver>)`) **and** failures/defer.   |
| `errors` | Failures and the "printer not detected" defer only.               |
| `none`   | Nothing.                                                          |

A failure banner appears when the conversion produces nothing, the USB push
returns nonzero, or setup is incomplete (missing Ghostscript, converter, or
firmware). When no supported printer is on the bus **and** a job is waiting, a
single `Printer not detected — job queued` banner is posted (not repeated on an
empty spool, to avoid spam when launchd re-fires).

Notifications are best-effort UX only: they never influence whether or how a job
prints, never change an exit code, and are skipped silently when `osascript` is
unavailable. Banner text carries only the printer model/driver label and the
outcome — never your home path, username, or other personal data.

## Per-job `.opts` sidecar

A single print job MAY be accompanied by a sidecar file sitting next to its PDF
in the spool directory:

```
~/HP-LaserJet-spool/job-<ts>.pdf     the job
~/HP-LaserJet-spool/job-<ts>.opts    its per-job options (optional)
```

The sidecar is the same `KEY=value` format and carries **per-job** overrides
that take precedence over the user config file for that one job. Planned keys:

| Key       | Example      | Meaning                          |
|-----------|--------------|----------------------------------|
| `COPIES`  | `COPIES=2`   | Number of copies for this job.   |
| `DUPLEX`  | `DUPLEX=long`| Two-sided printing.              |
| `NUP`     | `NUP=2`      | Pages per sheet (N-up).          |
| `DENSITY` | `DENSITY=3`  | Print-density override.          |

The watcher already looks for the sidecar via `read_job_opts` in the per-job
loop, but that function is currently a no-op placeholder: it resets the per-job
option variables to their config/default values and does **not** yet parse the
sidecar. Jobs without a `.opts` file are wholly unaffected. Downstream features
(duplex, notifications, multi-printer, density) populate both this parser and
the option handling.
