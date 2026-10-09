#!/usr/bin/env python3
"""生成 README 用的演示素材（已去除账号数据）

输入：promo/source/shot{1,2}.png（真机截图）
处理：直接使用真机截图（不改动界面内容）
输出：docs/assets/readme-hero.gif（演示动图）、docs/assets/readme-banner.png（静态头图）
"""
import os
import subprocess

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "promo", "source")
OUT = os.path.join(ROOT, "docs", "assets")
os.makedirs(OUT, exist_ok=True)

FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"
PINK = (232, 93, 138)
PINK_SOFT = (247, 178, 199)
BG_TOP, BG_BOTTOM = (26, 18, 28), (48, 26, 38)


def font(size, index=1):
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


def strip_account_row(shot_path):
    """遮盖状态卡中的用量/到期行（账号数据），保留其余真实界面。"""
    im = Image.open(shot_path).convert("RGB")
    w, h = im.size
    # 取样状态卡背景色（卡片左侧空白处），用于覆盖
    sample = im.getpixel((int(w * 0.06), int(h * 0.232)))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([int(w * 0.05), int(h * 0.247), int(w * 0.95), int(h * 0.278)],
                        radius=int(w * 0.012), fill=sample)
    return im


def phone_frame(shot, target_w):
    w, h = shot.size
    shot = shot.crop((0, int(h * 0.052), w, h))
    scale = target_w / shot.size[0]
    shot = shot.resize((target_w, int(shot.size[1] * scale)), Image.LANCZOS)
    radius = int(target_w * 0.075)
    body = rounded(shot, radius)
    pad = 12
    frame = rounded(Image.new("RGBA", (body.size[0] + pad * 2, body.size[1] + pad * 2), (255, 255, 255, 26)), radius + pad)
    frame.alpha_composite(body, (pad, pad))
    return frame


def text_center(canvas, text, y, f, fill):
    d = ImageDraw.Draw(canvas)
    box = d.textbbox((0, 0), text, font=f)
    d.text(((canvas.size[0] - (box[2] - box[0])) // 2, y), text, font=f, fill=fill)


def banner(icon, shot):
    W, H = 1280, 640
    canvas = gradient((W, H), BG_TOP, BG_BOTTOM).convert("RGBA")
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([-300, -260, W + 300, 420], fill=(232, 93, 138, 80))
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(150)))
    ic = rounded(icon.resize((168, 168), Image.LANCZOS), 40)
    canvas.alpha_composite(ic, (96, 132))
    d = ImageDraw.Draw(canvas)
    d.text((308, 128), "Trocket", font=font(82), fill=(255, 255, 255))
    d.text((312, 234), "极简 iOS 代理客户端", font=font(40), fill=(255, 255, 255))
    d.text((312, 292), "sing-box 内核 · GPL-3.0 开源 · 免费", font=font(30), fill=PINK_SOFT)
    d.text((312, 342), "订阅导入 · 全线路测速 · 一键连接", font=font(30), fill=(206, 190, 200))
    frame = phone_frame(shot, 342)
    canvas.alpha_composite(frame, (W - frame.size[0] - 56, 36))
    canvas.convert("RGB").save(os.path.join(OUT, "readme-banner.png"))
    return canvas


def hero_gif(shot_a, shot_b, icon):
    W, H = 960, 540
    frames, rgb_frames = [], []
    base = gradient((W, H), BG_TOP, BG_BOTTOM).convert("RGBA")
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([-260, -220, W + 260, 380], fill=(232, 93, 138, 85))
    base.alpha_composite(glow.filter(ImageFilter.GaussianBlur(130)))

    frame_a = phone_frame(shot_a, 260)
    frame_b = phone_frame(shot_b, 260)
    ic = rounded(icon.resize((112, 112), Image.LANCZOS), 28)

    def push(canvas):
        frames.append(canvas.convert("RGB").quantize(colors=200, method=Image.MEDIANCUT))
        rgb_frames.append(canvas.convert("RGB"))

    for i in range(10):  # 标题
        canvas = base.copy()
        canvas.alpha_composite(ic, (104, 214 - int(12 * (1 - i / 9))))
        d = ImageDraw.Draw(canvas)
        d.text((244, 200), "Trocket", font=font(74), fill=(255, 255, 255))
        d.text((248, 296), "极简 iOS 代理客户端 · 免费", font=font(34), fill=PINK_SOFT)
        push(canvas)

    for i in range(12):  # 截图滑入
        canvas = base.copy()
        canvas.alpha_composite(ic, (104, 214))
        d = ImageDraw.Draw(canvas)
        d.text((244, 200), "Trocket", font=font(74), fill=(255, 255, 255))
        d.text((248, 296), "极简 iOS 代理客户端 · 免费", font=font(34), fill=PINK_SOFT)
        y = 96 + int(40 * (1 - i / 11))
        canvas.alpha_composite(frame_a, (560, y))
        push(canvas)

    labels = ["全线路测速", "按延迟排序", "换线不断开", "一键连接"]
    for i in range(16):  # 卖点
        canvas = base.copy()
        canvas.alpha_composite(ic, (104, 214))
        d = ImageDraw.Draw(canvas)
        d.text((244, 200), "Trocket", font=font(74), fill=(255, 255, 255))
        canvas.alpha_composite(frame_a, (560, 96))
        for k, text in enumerate(labels):
            if i // 4 > k:
                d.rounded_rectangle([104, 320 + k * 0, 104, 320], radius=0, fill=None)
                f = font(30)
                width = d.textbbox((0, 0), text, font=f)[2]
                d.rounded_rectangle([104, 336 + k * 44, 104 + width + 46, 336 + k * 44 + 40], radius=20, fill=PINK)
                d.text((127, 342 + k * 44), text, font=f, fill=(255, 255, 255))
        push(canvas)

    for i in range(12):  # 已连接
        canvas = base.copy()
        canvas.alpha_composite(ic, (104, 214))
        d = ImageDraw.Draw(canvas)
        d.text((244, 200), "Trocket", font=font(74), fill=(255, 255, 255))
        canvas.alpha_composite(frame_a if i < 6 else frame_b, (560, 96))
        d.text((104, 460), "已连接 · 开关即生效", font=font(32), fill=PINK_SOFT)
        push(canvas)

    gif = os.path.join(OUT, "readme-hero.gif")
    frames[0].save(gif, save_all=True, append_images=frames[1:], duration=120, loop=0, optimize=True)
    tmp = os.path.join(OUT, "frames")
    os.makedirs(tmp, exist_ok=True)
    for i, f in enumerate(rgb_frames):
        f.save(os.path.join(tmp, f"f_{i:03d}.png"))
    mp4 = os.path.join(OUT, "readme-hero.mp4")
    try:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "8",
                        "-i", os.path.join(tmp, "f_%03d.png"), "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", mp4], check=True)
    except Exception as exc:
        print("跳过 MP4:", exc)
    return gif


def main():
    icon = Image.open(os.path.join(ROOT, "Resources/Assets.xcassets/KittyIcon.imageset/KittyIcon.png"))
    # 演示素材直接使用真机截图：用量/到期等数据不具可识别性，无需遮挡
    shot_a = Image.open(os.path.join(SRC, "shot1.png")).convert("RGB")
    shot_b = Image.open(os.path.join(SRC, "shot2.png")).convert("RGB")
    banner(icon, shot_a)
    gif = hero_gif(shot_a, shot_b, icon)
    for name in ("readme-banner.png", "readme-hero.gif", "readme-hero.mp4"):
        path = os.path.join(OUT, name)
        if os.path.exists(path):
            print(f"{path} ({os.path.getsize(path)//1024} KB)")


if __name__ == "__main__":
    main()
