# -*- coding: utf-8 -*-
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from common import resolve, code_html
from blocks_a import BLOCKS_A, FILE_A
from blocks_b import BLOCKS_B, FILE_B
from blocks_c import BLOCKS_C, FILE_C

CSS = """
  @font-face { font-family:'Heebo'; src:url('fonts/Heebo-Regular.ttf'); font-weight:400; }
  @font-face { font-family:'Heebo'; src:url('fonts/Heebo-Bold.ttf'); font-weight:700; }

  @page {
    size: letter; margin: 18mm 16mm 16mm 16mm;
    @bottom-center { content: counter(page); font-family:'Heebo'; font-size:8.5pt; color:#888; }
  }
  @page :first { @bottom-center { content: ""; } }

  body { font-family:'Heebo', sans-serif; direction:rtl; font-size:10.5pt;
         line-height:1.72; color:#1a1a1a; }

  h1 { font-size:20pt; line-height:1.3; margin:0 0 6px; color:#0b2545; font-weight:700; }
  .sub { font-size:10.5pt; color:#4a5568; margin:0 0 4px; line-height:1.6; }
  .rule { border-bottom:2.5px solid #0b2545; margin:10px 0 20px; }

  h2 { font-size:15pt; color:#fff; background:#0b2545; font-weight:700;
       margin:0 0 14px; padding:8px 12px; break-before:page; break-after:avoid; }
  h2.first { break-before:auto; }
  h3 { font-size:12.5pt; color:#0b2545; font-weight:700; margin:20px 0 8px;
       padding-bottom:4px; border-bottom:1px solid #cbd5e0; break-after:avoid; }
  p { margin:0 0 9px; orphans:2; widows:2; }
  ul, ol { margin:0 0 10px; padding-right:20px; padding-left:0; }
  li { margin-bottom:5px; }

  code, .en { font-family:'DejaVu Sans Mono', monospace; font-size:9pt;
              direction:ltr; unicode-bidi:isolate; background:#eef2f7;
              padding:1px 4px; border-radius:3px; color:#1a365d; white-space:nowrap; }

  /* One walkthrough block: the line-range tab, the source, then the prose. */
  /* The heading must not be orphaned from its code, and a code listing must not
     be split, but the prose after it may flow to the next page. Keeping whole
     blocks together instead left a third of every page empty. */
  .blk { margin:0 0 20px; }
  .blk-head { display:flex; align-items:baseline; gap:10px; margin:0 0 6px;
              border-right:3px solid #0b2545; padding:3px 9px 3px 0; background:#eef2f7;
              break-after:avoid; break-inside:avoid; }
  .blk-lines { font-family:'DejaVu Sans Mono', monospace; font-size:8.5pt;
               direction:ltr; unicode-bidi:isolate; color:#0b2545; font-weight:700;
               background:#fff; border:1px solid #c3ced9; padding:1px 6px; border-radius:3px;
               white-space:nowrap; }
  .blk-title { font-weight:700; font-size:11pt; color:#0b2545; }

  pre { font-family:'DejaVu Sans Mono', monospace; font-size:7.9pt; line-height:1.5;
        direction:ltr; unicode-bidi:isolate-override; text-align:left;
        background:#f7f9fc; border:1px solid #d8e0ea; border-right:3px solid #7d8da1;
        padding:8px 10px; margin:0 0 8px; white-space:pre-wrap;
        overflow-wrap:break-word; break-inside:avoid; orphans:3; widows:3; }
  pre code { background:none; padding:0; font-size:7.9pt; white-space:pre-wrap; }
  /* Hanging indent per source line: a wrapped line is visibly a continuation. */
  .cl { display:block; padding-left:2.2em; text-indent:-2.2em; }

  table { width:100%; border-collapse:collapse; margin:10px 0 15px; font-size:9.3pt;
          break-inside:avoid; }
  th, td { border:1px solid #c3ced9; padding:6px 9px; text-align:right;
           vertical-align:top; line-height:1.6; }
  th { background:#0b2545; color:#fff; font-weight:700; }
  tr:nth-child(even) td { background:#f6f8fb; }
  td.mono, th.mono { direction:ltr; unicode-bidi:isolate; text-align:left;
                     font-family:'DejaVu Sans Mono', monospace; font-size:8.3pt; }

  .note { background:#fff8e6; border:1px solid #f0d89b; border-right:3px solid #d99b16;
          padding:9px 12px; margin:11px 0; font-size:9.8pt; break-inside:avoid; }
  .warn { background:#fdf0ef; border:1px solid #f2c3bf; border-right:3px solid #c0392b;
          padding:9px 12px; margin:11px 0; font-size:9.8pt; break-inside:avoid; }
  .ok   { background:#eef8f0; border:1px solid #bfdfc7; border-right:3px solid #27823b;
          padding:9px 12px; margin:11px 0; font-size:9.8pt; break-inside:avoid; }
  .note p:last-child, .warn p:last-child, .ok p:last-child { margin-bottom:0; }
  .lbl { font-weight:700; }

  .toc { background:#f6f8fb; border:1px solid #d8e0ea; padding:10px 14px; margin:0 0 6px;
         font-size:9.8pt; }
  .toc ol { margin:6px 0 0; }
  .toc li { margin-bottom:3px; }
  .footer { margin-top:24px; padding-top:9px; border-top:1px solid #cbd5e0;
            font-size:8.5pt; color:#6b7280; line-height:1.65; }
"""


def render_blocks(blocks):
    out = []
    for start, end, title, expl, code in blocks:
        rng = f"{start}" if start == end else f"{start}–{end}"
        out.append(
            '<div class="blk">\n'
            f'  <div class="blk-head"><span class="blk-lines">{rng}</span>'
            f'<span class="blk-title">{title}</span></div>\n'
            f'  <pre><code>{code_html(code)}</code></pre>\n'
            f'  {expl}\n'
            '</div>'
        )
    return "\n".join(out)


a, total_a = resolve(BLOCKS_A, FILE_A)
b, total_b = resolve(BLOCKS_B, FILE_B)
c, total_c = resolve(BLOCKS_C, FILE_C)

INTRO = pathlib.Path(__file__).with_name("intro.html").read_text(encoding="utf-8")
OUTRO = pathlib.Path(__file__).with_name("outro.html").read_text(encoding="utf-8")

INTRO = (INTRO.replace("{{TOTAL_A}}", str(total_a))
              .replace("{{TOTAL_B}}", str(total_b))
              .replace("{{TOTAL_C}}", str(total_c))
              .replace("{{BLOCKS_A}}", str(len(a)))
              .replace("{{BLOCKS_B}}", str(len(b)))
              .replace("{{BLOCKS_C}}", str(len(c)))
              .replace("{{TOTAL_ALL}}", str(total_a + total_b + total_c))
              .replace("{{BLOCKS_ALL}}", str(len(a) + len(b) + len(c))))

html_doc = f"""<!DOCTYPE html>
<html lang="he" dir="rtl">
<head>
<meta charset="utf-8">
<title>סקריפטי ה-DNS Failover — הסבר שורה אחר שורה</title>
<style>{CSS}</style>
</head>
<body>
{INTRO}

<h2>‏2. סקריפט א' — הגרסה המקורית, שורה אחר שורה</h2>
<p>הקובץ <code>{FILE_A}</code>, {total_a} שורות, ב-{len(a)} מקטעים רצופים.
זוהי הגרסה שתומללה מההדפסה ולא נערכה. היא נשמרה בריפו כפי שהיא, כדי שאפשר יהיה להשוות.</p>
{render_blocks(a)}

<h2>‏3. סקריפט ב' — הגרסה המתוקנת, שורה אחר שורה</h2>
<p>הקובץ <code>{FILE_B}</code>, {total_b} שורות, ב-{len(b)} מקטעים רצופים.
אותה החלטה עסקית כמו בגרסה המקורית, עם טיפול בשגיאות, לוג, ולידציה ותצוגה מקדימה.</p>
{render_blocks(b)}

<h2>‏4. סקריפט ג' — בלי Alteon ובלי שרתי web, שורה אחר שורה</h2>
<p>הקובץ <code>{FILE_C}</code>, {total_c} שורות, ב-{len(c)} מקטעים רצופים.
כאן ההחלטה עצמה שונה: במקום לשאול load balancer על שרתי ה-web שמאחוריו,
הסקריפט מברר איזה שרת SolarWinds פעיל, והרשומה עוקבת אחריו.</p>
{render_blocks(c)}

{OUTRO}
</body>
</html>"""

out = pathlib.Path(__file__).with_name("doc.html")
out.write_text(html_doc, encoding="utf-8")
print(f"wrote {out}")
print(f"  script A: {len(a):>2} blocks / {total_a:>3} lines")
print(f"  script B: {len(b):>2} blocks / {total_b:>3} lines")
print(f"  script C: {len(c):>2} blocks / {total_c:>3} lines")
print(f"  total:    {len(a)+len(b)+len(c)} blocks / {total_a+total_b+total_c} lines, all contiguous")
