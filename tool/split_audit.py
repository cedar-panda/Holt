#!/usr/bin/env python3
"""純搬家拆檔審核工具（晏辭寫給 Codex 自查、給晏辭審核用）。

原理：把「拆檔前」與「拆檔後」同一組檔案的代碼去掉空白、註解、尾逗號，
再以 ; { } 切成片段做多重集合比對。純搬家時，換行、縮排、檔案位置都不影響結果；
只要有任何邏輯被改、被刪、被多寫，就會出現在差異清單裡。

用法：
  python3 tool/split_audit.py --base <拆檔前的 commit> <glob> [<glob> ...]
例：
  python3 tool/split_audit.py --base HEAD~1 'lib/memory/database*.dart'
  python3 tool/split_audit.py --base abc1234 'lib/screens/theme_workshop*.dart' 'lib/widgets/theme_workshop/*.dart'

預期：
  「只在拆檔前」→ 應該是空的（任何一條都代表有代碼消失或被改）。
  「只在拆檔後」→ 只允許：part / part of、類殼（class _XxxStore {、extension ... on ... {）、
                   轉發 stub（=> _XxxStore.方法(...)）、補上的 DatabaseHelper. / 類名前綴已自動忽略。
"""
import argparse
import collections
import fnmatch
import re
import subprocess
import sys
from pathlib import Path

PREFIX_RE = re.compile(r'\b(?:DatabaseHelper|_[A-Z][A-Za-z0-9]*(?:Store|Methods|Migrations|Invalidation|Schema))\.')


def strip_dart(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        # 字串原樣保留（含三引號）
        for q in ("'''", '"""', "'", '"'):
            if src.startswith(q, i):
                j = i + len(q)
                while j < n and not src.startswith(q, j):
                    j += 2 if src[j] == '\\' else 1
                out.append(src[i:j + len(q)])
                i = j + len(q)
                break
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def fragments(src: str):
    s = strip_dart(src)
    s = PREFIX_RE.sub('', s)  # 必須在去空白之前，否則 \b 判斷會失效
    s = re.sub(r'\s+', '', s)
    s = re.sub(r',(?=[)\]}])', '', s)  # 尾逗號
    parts = re.split(r'[;{}]', s)
    return [p for p in parts if p and not p.startswith(('part', 'import', 'library'))]


def files_at(base: str, globs):
    names = subprocess.run(['git', 'ls-tree', '-r', '--name-only', base],
                           capture_output=True, text=True, check=True).stdout.split()
    return sorted({f for f in names for g in globs if fnmatch.fnmatch(f, g)})


def files_now(globs):
    return sorted({str(p) for g in globs for p in Path('.').glob(g) if p.is_file()})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', required=True)
    ap.add_argument('globs', nargs='+')
    a = ap.parse_args()

    before = collections.Counter()
    for f in files_at(a.base, a.globs):
        src = subprocess.run(['git', 'show', f'{a.base}:{f}'],
                             capture_output=True, text=True, check=True).stdout
        before.update(fragments(src))
    after = collections.Counter()
    now = files_now(a.globs)
    for f in now:
        after.update(fragments(Path(f).read_text(encoding='utf-8')))

    lost = before - after
    added = after - before
    print(f'檔案（拆檔後）：{len(now)} 個')
    for f in now:
        print(f'  {sum(1 for _ in open(f, encoding="utf-8")):6d}  {f}')
    print(f'\n只在拆檔前（應為 0）：{sum(lost.values())}')
    for frag, k in lost.most_common(60):
        print(f'  -[{k}] {frag[:160]}')
    print(f'\n只在拆檔後（只該是 part/類殼/轉發）：{sum(added.values())}')
    for frag, k in added.most_common(80):
        print(f'  +[{k}] {frag[:160]}')
    sys.exit(1 if lost else 0)


if __name__ == '__main__':
    main()
