#!/usr/bin/env python3
"""fieldnotes — 两文件部署版的 ASGI 应用（uvicorn 直接跑，不依赖 Starlette）。

    uvicorn fieldnotes:app --host 127.0.0.1 --port 8080 --no-access-log
    python3 fieldnotes.py --port 8080        # 等价的本机临时启动

同目录的 fieldnotes.html 是页面（样式与脚本已内联）；图集数据、favicon、
占位图都内嵌在本文件里，因此没有 data/、assets/ 之类的目录。

与仓库版的关系：页面/CSS/JS/数据由 scripts/build_dist.py 从仓库生成；
路由层是手写的 ASGI（不引入 Starlette），接口契约保持一致：
/api/gallery、/api/image/{id}?size=、POST /api/contact，
错误统一 {"error":{"code","message"}}，留言只校验、不保存。
"""

from __future__ import annotations

import base64
import hashlib
import json
import re
import sys
from pathlib import Path
from urllib.parse import parse_qs

HERE = Path(__file__).resolve().parent
DEFAULT_HTML = HERE / "fieldnotes.html"

CATEGORY_LABELS = {"mountains": "山野", "coast": "海岸", "forest": "林间"}
IMAGE_SIZES = {
    "small": ("480", "320"),
    "medium": ("960", "640"),
    "hero": ("1600", "900"),
    "large": ("1920", "1280"),
}
ITEM_ID_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
MAX_QUERY_BYTES = 128
MAX_CONTACT_BYTES = 8192
CONTACT_LIMITS = {"name": 40, "contact": 80, "message": 1000}
TEXT_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
MESSAGE_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")

# 由 scripts/build_dist.py 在生成时写入；数据已在构建阶段通过仓库加载器校验。
GALLERY_JSON = r"""
{
  "schema_version": 1,
  "catalog_version": "v1",
  "hero_id": "mountains-06",
  "items": [
    {
      "id": "mountains-01",
      "picsum_id": "231",
      "title": "层叠的山脊",
      "category": "mountains",
      "note": "近处的草坡先从阴影里亮起来，岩层的折线一层压着一层，最后淡进远处的蓝灰雾气。",
      "author": "Aleksandra Boguslawska",
      "source_url": "https://unsplash.com/photos/XeCvtUX-AE0",
      "width": 4088,
      "height": 2715,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "mountains-02",
      "picsum_id": "327",
      "title": "冰川下的碎石坡",
      "category": "mountains",
      "note": "雪线之下是赭红的碎石与冰碛，天空干净，只剩一枚很小的月亮。冷暖在同一条山脊上分开。",
      "author": "Ryan Schroeder",
      "source_url": "https://unsplash.com/photos/Gg7uKdHFb_c",
      "width": 4442,
      "height": 2961,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "mountains-03",
      "picsum_id": "830",
      "title": "雾里的蓝色山峦",
      "category": "mountains",
      "note": "山一层比一层淡，像被水洗过。雾把距离变得柔和，视线沿着深蓝的轮廓一直走到最远处。",
      "author": "Luca Zanon",
      "source_url": "https://unsplash.com/photos/X0OoHrPvgXE",
      "width": 5000,
      "height": 3333,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "mountains-04",
      "picsum_id": "1043",
      "title": "岩壁与河湾",
      "category": "mountains",
      "note": "浅色的岩壁从林后竖起来，河面收进树影。近处的沙洲空着，给画面留出一块安静的底色。",
      "author": "Christian Joudrey",
      "source_url": "https://unsplash.com/photos/mWRR1xj95hg",
      "width": 5000,
      "height": 3333,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "mountains-05",
      "picsum_id": "906",
      "title": "孤峰",
      "category": "mountains",
      "note": "整座山只露出一个尖，其余都交给清透的天。雪的棱线被侧光描过一遍，暗部沉得干净。",
      "author": "Andras Toth",
      "source_url": "https://unsplash.com/photos/E9CrQou9K0Y",
      "width": 3840,
      "height": 2880,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "mountains-06",
      "picsum_id": "984",
      "title": "光落进山谷",
      "category": "mountains",
      "note": "云影压住大半片山地，只有中间一段被照亮。草色从金黄过渡到深绿，像谷底有人点了一盏灯。",
      "author": "Sylvain Guiheneuc",
      "source_url": "https://unsplash.com/photos/hIMdKs_0cSE",
      "width": 4000,
      "height": 2248,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "mountains-07",
      "picsum_id": "894",
      "title": "高原上的水色",
      "category": "mountains",
      "note": "赭红的坡地一路铺到湖边，水是淡青色。灌丛被晒成金，画面静得几乎没有风。",
      "author": "Paula Porto",
      "source_url": "https://unsplash.com/photos/Fma1wE_zIf8",
      "width": 5000,
      "height": 3333,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "mountains-08",
      "picsum_id": "377",
      "title": "星空下的雪峰",
      "category": "mountains",
      "note": "夜里山体只剩轮廓，雪面反着微光。云被风拉成长条，星星密得让深蓝的天显得很浅。",
      "author": "Martin Staněk",
      "source_url": "https://unsplash.com/photos/8WClaa1CmZ0",
      "width": 4884,
      "height": 3256,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "coast-01",
      "picsum_id": "218",
      "title": "峡口的水",
      "category": "coast",
      "note": "两侧岩壁像门一样立着，中间的水从青绿慢慢加深。阴天的光把颜色压得很稳。",
      "author": "Monika Majkowska",
      "source_url": "https://unsplash.com/photos/Nq8LdWC7HnM",
      "width": 4752,
      "height": 3168,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "coast-02",
      "picsum_id": "12",
      "title": "退潮之后",
      "category": "coast",
      "note": "近处的礁石还带着湿意，远处沙面被水抚平。一条浅浅的浪线横过画面，把视线送向小岛。",
      "author": "Paul Jarvis",
      "source_url": "https://unsplash.com/photos/I_9ILwtsl_k",
      "width": 2500,
      "height": 1667,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "coast-03",
      "picsum_id": "1052",
      "title": "黑沙滩上的石柱",
      "category": "coast",
      "note": "玄武岩柱立在白色的浪里，沙是深灰的。整幅几乎没有颜色，只剩黑白之间的层次。",
      "author": "Annie Spratt",
      "source_url": "https://unsplash.com/photos/x8R2oSWZRSE",
      "width": 4000,
      "height": 2667,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "coast-04",
      "picsum_id": "323",
      "title": "岬角与深蓝",
      "category": "coast",
      "note": "山坡顺着岸线收下去，海水在湾里变成很深的蓝。前景的灌丛偏黄，给冷色留了一点暖。",
      "author": "Paweł Wojciechowski",
      "source_url": "https://unsplash.com/photos/QYAojSRu82c",
      "width": 3831,
      "height": 2554,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "coast-05",
      "picsum_id": "516",
      "title": "被拉长的浪",
      "category": "coast",
      "note": "浪被时间拉成丝，绕着礁石散开。天边留一线金光，沙滩的暗色把整幅压得很沉。",
      "author": "Owen Walters",
      "source_url": "https://unsplash.com/photos/8C-TxFyk6UE",
      "width": 3008,
      "height": 2000,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "coast-06",
      "picsum_id": "404",
      "title": "浪撞上岩壁",
      "category": "coast",
      "note": "水花在半空散开，岩石的纹理被溅湿后更清楚。俯视的角度让海面显得拥挤，也显得有力。",
      "author": "Cole Patrick",
      "source_url": "https://unsplash.com/photos/H28ODcp4EUk",
      "width": 3264,
      "height": 2176,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "coast-07",
      "picsum_id": "1050",
      "title": "海蚀柱",
      "category": "coast",
      "note": "几块浅色岩体站在青绿的水里，浪在它们之间挤成白线。岸边的植被一路垂到水边。",
      "author": "Joseph Barrientos",
      "source_url": "https://unsplash.com/photos/xcC5ozHk_N8",
      "width": 5000,
      "height": 3333,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "coast-08",
      "picsum_id": "849",
      "title": "海岸线的弧",
      "category": "coast",
      "note": "绿色坡地弯出一道弧，沙滩与海水在下面接住它。云影落在海面上，远处几乎看不见边。",
      "author": "Rob Bye",
      "source_url": "https://unsplash.com/photos/OlZ1nWLEEgM",
      "width": 3202,
      "height": 2401,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "forest-01",
      "picsum_id": "229",
      "title": "雾里的林道",
      "category": "forest",
      "note": "树干的竖线一直排进雾里，小路在中间微微转弯。湿土与落叶的颜色让整幅偏冷。",
      "author": "Orlova Maria",
      "source_url": "https://unsplash.com/photos/7FLh300YONc",
      "width": 2300,
      "height": 1533,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "forest-02",
      "picsum_id": "498",
      "title": "抬头看树冠",
      "category": "forest",
      "note": "视线从地面抬起来，树干向中心收拢，光从针叶的缝隙漏下。整幅像一张撑开的网。",
      "author": "Kim Daniel",
      "source_url": "https://unsplash.com/photos/JsqAqevX6lg",
      "width": 5000,
      "height": 3333,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "forest-03",
      "picsum_id": "423",
      "title": "雪压枝头",
      "category": "forest",
      "note": "雪一层层堆在枝条上，雾把背后的林子抹淡。光从侧面来，雪面泛着很浅的粉。",
      "author": "Gabriel Santiago",
      "source_url": "https://unsplash.com/photos/pTgTMVxQE_k",
      "width": 5000,
      "height": 3333,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "forest-04",
      "picsum_id": "502",
      "title": "林间的光柱",
      "category": "forest",
      "note": "阳光斜穿过树干，落在青苔上拉出长影。暗部很重，亮的草地像被单独点过。",
      "author": "Sven Schlager",
      "source_url": "https://unsplash.com/photos/xzjouTJASSA",
      "width": 1920,
      "height": 1280,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "forest-05",
      "picsum_id": "767",
      "title": "笔直的路",
      "category": "forest",
      "note": "两侧的松树一样高，路一直延伸到看不见的尽头。湿路面留着浅浅的反光，安静得没有人。",
      "author": "Sébastien Marchand",
      "source_url": "https://unsplash.com/photos/EeEx8zpOESA",
      "width": 3069,
      "height": 2048,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "forest-06",
      "picsum_id": "932",
      "title": "雾漫过林梢",
      "category": "forest",
      "note": "云从坡上滑下来，把树冠分成明暗两半。秋色只有零星几点，更多的还是深绿。",
      "author": "Vadim Sherbakov",
      "source_url": "https://unsplash.com/photos/NQSWvyVRIJk",
      "width": 5000,
      "height": 3333,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "forest-07",
      "picsum_id": "466",
      "title": "林中小溪",
      "category": "forest",
      "note": "水在石头间压低声音流过，两岸的绿被树影调暗。偏冷的色调让画面带着没干透的湿气。",
      "author": "Caleb George",
      "source_url": "https://unsplash.com/photos/zZzKLzKP24o",
      "width": 3264,
      "height": 2176,
      "reviewed_at": "2026-10-28"
    },
    {
      "id": "forest-08",
      "picsum_id": "216",
      "title": "苔藓与落叶",
      "category": "forest",
      "note": "镜头贴近地面，落叶铺成一条窄路，青苔把两侧填满。焦点只落在中间一小段。",
      "author": "Paul Jarvis",
      "source_url": "https://unsplash.com/photos/9702xTENR-M",
      "width": 2500,
      "height": 1667,
      "reviewed_at": "2026-10-28"
    }
  ]
}
"""

FAVICON_SVG = r"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <rect width="32" height="32" rx="6" fill="#232722"/>
  <circle cx="22.5" cy="10.5" r="2.2" fill="#697A60"/>
  <path d="M5 23.5 12.5 12.8 17.4 19.4 21.2 14.6 27 23.5" fill="none" stroke="#F5F3EE" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
"""

PLACEHOLDER_SVG = r"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 800">
  <rect width="1200" height="800" fill="#F5F3EE"/>
  <circle cx="900" cy="252" r="26" fill="none" stroke="#697A60" stroke-width="6" opacity="0.5"/>
  <g fill="none" stroke="#697A60" stroke-width="6" stroke-linecap="round" stroke-linejoin="round" opacity="0.5">
    <path d="M240 560 430 330 560 480 680 350 900 560"/>
    <path d="M330 560 470 420 590 560"/>
  </g>
  <path d="M180 610H1020" stroke="#DDDCD5" stroke-width="4"/>
</svg>
"""

NOT_FOUND_HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>页面不存在 — fieldnotes.</title>
<style>
  body { margin: 0; min-height: 100vh; display: grid; place-items: center;
         background: #F5F3EE; color: #232722;
         font-family: -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; }
  main { max-width: 32rem; padding: 2rem; }
  p.code { margin: 0 0 .6rem; color: #60685E; font-size: .85rem; letter-spacing: .08em; }
  h1 { margin: 0 0 1rem; font-size: 1.6rem; line-height: 1.4; }
  a { color: #232722; text-underline-offset: .2em; }
</style>
</head>
<body>
<main>
  <p class="code">404</p>
  <h1>这一页没有被收进册子。</h1>
  <p><a href="/">返回首页</a></p>
</main>
</body>
</html>
"""


def _load_catalog() -> tuple[bytes, dict[str, str]]:
    """把内嵌清单编译成公开 JSON（一次性）与 id→picsum_id 索引。"""

    raw = json.loads(GALLERY_JSON)
    items = []
    picsum_by_id: dict[str, str] = {}
    for item in raw["items"]:
        item_id = item["id"]
        picsum_by_id[item_id] = str(item["picsum_id"])
        items.append(
            {
                "id": item_id,
                "title": item["title"],
                "category": item["category"],
                "note": item["note"],
                "author": item["author"],
                "source_url": item["source_url"],
                "images": {
                    size: f"/api/image/{item_id}?size={size}" for size in IMAGE_SIZES
                },
            }
        )
    public = {
        "schema_version": 1,
        "catalog_version": raw["catalog_version"],
        "hero_id": raw["hero_id"],
        "categories": [
            {"id": key, "label": label} for key, label in CATEGORY_LABELS.items()
        ],
        "items": items,
    }
    payload = json.dumps(public, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return payload, picsum_by_id


GALLERY_BYTES, PICSUM_BY_ID = _load_catalog()


def _inline_hashes(html: str) -> tuple[list[str], list[str]]:
    """给内联 <style>/<script> 算 CSP 哈希，避免为内联开 unsafe-inline。"""

    def digest(block: str) -> str:
        return "'sha256-" + base64.b64encode(
            hashlib.sha256(block.encode("utf-8")).digest()
        ).decode() + "'"

    styles = [digest(b) for b in re.findall(r"<style>(.*?)</style>", html, re.S)]
    scripts = [
        digest(b)
        for b in re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", html, re.S)
    ]
    return styles, scripts


def _csp(style_hashes: list[str], script_hashes: list[str]) -> str:
    script_src = " ".join(["'self'", *script_hashes, "https://cdn.jsdelivr.net"])
    style_src = " ".join(["'self'", *style_hashes])
    return (
        f"default-src 'self'; script-src {script_src}; style-src {style_src}; "
        "img-src 'self' https://picsum.photos https://fastly.picsum.photos; "
        "connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; "
        "frame-ancestors 'none'; form-action 'self'"
    )


class PageCache:
    """按 mtime+size 缓存页面与 CSP 哈希：改了 html 不必重启服务。"""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._key: tuple[int, int] | None = None
        self._html = ""
        self._hashes: tuple[list[str], list[str]] = ([], [])

    def get(self) -> tuple[str, tuple[list[str], list[str]]]:
        stat = self.path.stat()
        key = (stat.st_mtime_ns, stat.st_size)
        if key != self._key:
            self._html = self.path.read_text(encoding="utf-8")
            self._hashes = _inline_hashes(self._html)
            self._key = key
        return self._html, self._hashes


NOT_FOUND_HASHES = _inline_hashes(NOT_FOUND_HTML)
PAGE = PageCache(DEFAULT_HTML)


# ---------------------------------------------------------------------------
# 响应构造
# ---------------------------------------------------------------------------


def _json_bytes(payload: dict) -> bytes:
    return json.dumps(payload, ensure_ascii=False).encode("utf-8")


async def _respond(send, status: int, headers: dict[str, str], body: bytes, head: bool) -> None:
    raw = [(key.lower().encode("latin-1"), value.encode("latin-1")) for key, value in headers.items()]
    raw.append((b"content-length", str(len(body)).encode("latin-1")))
    await send({"type": "http.response.start", "status": status, "headers": raw})
    await send({"type": "http.response.body", "body": b"" if head else body})


async def _error(send, status: int, code: str, message: str, head: bool, extra=None) -> None:
    headers = {"content-type": "application/json", "cache-control": "no-store",
               "x-content-type-options": "nosniff"}
    if extra:
        headers.update(extra)
    await _respond(send, status, headers, _json_bytes({"error": {"code": code, "message": message}}), head)


async def _page(send, status: int, html: str, hashes, head: bool) -> None:
    await _respond(
        send,
        status,
        {
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-cache",
            "content-security-policy": _csp(*hashes),
            "x-content-type-options": "nosniff",
            "referrer-policy": "strict-origin-when-cross-origin",
            "x-frame-options": "DENY",
        },
        html.encode("utf-8"),
        head,
    )


async def _read_body(receive, limit: int) -> bytes | None:
    total = 0
    chunks: list[bytes] = []
    while True:
        message = await receive()
        if message["type"] == "http.disconnect":
            return None
        chunk = message.get("body", b"")
        total += len(chunk)
        if total > limit:
            return None
        chunks.append(chunk)
        if not message.get("more_body"):
            return b"".join(chunks)


def _validate_contact(payload: dict) -> bool:
    if set(payload) != set(CONTACT_LIMITS):
        return False
    for field, limit in CONTACT_LIMITS.items():
        value = payload[field]
        if not isinstance(value, str):
            return False
        value = value.strip()
        if not value or len(value) > limit:
            return False
        pattern = MESSAGE_CONTROL_RE if field == "message" else TEXT_CONTROL_RE
        if pattern.search(value):
            return False
    return True


# ---------------------------------------------------------------------------
# ASGI
# ---------------------------------------------------------------------------


async def app(scope, receive, send) -> None:
    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return

    if scope["type"] != "http":  # pragma: no cover - 只处理 HTTP
        return

    method = scope["method"]
    head = method == "HEAD"
    path = scope["path"]
    query = scope.get("query_string", b"").decode("latin-1")

    # ---- 页面 ----
    if path in ("/", "/index.html"):
        if query:
            await _error(send, 400, "bad_request", "请求参数无效", head)
        elif method not in ("GET", "HEAD"):
            await _error(send, 405, "method_not_allowed", "请求方法不受支持", head, {"allow": "GET, HEAD"})
        else:
            html, hashes = PAGE.get()
            await _page(send, 200, html, hashes, head)
        return

    if path in ("/contact", "/contact/"):
        await _respond(send, 308, {"location": "/#contact", "cache-control": "no-store"}, b"", head)
        return

    # ---- 静态小资源 ----
    if path in ("/favicon.svg", "/assets/placeholder.svg", "/placeholder.svg"):
        svg = FAVICON_SVG if path == "/favicon.svg" else PLACEHOLDER_SVG
        await _respond(
            send,
            200,
            {"content-type": "image/svg+xml", "cache-control": "public, max-age=3600",
             "x-content-type-options": "nosniff"},
            svg.encode("utf-8"),
            head,
        )
        return

    # ---- API ----
    if path == "/api/gallery":
        if query:
            await _error(send, 400, "bad_request", "请求参数无效", head)
        elif method not in ("GET", "HEAD"):
            await _error(send, 405, "method_not_allowed", "请求方法不受支持", head, {"allow": "GET, HEAD"})
        else:
            await _respond(
                send,
                200,
                {"content-type": "application/json", "cache-control": "public, max-age=300",
                 "x-content-type-options": "nosniff"},
                GALLERY_BYTES,
                head,
            )
        return

    if path.startswith("/api/image/"):
        if method not in ("GET", "HEAD"):
            await _error(send, 405, "method_not_allowed", "请求方法不受支持", head, {"allow": "GET, HEAD"})
            return
        await _image(send, path, query, head)
        return

    if path == "/api/contact":
        if method != "POST":
            await _error(send, 405, "method_not_allowed", "请求方法不受支持", head, {"allow": "POST"})
            return
        await _contact(scope, receive, send)
        return

    if path == "/api" or path.startswith("/api/"):
        await _error(send, 404, "not_found", "资源不存在", head)
        return

    # ---- 404 ----
    await _page(send, 404, NOT_FOUND_HTML, NOT_FOUND_HASHES, head)


async def _image(send, path: str, query: str, head: bool) -> None:
    if len(query.encode("utf-8")) > MAX_QUERY_BYTES:
        await _error(send, 400, "bad_request", "请求参数无效", head)
        return
    pairs = parse_qs(query, keep_blank_values=True)
    if any(key != "size" for key in pairs):
        await _error(send, 400, "bad_request", "请求参数无效", head)
        return
    sizes = pairs.get("size", [])
    if len(sizes) > 1:
        await _error(send, 400, "bad_request", "请求参数无效", head)
        return
    size = sizes[0] if sizes else "medium"
    if size not in IMAGE_SIZES:
        await _error(send, 400, "bad_request", "请求参数无效", head)
        return

    image_id = path[len("/api/image/"):]
    if not ITEM_ID_RE.fullmatch(image_id):
        await _error(send, 404, "not_found", "资源不存在", head)
        return
    picsum_id = PICSUM_BY_ID.get(image_id)
    if picsum_id is None:
        await _error(send, 404, "not_found", "资源不存在", head)
        return

    width, height = IMAGE_SIZES[size]
    await _respond(
        send,
        302,
        {
            "location": f"https://picsum.photos/id/{picsum_id}/{width}/{height}.webp",
            "cache-control": "public, max-age=3600",
            "x-content-type-options": "nosniff",
        },
        b"",
        head,
    )


async def _contact(scope, receive, send) -> None:
    headers = {key.decode("latin-1").lower(): value.decode("latin-1") for key, value in scope["headers"]}
    declared = headers.get("content-length")
    if declared is not None:
        try:
            if int(declared) > MAX_CONTACT_BYTES:
                await _error(send, 400, "bad_request", "请求参数无效", False)
                return
        except ValueError:
            await _error(send, 400, "bad_request", "请求参数无效", False)
            return

    raw = await _read_body(receive, MAX_CONTACT_BYTES)
    if raw is None:
        await _error(send, 400, "bad_request", "请求参数无效", False)
        return

    content_type = headers.get("content-type", "").split(";")[0].strip().lower()
    is_form = content_type == "application/x-www-form-urlencoded"
    try:
        if content_type == "application/json":
            payload = json.loads(raw.decode("utf-8"))
            if not isinstance(payload, dict):
                raise ValueError
        elif is_form:
            pairs = parse_qs(raw.decode("utf-8"), keep_blank_values=True)
            if any(len(values) != 1 for values in pairs.values()):
                raise ValueError
            payload = {key: values[0] for key, values in pairs.items()}
        else:
            raise ValueError
    except (ValueError, UnicodeDecodeError):
        await _error(send, 400, "bad_request", "请求参数无效", False)
        return

    if not _validate_contact(payload):
        await _error(send, 400, "bad_request", "请求参数无效", False)
        return

    # 校验通过即丢弃：不写磁盘、不打印内容、不转发。
    if is_form:
        await _respond(send, 303, {"location": "/#contact", "cache-control": "no-store"}, b"", False)
        return
    await _respond(
        send,
        202,
        {"content-type": "application/json", "cache-control": "no-store",
         "x-content-type-options": "nosniff"},
        _json_bytes({"status": "received"}),
        False,
    )


def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="fieldnotes 两文件部署版")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args(argv)

    try:
        import uvicorn
    except ImportError:
        print(
            "未安装 uvicorn。先在虚拟环境里安装：python -m pip install uvicorn",
            file=sys.stderr,
        )
        return 1

    if not DEFAULT_HTML.is_file():
        print(f"读不到页面文件 {DEFAULT_HTML}", file=sys.stderr)
        return 1

    uvicorn.run(app, host=args.host, port=args.port, workers=1, access_log=False, log_level="warning")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())