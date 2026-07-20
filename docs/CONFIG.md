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
# DEFAULT_DUPLEX=none
# DEFAULT_NUP=1
EOF
```

### Keys

| Key              | Values              | Default | Meaning                                                        |
|------------------|---------------------|---------|----------------------------------------------------------------|
| `PAPER`          | `letter` \| `a4` \| `auto` | `auto`  | Paper size. `auto` detects A4 vs US Letter from the PDF page height (current behaviour). |
| `DENSITY`        | integer, or unset   | unset   | Print density. When unset, no density flag is passed and the driver default is used. |
| `DEFAULT_COPIES` | integer ≥ 1         | `1`     | Default number of copies per job when a job does not specify its own. |
| `DEFAULT_DUPLEX` | `none` \| `long` \| `short` | `none`  | Default duplex mode per job. See "Duplex, N-up, copies" below — most supported models are simplex-only. |
| `DEFAULT_NUP`    | integer ≥ 1         | `1`     | Default pages-per-sheet. Only `1` is honoured; the converters have no N-up (see below). |

An unrecognised or empty `PAPER` value falls back to `auto`; an empty
`DEFAULT_COPIES` falls back to `1`; an unrecognised `DEFAULT_DUPLEX` falls back
to `none`; a non-integer `DEFAULT_NUP` falls back to `1`.

## Per-job `.opts` sidecar

A single print job MAY be accompanied by a sidecar file sitting next to its PDF
in the spool directory:

```
~/HP-LaserJet-spool/job-<ts>.pdf     the job
~/HP-LaserJet-spool/job-<ts>.opts    its per-job options (optional)
```

The sidecar is the same `KEY=value` format and carries **per-job** overrides
that take precedence over the user config file for that one job. Recognised keys:

| Key       | Example      | Meaning                          |
|-----------|--------------|----------------------------------|
| `COPIES`  | `COPIES=2`   | Number of copies for this job.   |
| `DUPLEX`  | `DUPLEX=long`| Two-sided printing (`none`/`long`/`short`). |
| `NUP`     | `NUP=2`      | Pages per sheet (N-up).          |
| `DENSITY` | `DENSITY=3`  | Print-density override.          |

`read_job_opts` parses the sidecar with an injection-safe reader (it is **not**
sourced): only the four keys above are honoured, values are trimmed, blanks and
`#` comments are skipped, and any other line is ignored. Anything the sidecar
omits falls back to the user config, then to the built-in default. Jobs without
a `.opts` file are wholly unaffected — the option variables take their default
values and the converter flag string is byte-identical to a plain job.

The `.opts` sidecar is removed together with its PDF once the job is processed.

## Duplex, N-up, copies

These options are realised against the two raster converters, whose flags were
taken from the extracted foo2zjs source (`vendor/foo2zjs-src.tar.gz`):

```
-d duplex         Duplex code to send to printer   (foo2zjs.c / foo2xqx.c usage)
-n copies         Number of copies
```

and the shared duplex enum in `hiperc.h` / `hbpl.h`:

```
DMDUPLEX_OFF = 1, DMDUPLEX_LONGEDGE = 2, DMDUPLEX_SHORTEDGE = 3,
DMDUPLEX_MANUALLONG = 4, DMDUPLEX_MANUALSHORT = 5
```

### Copies

- **ZjStream printers (foo2zjs)** encode the copy count into the stream, so the
  watcher passes `-n N` to the converter and pushes the raster **once**.
- **XQX printers (foo2xqx)** parse `-n` but never write it into the output
  stream, so `-n` is a no-op there. The watcher instead realises copies by
  **pushing the raster over USB `N` times**. The watcher logs which path it took.

### Duplex

`DUPLEX=long` → `-d 2` (long-edge), `DUPLEX=short` → `-d 3` (short-edge),
`DUPLEX=none` (the default) passes no `-d` flag.

Both converters accept `-d`, but **the supported models are overwhelmingly
simplex-only** (no hardware duplexer). The watcher passes the code through and
prints — but on a printer with no duplex unit the job simply comes out
one-sided. When a duplex mode is requested the watcher logs a NOTE to that
effect. Manual-duplex modes (codes 4/5), which reorder pages for the user to
re-feed, are intentionally **not** wired up: they need interactive paper
reinsertion that does not fit the unattended watcher.

### N-up

Neither `foo2zjs` nor `foo2xqx` has an N-up flag (their `-n` is *copies*, not
pages-per-sheet), so N-up cannot be produced in the raster stage. `NUP` is
parsed and validated, but any value greater than `1` is **ignored** and the job
prints 1-up; the watcher logs a NOTE explaining why. If you need true N-up,
impose it upstream (e.g. combine pages into the PDF before printing).

### Setting options without the print dialog

The macOS PDF Service workflow runs inside the print sandbox and cannot reliably
read the dialog's Copies/Two-Sided/Layout controls, so those UI settings are
**not** plumbed through. Instead set defaults in the user config file
(`DEFAULT_COPIES`, `DEFAULT_DUPLEX`, `DEFAULT_NUP`), and/or drop a per-job
`.opts` sidecar next to a freshly spooled `job-<ts>.pdf` before the watcher runs.
For example, to force two copies on the next job:

```sh
echo 'COPIES=2' > ~/HP-LaserJet-spool/job-<ts>.opts
```

As a convenience, if you create a **default options file** at
`~/.config/hp-laserjet/job.opts`, the PDF Service copies it to each new job's
`job-<ts>.opts` automatically — so every print you send through the dialog picks
up those options without any manual step:

```sh
mkdir -p ~/.config/hp-laserjet
printf 'COPIES=2\nDUPLEX=none\n' > ~/.config/hp-laserjet/job.opts
```
