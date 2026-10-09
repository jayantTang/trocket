#!/usr/bin/env python3
"""Trocket 宣传素材生成：App Store 截图（1290×2796）+ 宣传动图（GIF/MP4）

素材：promo/source/shot{1,2,3}.png（真机截图，深色模式）
输出：promo/out/appstore-{1,2,3}.png、promo/out/trocket-promo.gif、promo/out/trocket-promo.mp4
风格：与图标一致的粉色系（脸 #F494AC / 鼻 #D65C7A / 底 #FAD2DE），深色背景衬托深色 UI。
"""
import os
import subprocess

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "promo", "source")
OUT = os.path.join(ROOT, "promo", "out")
os.makedirs(OUT, exist_ok=True)

W, H = 1290, 2796
PINK = (232, 93, 138)
PINK_SOFT = (247, 178, 199)
INK = (255, 255, 255)
BG_TOP = (26, 18, 28)
BG_BOTTOM = (48, 26, 38)
FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"   # macOS 上可用的中文黑体（PingFang.ttc 在部分版本不存在）


def font(size, index=1):
    """Hiragino Sans GB：index 1 ≈ W6（偏粗），index 0 ≈ W3。"""
    try:
        return ImageFont.truetype(FONT, size, index=index)
    except OSError:
        return ImageFont.truetype("/System/Library/Fonts/STHeiti Medium.ttc", size)


def gradient(size, top, bottom):
    w, h = size
    img = Image.new("RGB", size, top)
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(h - 1, 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def phone_frame(shot_path, target_w):
    """把真机截图裁掉系统状态栏并套上圆角机身。"""
    shot = Image.open(shot_path).convert("RGB")
    w, h = shot.size
    shot = shot.crop((0, int(h * 0.052), w, h))          # 去掉顶部状态栏
    scale = target_w / shot.size[0]
    shot = shot.resize((target_w, int(shot.size[1] * scale)), Image.LANCZOS)
    radius = int(target_w * 0.075)
    body = rounded(shot, radius)
    pad = 14
    frame = Image.new("RGBA", (body.size[0] + pad * 2, body.size[1] + pad * 2), (255, 255, 255, 26))
    frame = rounded(frame, radius + pad)
    frame.alpha_composite(body, (pad, pad))
    return frame


def paste_centered(canvas, img, y):
    canvas.alpha_composite(img, ((canvas.size[0] - img.size[0]) // 2, y))


def text_center(canvas, text, y, f, fill):
    d = ImageDraw.Draw(canvas)
    box = d.textbbox((0, 0), text, font=f)
    d.text(((canvas.size[0] - (box[2] - box[0])) // 2, y), text, font=f, fill=fill)


def make_shot(shot_path, headline, sub, out_name, tilt=False):
    canvas = gradient((W, H), BG_TOP, BG_BOTTOM).convert("RGBA")
    # 顶部粉色光晕
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([-W // 3, -int(H * 0.28), W + W // 3, int(H * 0.30)], fill=(232, 93, 138, 70))
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(180)))
    text_center(canvas, headline, int(H * 0.062), font(92), INK)
    text_center(canvas, sub, int(H * 0.062) + 122, font(50, index=1), PINK_SOFT)
    frame = phone_frame(shot_path, int(W * 0.78))
    if tilt:
        frame = frame.rotate(-2.2, resample=Image.BICUBIC, expand=True)
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow.alpha_composite(frame, ((W - frame.size[0]) // 2, int(H * 0.195) + 26))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(60)))
    paste_centered(canvas, frame, int(H * 0.195))
    canvas.convert("RGB").save(os.path.join(OUT, out_name), quality=95)
    return canvas


def mask_subscription_url(img_path):
    """订阅页里的链接做隐私遮挡（订阅链接等同账号凭证）。"""
    im = Image.open(img_path).convert("RGB")
    d = ImageDraw.Draw(im)
    w, h = im.size
    d.rounded_rectangle([int(w * 0.06), int(h * 0.205), int(w * 0.94), int(h * 0.262)],
                        radius=28, fill=(58, 58, 66))
    masked_text = "https://••••••••/link/••••••"
    f = font(int(w * 0.038), 1)
    box = d.textbbox((0, 0), masked_text, font=f)
    d.text((int(w * 0.06) + (int(w * 0.88) - (box[2] - box[0])) // 2, int(h * 0.221)),
           masked_text, font=f, fill=(150, 150, 158))
    out = os.path.join(SRC, "shot3-masked.png")
    im.save(out)
    return out


def make_animation(shot_a, shot_b):
    AW, AH = 1080, 1920
    frames = []
    rgb_frames = []
    base = gradient((AW, AH), BG_TOP, BG_BOTTOM).convert("RGBA")
    glow = Image.new("RGBA", (AW, AH), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([-AW // 3, -400, AW + AW // 3, 700], fill=(232, 93, 138, 80))
    base.alpha_composite(glow.filter(ImageFilter.GaussianBlur(160)))

    icon = Image.open(os.path.join(ROOT, "Resources/Assets.xcassets/KittyIcon.imageset/KittyIcon.png")).convert("RGBA")

    def icon_scaled(size):
        return icon.resize((size, size), Image.LANCZOS)

    # 1) 图标 + 标题
    for i in range(10):
        t = i / 9
        canvas = base.copy()
        size = int(180 + 40 * (1 - t))
        ic = icon_scaled(size)
        ic = rounded(ic, int(size * 0.24))
        paste_centered(canvas, ic, int(AH * 0.32) + int(20 * (1 - t)))
        text_center(canvas, "Trocket", int(AH * 0.52), font(118), INK)
        text_center(canvas, "极简 · 快速 · 免费", int(AH * 0.52) + 150, font(56, 1), PINK_SOFT)
        frames.append(canvas.convert("RGB").quantize(colors=200, method=Image.MEDIANCUT))
        rgb_frames.append(canvas.convert("RGB"))

    # 2) 截图滑入
    frame_a = phone_frame(shot_a, 720)
    frame_b = phone_frame(shot_b, 720)
    for i in range(14):
        t = i / 13
        canvas = base.copy()
        y = int(AH * 0.20 + 420 * (1 - t))
        paste_centered(canvas, frame_a, y)
        text_center(canvas, "一键测速 · 未连接也能测", int(AH * 0.075), font(62), INK)
        frames.append(canvas.convert("RGB").quantize(colors=200, method=Image.MEDIANCUT))
        rgb_frames.append(canvas.convert("RGB"))

    # 3) 卖点浮出
    chips = ["一键测速", "自动选线", "换线不断开", "完全免费"]
    for i in range(16):
        canvas = base.copy()
        paste_centered(canvas, frame_a, int(AH * 0.20))
        for k, text in enumerate(chips):
            if i // 4 > k:
                f = font(44, 1)
                d = ImageDraw.Draw(canvas)
                box = d.textbbox((0, 0), text, font=f)
                tw = box[2] - box[0]
                x = (AW - tw) // 2
                y = int(AH * 0.70) + k * 76
                d.rounded_rectangle([x - 34, y - 14, x + tw + 34, y + 62], radius=38, fill=(232, 93, 138, 235))
                d.text((x, y), text, font=f, fill=(255, 255, 255))
        frames.append(canvas.convert("RGB").quantize(colors=200, method=Image.MEDIANCUT))
        rgb_frames.append(canvas.convert("RGB"))

    # 4) 已连接
    for i in range(12):
        t = i / 11
        canvas = base.copy()
        shot = frame_a if t < 0.5 else frame_b
        paste_centered(canvas, shot, int(AH * 0.20))
        text_center(canvas, "已连接 · 一键开关", int(AH * 0.075), font(62), INK)
        frames.append(canvas.convert("RGB").quantize(colors=200, method=Image.MEDIANCUT))
        rgb_frames.append(canvas.convert("RGB"))

    # 5) 结束卡
    for i in range(12):
        canvas = base.copy()
        ic = rounded(icon_scaled(150), 36)
        paste_centered(canvas, ic, int(AH * 0.34))
        text_center(canvas, "Trocket", int(AH * 0.48), font(112), INK)
        text_center(canvas, "免费 · TestFlight 公测中", int(AH * 0.48) + 146, font(54, 1), PINK_SOFT)
        frames.append(canvas.convert("RGB").quantize(colors=200, method=Image.MEDIANCUT))
        rgb_frames.append(canvas.convert("RGB"))

    gif = os.path.join(OUT, "trocket-promo.gif")
    frames[0].save(gif, save_all=True, append_images=frames[1:], duration=110, loop=0, optimize=True)

    # MP4：将 RGB 帧落盘后交给 ffmpeg（分享用，比 GIF 清晰）
    mp4 = os.path.join(OUT, "trocket-promo.mp4")
    tmp = os.path.join(OUT, "frames")
    os.makedirs(tmp, exist_ok=True)
    for i, f in enumerate(rgb_frames):
        f.save(os.path.join(tmp, f"f_{i:03d}.png"))
    try:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "9",
                        "-i", os.path.join(tmp, "f_%03d.png"),
                        "-vf", "scale=1080:1920", "-c:v", "libx264", "-pix_fmt", "yuv420p", mp4], check=True)
    except Exception as exc:
        print("跳过 MP4:", exc)
    return gif, mp4


def main():
    a = os.path.join(SRC, "shot1.png")
    b = os.path.join(SRC, "shot2.png")
    c = os.path.join(SRC, "shot3.png")
    make_shot(a, "一键测速，线路快慢一目了然", "未连接也能测 · 按延迟排序", "appstore-1.png")
    make_shot(b, "一键连接，换线无需断开", "开关即生效 · 实时流量显示", "appstore-2.png")
    masked = mask_subscription_url(c)
    make_shot(masked, "订阅导入，凭证只存在本机", "不上传第三方 · 无账号体系", "appstore-3.png")
    gif, mp4 = make_animation(a, b)
    print("已生成：")
    for name in ("appstore-1.png", "appstore-2.png", "appstore-3.png"):
        p = os.path.join(OUT, name)
        print(f"  {p} ({os.path.getsize(p)//1024} KB)")
    print(f"  {gif} ({os.path.getsize(gif)//1024} KB)")
    print(f"  {mp4} ({os.path.getsize(mp4)//1024} KB)" if os.path.exists(mp4) else "  （未生成 MP4）")


if __name__ == "__main__":
    main()
