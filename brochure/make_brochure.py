# -*- coding: utf-8 -*-
"""تصاویر نمای برنامه برای بروشور فارسی قلم صفحه."""
import os
import arabic_reshaper
from bidi.algorithm import get_display
from PIL import Image, ImageDraw, ImageFont

BASE = os.path.dirname(os.path.abspath(__file__))
TAHOMA = r"C:\Windows\Fonts\tahoma.ttf"
TAHOMA_B = r"C:\Windows\Fonts\tahomabd.ttf"


def T(s):
    """شکل‌دهی فارسی برای رسم با Pillow."""
    return get_display(arabic_reshaper.reshape(s))


TOOLBAR_BG = (32, 39, 53)
SELECTED = (45, 138, 199)
ACCENT = (53, 167, 255)
YELLOW = (255, 212, 71)
GREEN = (86, 211, 100)
BULL = (70, 209, 125)
RED = (255, 93, 115)
BEAR = (255, 77, 103)
WHITE = (255, 255, 255)

QUICK = [(53,167,255),(255,212,71),(86,211,100),(255,93,115),
         (255,255,255),(29,36,51),(32,199,183),(198,107,255)]


def font(size, bold=False):
    try:
        return ImageFont.truetype(TAHOMA_B if bold else TAHOMA, size)
    except Exception:
        return ImageFont.load_default()


def save(img, name):
    p = os.path.join(BASE, name)
    img.save(p, "PNG")
    print("image:", p)
    return p


# ---------- ۱) نوار ابزار ----------
def img_toolbar():
    W, H = 480, 1180
    img = Image.new("RGB", (W, H), (240, 243, 247))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([20, 10, 20 + 112, H - 10], 22, fill=TOOLBAR_BG)
    cx = 20 + 56
    y = 30
    d.text((cx, y), "...", fill=(150, 160, 175), font=font(20, True), anchor="ma")
    y += 36
    for label, col in [("S", (120,130,145)), ("W", WHITE), ("B", (120,130,145))]:
        d.rounded_rectangle([cx-30, y, cx+30, y+44], 10,
                            fill=(45,52,66), outline=(70,80,95), width=2)
        d.text((cx, y+22), label, fill=col, font=font(19, True), anchor="mm")
        y += 52
    y += 6
    d.line([40, y, 112, y], fill=(70, 80, 95), width=2)
    y += 14
    tools = [
        ("pen", ACCENT, True), ("hl", YELLOW, False), ("T", ACCENT, False),
        ("!", RED, False), ("N", ACCENT, False), ("line", YELLOW, False),
        ("rect", GREEN, False), ("cg", BULL, True), ("cr", BEAR, True),
    ]
    for kind, col, sel in tools:
        if sel:
            d.rounded_rectangle([cx-32, y-4, cx+32, y+48], 12, fill=SELECTED)
        if kind == "pen":
            d.line([cx-14, y+32, cx+14, y+8], fill=col, width=6)
            d.ellipse([cx+8, y+2, cx+20, y+14], fill=col)
        elif kind == "hl":
            d.rounded_rectangle([cx-16, y+14, cx+16, y+30], 6, fill=col)
        elif kind in ("T", "!", "N"):
            d.text((cx, y+22), kind, fill=col, font=font(24, True), anchor="mm")
        elif kind == "line":
            d.line([cx-16, y+22, cx+16, y+22], fill=col, width=5)
        elif kind == "rect":
            d.rectangle([cx-14, y+8, cx+14, y+36], outline=col, width=4)
        elif kind in ("cg", "cr"):
            d.line([cx, y+4, cx, y+40], fill=col, width=3)
            d.rectangle([cx-9, y+12, cx+9, y+32], fill=col)
        y += 52
    d.line([40, y, 112, y], fill=(70, 80, 95), width=2)
    y += 14
    # پاک‌کن: مستطیل صورتی چرخیده (لوزی)
    d.polygon([(cx-12, y+8), (cx+12, y+2), (cx+12, y+30), (cx-12, y+36)],
              fill=(255, 112, 130))
    y += 50
    # ذره‌بین: دایره + دسته
    d.ellipse([cx-16, y, cx+8, y+24], outline=WHITE, width=4)
    d.line([cx+4, y+20, cx+16, y+36], fill=WHITE, width=4)
    y += 50
    # اشاره‌گر: حلقه + نقطه
    d.ellipse([cx-16, y, cx+16, y+32], outline=(255, 90, 110), width=4)
    d.ellipse([cx-4, y+12, cx+4, y+20], fill=(255, 90, 110))
    y += 50
    d.line([40, y, 112, y], fill=(70, 80, 95), width=2)
    y += 12
    # برگردان: کمان + نوک پیکان
    d.arc([cx-16, y, cx+16, y+30], 20, 300, fill=(200,208,220), width=4)
    d.polygon([(cx-16, y+14), (cx-16, y+26), (cx-26, y+20)], fill=(200,208,220))
    y += 42
    # سطل: بدنه + در
    d.rectangle([cx-12, y+8, cx+12, y+32], outline=(200,208,220), width=3)
    d.line([cx-14, y+8, cx+14, y+8], fill=(200,208,220), width=4)
    d.line([cx-6, y+2, cx+6, y+2], fill=(200,208,220), width=4)
    y += 42
    # دوربین: بدنه + لنز
    d.rounded_rectangle([cx-17, y+6, cx+17, y+32], 5,
                        outline=(200,208,220), width=3)
    d.ellipse([cx-7, y+12, cx+7, y+26], outline=(200,208,220), width=3)
    y += 42
    # تنظیمات: چرخ‌دنده ساده (دایره + پره‌ها)
    for k in range(8):
        import math
        a = math.pi * k / 4
        d.line([cx+math.cos(a)*8, y+18+math.sin(a)*8,
                cx+math.cos(a)*16, y+18+math.sin(a)*16],
               fill=(200,208,220), width=3)
    d.ellipse([cx-8, y+10, cx+8, y+26], outline=(200,208,220), width=3)
    y += 42
    d.text((cx, y+14), "+", fill=(200, 208, 220), font=font(28, True), anchor="mm")
    y += 42
    # رنگ‌های سریع
    y += 4
    for i, c in enumerate(QUICK):
        x = 42 + (i % 2) * 34
        yy = y + (i // 2) * 34
        d.ellipse([x, yy, x+28, yy+28], fill=c,
                  outline=WHITE if c != WHITE else (160,160,160), width=2)
    # برچسب‌های فارسی
    labels = ["قلم", "هایلایتر", "متن", "مهم", "یادداشت", "خط",
              "مستطیل", "کندل سبز", "کندل قرمز"]
    yy = 30 + 36 + 3*52 + 6 + 14 + 26
    for t in labels:
        d.text((440, yy), T(t), fill=(40, 50, 65), font=font(20), anchor="rm")
        yy += 52
    for t in ["پاک‌کن", "ذره‌بین", "اشاره‌گر"]:
        d.text((440, yy+16), T(t), fill=(40, 50, 65), font=font(20), anchor="rm")
        yy += 50
    d.text((440, yy+16), T("برگردان، عکس، تنظیمات"), fill=(40, 50, 65),
           font=font(20), anchor="rm")
    return save(img, "img_toolbar.png")


# ---------- ۲) سه بوم ----------
def img_modes():
    W, H = 1200, 480
    img = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(img)
    titles = [("صفحه", "شفاف روی هر پنجره"),
              ("وایت‌برد", "سفید برای تدریس"),
              ("بلک‌برد", "مشکی برای شب")]
    bgs = [(238,244,250), WHITE, (10, 10, 12)]
    for i, ((t, sub), bg) in enumerate(zip(titles, bgs)):
        x0 = 20 + i * 390
        d.rounded_rectangle([x0, 20, x0+370, H-20], 18, fill=bg,
                            outline=(180,190,205), width=3)
        if i == 0:
            d.line([x0+40, 300, x0+150, 220, x0+220, 250, x0+330, 150],
                   fill=ACCENT, width=5)
            d.ellipse([x0+140, 210, x0+160, 230], fill=RED)
        else:
            fg = ACCENT if i == 1 else YELLOW
            fg2 = RED if i == 1 else GREEN
            d.ellipse([x0+60, 130, x0+200, 250], outline=fg, width=5)
            d.line([x0+220, 140, x0+320, 240], fill=fg2, width=5)
            d.rectangle([x0+70, 270, x0+300, 330], outline=fg, width=4)
        d.text((x0+185, 380), T(t), fill=(30,40,55) if i != 2 else WHITE,
               font=font(26, True), anchor="mm")
        d.text((x0+185, 415), T(sub),
               fill=(100,110,125) if i != 2 else (170,175,185),
               font=font(19), anchor="mm")
    return save(img, "img_modes.png")


# ---------- ۳) ویترین ابزارها ----------
def img_tools():
    W, H = 1200, 560
    img = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([10, 10, W-10, H-10], 20, outline=(180,190,205), width=3)
    d.line([60,120,150,80,240,110,330,70], fill=ACCENT, width=5, joint="curve")
    d.text((195, 145), T("قلم"), fill=(40,50,65), font=font(22, True), anchor="mm")
    d.rounded_rectangle([400, 80, 700, 115], 10, fill=(255, 212, 71))
    d.text((550, 145), T("هایلایتر"), fill=(40,50,65), font=font(22, True), anchor="mm")
    d.line([760, 95, 1100, 95], fill=RED, width=6)
    d.line([930, 60, 930, 150], fill=RED, width=4)
    d.text((930, 145), T("خط"), fill=(40,50,65), font=font(22, True), anchor="mm")
    d.rectangle([60, 230, 250, 330], outline=GREEN, width=5)
    d.rectangle([300, 230, 490, 330], fill=(86,211,100))
    d.text((275, 360), T("مستطیل توخالی و توپر"), fill=(40,50,65),
           font=font(22, True), anchor="mm")
    d.text((640, 260), "Important", fill=RED, font=font(40, True), anchor="mm")
    d.text((640, 320), "Note", fill=ACCENT, font=font(36, True), anchor="mm")
    d.text((640, 360), T("متن آماده با یک کلیک"), fill=(40,50,65),
           font=font(22, True), anchor="mm")
    for j, (x, o, c, col) in enumerate([(830, 300, 220, BULL), (900, 280, 240, BULL),
                                        (970, 230, 300, BEAR), (1040, 250, 320, BEAR)]):
        d.line([x, o-30, x, c+30], fill=col, width=4)
        d.rectangle([x-16, min(o,c), x+16, max(o,c)], fill=col)
    d.text((935, 360), T("کندل سبز و قرمز"), fill=(40,50,65),
           font=font(22, True), anchor="mm")
    d.text((600, 435), T("پاک‌کن: با کلیک یا کشیدن یک شکل را پاک کنید"),
           fill=(80,90,105), font=font(21), anchor="mm")
    d.text((600, 480), T("ضخامت قلم: ۲ تا ۲۰  •  اندازه متن: ۱۲ تا ۷۲"),
           fill=(80,90,105), font=font(21), anchor="mm")
    return save(img, "img_tools.png")


# ---------- ۴) نمای نزدیک کندل ----------
def img_candles():
    W, H = 1200, 520
    img = Image.new("RGB", (W, H), (13, 20, 32))
    d = ImageDraw.Draw(img)
    for gx in range(60, W-20, 80):
        d.line([gx, 20, gx, H-90], fill=(30, 40, 58), width=2)
    for gy in range(40, H-80, 60):
        d.line([40, gy, W-20, gy], fill=(30, 40, 58), width=2)
    seq = [(120,300,200,BULL),(200,260,280,BULL),(280,240,300,BEAR),
           (360,220,320,BULL),(440,300,240,BEAR),(520,280,200,BEAR),
           (600,220,140,BULL),(680,180,220,BULL),(760,240,180,BEAR),
           (840,200,120,BULL),(920,160,200,BULL),(1000,220,150,BEAR)]
    for x, o, c, col in seq:
        d.line([x, o-45, x, c+45], fill=col, width=5)
        d.rectangle([x-22, min(o,c), x+22, max(o,c)], fill=col)
    d.text((600, H-50), T("بالا بکشید = صعودی (سبز)  •  پایین بکشید = نزولی (قرمز)"),
           fill=(200,210,225), font=font(23, True), anchor="mm")
    return save(img, "img_candles.png")


# ---------- ۵) ذره‌بین و اشاره‌گر ----------
def img_mag():
    W, H = 1200, 500
    img = Image.new("RGB", (W, H), (35, 45, 60))
    d = ImageDraw.Draw(img)
    d.ellipse([180, 200, 300, 320], outline=(255, 90, 110), width=6)
    d.ellipse([228, 248, 252, 272], fill=(255, 90, 110))
    d.text((240, 355), T("حلقه اشاره‌گر"), fill=WHITE, font=font(22, True), anchor="mm")
    d.rounded_rectangle([450, 150, 950, 400], 24, fill=WHITE, outline=ACCENT, width=5)
    d.text((700, 240), T("جزئیات نمودار، درشت و خوانا"), fill=(30,40,55),
           font=font(32, True), anchor="mm")
    d.text((700, 305), T("بزرگ‌نمایی ۲ و ۴ و ۸ برابر"), fill=(200,60,80),
           font=font(28, True), anchor="mm")
    d.text((700, 355), T("اندازه عدسی: کوچک، متوسط، بزرگ"), fill=(80,90,105),
           font=font(22), anchor="mm")
    return save(img, "img_magnifier.png")


# ---------- ۶) تنظیمات ----------
def img_settings():
    W, H = 1100, 620
    img = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([60, 20, W-60, H-20], 22, fill=(250,251,253),
                        outline=(180,190,205), width=3)
    d.text((W//2, 70), T("تنظیمات"), fill=(30,40,55), font=font(30, True), anchor="mm")
    rows = [("پوشش نوار وظیفه ویندوز", True), ("نشانگر ارائه", True),
            ("یادآوری نقاشی‌ها", True), ("رنگ‌های سریع بزرگ", False)]
    y = 130
    for t, on in rows:
        d.text((W-140, y), T(t), fill=(40,50,65), font=font(22), anchor="rm")
        d.rounded_rectangle([120, y-18, 190, y+18], 18,
                            fill=SELECTED if on else (200,205,215))
        d.ellipse([152 if on else 120, y-18, 190 if on else 158, y+18], fill=WHITE)
        y += 62
    d.text((W-140, y+10), T("پوشه عکس‌ها: Pictures"), fill=(40,50,65),
           font=font(21), anchor="rm")
    d.rounded_rectangle([120, y-12, 230, y+32], 10, outline=SELECTED, width=3)
    d.text((175, y+10), T("انتخاب"), fill=SELECTED, font=font(20, True), anchor="mm")
    y += 85
    d.text((W-140, y), T("قلم، هایلایتر، متن، خط، مستطیل، کندل سبز، کندل قرمز"),
           fill=(40,50,65), font=font(21), anchor="rm")
    y += 46
    d.text((W-140, y), T("افزودن ابزار تازه، حذف ابزار اضافه"),
           fill=(80,90,105), font=font(20), anchor="rm")
    return save(img, "img_settings.png")


if __name__ == "__main__":
    img_toolbar(); img_modes(); img_tools(); img_candles(); img_mag(); img_settings()
