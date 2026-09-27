# DNS-Failover-Explained.pdf — how it is built

`gen.py` produces `../Scripts/DNS-Failover-Explained.pdf`: a line-by-line
walkthrough, in Hebrew, of the three DNS failover scripts.

The prose lives in `blocks_a.py`, `blocks_b.py` and `blocks_c.py` as a list of
`(start_line, title, explanation)`. **The code shown in the document is not
stored here** — `common.py` pulls it out of the real script files by line
range at build time, so the document cannot drift from the repository.

Each block ends where the next one begins, so coverage is contiguous by
construction. `common.py` additionally asserts, on every build, that each line
of each script lands in exactly one block, and stops with an error naming the
gap or overlap if it does not.

## Rebuilding

Needed once: WeasyPrint, and Heebo as static instances next to this folder.

```
pip install weasyprint fonttools
mkdir -p fonts
curl -fsSLo fonts/Heebo-var.ttf \
  'https://raw.githubusercontent.com/google/fonts/main/ofl/heebo/Heebo%5Bwght%5D.ttf'
python -c "
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
for label, wght in (('Regular', 400), ('Bold', 700)):
    instancer.instantiateVariableFont(
        TTFont('fonts/Heebo-var.ttf'), {'wght': wght}).save(f'fonts/Heebo-{label}.ttf')
"
```

Then:

```
python gen.py
python -c "from weasyprint import HTML; HTML(filename='doc.html', base_url='.').write_pdf('../Scripts/DNS-Failover-Explained.pdf')"
```

## After editing a script

Line numbers move, so the block starts move with them. Adjust the `start_line`
values in the matching `blocks_*.py` and rebuild; the coverage check will point
at any range left inconsistent.
