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
# ECONOMODE=off
DEFAULT_COPIES=1
EOF
```

### Keys

| Key              | Values              | Default | Meaning                                                        |
|------------------|---------------------|---------|----------------------------------------------------------------|
| `PAPER`          | `letter` \| `a4` \| `auto` | `auto`  | Paper size. `auto` detects A4 vs US Letter from the PDF page height (current behaviour). |
| `DENSITY`        | `1`–`5`, or unset   | unset   | Print density. When unset, no override is added and the driver default is used. See [Print quality / density](#print-quality--density). |
| `ECONOMODE`      | `on` \| `off`, or unset | unset | Toner-save / draft mode. `off`/unset adds no flag. See [Print quality / density](#print-quality--density). |
| `DEFAULT_COPIES` | integer ≥ 1         | `1`     | Default number of copies per job when a job does not specify its own. |

An unrecognised or empty `PAPER` value falls back to `auto`; an empty
`DEFAULT_COPIES` falls back to `1`.

> **Note:** `PAPER=auto`, `DENSITY` unset, `ECONOMODE` unset and
> `DEFAULT_COPIES=1` (the defaults) reproduce today's behaviour exactly — the
> converter flag string is byte-for-byte identical to running with no config.

## Per-job `.opts` sidecar

A single print job MAY be accompanied by a sidecar file sitting next to its PDF
in the spool directory:

```
~/HP-LaserJet-spool/job-<ts>.pdf     the job
~/HP-LaserJet-spool/job-<ts>.opts    its per-job options (optional)
```

The sidecar is the same `KEY=value` format and carries **per-job** overrides
that take precedence over the user config file for that one job. Planned keys:

| Key         | Example        | Meaning                                             |
|-------------|----------------|-----------------------------------------------------|
| `COPIES`    | `COPIES=2`     | Number of copies for this job.                      |
| `DUPLEX`    | `DUPLEX=long`  | Two-sided printing.                                 |
| `NUP`       | `NUP=2`        | Pages per sheet (N-up).                             |
| `DENSITY`   | `DENSITY=3`    | Print-density override (`1`–`5`) for this job.      |
| `ECONOMODE` | `ECONOMODE=on` | Toner-save / draft mode for this job.               |

`read_job_opts` parses the sidecar as a small `KEY=value` allow-list — it is
**not** sourced, so a stray line cannot run code or clobber other variables.
For each job it first resets the per-job variables to their config/default
values, then applies any recognised keys from the sidecar; a sidecar value
therefore overrides the user config for that one job. Jobs without a `.opts`
file are wholly unaffected. Print-quality keys (`DENSITY`, `ECONOMODE`) are
handled here today; `COPIES` / `DUPLEX` / `NUP` are owned by other features and
unknown keys are ignored so multiple features can share one sidecar.

## Print quality / density

Both raster converters (`foo2zjs` for ZjStream models, `foo2xqx` for XQX
models) accept the same two geometry-safe quality flags, confirmed from their
`usage()`/`getopt` (`vendor/foo2zjs-src.tar.gz`):

```
-t                Draft mode.  Every other pixel is white.
-T density        Print density (1-5) [3].
```

- **`DENSITY` → `-T <1-5>`.** Higher is darker. The value is validated to the
  integer range `1`–`5`; anything else is logged and skipped (no flag added).
  ZjStream jobs already carry a hardcoded `-T5` in the base flag string; an
  explicit `DENSITY` appends a second `-T`, and since `getopt` keeps the last
  occurrence the requested value wins.
- **`ECONOMODE` → `-t`.** Accepts `on`/`1`/`true`/`yes` (adds `-t`) or
  `off`/`0`/`false`/`no`/unset (adds nothing). On these models the driver maps
  toner-save to the printer's EconoMode.

Both flags only set an internal driver flag; neither alters the raster
resolution (`-r`) or page grid (`-g`), so they cannot desync the geometry.

### Why resolution is not exposed

Resolution is **not** a configurable key. The per-model resolution (`RES`) and
the paper grid (`-g`, built by `grid_for`) are coupled through the model row's
`XSCALE`: the 1200×600 models pass a horizontally-doubled pixel grid. The same
`-r`/`-g` values are also handed to Ghostscript so its rasteriser and the
converter agree on pixel dimensions. Overriding resolution alone would desync
Ghostscript's output, the converter's expected grid, and the printer's native
dot geometry, producing corrupt or clipped output. Density and EconoMode were
chosen precisely because they are orthogonal to that geometry.
