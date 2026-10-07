# Workspace tools in the rho image

The published image includes development runtimes, headless Chromium, Office converters,
fonts and Python libraries for working with local files. Commands run as uid 1000 in the
mounted workspace. Save deliverables in that workspace so they survive container replacement.

## Finding this guide

rho's Coding extension lists this guide as the `workspace-tools` skill. Load it with
`skill` using `{"name":"workspace-tools"}` when choosing tools for a task. The guide
is read on demand from `/usr/local/share/cybros/workspace-tools.md`; only its name and
description are announced in advance. A project skill with the same name in the runner's
announced catalog takes precedence. Binding a conversation to another directory keeps
that same catalog available.

## Coding

`git`, `git-lfs`, `gh`, `rg`, `fd`, `jq`, `zip`, `unzip`, `xz`, C/C++ compilers,
`cmake`, `ninja`, `sqlite3`, and common development headers are installed. The preinstalled
project runtimes are Node LTS with npm, Go, Rust Stable and Python 3.14. Node, Go and Rust
are managed by `mise`; Python is managed by `uv`. Rust includes cargo, rustc, rustfmt and
clippy without the rust-docs component. `pnpm`, `prettier`, `eslint`, `typescript`, `ruff`,
`pyright` and `mypy` are available. Image releases pin concrete runtime versions in the
install manifest; LTS and Stable describe how those versions are selected.
Credentials are not included; authenticate services only when the task calls for them.

### Additional project runtimes

Java, project Ruby and Bun are not preinstalled. mise reads the project's runtime version
files; run `mise install` in a project that already declares its versions. For a project
that needs a new runtime, install and record its resolved version with the relevant command:

```sh
mise use --pin ruby@4
mise use --pin java@25
mise use --pin bun@1
```

Choose the runtime and version the project needs; these commands update its mise configuration
and require network access for uncached downloads. rho's own portable Ruby is independent of
project Ruby. The default rho user's `~/.gemrc` sets RubyGems to `--no-document`.

`uv` and `uvx` are available, with Python 3.14 preinstalled. Install another Python only when
the project needs it, for example `uv python install 3.13`. Run project commands with that
version using `uv run --python 3.13 python script.py`; their dependencies remain separate
from the Cowork environment below.

## Documents, spreadsheets, slides, PDFs and images

`python` and `python3` default to `/opt/cowork/bin`, a Python 3.14 virtual environment.
It includes `python-docx`, `openpyxl`, `python-pptx`, `pypdf`, `reportlab`, `Pillow`,
`pandas` and `matplotlib`. Use these imports directly:

```python
from docx import Document
from openpyxl import Workbook, load_workbook
from pptx import Presentation
from pypdf import PdfReader, PdfWriter
from reportlab.pdfgen import canvas
from PIL import Image
import pandas as pd
import matplotlib.pyplot as plt
```

An explicitly activated project virtual environment takes precedence. `uv run` uses the
project's own dependencies; it does not inherit the Cowork library set. No global
`VIRTUAL_ENV` or `PYTHONPATH` is set. The host installer and the rho gem do not install
this image-only environment.

LibreOffice Writer, Calc and Impress provide headless rendering. Give each concurrent
conversion its own profile directory, then render the PDF for visual inspection:

```sh
mkdir -p output
profile=$(mktemp -d)
libreoffice "-env:UserInstallation=file://$profile" --headless \
  --convert-to pdf --outdir output report.docx
pdftoppm -png -scale-to 1600 output/report.pdf output/report-page
pdftotext output/report.pdf -
rm -rf "$profile"
```

The same conversion accepts `.xlsx` and `.pptx`. `openpyxl` writes formulas but does
not calculate them; LibreOffice calculates them when opening/rendering a workbook.
Noto core and CJK, DejaVu and Liberation fonts are installed. Use `fc-match` to select
an available font; `Noto Sans CJK SC` covers Simplified Chinese. Inspect rendered
pages for clipping, overlap, missing glyphs and pagination before delivering them.
Poppler provides PDF inspection/rendering, Pillow handles raster images, and FFmpeg
handles audio/video conversion and frame extraction.

## Browser QA

rho's existing browser extension supplies `browser_navigate`, `browser_snapshot`,
`browser_click`, `browser_type`, `browser_screenshot` and `browser_evaluate` when
`rho/browser` is enabled in the home's extension settings. The image supplies its
matching Node/Playwright driver and Chromium headless shell in advance. Installing
these dependencies does not enable the extension or start a browser.

`rho-playwright --version` checks the installed driver. This wrapper scopes the
browser cache to rho's own installation; a project's Playwright installation keeps
its own dependencies. Use the exposed rho browser tools for interactive QA rather
than installing another browser driver or downloading a second Chromium.
