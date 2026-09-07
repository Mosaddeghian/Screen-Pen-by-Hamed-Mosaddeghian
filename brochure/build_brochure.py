# -*- coding: utf-8 -*-
"""ساخت بروشور فارسی PDF قلم صفحه — نسخه 1.5.0"""
import os
import arabic_reshaper
from bidi.algorithm import get_display
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib.colors import HexColor, white, black
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_RIGHT, TA_CENTER, TA_LEFT
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (SimpleDocTemplate, Paragraph, Spacer, Image,
                                Table, TableStyle, HRFlowable, KeepTogether,
                                PageBreak)

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(BASE, "ScreenPen-Brochure-FA-v1.5.0.pdf")

pdfmetrics.registerFont(TTFont("Tahoma", r"C:\Windows\Fonts\tahoma.ttf"))
pdfmetrics.registerFont(TTFont("Tahoma-Bold", r"C:\Windows\Fonts\tahomabd.ttf"))

PRIMARY = HexColor("#1a5fa0")
DARK = HexColor("#1e2a3a")
ACCENT = HexColor("#ff8a3d")
LIGHT_BG = HexColor("#eef4fa")
GRAY = HexColor("#5b6b7f")
GREEN = HexColor("#1e9e57")
RED = HexColor("#d6405e")


def fa(text):
    """آماده‌سازی متن فارسی برای نمایش درست در PDF."""
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    lines = text.split("\n")
    out = []
    for ln in lines:
        if ln.strip() == "":
            out.append("<br/>")
        else:
            out.append(get_display(arabic_reshaper.reshape(ln)))
    return "<br/>".join(out)


def P(text, style):
    return Paragraph(fa(text), style)


def EN(text, style):
    return Paragraph(text, style)


body = ParagraphStyle("body", fontName="Tahoma", fontSize=10.5, leading=19,
                      alignment=TA_RIGHT, textColor=DARK, spaceAfter=6)
bullet = ParagraphStyle("bullet", parent=body, rightIndent=14, spaceAfter=4,
                        bulletIndent=0)
cap = ParagraphStyle("cap", fontName="Tahoma", fontSize=9, leading=15,
                     alignment=TA_CENTER, textColor=GRAY, spaceAfter=10)
h1 = ParagraphStyle("h1", fontName="Tahoma-Bold", fontSize=16, leading=24,
                    alignment=TA_RIGHT, textColor=PRIMARY, spaceBefore=4,
                    spaceAfter=2)
h2 = ParagraphStyle("h2", fontName="Tahoma-Bold", fontSize=12.5, leading=20,
                    alignment=TA_RIGHT, textColor=DARK, spaceBefore=8,
                    spaceAfter=4)
cover_title = ParagraphStyle("ct", fontName="Tahoma-Bold", fontSize=34,
                             leading=44, alignment=TA_CENTER,
                             textColor=PRIMARY)
cover_sub = ParagraphStyle("cs", fontName="Tahoma", fontSize=13, leading=22,
                           alignment=TA_CENTER, textColor=GRAY)
pill = ParagraphStyle("pill", fontName="Tahoma-Bold", fontSize=10, leading=16,
                      alignment=TA_CENTER, textColor=white)


def heading(title):
    return [P(title, h1),
            HRFlowable(width="100%", thickness=1.5, color=PRIMARY,
                       spaceAfter=8, spaceBefore=2, hAlign="RIGHT")]


def bullets(items):
    flow = []
    for it in items:
        flow.append(P("- " + it, bullet))
    flow.append(Spacer(1, 4))
    return flow


def shot(name, w=480, h=None):
    from PIL import Image as PILImage
    p = os.path.join(BASE, name)
    iw, ih = PILImage.open(p).size
    max_h = h or 420
    scale = min(w / iw, max_h / ih)
    im = Image(p, width=iw * scale, height=ih * scale)
    im.hAlign = "CENTER"
    return im


def caption(t):
    return P("— " + t + " —", cap)


story = []

# ================= روی جلد =================
story.append(Spacer(1, 26))
story.append(P("قلم صفحه", cover_title))
story.append(P("Screen Pen by Hamed Mosaddeghian", cover_sub))
story.append(Spacer(1, 4))
story.append(P("بنویس، بکش و توضیح بده — روی هر صفحه، بدون این‌که چیزی به‌هم بریزد",
               ParagraphStyle("tag", parent=cover_sub, fontSize=12.5,
                              textColor=DARK, fontName="Tahoma-Bold")))
story.append(Spacer(1, 8))

badge_data = [[P("نسخه ۱٫۵٫۰", pill), P("ویندوز • بدون نصب (قابل‌حمل)", pill),
               P("فارسی • رایگان", pill)]]
badge = Table(badge_data, colWidths=[120, 200, 120])
badge.setStyle(TableStyle([
    ("BACKGROUND", (0, 0), (-1, -1), PRIMARY),
    ("ROUNDEDCORNERS", [8, 8, 8, 8]),
    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
    ("TOPPADDING", (0, 0), (-1, -1), 6),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
]))
story.append(badge)
story.append(Spacer(1, 12))
story.append(shot("img_modes.png", w=480))
story.append(caption("نمای هر سه بوم برنامه: صفحه، وایت‌برد و بلک‌برد"))
story.append(P("این بروشور هم معرفی کامل امکانات است و هم راهنمای قدم‌به‌قدم کار با برنامه؛ از نصب تا تدریس آنلاین و تحلیل چارت.",
               ParagraphStyle("intro", parent=body, alignment=TA_CENTER,
                              fontSize=11)))
story.append(PageBreak())

# ================= ۱. این برنامه چیست؟ =================
story += heading("۱. قلم صفحه چیست؟")
story.append(P("قلم صفحه یک برنامه سبک ویندوزی است که یک لایه شفافِ همیشه‌رو برای نوشتن، روی صفحه شما می‌گذارد. می‌توانید روی هر چیزی — فیلم کلاس، نمودار بورس، فایل PDF، مرورگر — خط بکشید و توضیح بنویسید، بعد با یک کلیک همه را پاک کنید؛ بدون این‌که به فایل اصلی دست بخورد.",
               body))
story.append(P("برای چه کسانی ساخته شده؟", h2))
story += bullets([
    "معلم و مدرس آنلاین: توضیح روی اسلاید، فیلم و وایت‌برد سفید و مشکی.",
    "تریدر و تحلیل‌گر: کشیدن کندل سبز و قرمز با سایه، روی هر چارتی.",
    "ارائه‌دهنده و مدیر جلسه: اشاره با حلقه نورانی و بزرگ‌نمایی جزئیات.",
    "پشتیبانی و تولیدکننده محتوا: عکس گرفتن از توضیحات برای ارسال به دیگران.",
])
story.append(P("چرا با بقیه فرق دارد؟", h2))
story += bullets([
    "خیلی سبک و سریع است و بالای همه پنجره‌ها می‌ماند.",
    "حالت «عبور کلیک» دارد: وقتی کارتان تمام شد، موس دوباره عادی می‌شود.",
    "نوشته‌های هر بوم جدا ذخیره می‌ماند؛ حتی بعد از بستن برنامه.",
    "نوشته‌ها در اشتراک صفحه گوگل‌میت و فیلم‌برداری هم دیده می‌شوند.",
])

# ================= ۲. شروع در ۵ قدم =================
story += heading("۲. شروع کار در ۵ قدم")
story.append(P("قدم ۱ — دانلود: از صفحه انتشار (Releases) فایل ScreenPen-vX.Y.Z-portable-win64.zip را بگیرید.",
               body))
story += bullets([
    "روی فایل زیپ راست‌کلیک کنید و Extract All را بزنید.",
    "وارد پوشه شوید و روی pen.exe دو بار کلیک کنید.",
    "اگر ویندوز هشدار امنیتی داد: More info و بعد Run anyway.",
    "قدم ۲ — اجرای اول: نوار ابزار تیره سمت چپ باز می‌شود و قلم آبی فعال است.",
    "قدم ۳ — اولین خط: با موس روی صفحه بکشید. خط همان‌جا می‌ماند.",
    "قدم ۴ — عکس بگیرید: دکمه دوربین (📷) یک عکس از بوم در پوشه Pictures ذخیره می‌کند.",
    "قدم ۵ — تمام کنید: راست‌کلیک کنید تا موس عادی شود؛ برنامه همچنان باز است.",
])

# ================= ۳. نوار ابزار =================
story += heading("۳. نوار ابزار را بشناسید")
story.append(shot("img_toolbar.png", w=200))
story.append(caption("نمای واقعی نوار ابزار برنامه (نسخه ۱٫۵٫۰) و نام هر دکمه"))
story += bullets([
    "بالا: سه دکمه حالت بوم — صفحه (S)، وایت‌برد (W)، بلک‌برد (B).",
    "وسط: ابزارهای رسم — قلم، هایلایتر، متن، «مهم» و «یادداشت» آماده، خط، مستطیل، کندل سبز و کندل قرمز.",
    "پایین‌وسط: پاک‌کن، ذره‌بین، اشاره‌گر (حلقه نورانی).",
    "پایین: برگردان، سطل آشغال، دوربین، تنظیمات، افزودن ابزار، مخفی‌کردن و خروج.",
    "آخر نوار: ۸ رنگ سریع؛ دکمه رنگ‌ها، پالت کامل ۱۶ رنگ را باز می‌کند.",
    "نکته: روی ابزار فعال دوباره کلیک کنید تا خاموش شود و موس عادی شود.",
])

# ================= ۴. سه بوم =================
story += heading("۴. سه بوم مستقل: صفحه، وایت‌برد، بلک‌برد")
story.append(P("هر بوم حافظه جدا دارد؛ یعنی می‌توانید هم‌زمان روی هر سه چیزهای مختلف داشته باشید و با عوض کردن بوم، هیچ‌چیز پاک نمی‌شود.",
               body))
tdata = [
    [EN("Screen", ParagraphStyle("en", fontName="Tahoma-Bold", fontSize=10.5,
                                 alignment=TA_LEFT, textColor=DARK)),
     P("صفحه شفاف روی همه پنجره‌ها", body),
     P("توضیح روی فیلم، چارت و PDF", body)],
    [EN("Whiteboard", ParagraphStyle("en2", fontName="Tahoma-Bold",
                                     fontSize=10.5, alignment=TA_LEFT,
                                     textColor=DARK)),
     P("تخته سفید تمیز", body), P("تدریس و حل تمرین", body)],
    [EN("Blackboard", ParagraphStyle("en3", fontName="Tahoma-Bold",
                                     fontSize=10.5, alignment=TA_LEFT,
                                     textColor=DARK)),
     P("تخته مشکی", body), P("کلاس شب و چشم راحت", body)],
]
t = Table(tdata, colWidths=[120, 170, 190])
t.setStyle(TableStyle([
    ("BACKGROUND", (0, 0), (-1, -1), LIGHT_BG),
    ("BOX", (0, 0), (-1, -1), 1, PRIMARY),
    ("INNERGRID", (0, 0), (-1, -1), 0.5, HexColor("#b9cbe0")),
    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
    ("TOPPADDING", (0, 0), (-1, -1), 6),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
    ("LEFTPADDING", (0, 0), (-1, -1), 8),
    ("RIGHTPADDING", (0, 0), (-1, -1), 8),
]))
story.append(KeepTogether(t))
story.append(Spacer(1, 6))
story.append(P("جابه‌جایی سریع: Ctrl+Shift+W وایت‌برد، Ctrl+Shift+B بلک‌برد. برای برگشت به صفحه، دوباره همان دکمه بوم را در نوار بزنید.",
               body))

# ================= ۵. ابزارهای رسم =================
story += heading("۵. ابزارهای رسم، یکی‌یکی")
story.append(shot("img_tools.png", w=480))
story.append(caption("ویترین ابزارها: قلم، هایلایتر، خط، مستطیل، متن آماده و کندل"))
story.append(P("قلم", h2))
story.append(P("خط آزاد و دقیق برای دور کشیدن و نوشتن. ضخامت از ۲ تا ۲۰ پیکسل؛ با دکمه عرض قلم در نوار عوض می‌شود.",
               body))
story.append(P("هایلایتر", h2))
story.append(P("ماژیک شفاف برای مهم‌کردن متن‌ها؛ رنگ انتخابی شما همیشه پررنگ می‌ماند ولی جوهری که روی صفحه می‌نشیند نیمه‌شفاف است تا نوشته زیرش خوانا بماند.",
               body))
story.append(P("متن و دکمه‌های «مهم» و «یادداشت»", h2))
story.append(P("روی ابزار متن بزنید، بعد هر جای صفحه کلیک کنید و تایپ کنید؛ با Enter ثبت می‌شود و با Esc لغو. دکمه‌های «مهم» (قرمز) و «یادداشت» (آبی) همان کلمه را با یک کلیک می‌گذارند — عالی برای کلاس. اندازه متن از ۱۲ تا ۷۲.",
               body))
story.append(P("خط و مستطیل", h2))
story += bullets([
    "خط: برای فلش و محور؛ کلید Shift را نگه دارید تا خط کاملاً افقی یا عمودی شود (حتی اگر پنجره دیگری فعال باشد).",
    "مستطیل: دو حالت توخالی (فقط قاب) و توپر (پرشده)؛ از نوار می‌توانید چند مستطیل با رنگ‌های مختلف بسازید و با دکمه‌های جلو/عقب موس بینشان بچرخید.",
])
story.append(P("پاک‌کن، برگردان، سطل آشغال", h2))
story += bullets([
    "پاک‌کن: روی یک شکل کلیک کنید تا فقط همان پاک شود، یا بکشید تا چندتایی پاک شوند.",
    "برگردان (↩): تا ۵۰ قدم آخر هر بوم را برمی‌گرداند.",
    "سطل آشغال (🗑): همه نوشته‌های همین بوم را یک‌جا پاک می‌کند.",
])

# ================= ۶. کندل =================
story += heading("۶. کندل برای تریدرها (سبز و قرمز)")
story.append(shot("img_candles.png", w=480))
story.append(caption("کشیدن کندل روی چارت: جهت کشیدن، رنگ را مشخص می‌کند"))
story += bullets([
    "دو ابزار جدا: کندل سبز (صعودی) و کندل قرمز (نزولی).",
    "روش کشیدن بدنه: از نقطه باز شدن تا بسته شدن بکشید. بالا بکشید صعودی می‌شود، پایین بکشید نزولی.",
    "سایه‌ها (فتیله): بعد از کشیدن بدنه، دو سر سایه را بکشید؛ یا با یک کلیک، کندل آماده با سایه استاندارد بگذارید.",
    "رنگ هر کندل را می‌توانید از پالت عوض کنید؛ کندل‌های قبلی همان رنگ قبلی می‌مانند.",
    "کلید Esc کشیدن نیمه‌تمام را لغو می‌کند.",
])

# ================= ۷. ذره‌بین و اشاره‌گر =================
story += heading("۷. ذره‌بین و حلقه اشاره‌گر")
story.append(shot("img_magnifier.png", w=480))
story.append(caption("حلقه اشاره‌گر و عدسی ذره‌بین با بزرگ‌نمایی و اندازه دلخواه"))
story += bullets([
    "اشاره‌گر (◯): یک حلقه نورانی دور موس می‌گذارد و کلیک‌ها از برنامه رد می‌شوند؛ یعنی عادی با ویندوز کار کنید ولی همه، موس شما را ببینند. برگشت با Ctrl+Shift+P.",
    "نشانگر ارائه: در تنظیمات روشن کنید تا هنگام رسم هم حلقه دیده شود.",
    "حالت عادی بدون حلقه: راست‌کلیک روی صفحه یا خاموش‌کردن ابزار؛ موس کاملاً معمولی می‌شود.",
    "ذره‌بین (⊕): عدسی زنده روی موس؛ بزرگ‌نمایی ۲ و ۴ و ۸ برابر، اندازه عدسی S و M و L.",
])

# ================= ۸. تنظیمات =================
story += heading("۸. تنظیمات و شخصی‌سازی")
story.append(shot("img_settings.png", w=460))
story.append(caption("پنجره تنظیمات: رفتار برنامه، پوشه عکس‌ها و مدیریت ابزارها"))
story += bullets([
    "جای نوار: چپ، راست، بالا یا پایین؛ با دستگیره بالای نوار می‌توانید برنامه را به مانیتور دیگر هم ببرید (چند مانیتوره، با DPI درست).",
    "مخفی‌کردن نوار (Ctrl+Shift+H): نوار جمع می‌شود و رسم متوقف می‌شود؛ با همان کلید برمی‌گردد و ابزار قبلی سر جایش است.",
    "رنگ و ضخامت: ۸ رنگ سریع، حالت گسترده، و پالت کامل ۱۶ رنگ؛ ضخامت قلم و اندازه متن برای هر ابزار جدا ذخیره می‌شود.",
    "افزودن ابزار: دکمه + ابزار تازه با رنگ و ضخامت دلخواه می‌سازد؛ ابزار اضافه را از تنظیمات حذف کنید (آخرین ابزار همیشه محافظت می‌شود).",
    "پوشش نوار وظیفه: بوم می‌تواند کل مانیتور را بپوشاند.",
    "یادآوری نقاشی‌ها: اگر روشن باشد، بعد از بستن و باز کردن، نوشته‌ها برمی‌گردند.",
    "پوشه عکس‌ها: پیش‌فرض پوشه Pictures است و با دکمه «انتخاب» عوض می‌شود.",
])

# ================= ۹. میانبرها =================
story += heading("۹. همه کلیدهای میانبر")
shead = ParagraphStyle("sh", fontName="Tahoma-Bold", fontSize=10.5,
                       leading=17, alignment=TA_CENTER, textColor=white)
scell = ParagraphStyle("sc", fontName="Helvetica-Bold", fontSize=10.5,
                       leading=17, alignment=TA_CENTER, textColor=DARK)
dcell = ParagraphStyle("dc", parent=body, fontSize=10.5, alignment=TA_RIGHT)
rows = [
    ("W", "رفتن به وایت‌برد"), ("B", "رفتن به بلک‌برد"),
    ("Z", "برگردان آخرین کار"), ("S", "گرفتن عکس از بوم"),
    ("H", "مخفی / نمایش نوار ابزار"), ("P", "حالت اشاره و برگشت"),
    ("Q", "خروج از برنامه"),
]
sdata = [[EN("Shortcut", shead), P("کار", shead)]]
for k, dsc in rows:
    sdata.append([EN("Ctrl+Shift+" + k, scell), P(dsc, dcell)])
st = Table(sdata, colWidths=[180, 300])
st.setStyle(TableStyle([
    ("BACKGROUND", (0, 0), (-1, 0), PRIMARY),
    ("BACKGROUND", (0, 1), (-1, -1), LIGHT_BG),
    ("BOX", (0, 0), (-1, -1), 1, PRIMARY),
    ("INNERGRID", (0, 0), (-1, -1), 0.5, HexColor("#b9cbe0")),
    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
    ("TOPPADDING", (0, 0), (-1, -1), 5),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
]))
story.append(st)
story.append(Spacer(1, 6))
story += bullets([
    "Shift + خط: قفل افقی/عمودی — حتی وسط کشیدن هم می‌توانید Shift را بگیرید.",
    "Esc: لغو متن یا کندل نیمه‌تمام.",
    "راست‌کلیک روی صفحه: برگشت به موس عادی.",
    "نکته چند مانیتوره: دستگیره نوار را بگیرید و بکشید تا برنامه به نمایشگر دیگر برود.",
])

# ================= ۱۰. ترفند و پرسش =================
story += heading("۱۰. ترفندها، پرسش‌ها و مشخصات")
story.append(P("ترفندهای کلاسی و کاری", h2))
story += bullets([
    "قبل از کلاس، بوم وایت‌برد را آماده کنید؛ وسط ارائه فقط با W و B جابه‌جا شوید.",
    "برای شلوغ‌نشدن صفحه: هایلایتر برای مهم‌ها، «مهم» قرمز برای تیتر، عکس 📷 برای جزوه.",
    "برای ترید: اول بدنه کندل را بزرگ بکشید بعد سایه‌ها را دقیق کنید؛ رنگ هر سناریو را جدا بگذارید.",
])
story.append(P("پرسش‌های پرتکرار", h2))
story += bullets([
    "آیا باید نصب کنم؟ نه؛ نسخه قابل‌حمل است: فقط دانلود، Extract All، اجرای pen.exe.",
    "آیا در گوگل‌میت دیده می‌شود؟ بله؛ از نسخه ۱٫۲٫۱ نوشته‌ها در اشتراک صفحه و ضبط هم هستند.",
    "نوشته‌هایم بعد از بستن می‌ماند؟ اگر «یادآوری نقاشی‌ها» روشن باشد بله.",
    "نسخه برنامه کجاست؟ در پنجره تنظیمات پایین صفحه نوشته شده: ۱٫۵٫۰.",
    "اگر چیزی خراب شد چه؟ پوشه عکس‌ها و ابزارها در تنظیمات قابل تغییرند؛ با حذف ابزار اضافه، برنامه سبک می‌شود.",
])
story.append(P("مشخصات این نسخه", h2))
story += bullets([
    "نام: Screen Pen by Hamed Mosaddeghian — نسخه ۱٫۵٫۰ (بیلد ویندوز ۶).",
    "دو ابزار کندل سبز و قرمز با رنگ دلخواه؛ ابزارهای الگوی قدیمی (دوجی، چکش و…) حذف شده‌اند.",
    "دریافت: صفحه Releases در گیت‌هاب — فایل portable-win64.",
    "اجرا برای توسعه‌دهندگان: flutter run -d windows ؛ بررسی: flutter analyze و flutter test.",
])

story.append(Spacer(1, 10))
endbox = [[P("ممنون که از قلم صفحه استفاده می‌کنید — موفق باشید!", ParagraphStyle(
    "end", parent=pill, fontSize=12))]]
et = Table(endbox, colWidths=[480])
et.setStyle(TableStyle([
    ("BACKGROUND", (0, 0), (-1, -1), GREEN),
    ("ROUNDEDCORNERS", [10, 10, 10, 10]),
    ("TOPPADDING", (0, 0), (-1, -1), 10),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 10),
    ("LEFTPADDING", (0, 0), (-1, -1), 10),
    ("RIGHTPADDING", (0, 0), (-1, -1), 10),
]))
story.append(et)


def footer(canvas, doc):
    canvas.saveState()
    canvas.setStrokeColor(PRIMARY)
    canvas.setLineWidth(1)
    canvas.line(40, 30, A4[0] - 40, 30)
    canvas.setFont("Tahoma", 8)
    canvas.setFillColor(GRAY)
    canvas.drawRightString(A4[0] - 40, 18, "")
    canvas.setFont("Helvetica", 8)
    canvas.drawString(40, 18, f"Screen Pen by Hamed Mosaddeghian  v1.5.0  |  p. {doc.page}")
    canvas.setFont("Tahoma", 8)
    canvas.drawRightString(A4[0] - 40, 18,
                           get_display(arabic_reshaper.reshape("بروشور فارسی راهنما")))
    canvas.restoreState()


doc = SimpleDocTemplate(OUT, pagesize=A4, rightMargin=44, leftMargin=44,
                        topMargin=40, bottomMargin=44,
                        title="بروشور قلم صفحه",
                        author="Hamed Mosaddeghian")
doc.build(story, onFirstPage=footer, onLaterPages=footer)
print("PDF:", OUT)
