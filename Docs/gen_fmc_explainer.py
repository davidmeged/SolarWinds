"""Build ../Scripts/FMC-Integration-Explained.pdf - a Hebrew (RTL) explainer of
Scripts/FMC.DiscoverNodes.ps1, laid out like DNA-Integration-Explained.pdf.

The prose lives here; the code shown in the document does not. Every code
block is cut out of the real script at build time between two anchor lines,
and the build stops with an error if an anchor is missing, so the document
cannot quietly drift from the script.

    pip install weasyprint
    python gen_fmc_explainer.py
"""

import html
import re
import sys
from pathlib import Path

HERE   = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "Scripts" / "FMC.DiscoverNodes.ps1"
OUTPUT = HERE.parent / "Scripts" / "FMC-Integration-Explained.pdf"

LINES = SCRIPT.read_text(encoding="utf-8-sig").splitlines()


# --------------------------------------------------------------------------
# Code extraction
# --------------------------------------------------------------------------

def _find(text, start=0, exact=False):
    for i in range(start, len(LINES)):
        line = LINES[i].rstrip()
        if (line == text) if exact else (text in line):
            return i
    sys.exit(f"anchor not found in {SCRIPT.name}: {text!r}")


def cut(start, end, end_exact=False, drop_help=True, after=None):
    """Lines from the first one containing `start` to the first one after it
    containing `end` (or equal to it with end_exact), dedented. Comment-based
    help blocks (<# ... #>) inside the cut are left out."""
    s = _find(start, _find(after) if after else 0)
    e = _find(end, s + 1, exact=end_exact)
    out, in_help = [], False
    for line in LINES[s:e + 1]:
        stripped = line.strip()
        if drop_help and stripped == "<#":
            in_help = True
            continue
        if in_help:
            if stripped == "#>":
                in_help = False
            continue
        out.append(line)
    indent = min(len(l) - len(l.lstrip()) for l in out if l.strip())
    return "\n".join(l[indent:] for l in out)


def function(name):
    return cut(f"function {name} {{", "}", end_exact=True)


# --------------------------------------------------------------------------
# PowerShell highlighting
# --------------------------------------------------------------------------

TOKEN = re.compile(r"""
    (?P<str>"(?:[^"`]|`.)*"|'[^']*')
  | (?P<com>\#[^\n]*)
  | (?P<var>\$\{[^}]+\}|\$[A-Za-z_][\w:]*)
  | (?P<op>(?<=\s)-(?:eq|ne|lt|le|gt|ge|match|notmatch|contains|notcontains|in|and|or|not|band|bor|shl|shr)\b)
  | (?P<kw>\b(?:function|param|if|elseif|else|foreach|for|in|try|catch|finally|return|do|while|continue|throw|exit)\b)
  | (?P<cmd>\b[A-Z][a-z]+-[A-Z][A-Za-z]+\b)
  | (?P<type>\[[A-Za-z][\w.]*(?:\[\])?\])
""", re.VERBOSE)


def highlight(code):
    out, pos = [], 0
    for m in TOKEN.finditer(code):
        out.append(html.escape(code[pos:m.start()]))
        out.append(f'<span class="{m.lastgroup}">{html.escape(m.group())}</span>')
        pos = m.end()
    out.append(html.escape(code[pos:]))
    return "".join(out)


def pre(code):
    return f'<pre dir="ltr">{highlight(code)}</pre>'


# --------------------------------------------------------------------------
# Hebrew text helpers
# --------------------------------------------------------------------------

def heb(text):
    """A one-letter Hebrew prefix glued to a Latin word or to code ("ל-FMC",
    "ה-<code>") gets a non-breaking hyphen, so the line never breaks between
    the prefix and the word it belongs to."""
    return re.sub(r"(?<![\u05d0-\u05ea])([בהולמשכ])-(?=[A-Za-z0-9$<\[])", "\\1\u2011", text)


def c(text):
    return f"<code>{html.escape(text)}</code>"


def table(headers, rows, cls=""):
    head = "".join(f"<th>{h}</th>" for h in headers)
    body = "".join("<tr>" + "".join(f"<td>{cell}</td>" for cell in row) + "</tr>" for row in rows)
    return f'<table class="{cls}"><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>'


def h2(num, title):
    return f'<h2><span class="num">{num}.</span> {title}</h2>'


def box(kind, title, body):
    return f'<div class="box {kind}"><div class="box-title">{title}</div>{body}</div>'


# --------------------------------------------------------------------------
# Document
# --------------------------------------------------------------------------

S = []

FILTER_RE = r"TenGigabitEthernet|TenGigE|Te\d|Port-channel|Po\d"

S.append(f"""
<h1>אינטגרציית Cisco FMC ל-SolarWinds — הסבר</h1>
<div class="lead">
<p>איך {c("Scripts/FMC.DiscoverNodes.ps1")} מושך מ-Cisco Secure Firewall Management Center (FMC) את רשימת
מכשירי ה-FTD שהוא מנהל, רושם כל מכשיר כ-Node ב-SolarWinds, מוסיף לניטור רק את הממשקים שנבחרו,
ומתעד כל פעולה כזאת בלוג.</p>
</div>
<p class="sub">מסמך מקביל ל-DNA-Integration-Explained.pdf, עבור מסלול ה-FMC.</p>
""")

# 1 ------------------------------------------------------------------------
S.append(h2(1, "מה האוטומציה הזאת עושה"))
S.append(f"""
<p>המטרה היא לקחת את כל מכשירי ה-FTD שרשומים ב-FMC, לרשום כל אחד מהם כ-Node מנוטר ב-SolarWinds,
ואז לגלות את הממשקים של אותו Node ולהוסיף לניטור רק את אלה שעומדים בקריטריון מוגדר.</p>
<p>כמו בסקריפט ה-DNA, הכול נמצא בקובץ אחד שרץ מקצה לקצה. הוא עובר את השלבים הבאים לפי הסדר:</p>
""")
S.append(table(
    ["שלב", "פונקציה / קטע", "תפקיד"],
    [
        ["1", f"{c('Write-Log')} / {c('Invoke-LogRotation')}", "פותח את הלוג של ההרצה ומבצע רוטציה אם הקובץ חרג מהגודל שהוגדר."],
        ["2", c("Connect-Fmc"), "מתחבר ל-FMC ב-Basic Auth ושומר את ה-token, ה-refresh token וה-UUID של ה-Global domain."],
        ["3", c("Invoke-FmcApi"), "מבצע כל קריאה ל-API. מחדש את ה-token כשהוא פג (401) וממתין כשעוברים את מגבלת הקצב (429)."],
        ["4", c("Get-FmcDeviceRecords"), "מושך את רשימת המכשירים המנוהלים, עמוד אחרי עמוד."],
        ["5", f"{c('Stop-Sessions')} + {c('Connect-Swis')} + בניית {c('$components')}", "מבטל את ה-token של FMC, מתחבר ל-SolarWinds, ממיר כל כתובת ניהול ל-IPv4 ובונה את רשימת הרכיבים."],
        ["6", c("Add-Component"), "יוצר Node חדש ב-SolarWinds ורושם עבורו את ארבעת ה-pollers הסטנדרטיים."],
        ["7", c("Add-DiscoveredInterfaces"), "מגלה את ממשקי ה-Node, מסנן לפי רשימת ההיתר, מוסיף את הנותרים ורושם בלוג רק את מה שנוסף בפועל."],
        ["8", c("Stop-Sessions"), "סוגר את החיבור ל-SWIS וכותב שורת סיכום."],
    ],
    cls="stages",
))
S.append(box("note", "מה שונה כאן מול מסלול ה-DNA", f"""
<p>הצד של SolarWinds כמעט זהה לסקריפט ה-DNA. ההבדלים הם בצד של FMC, וכל אחד מהם קיבל קוד משלו:</p>
<ul>
<li>ה-token חוזר ב-headers של התשובה ולא בגוף שלה.</li>
<li>ה-token תקף 30 דקות בלבד, ואפשר לחדש אותו עד שלוש פעמים.</li>
<li>ל-API יש מגבלת קצב של 120 קריאות לדקה.</li>
<li>ל-FMC יש endpoint לביטול ה-token, והסקריפט משתמש בו מיד אחרי שרשימת המכשירים נמשכה.</li>
<li>כתובת הניהול של מכשיר יכולה להיות שם DNS ולא כתובת IP.</li>
</ul>
"""))

# 2 ------------------------------------------------------------------------
S.append(h2(2, "התחברות ל-FMC וקבלת token"))
S.append(f"""
<p>הפונקציה {c("Connect-Fmc")} בונה כותרת {c("Authorization: Basic")} משם המשתמש והסיסמה (בפורמט
{c("user:password")}, מקודדים ב-Base64), ושולחת {c("POST")} אל {c("/api/fmc_platform/v1/auth/generatetoken")}
בלי גוף. התשובה חוזרת בלי body: כל המידע נמצא ב-headers. לכן הקריאה נעשית ב-{c("Invoke-WebRequest")}
ולא ב-{c("Invoke-RestMethod")}, שמחזיר רק את הגוף.</p>
""")
S.append(pre(function("Connect-Fmc")))
S.append(f"""
<p>התוצאה היא אובייקט session אחד. כל שאר הפונקציות מקבלות אותו בפרמטר {c("-Session")}, במקום משתנים
נפרדים לכל ערך:</p>
""")
S.append(table(
    ["שדה", "למה הוא משמש"],
    [
        [c("Server"), "בניית ה-URL בכל קריאה."],
        [c("AccessToken"), f"נשלח בכותרת {c('X-auth-access-token')} בכל קריאה."],
        [c("RefreshToken"), f"חידוש ה-token אחרי 30 דקות ({c('Update-FmcToken')})."],
        [c("DomainUuid"), f"חלק מה-URL: {c('/domain/{UUID}/devices/...')}"],
        [c("RefreshCount"), "מונה חידושים. FMC מאפשר עד שלושה, ואחר כך צריך להתחבר מחדש."],
        [c("TrustAllCertificates"), "כדי שגם הקריאות הבאות ידלגו על בדיקת התעודה."],
    ],
))
S.append(f"""
<p>את ה-headers קוראת פונקציית עזר קטנה:</p>
""")
S.append(pre(function("Get-FmcHeaderValue")))
S.append(box("note", f"למה לא פשוט {c('$response.Headers[...]')}", f"""
<p>ב-PowerShell 7 כל header חוזר כמערך של מחרוזות ולא כמחרוזת אחת. בקוד המקורי זה עבד במקרה, כי המערך
הומר למחרוזת כשנכנס לתוך מירכאות. אבל header שמופיע פעמיים היה הופך ל-token שבור. {c("@(...)[0]")} לוקח תמיד
את הערך הראשון, והבדיקה שהערך לא ריק עוצרת מיד עם הודעה ברורה, במקום 401 לא מוסבר בקריאה הבאה.</p>
"""))

# 3 ------------------------------------------------------------------------
S.append(h2(3, f"קריאות ל-API: {c('Invoke-FmcApi')}"))
S.append(f"""
<p>כל קריאה ל-API של FMC עוברת דרך פונקציה אחת. היא משלימה את ה-URL מתוך ה-session, שולחת את ה-token,
ומטפלת בשתי השגיאות שאפשר להתאושש מהן:</p>
""")
S.append(pre(function("Invoke-FmcApi")))
S.append(table(
    ["קוד", "מה קרה", "מה הפונקציה עושה"],
    [
        ["401", "ה-token פג (תוקף של 30 דקות).", f"{c('Update-FmcToken')} מחדש אותו, והלולאה שולחת שוב."],
        ["429", "עברו את מגבלת 120 הקריאות לדקה.", "ממתינה ושולחת שוב. ההמתנה גדלה בכל ניסיון: 20, 40, 60 שניות."],
        ["אחר", "למשל 404, 400, 500, או שהשרת לא זמין.", f"{c('throw')} מיד. ניסיון חוזר יחזיר את אותה תוצאה."],
    ],
))
S.append(f"""
<p>ה-header נבנה מחדש בכל סיבוב בכוונה: אם ה-token התחדש בסיבוב הקודם, הסיבוב הבא כבר שולח את החדש.
{c("Content-Type")} נשלח רק כשיש גוף, כלומר לא ב-GET. ברירת המחדל {c("$MaxRetries = 3")} פירושה עד ארבעה ניסיונות.</p>
<p>החידוש עצמו נעשה ב-{c("Update-FmcToken")}, שמעדכנת את אותו אובייקט session במקום ליצור חדש:</p>
""")
S.append(pre(cut("if ($Session.RefreshCount -ge 3) {", "$Session.RefreshCount++")))
S.append(box("warn", "401 שאינו נובע מתוקף", f"""
<p>FMC מחזיר 401 גם כשה-token תקף אבל למשתמש אין הרשאה לנתיב. במקרה כזה הפונקציה תחדש את ה-token שלוש
פעמים לשווא ורק אז תיכשל, וההודעה האחרונה תהיה "already been refreshed 3 times" ולא שגיאת ההרשאה המקורית.
זה לא שובר כלום, אבל כדאי לדעת את זה כשקוראים את הלוג.</p>
"""))

# 4 ------------------------------------------------------------------------
S.append(h2(4, "משיכת המכשירים"))
S.append(f"""
<p>{c("Get-FmcDeviceRecords")} קוראת ל-{c("devices/devicerecords?expanded=true")}. בלי {c("expanded=true")}
FMC מחזיר רק שם ו-ID לכל מכשיר, בלי כתובת הניהול.</p>
""")
S.append(pre(function("Get-FmcDeviceRecords")))
S.append(f"""
<p>FMC מחזיר לכל היותר 1,000 פריטים בעמוד. בניגוד ל-DNA, התשובה כוללת את מספר המכשירים הכולל
({c("paging.count")}), ולכן הלולאה ממשיכה עד שה-{c("offset")} מגיע אליו ולא לפי אורך העמוד. הבדיקה
{c("$page.paging -and")} מגינה על המקרה שבו אין מכשירים בכלל ו-FMC לא מחזיר בלוק paging.</p>
""")
S.append(table(
    ["שדה בתוצאה", "מקור ב-FMC", "שימוש"],
    [
        [c("Name"), c("name"), "ה-Caption של ה-Node ב-SolarWinds."],
        [c("HostName"), c("hostName"), "כתובת הניהול: IP או שם DNS."],
        [c("Model"), c("model"), "לא בשימוש כרגע."],
        [c("Version"), c("sw_version"), "לא בשימוש כרגע."],
        [c("HealthStatus"), c("healthStatus"), "לא בשימוש כרגע."],
        [c("Id"), c("id"), "לא בשימוש כרגע."],
    ],
))
S.append(f"""
<p>הסקריפט עובד רק מול ה-Global domain, שה-UUID שלו חוזר מ-{c("generatetoken")}. מכשירים שרשומים בתת-domain
לא ייכללו.</p>
""")

# 5 ------------------------------------------------------------------------
S.append(h2(5, "סגירת FMC, התחברות ל-SWIS ובניית רשימת הרכיבים"))
S.append(f"""
<p>אחרי שהרשימה בידיים, אין עוד צורך ב-FMC. הסקריפט מבטל את ה-token מיד, ולא רק בסוף ההרצה, כדי שלא יפוג
באמצע הוספת ה-Nodes:</p>
""")
S.append(pre(cut("# The device list is all that is needed from FMC", "    exit", after="# Call function \"Get-FmcDeviceRecords\"")
             + "\n}"))
S.append(f"""
<p>FMC רושם כל מכשיר לפי כתובת הניהול שהוזנה כשהמכשיר נוסף, וזו יכולה להיות כתובת IP או שם DNS. ב-SolarWinds
מוסיפים Nodes לפי IP, ולכן כל כתובת עוברת דרך {c("Resolve-ManagementAddress")}:</p>
""")
S.append(pre(function("Resolve-ManagementAddress")))
S.append(f"""
<p>כתובת IP חוזרת כמו שהיא. שם DNS מתורגם לכתובת ה-IPv4 הראשונה שלו. אם התרגום נכשל, המכשיר מדולג עם
אזהרה בלוג ונספר ב-{c("skipped")} בשורת הסיכום. אחר כך כל מכשיר הופך ל-hashtable אחיד, כמו ב-DNA, עם שם
המכשיר מ-FMC כ-Caption:</p>
""")
S.append(pre(cut("$components = foreach ($device in $results) {", "}", end_exact=True)))

# 6 ------------------------------------------------------------------------
S.append(h2(6, "הוספת Node ורישום pollers"))
S.append(f"""
<p>{c("Add-Component")} זהה כמעט לחלוטין לפונקציה בסקריפט ה-DNA. ההבדל היחיד הוא ה-{c("Caption")}: כאן
ה-Node נכנס ל-SolarWinds עם שם המכשיר מ-FMC ולא רק עם כתובת ה-IP.</p>
""")
S.append(pre(function("Add-Component")))
S.append(table(
    ["Poller", "מה הוא אוסף"],
    [
        [c("N.Status.ICMP.Native"), "זמינות (Up/Down) בפינג."],
        [c("N.ResponseTime.ICMP.Native"), "זמן תגובה ואיבוד חבילות."],
        [c("N.Details.SNMP.Generic"), "פרטי המכשיר ב-SNMP: שם, דגם, גרסה."],
        [c("N.Uptime.SNMP.Generic"), "זמן פעולה מאז האתחול האחרון."],
    ],
))
S.append(f"""
<p>שני ה-pollers של SNMP אוספים נתונים רק אם ה-community שב-{c("-SNMPCommunity")} מוגדר על מכשירי ה-FTD
(בממשק של FMC, תחת {c("Devices > Platform Settings > SNMP")}), ושרת ה-SolarWinds מופיע שם ברשימת ה-Hosts.</p>
""")

# 7 ------------------------------------------------------------------------
S.append(h2(7, "גילוי הממשקים והסינון"))
S.append(f"""
<p>{c("Add-DiscoveredInterfaces")} מריצה את {c("DiscoverInterfacesOnNode")}, מסירה מהתוצאה כל ממשק שלא עובר את
המסנן, ומוסיפה את הנותרים עם {c("AddInterfacesOnNode")}. המסנן משאיר רק ממשקי TenGigabit ו-Port-channel
שנמצאים במצב up ({c("ifOperStatus")} שווה 1):</p>
""")
S.append(pre(cut("@($discovered.DiscoveredInterfaces.DiscoveredLiteInterface) | Where-Object {",
                 "$interfaceCount = @(")))
S.append(f"""
<p>כדי שהלוג ירשום רק את מה שבאמת נוסף, הפונקציה קוראת את רשימת הממשקים של ה-Node לפני ההוספה ואחריה,
ורושמת רק את ההפרש:</p>
""")
S.append(pre(cut("$interfaceQuery = ", "$script:interfaceTotal += $added.Count")))
S.append(box("note", "שלוש נקודות שקל לטעות בהן בבלוק הזה", f"""
<ul>
<li><b>{c("@(...)")} לפני ההסרה.</b> {c("RemoveChild")} מקצר את הרשימה החיה בזמן שה-pipeline עדיין עובר עליה.
בלי להעתיק אותה קודם למערך, חלק מהממשקים היו מדולגים.</li>
<li><b>{c("Where-Object { $_ }")} בספירה.</b> כשהמסנן מסיר את כל הממשקים, נשאר {c("$null")}, ו-{c("@($null).Count")}
שווה 1. בלי הסינון הזה הסקריפט היה מדווח על ממשק אחד ושולח ל-SolarWinds רשימה ריקה.</li>
<li><b>לפני ואחרי, ולא לפי מה שנשלח.</b> ב-Node קיים, חלק מהממשקים שעברו את המסנן כבר מנוטרים. הלוג רושם
רק ממשקים שה-{c("InterfaceID")} שלהם לא היה קיים לפני ההוספה.</li>
</ul>
"""))
S.append(box("warn", "המסנן הועתק מ-DNA ועדיין לא הותאם ל-FTD", f"""
<p>התבנית {c(FILTER_RE)} מתאימה למתגים של סיסקו. ממשקי FTD נקראים
אחרת לפי הדגם, למשל {c("Ethernet1/1")} בציוד Firepower או {c("GigabitEthernet0/0")} ב-FTD וירטואלי. בלי
התאמה, ייתכן שהמסנן יסיר את כל הממשקים של כל המכשירים. את התבנית משנים בשורה של {c("-notmatch")}.</p>
"""))

# 8 ------------------------------------------------------------------------
S.append(h2(8, "הלולאה הראשית וסגירת הסשנים"))
S.append(f"""
<p>לכל רכיב, הלולאה בודקת אם כבר יש ב-SolarWinds Node עם אותה כתובת IP. אם יש, היא לא מוסיפה אותו שוב.
בכל מקרה, חדש או קיים, היא ממשיכה לגילוי הממשקים:</p>
""")
S.append(pre(cut("foreach ($component in $components) {", "}", end_exact=True)))
S.append(f"""
<p>ה-IP מועבר לשאילתה כפרמטר ({c("@ip")}) ולא נכנס לטקסט שלה. כשל ברכיב אחד נתפס ב-{c("catch")}, נספר
ב-{c("failed")}, והלולאה ממשיכה לרכיב הבא. בסוף ההרצה {c("Stop-Sessions")} סוגרת את מה שעוד פתוח:</p>
""")
S.append(pre(function("Stop-Sessions")))
S.append(box("note", "שני הצדדים נסגרים באמת", f"""
<p>ב-DNA אין endpoint לביטול token, ולכן שם אפשר רק לזרוק אותו מהזיכרון. ל-FMC יש
{c("auth/revokeaccess")}, ו-{c("Disconnect-Fmc")} קוראת לו. בצד של SolarWinds אין {c("Disconnect-Swis")}, אבל
{c("Connect-Swis")} מחזיר אובייקט שמממש IDisposable, ולכן {c("Close()")} סוגר את החיבור בפועל. הפונקציה בטוחה
לקריאה כפולה: היא נקראת פעם אחת אחרי משיכת המכשירים ופעם נוספת בסוף, וכל צד נסגר רק פעם אחת.</p>
"""))

# 9 ------------------------------------------------------------------------
S.append(h2(9, "הלוג"))
S.append(f"""
<h3>מודל הלוג: קובץ אחד עם רוטציה לפי גודל</h3>
<p>{c("Write-Log")} ו-{c("Invoke-LogRotation")} הועתקו מ-{c("DNS.SetSolarWindsRecordToActiveServer.ps1")}, כך
שהפורמט וההתנהגות זהים. כל ההרצות נכתבות לקובץ אחד, {c("-LogPath")}, וכשהוא מגיע ל-{c("-LogMaxBytes")}
הוא עובר הצידה עם עד {c("-LogKeep")} דורות קודמים:</p>
""")
S.append(table(
    ["פרמטר", "ברירת מחדל", "משמעות"],
    [
        [c("-LogPath"), c("%ProgramData%\\SolarWinds\\fmc-discover-nodes.log"), "התיקייה נוצרת אוטומטית אם אינה קיימת."],
        [c("-LogMaxBytes"), "1MB", f"מעבר לגודל הזה הקובץ עובר ל-{c('.log.1')}."],
        [c("-LogKeep"), "3", "כמה קבצים ישנים לשמור. 0 פירושו שהלוג מתחיל מחדש."],
    ],
))
S.append(f"""
<p>כל שורה מוצגת על המסך וגם נכתבת לקובץ, עם תאריך, שעה ורמה:</p>
""")
S.append(pre(cut("$line = '{0:yyyy-MM-dd HH:mm:ss}", "Write-Warning \"Could not write to the log file", after="function Write-Log {")
             + "\n}"))
S.append(f"""
<h3>מה נרשם</h3>
""")
S.append(table(
    ["רשומה", "מתי"],
    [
        [f"{c('Run started')} / {c('Run completed')}", "בתחילת ההרצה ובסופה. שורת הסיכום מונה Nodes שנוספו, שהיו קיימים, שדולגו ושנכשלו, וממשקים שנוספו."],
        [c("FMC returned N device[s]"), "אחרי משיכת המכשירים."],
        [f"{c('Node already exists')} / {c('Added node')}", "לכל רכיב: שם, IP ו-NodeID."],
        [c("Added poller"), "לכל אחד מארבעת ה-pollers של Node חדש."],
        [c("Added interface"), "לכל ממשק שנוסף בפועל: שם ו-InterfaceID."],
        [f"{c('WARN')} / {c('ERROR')}", "מכשיר בלי כתובת תקינה, 429, כשל בהתחברות ל-FMC או ל-SWIS, כשל ברכיב."],
    ],
))
S.append(f"""
<p>דוגמה מהרצה מול FMC ו-SolarWinds מדומים:</p>
<pre dir="ltr" class="log">2026-10-05 13:30:36 [INFO ] ===== Run started: FMC fmc01 -> SolarWinds orion01 =====
2026-10-05 13:30:56 [INFO ] FMC returned 1500 device[s].
2026-10-05 13:30:56 [WARN ] Skipping 'ftd4' - no usable management address ('no-such-host.invalid').
2026-10-05 13:30:57 [INFO ]  Node already exists: ftd0 (10.0.0.1) [NodeID 42], skipping add.
2026-10-05 13:30:57 [INFO ]   Added interface Po2 [InterfaceID 1001] to node 42.
2026-10-05 13:30:57 [INFO ]   Added poller N.Status.ICMP.Native to node 101.
2026-10-05 13:30:57 [INFO ]  Added node: ftd1 (10.0.0.2) [NodeID 101].
2026-10-05 13:30:57 [INFO ]   Added interface TenGigabitEthernet1/1 [InterfaceID 1002] to node 101.
2026-10-05 13:31:25 [INFO ] ===== Run completed: 1498 node[s] added, 1 already existed, 1 skipped, 0 failed, 2997 interface[s] added =====</pre>
""")
S.append(box("note", "כשל בכתיבה אינו מפיל את ההרצה", f"""
<p>הכתיבה לקובץ עטופה ב-{c("try/catch")}. אם אין הרשאת כתיבה ל-{c("-LogPath")}, מופיעה אזהרה על המסך וההרצה
ממשיכה, אבל לא תתועד. בהרצה על 1,500 מכשירים נכתבים כ-12,000 שורות, בערך 1MB, כך שבסביבה גדולה כדאי להגדיל
את {c("-LogMaxBytes")}.</p>
"""))

# 10 -----------------------------------------------------------------------
S.append(h2(10, "זרימה מקצה לקצה"))
S.append(table(
    ["שלב", "מה קורה", "אם זה נכשל"],
    [
        ["1", "פתיחת הלוג ורוטציה אם צריך", "אזהרה; ההרצה ממשיכה בלי לוג"],
        ["2", "התחברות ל-FMC", f"שגיאה, {c('Stop-Sessions')}, יציאה"],
        ["3", "משיכת המכשירים, כולל חידוש token והמתנה ל-429", f"שגיאה, {c('Stop-Sessions')}, יציאה"],
        ["4", "ביטול ה-token של FMC", "אזהרה בלבד"],
        ["5", "בדיקה שחזרו מכשירים", "אזהרה ויציאה"],
        ["6", "התחברות ל-SWIS", f"שגיאה, {c('Stop-Sessions')}, יציאה"],
        ["7", "המרת כתובת הניהול ל-IPv4", "המכשיר מדולג עם אזהרה"],
        ["8", "לכל רכיב: בדיקה אם קיים, הוספת Node ו-pollers", f"נרשם כ-{c('failed')}, ממשיכים לרכיב הבא"],
        ["9", "גילוי, סינון והוספת ממשקים", "שגיאה בלוג, ממשיכים לרכיב הבא"],
        ["10", "סגירת SWIS ושורת סיכום", "אזהרה בלבד"],
    ],
    cls="stages",
))
S.append("""
<p>ההבדל בין שלבים 2–6 לשלבים 7–9 מכוון: כשל בהתחברות עוצר הכול, כי בלעדיה אין מה לעשות. כשל במכשיר בודד רק
נרשם בלוג, כדי שמכשיר אחד בעייתי לא יעצור את כל ההרצה.</p>
""")

# 11 -----------------------------------------------------------------------
S.append(h2(11, "מה לשנות לפני הרצה אמיתית"))
S.append(f"""
<ul class="checklist">
<li><b>למלא את פרטי החיבור.</b> {c("-FmcServer")} ו-{c("-SwisHost")} מוגדרים כברירת מחדל ל-{c("1.1.1.1")}
ו-{c("5.5.5.5")}, שהם ערכים לדוגמה. גם נתיבי קבצי ה-XML צריכים להתאים לשרת.</li>
<li><b>ליצור את קבצי ה-credentials בחשבון שמריץ את הסקריפט.</b> {c("Get-Credential | Export-Clixml -Path <path>")}.
הסיסמה בקובץ מוצפנת כך שרק אותו משתמש, על אותו שרת, יכול לפתוח אותה. קובץ שנוצר בחשבון אחר לא ייפתח במשימה
המתוזמנת.</li>
<li><b>משתמש ייעודי ל-API ב-FMC.</b> עם הרשאת REST API, ונפרד מהמשתמש שמתחברים איתו לממשק.</li>
<li><b>להגדיר {c("-SNMPCommunity")}.</b> ברירת המחדל ריקה. צריך גם להגדיר SNMP על ה-FTD ב-FMC ולהוסיף את שרת
ה-SolarWinds לרשימת ה-Hosts.</li>
<li><b>להתאים את מסנן הממשקים ל-FTD.</b> ראו את פרק 7.</li>
<li><b>לאמת את {c("-EngineID")}.</b> ברירת המחדל היא 2. בסביבה עם polling engine יחיד הערך הנכון הוא בדרך כלל 1.</li>
<li><b>לוודא הרשאת כתיבה ל-{c("-LogPath")}.</b> אחרת ההרצה תעבוד אבל לא תתועד.</li>
<li><b>PowerShell 7 ומעלה.</b> {c("-SkipCertificateCheck")} אינו קיים ב-Windows PowerShell 5.1, ושם הסקריפט ייפול.</li>
<li><b>להריץ קודם על מעט מכשירים.</b> אין שלב סקירה ואין הרצה יבשה: כל מכשיר שמגיע מ-FMC נרשם לניטור וצורך רישיון.</li>
</ul>
""")

# 12 -----------------------------------------------------------------------
S.append(h2(12, "מגבלות ידועות"))
S.append(f"""
<p>דברים שעדיין פתוחים בקוד, ונרשמים כאן כדי שלא יתגלו בהפתעה:</p>
<ul class="checklist">
<li><b>Global domain בלבד.</b> מכשירים בתת-domain של FMC לא נכללים.</li>
<li><b>אין סינון לפי מצב המכשיר.</b> {c("healthStatus")} נקרא אבל לא משמש. גם מכשיר במצב תקלה נרשם לניטור.</li>
<li><b>בדיקת התעודה מכובה תמיד.</b> {c("-TrustAllCertificates")} קבוע בקריאה ל-{c("Connect-Fmc")}, גם כשל-FMC יש
תעודה תקינה.</li>
<li><b>סיסמה עם תווים שאינם באנגלית תיכשל.</b> {c("ASCII.GetBytes")} מחליף כל תו כזה ב-{c("?")}.</li>
<li><b>401 שנובע מהרשאה ולא מתוקף</b> יגרום לשלושה חידושים מיותרים ולהודעה מטעה (פרק 3).</li>
<li><b>תת-ממשקים נכללים.</b> המסנן בודק רק את תחילת השם, ולכן גם {c("Port-channel1.100")} יעבור.</li>
<li><b>המסנן תלוי במבנה ה-XML.</b> {c("$_.Caption.InnerText")} מחזיר ערך רק כשאלמנט ה-Caption מכיל אלמנט פנימי, כמו
בדוגמה של ה-SDK. אם SolarWinds היה מחזיר טקסט נקי, הערך היה ריק והמסנן היה מסיר כל ממשק בשקט.</li>
<li><b>SNMPv2 בלבד.</b> ה-Nodes נוספים עם community. אין תמיכה ב-SNMPv3.</li>
<li><b>קוד היציאה אינו משתנה בכשל.</b> גם יציאה אחרי שגיאה מסתיימת בקוד 0, כך שמתזמן המשימות לא יזהה את הכשל
אלא מתוך הלוג.</li>
<li><b>כפילות מול סקריפטי DNA ו-SmartConsole.</b> {c("Add-Component")}, הלולאה הראשית ופונקציות הלוג כמעט זהים
בשלושת הקבצים, ותיקון באחד אינו מגיע לאחרים.</li>
</ul>
<p class="footer-note">מסמך זה מתאר את {c("Scripts/FMC.DiscoverNodes.ps1")} שבמאגר. קטעי הקוד נשלפים מהסקריפט
בזמן בניית המסמך ({c("Docs/gen_fmc_explainer.py")}), ולכן תמיד תואמים לקוד. הסקריפט נבדק עם PowerShell 7.4.6 מול
FMC ו-SolarWinds מדומים: ריבוי עמודים, 401, 429, ביטול token, לוג ורוטציה. הוא לא נבדק מול FMC ו-SolarWinds
אמיתיים.</p>
""")


CSS = """
@page {
  size: A4;
  margin: 18mm 17mm 20mm 17mm;
  @bottom-center {
    content: counter(page) " / " counter(pages);
    font-family: "DejaVu Sans"; font-size: 8pt; color: #8a94a3;
    direction: rtl;
  }
}
html { direction: rtl; }
body {
  font-family: "DejaVu Sans", sans-serif;
  font-size: 9.4pt; line-height: 1.75; color: #1f2a37;
  text-align: right;
}
h1 { font-size: 19pt; color: #1b3a5c; margin: 0 0 10px 0; line-height: 1.35; }
h2 {
  font-size: 13.5pt; color: #1b3a5c; margin: 26px 0 10px 0;
  padding-bottom: 5px; border-bottom: 1.5px solid #d8e1ec;
  page-break-after: avoid;
}
h3 { font-size: 10.5pt; color: #1b3a5c; margin: 16px 0 6px 0; page-break-after: avoid; }
.num { }
p { margin: 0 0 8px 0; }
.lead { border-right: 4px solid #c9d3df; padding: 2px 12px 2px 0; margin-bottom: 8px; color: #384656; }
.lead p { margin: 0; }
.sub { font-size: 8.2pt; color: #8a94a3; }
code {
  font-family: "DejaVu Sans Mono", monospace; font-size: 8.1pt;
  background: #eef2f6; border: 1px solid #dde4ec; border-radius: 3px;
  padding: 0 3px; color: #2a4b6d;
  direction: ltr; unicode-bidi: isolate;
}
p code, li code { white-space: nowrap; }
pre {
  direction: ltr; text-align: left; unicode-bidi: isolate;
  font-family: "DejaVu Sans Mono", monospace; font-size: 7.4pt; line-height: 1.5;
  background: #f6f8fa; border: 1px solid #e3e8ee; border-left: 3px solid #3f6fa0;
  border-radius: 3px; padding: 9px 11px; margin: 8px 0 12px 0;
  white-space: pre-wrap; color: #24292f;
}
pre.log { font-size: 6.9pt; color: #3b4652; }
pre .kw   { color: #1b3a8c; font-weight: bold; }
pre .str  { color: #a3501a; }
pre .com  { color: #7b8794; font-style: italic; }
pre .var  { color: #6b2f8a; }
pre .cmd  { color: #0c6b6b; }
pre .op   { color: #b0306a; }
pre .type { color: #2f6f3e; }
table {
  width: 100%; border-collapse: collapse; margin: 8px 0 14px 0;
  font-size: 8.6pt; page-break-inside: auto;
}
tr { page-break-inside: avoid; }
th {
  background: #eaf0f6; color: #1b3a5c; font-weight: bold;
  border: 1px solid #d3dce7; padding: 6px 8px; text-align: right;
}
td { border: 1px solid #dfe5ec; padding: 6px 8px; vertical-align: top; text-align: right; }
table.stages td:first-child { width: 7%; text-align: center; }
.box {
  border-radius: 4px; padding: 9px 13px 4px 13px; margin: 10px 0 14px 0;
  page-break-inside: avoid; font-size: 8.9pt;
}
.box.note { background: #eef5fb; border-right: 4px solid #3f7cc0; }
.box.warn { background: #fdf5ea; border-right: 4px solid #e0973a; }
.box-title { font-weight: bold; color: #1b3a5c; margin-bottom: 4px; }
.box.warn .box-title { color: #8a4a0c; }
ul { margin: 4px 0 8px 0; padding-right: 18px; padding-left: 0; }
li { margin-bottom: 4px; }
.footer-note {
  margin-top: 22px; padding-top: 8px; border-top: 1px solid #dde4ec;
  font-size: 7.8pt; color: #7b8794;
}
"""

DOC = f"""<!DOCTYPE html>
<html lang="he" dir="rtl">
<head>
<meta charset="utf-8">
<title>FMC-to-SolarWinds Integration - Explained</title>
<style>{CSS}</style>
</head>
<body>
{heb("".join(S))}
</body>
</html>
"""

if __name__ == "__main__":
    from weasyprint import HTML
    (HERE / "fmc_explainer.html").write_text(DOC, encoding="utf-8")
    HTML(string=DOC, base_url=str(HERE)).write_pdf(OUTPUT)
    print(f"wrote {OUTPUT}")
