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
EOF
```

### Keys

| Key              | Values              | Default | Meaning                                                        |
|------------------|---------------------|---------|----------------------------------------------------------------|
| `PAPER`          | `letter` \| `a4` \| `auto` | `auto`  | Paper size. `auto` detects A4 vs US Letter from the PDF page height (current behaviour). |
| `DENSITY`        | integer, or unset   | unset   | Print density. When unset, no density flag is passed and the driver default is used. |
| `DEFAULT_COPIES` | integer ≥ 1         | `1`     | Default number of copies per job when a job does not specify its own. |
| `PRINTER`        | USB PID or name substring, or unset | unset | Which printer to use when **several** supported printers are attached. See "Selecting a printer" below. Ignored when only one supported printer is present. |

An unrecognised or empty `PAPER` value falls back to `auto`; an empty
`DEFAULT_COPIES` falls back to `1`.

> **Note:** As of this release these keys are read into the watcher but not all
> are acted on yet — `PAPER=auto`, `DENSITY` unset and `DEFAULT_COPIES=1` (the
> defaults) reproduce today's behaviour exactly. `PRINTER` is honoured (see
> below). Later features consume the rest.

## Selecting a printer when several are connected

The watcher enumerates **every** supported HP LaserJet on the USB bus (via
`ioreg`, matched against its model table). What happens depends on how many it
finds:

- **One supported printer** — it is used, exactly as before. `PRINTER` is
  ignored. Behaviour is byte-for-byte identical to having a single printer and
  no config.
- **No supported printer** — the watcher logs `no supported printer detected —
  deferring queued jobs`, leaves the jobs in the spool and exits. It never
  guesses a model (driving a job with the wrong protocol/firmware would
  misprint). Powering the printer on or printing again re-triggers detection.
- **Several supported printers** — the macOS Print dialog cannot tell the
  watcher which one you meant (the PDF Service that spools the job is
  sandboxed), so the watcher routes as follows:
  1. If `PRINTER` is set **and** the named printer is on the bus, all jobs go to
     it. `PRINTER` may be either a USB **product id** (`PRINTER=0x3d17`) or a
     case-insensitive **substring of the product name** (`PRINTER=p1005`,
     `PRINTER=m1005`).
  2. If `PRINTER` is unset or does not match a present printer, the watcher
     falls back to a **deterministic primary**: the lowest USB product id
     present. It logs which printer it chose and which it ignored, e.g.:

     ```
     multiple supported printers detected: 0x002a 0x3d17
     no PRINTER set; defaulting to lowest PID 0x002a (ignoring: 0x3d17) — set PRINTER in ~/.config/hp-laserjet/config to choose
     ```

Example config selecting the P1005 by name:

```sh
cat >> ~/.config/hp-laserjet/config <<'EOF'
PRINTER=p1005
EOF
```

You can also override the target for a **single job** with the per-job sidecar
(next section): a `PRINTER=` line in `job-<ts>.opts` routes just that job,
without changing the config default. This too is ignored unless several
supported printers are attached.

## Per-job `.opts` sidecar

A single print job MAY be accompanied by a sidecar file sitting next to its PDF
in the spool directory:

```
~/HP-LaserJet-spool/job-<ts>.pdf     the job
~/HP-LaserJet-spool/job-<ts>.opts    its per-job options (optional)
```

The sidecar is the same `KEY=value` format and carries **per-job** overrides
that take precedence over the user config file for that one job. Planned keys:

| Key       | Example         | Meaning                          | Honoured? |
|-----------|-----------------|----------------------------------|-----------|
| `PRINTER` | `PRINTER=0x3d17`| Route this one job to a specific printer when several are attached (PID or product-name substring). | **yes** |
| `COPIES`  | `COPIES=2`      | Number of copies for this job.   | not yet |
| `DUPLEX`  | `DUPLEX=long`   | Two-sided printing.              | not yet |
| `NUP`     | `NUP=2`         | Pages per sheet (N-up).          | not yet |
| `DENSITY` | `DENSITY=3`     | Print-density override.          | not yet |

The watcher reads the sidecar via `read_job_opts` in the per-job loop. This
release parses only `PRINTER=` from it (used for multi-printer routing, see
"Selecting a printer" above); the other keys are reset to their config/default
values but not yet parsed — downstream features (copies, duplex, density)
populate them. `PRINTER=` is parsed with a line-anchored match rather than by
sourcing the file, so a malformed sidecar cannot execute code. Jobs without a
`.opts` file, and jobs whose sidecar sets no `PRINTER`, are wholly unaffected.
