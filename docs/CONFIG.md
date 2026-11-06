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
# DEFAULT_DUPLEX=none
# DEFAULT_NUP=1
NOTIFY=all
EOF
```

### Keys

| Key              | Values              | Default | Meaning                                                        |
|------------------|---------------------|---------|----------------------------------------------------------------|
| `PAPER`          | `auto` \| `letter` \| `a4` \| `legal` \| `a5` \| `executive` \| `com10` \| `dl` | `auto`  | Paper size. `auto` detects A4 vs US Letter from the PDF page height (current behaviour); any other value forces the size and raster grid. See [Paper sizes](#paper-sizes). |
| `SCALE`          | positive integer percent, or unset | unset | Scale the page during rasterisation (e.g. `90` = 90 %). Unset = no scaling (identical to prior behaviour). See [Scale and margin](#scale-and-margin). |
| `MARGIN`         | non-negative integer points, or unset | unset | Uniform blank border inset, in points (72 pt = 1 in), applied during rasterisation. Unset/`0` = none (identical to prior behaviour). See [Scale and margin](#scale-and-margin). |
| `DENSITY`        | `1`–`5`, or unset   | unset   | Print density. When unset, no override is added and the driver default is used. See [Print quality / density](#print-quality--density). |
| `ECONOMODE`      | `on` \| `off`, or unset | unset | Toner-save / draft mode. `off`/unset adds no flag. See [Print quality / density](#print-quality--density). |
| `DEFAULT_COPIES` | integer ≥ 1         | `1`     | Default number of copies per job when a job does not specify its own. |
| `DEFAULT_DUPLEX` | `none` \| `long` \| `short` \| `manual` | `none`  | Default duplex mode per job. `manual` = two-sided by hand (see [Two-sided printing by hand](#two-sided-printing-by-hand-duplexmanual)). `long`/`short` need a hardware duplexer, which most supported models lack. |
| `DEFAULT_NUP`    | integer ≥ 1         | `1`     | Default pages-per-sheet. Only `1` is honoured; the converters have no N-up (see below). |
| `NOTIFY`         | `all` \| `errors` \| `none` | `all` | macOS notifications on job completion (see below). |
| `PRINTER`        | USB PID or name substring, or unset | unset | Which printer to use when **several** supported printers are attached. See "Selecting a printer" below. Ignored when only one supported printer is present. |

An unrecognised or empty `PAPER` value falls back to `auto`; a non-positive or
non-integer `SCALE` is ignored (no scaling); a negative or non-integer `MARGIN`
is ignored (no inset); an empty `DEFAULT_COPIES` falls back to `1`; an
unrecognised `DEFAULT_DUPLEX` falls back to `none`; a non-integer `DEFAULT_NUP`
falls back to `1`; an unrecognised or empty `NOTIFY` falls back to `all`.

> **Note:** `PAPER=auto`, `SCALE` unset, `MARGIN` unset, `DENSITY` unset,
> `ECONOMODE` unset, `DEFAULT_COPIES=1`, `DEFAULT_DUPLEX=none`, `DEFAULT_NUP=1`,
> `NOTIFY=all` and `PRINTER` unset (the defaults) reproduce today's behaviour
> exactly — the converter flag string is byte-for-byte identical to running with
> no config, the Ghostscript command line is unchanged (no page transform is
> injected), and notifications are informational only.

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
that take precedence over the user config file for that one job. Recognised keys:

| Key         | Example         | Meaning                                             |
|-------------|-----------------|-----------------------------------------------------|
| `PRINTER`   | `PRINTER=0x3d17`| Route this one job to a specific printer when several are attached (PID or product-name substring). |
| `COPIES`    | `COPIES=2`      | Number of copies for this job.                      |
| `DUPLEX`    | `DUPLEX=manual` | Two-sided printing: `manual` (by hand, any printer), or `long`\|`short` (hardware duplexer only), or `none`. |
| `PAGES`     | `PAGES=3-7,10`  | Print only these pages (comma-separated pages and ascending ranges). Works one-sided and two-sided. |
| `NUP`       | `NUP=2`         | Pages per sheet (N-up).                             |
| `DENSITY`   | `DENSITY=3`     | Print-density override (`1`–`5`) for this job.      |
| `ECONOMODE` | `ECONOMODE=on`  | Toner-save / draft mode for this job.               |
| `PAPER`     | `PAPER=legal`   | Paper size for this job (`auto`\|`letter`\|`a4`\|`legal`\|`a5`\|`executive`\|`com10`\|`dl`). |
| `SCALE`     | `SCALE=90`      | Scale the page to N % during rasterisation.         |
| `MARGIN`    | `MARGIN=18`     | Uniform blank border inset in points for this job.  |

`read_job_opts` parses the sidecar as a small `KEY=value` allow-list — it is
**not** sourced, so a stray line cannot run code or clobber other variables.
For each job it first resets the per-job variables to their config/default
values, then applies any recognised keys from the sidecar; a sidecar value
therefore overrides the user config for that one job. Jobs without a `.opts`
file are wholly unaffected. `PRINTER` (routing, see "Selecting a printer"),
print-quality keys (`DENSITY`, `ECONOMODE`), page-geometry keys (`PAPER`,
`SCALE`, `MARGIN`) and `COPIES` / `DUPLEX` / `NUP` are all handled; unknown keys
are ignored so multiple features can share one sidecar.

Every key in the user-config table above is also **per-job-sidecar-capable** —
`PAPER`, `SCALE` and `MARGIN` included — so a `.opts` value overrides the config
default for that one job.

The `.opts` sidecar is removed together with its PDF once the job is processed.

## Paper sizes

`PAPER=auto` (the default) keeps the original behaviour: the watcher reads the
PDF's page height with `pdfinfo` and picks **A4** (height > 820 pt, i.e. 842 pt)
or **US Letter** (everything else). Nothing else is auto-detected.

Set `PAPER` explicitly (in the config file or a per-job `.opts`) to force a size
regardless of the PDF. Each name maps to the printer's `-p` **paper code** and a
matching raster grid `-g<W>x<H>`. The paper codes are the converters' own
`DMPAPER_*` numbering (`hbpl.h` / `hiperc.h` in `vendor/foo2zjs-src.tar.gz`,
identical in both `foo2zjs` and `foo2xqx`, and echoed in each tool's
`-p` usage line):

| `PAPER`     | `-p` code | `DMPAPER_*`     | Size            | Base 600-dpi grid (W×H) |
|-------------|-----------|-----------------|-----------------|--------------------------|
| `letter`    | `1`       | `LETTER`        | 8.5 × 11 in     | 5100 × 6600 |
| `legal`     | `5`       | `LEGAL`         | 8.5 × 14 in     | 5100 × 8400 |
| `executive` | `7`       | `EXECUTIVE`     | 7.25 × 10.5 in  | 4350 × 6300 |
| `a4`        | `9`       | `A4`            | 210 × 297 mm    | 4960 × 7016 |
| `a5`        | `11`      | `A5`            | 148 × 210 mm    | 3500 × 4960 |
| `com10`     | `20`      | `ENV_10`        | #10 env, 4.125 × 9.5 in | 2475 × 5700 |
| `dl`        | `27`      | `ENV_DL`        | DL env, 110 × 220 mm | 2600 × 5200 |

The grid is the page size in 600-dpi pixels (inches × 600). For the 1200 × 600
models (`XSCALE=2`) the **width** is doubled by `grid_for()` before it reaches
Ghostscript and the converter, exactly as for the pre-existing Letter/A4 grids;
the height is unchanged. `a5`/`dl` widths are rounded to the same round-number
convention as the existing `a4` grid (4960 vs the exact 4961).

The PDF is fitted into that grid with Ghostscript's `-dFIXEDMEDIA -dPDFFitPage`
(as before), so a document whose page differs from the selected paper is scaled
to fit rather than clipped. An unknown or empty `PAPER` value falls back to
`auto`, which in turn falls back to Letter — so behaviour for anything the
watcher does not recognise is unchanged.

## Scale and margin

`SCALE` and `MARGIN` are applied **only** in the Ghostscript rasterisation step,
via a small PostScript `/BeginPage` prologue injected with `-c … -f`. When both
are unset (the default) **no** prologue is injected and the `gs` command line is
byte-for-byte identical to the pre-feature invocation — the raster converter and
its flags are untouched either way.

- **`SCALE=<percent>`** scales the page about its centre (e.g. `SCALE=90`
  prints at 90 %, `SCALE=110` enlarges). Only a positive integer is accepted;
  `0`, a non-integer, or `auto`/empty is logged and ignored (no scaling).
- **`MARGIN=<points>`** insets a uniform blank border of N points (72 pt = 1
  inch) on all four sides. The content is scaled down uniformly (aspect
  preserved) and re-centred so it fits inside the reduced area rather than being
  clipped. `0`, a negative value, a non-integer, or empty is ignored (no inset).

The two compose: the net scale is `SCALE/100 × (paper − 2·MARGIN)/paper` (taking
the smaller of the width/height insets so the aspect ratio is preserved), and
the content is re-centred on the page. Because these run entirely inside
Ghostscript they never touch the converter's `-r`/`-g`/`-p` geometry, so they
cannot desync the paper grid.

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
effect. For two-sided output on these printers use `DUPLEX=manual` below
(the converters' own manual-duplex codes 4/5 are not used: they rely on a
printer-panel resume and rotate the backs, which doesn't match HP's reload
instructions).

### Two-sided printing by hand (`DUPLEX=manual`)

For one-sided printers. The watcher prints the **front sides**, shows a dialog
asking you to put the stack back in, then prints the **back sides in reverse
order**:

1. Fronts print: positions 1, 3, 5, … of the job.
2. Dialog: take the whole stack from the output tray **without reordering it**
   and put it in the input tray **printed side down, top of the pages going in
   first** (HP's P1100-series instructions). Click **Print back sides**.
3. Backs print in reverse: …, 6, 4, 2. The printer loads face-up and delivers
   face-down, so the last front ends up on top and is fed first.

Rules that keep every back on the right sheet:

- **Odd page count**: the last sheet has no back. It's on top of the reloaded
  stack, so the backs start with a **blank**: 5 pages → fronts 1 3 5, backs
  blank 4 2.
- **Page subsets** (`PAGES=`, a Print-dialog range, or Folio's page picker):
  the split uses the order of the pages being printed. `PAGES=3-7` → fronts
  3 5 7, backs blank 6 4.
- **Copies**: each copy starts on a fresh sheet (an odd-length copy gets a
  blank back), and all fronts print before the single flip.
- **One page**: nothing to put on a back, so it prints one-sided.

If the dialog is answered **Cancel back sides**, the job ends after the fronts.
If it goes unanswered for an hour, or the backs fail to print, the job is saved
as "back sides only" and you're asked again later (see failed jobs). Reprinting
it sends only the backs.

If your backs come out upside down, reload the stack rotated 180° instead.

Ways to request it: the **"Print on HP LaserJet (two-sided)"** entry in the
Print dialog's PDF menu, Folio PDF's **Sides: Both sides** switch, a per-job
`DUPLEX=manual` sidecar, or `DEFAULT_DUPLEX=manual` in the config.

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
