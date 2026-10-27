#!/usr/bin/env python3
"""Small, fail-closed configuration helper. Python 3.6+, standard library only."""
import json
import os
import re
import sys
import uuid
from pathlib import Path

BEGIN = '# BEGIN XRAY-QUICK-DEPLOY'
END = '# END XRAY-QUICK-DEPLOY'


def credentials(user_id, route, port):
    if str(uuid.UUID(user_id)) != user_id.lower():
        raise ValueError('UUID 格式不符合预期。')
    if not re.fullmatch(r'/api/[0-9a-f]{32}/', route):
        raise ValueError('路径必须是本方案生成的 /api/<32位十六进制>/。')
    if not 1024 <= int(port) <= 65535:
        raise ValueError('后端端口必须介于 1024 和 65535。')


def read_xray(filename, port):
    p = Path(filename)
    if not p.exists():
        return ['empty']
    cfg = json.loads(p.read_text(encoding='utf-8'))
    if cfg == {}:
        return ['empty']
    ins = cfg.get('inbounds', [])
    outs = cfg.get('outbounds', [])
    if (len(ins) != 1 or len(outs) != 1 or
            outs[0].get('protocol') != 'freedom' or cfg.get('routing')):
        raise ValueError('已有配置不是本方案的单入站、直接出站配置；未覆盖。')
    i = ins[0]
    s = i.get('settings', {})
    t = i.get('streamSettings', {})
    x = t.get('xhttpSettings', {})
    users = s.get('clients') or s.get('users') or []
    if (i.get('tag') != 'vless-xhttp-in' or i.get('protocol') != 'vless' or
            i.get('listen') != '127.0.0.1' or i.get('port') != int(port) or
            s.get('decryption') != 'none' or len(users) != 1 or
            users[0].get('flow') or t.get('network') != 'xhttp' or
            t.get('security') != 'none' or x.get('mode') != 'auto'):
        raise ValueError('已有入站参数与本方案不一致；未覆盖，请检查配置及 XRAY_PORT。')
    user_id, route = users[0]['id'], x['path']
    credentials(user_id, route, port)
    return ['ready', user_id, route, str(port)]


def write_xray(filename, user_id, route, port):
    credentials(user_id, route, port)
    cfg = {
        'log': {'access': 'none', 'loglevel': 'warning'},
        'inbounds': [{
            'tag': 'vless-xhttp-in', 'listen': '127.0.0.1',
            'port': int(port), 'protocol': 'vless',
            'settings': {'clients': [{'id': user_id}], 'decryption': 'none'},
            'streamSettings': {
                'network': 'xhttp', 'security': 'none',
                'xhttpSettings': {'path': route, 'mode': 'auto'}
            }
        }],
        'outbounds': [{'tag': 'direct', 'protocol': 'freedom'}]
    }
    Path(filename).write_text(json.dumps(cfg, indent=2) + '\n', encoding='utf-8')


def tokenize(text):
    """Keep source offsets; understand comments, quotes, escapes and ${vars}."""
    tokens = []
    i, size = 0, len(text)
    while i < size:
        if text[i].isspace():
            i += 1
            continue
        if text[i] == '#':
            j = text.find('\n', i)
            i = size if j < 0 else j + 1
            continue
        start = i
        if text[i] in '{};':
            tokens.append((text[i], start, i + 1, 'punct'))
            i += 1
            continue
        chars = []
        quote = None
        while i < size:
            c = text[i]
            if c == '\\':
                if i + 1 >= size:
                    raise ValueError('Nginx 配置末尾存在未完成的转义。')
                chars.append(text[i + 1])
                i += 2
            elif quote:
                if c == quote:
                    quote = None
                else:
                    chars.append(c)
                i += 1
            elif c in "\"'":
                quote = c
                i += 1
            elif text.startswith('${', i):
                end = text.find('}', i + 2)
                if end < 0:
                    raise ValueError('Nginx 配置含未闭合的 ${变量}。')
                chars.append(text[i:end + 1])
                i = end + 1
            elif c.isspace() or c in '{};#':
                break
            else:
                chars.append(c)
                i += 1
        if quote:
            raise ValueError('Nginx 配置含未闭合引号。')
        if i == start:
            raise ValueError('无法识别 Nginx 配置。')
        tokens.append((''.join(chars), start, i, 'word'))
    return tokens


def parse(text):
    tokens = tokenize(text)

    def level(pos, nested=False):
        nodes = []
        while pos < len(tokens):
            if tokens[pos][0] == '}' and tokens[pos][3] == 'punct':
                if not nested:
                    raise ValueError('Nginx 配置有多余的右括号。')
                return nodes, pos + 1, tokens[pos][1]
            start = tokens[pos][1]
            words = []
            while pos < len(tokens) and tokens[pos][3] == 'word':
                words.append(tokens[pos][0])
                pos += 1
            if not words or pos >= len(tokens):
                raise ValueError('Nginx 配置指令不完整。')
            punctuation = tokens[pos][0]
            opening = tokens[pos][2]
            pos += 1
            if punctuation == ';':
                nodes.append({'words': words, 'start': start, 'open': None,
                              'close': tokens[pos - 1][1], 'children': []})
            elif punctuation == '{':
                children, pos, closing = level(pos, True)
                nodes.append({'words': words, 'start': start, 'open': opening,
                              'close': closing, 'children': children})
            else:
                raise ValueError('Nginx 配置存在无法安全处理的语法。')
        if nested:
            raise ValueError('Nginx 配置缺少右括号。')
        return nodes, pos, len(text)
    return level(0)[0]


def target_server(nodes, domain):
    matches = []
    for n in nodes:
        if n['words'] == ['http']:
            matches.extend(target_candidates(n['children'], domain))
    matches.extend(target_candidates(nodes, domain))
    if len(matches) != 1:
        raise ValueError('必须在指定文件中唯一找到 server_name 精确包含该域名、'
                         '并直接 listen 443 ssl 的 server 块；实际找到 {} 个。'
                         .format(len(matches)))
    return matches[0]


def target_candidates(nodes, domain):
    matches = []
    for n in nodes:
        if n['words'] != ['server']:
            continue
        names, tls443 = [], False
        for child in n['children']:
            words = child['words']
            if words[0] == 'server_name':
                names.extend(w.lower().rstrip('.') for w in words[1:])
            if words[0] == 'listen' and len(words) > 1 and 'ssl' in words[2:]:
                tls443 = tls443 or words[1] == '443' or words[1].endswith(':443')
        if domain in names and tls443:
            matches.append(n)
    return matches


def route_block(route, port):
    credentials('00000000-0000-4000-8000-000000000000', route, port)
    return '''    # BEGIN XRAY-QUICK-DEPLOY
    location ^~ %s {
        proxy_pass http://127.0.0.1:%s;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_intercept_errors off;
        proxy_next_upstream off;
        gzip off;
        client_max_body_size 20m;
        client_body_timeout 3600s;
        proxy_connect_timeout 5s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        send_timeout 3600s;
        access_log off;
    }
    # END XRAY-QUICK-DEPLOY
''' % (route, port)


def patch_nginx(text, domain, route, port):
    server = target_server(parse(text), domain)
    starts = list(re.finditer(r'(?m)^[ \t]*' + re.escape(BEGIN) + r'[ \t]*\r?$', text))
    ends = list(re.finditer(r'(?m)^[ \t]*' + re.escape(END) + r'[ \t]*\r?$', text))
    if len(starts) != len(ends) or len(starts) > 1:
        raise ValueError('受管标记不完整或不唯一，未修改。')
    span = None
    if starts:
        start, end = starts[0].start(), ends[0].end()
        if not server['open'] <= start < end <= server['close']:
            raise ValueError('受管路由不在指定 HTTPS server 内，未修改。')
        if text[end:end + 1] == '\n':
            end += 1
        span = start, end
        managed = [n for n in server['children']
                   if start <= n['start'] < end]
        if (len(managed) != 1 or managed[0]['words'][0:2] != ['location', '^~'] or
                not start < managed[0]['close'] < end):
            raise ValueError('受管标记范围不是独立的 location，未修改。')
    for n in server['children']:
        if n['words'][0] == 'location' and route in n['words'][1:]:
            if not span or not span[0] <= n['start'] < span[1]:
                raise ValueError('该路径已有手工 location；请保留现有配置并使用 check，'
                                 '或自行处理重复路由后再运行 nginx 阶段。')
    block = route_block(route, port)
    if span:
        return text[:span[0]] + block + text[span[1]:]
    closing = server['close']
    line_start = text.rfind('\n', 0, closing) + 1
    insertion = line_start if not text[line_start:closing].strip() else closing
    return text[:insertion] + '\n' + block + text[insertion:]


def main(args):
    action = args[0]
    if action == 'xray-read':
        print('\n'.join(read_xray(args[1], args[2])))
    elif action == 'xray-write':
        write_xray(*args[1:])
    elif action == 'nginx-write':
        source, destination, domain, route, port = args[1:]
        text = Path(source).read_text(encoding='utf-8')
        updated = patch_nginx(text, domain, route, port)
        Path(destination).write_text(updated, encoding='utf-8')
        print('unchanged' if updated == text else 'changed')
    elif action == 'included':
        dump, site = args[1:]
        paths = re.findall(r'^# configuration file (.+):$',
                           Path(dump).read_text(encoding='utf-8'), re.M)
        if os.path.realpath(site) not in [os.path.realpath(p) for p in paths]:
            raise ValueError('指定站点文件没有被当前 Nginx 主配置加载。')
    else:
        raise ValueError('未知工具动作。')


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (ValueError, OSError, KeyError, TypeError, IndexError, AttributeError) as exc:
        sys.exit('配置检查失败：{}'.format(exc))
