# -*- coding: utf-8 -*-
"""Render each PowerShell script as its own printable PDF listing.

One PDF per script, named after it, matching the convention the repository
already uses for Redact-FileContent.pdf and Search-FilesForWord.pdf. Line
numbers are included so a listing can be read alongside
DNS-Failover-Explained.pdf, which refers to the code by line range.

The code is read from the .ps1 files at build time, so a listing cannot
drift from the script it documents.
"""
import html
import pathlib
import sys

from weasyprint import HTML

SCRIPTS = pathlib.Path(__file__).resolve().parent.parent / "Scripts"
HERE = pathlib.Path(__file__).resolve().parent

LISTINGS = [
    ("DNS.SetSolarWindsRecordToActiveLB.ps1",
     "PowerShell script - points the SolarWinds DNS record at a data centre's load balancer, "
     "based on the health of its web servers read over SNMP. Transcribed from the printed "
     "original and left unedited."),
    ("DNS.SetSolarWindsRecordToActiveLB.v2.ps1",
     "PowerShell script - the same decision as the original, reworked: SNMP failures are "
     "handled rather than fatal, a data centre is polled more than once before being declared "
     "down, and the run is logged, validated and previewable with -WhatIf."),
    ("DNS.SetSolarWindsRecordToActiveServer.ps1",
     "PowerShell script - no load balancer and no SNMP. It is told which SolarWinds server has "
     "become active and points the DNS record straight at it."),
    ("NexusDashboard.Connect.ps1",
     "PowerShell script - reads the switches managed by Cisco Nexus Dashboard (Fabric "
     "Controller) over its REST API, logging in through the TACACS login domain, and adds "
     "them to SolarWinds as nodes with their pollers and interfaces, the way "
     "DNA.DiscoverNodesAndInterfaces.ps1 does it for Cisco DNA Center. Every run is logged."),
]

CSS = """
  @page {
    size: letter; margin: 16mm 14mm 14mm 14mm;
    @bottom-right { content: counter(page) " / " counter(pages);
                    font-family:'DejaVu Sans', sans-serif; font-size:8pt; color:#888; }
    @bottom-left  { content: string(fname);
                    font-family:'DejaVu Sans Mono', monospace; font-size:7.5pt; color:#888; }
  }
  body { font-family:'DejaVu Sans', sans-serif; color:#111; margin:0; }

  h1 { font-family:'DejaVu Sans Mono', monospace; font-size:13pt; font-weight:700;
       margin:0 0 4px; color:#0b2545; string-set: fname content(); }
  .desc { font-size:9pt; line-height:1.5; color:#444; margin:0 0 10px; }
  .meta { font-size:7.5pt; color:#888; margin:0 0 12px;
          border-bottom:1.5px solid #0b2545; padding-bottom:8px; }

  table.code { width:100%; border-collapse:collapse;
               font-family:'DejaVu Sans Mono', monospace; font-size:7.6pt; }
  table.code td { padding:0; vertical-align:top; line-height:1.42; }
  /* The number column is fixed and right-aligned so the code starts at one
     column throughout, the way a printed listing reads. */
  td.n { width:11mm; text-align:right; padding-right:4mm; color:#9aa5b1;
         border-right:1px solid #dde3ea; user-select:none; }
  td.l { padding-left:4mm; white-space:pre-wrap; overflow-wrap:break-word; }
  /* A line too wide for the page wraps with a hanging indent, so the
     continuation is not mistaken for a new statement. */
  td.l > span { display:block; padding-left:2.2em; text-indent:-2.2em; }
  tr.blank td { line-height:1.42; }
"""


def build(filename, description):
    path = SCRIPTS / filename
    lines = path.read_text(encoding="utf-8").split("\n")
    while lines and lines[-1] == "":
        lines.pop()

    rows = []
    for i, line in enumerate(lines, start=1):
        cls = ' class="blank"' if not line.strip() else ""
        body = f"<span>{html.escape(line)}</span>" if line else "&nbsp;"
        rows.append(f'<tr{cls}><td class="n">{i}</td><td class="l">{body}</td></tr>')

    doc = f"""<!DOCTYPE html>
<html lang="en" dir="ltr">
<head><meta charset="utf-8"><title>{html.escape(filename)}</title>
<style>{CSS}</style></head>
<body>
<h1>{html.escape(filename)}</h1>
<p class="desc">{html.escape(description)}</p>
<p class="meta">{len(lines)} lines &middot; Scripts/{html.escape(filename)}</p>
<table class="code">
{chr(10).join(rows)}
</table>
</body></html>"""

    out = SCRIPTS / (filename[:-4] + ".pdf")
    HTML(string=doc, base_url=str(HERE)).write_pdf(out)
    return out, len(lines)


if __name__ == "__main__":
    wanted = sys.argv[1:]
    for filename, description in LISTINGS:
        if wanted and filename not in wanted:
            continue
        out, n = build(filename, description)
        print(f"{out.name:<48} {n:>4} lines  {out.stat().st_size:>7} bytes")
