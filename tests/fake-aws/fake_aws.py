#!/usr/bin/env python3
"""偽の AWS CLI。

checkRisk.sh を AWS に接続せずに動かすためのスタブ。
  - 応答は tests/fixtures/<service>/<operation>[__<引数値>].json から返す
  - --query は jmespath で評価し、--output text は CLI の表示形式を模倣する
  - fixture が {"__error__": "..."} なら、その文字列を stderr に出して 254 で終了（API エラーの模倣）
  - 呼び出しは FAKE_AWS_LOG に1行ずつ記録する（読み取り専用 API しか使っていないかの検証に使う）

fixture の探索順:
  1. <operation>__<最初の固有オプションの値を [A-Za-z0-9._-] 以外 '_' に置換したもの>.json
  2. <operation>.json
"""
import json
import os
import re
import sys

try:
    import jmespath
except ImportError:  # pragma: no cover
    sys.stderr.write("fake-aws: jmespath が必要です（pip install jmespath、または FAKE_AWS_PYTHON に AWS CLI 同梱の python を指定）\n")
    sys.exit(253)

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.environ.get("FAKE_AWS_FIXTURES") or os.path.join(HERE, "..", "fixtures", "sample")
LOG = os.environ.get("FAKE_AWS_LOG")

# fixture 名の決定に使わない共通オプション
GLOBAL_OPTS = {
    "--region", "--output", "--query", "--profile", "--no-paginate", "--max-items",
    "--starting-token", "--page-size", "--no-cli-pager", "--cli-read-timeout",
    "--all-availability-zones", "--include-shadow-trails", "--no-include-shadow-trails",
}
# 値を取らないフラグ
FLAG_OPTS = {
    "--no-paginate", "--all-availability-zones", "--no-cli-pager",
    "--include-shadow-trails", "--no-include-shadow-trails",
}


def parse(argv):
    if not argv:
        sys.stderr.write("usage: aws <service> <operation> [options]\n")
        sys.exit(252)
    if argv[0] == "--version":
        print("aws-cli/2.0.0-fake Python/3 fake/fake")
        sys.exit(0)
    if len(argv) < 2:
        sys.stderr.write("fake-aws: operation がありません\n")
        sys.exit(252)
    service, op = argv[0], argv[1]
    opts, order = {}, []
    i = 2
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            if a in FLAG_OPTS or i + 1 >= len(argv) or argv[i + 1].startswith("--"):
                opts[a] = True
                i += 1
            else:
                opts[a] = argv[i + 1]
                order.append(a)
                i += 2
        else:
            i += 1
    return service, op, opts, order


def sanitize(value):
    return re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("_")


def validate_ids(opts):
    """実 API と同様に、空白を含む ID は不正として拒否する。"""
    for k, v in opts.items():
        if k.endswith("-ids") or k.endswith("-id"):
            if isinstance(v, str) and re.search(r"\s", v):
                sys.stderr.write(f"An error occurred (InvalidParameterValue) when calling the operation: Invalid id: \"{v}\"\n")
                sys.exit(254)


def load(service, op, opts, order):
    base = os.path.join(FIXTURES, service)
    candidates = []
    for k in order:
        if k in GLOBAL_OPTS:
            continue
        candidates.append(os.path.join(base, f"{op}__{sanitize(opts[k])}.json"))
        break  # 最初の固有オプションだけを見る
    candidates.append(os.path.join(base, f"{op}.json"))
    for c in candidates:
        if os.path.exists(c):
            with open(c, encoding="utf-8") as f:
                return json.load(f), candidates
    return None, candidates


def to_text(v):
    """AWS CLI の --output text を必要十分に模倣する。"""
    if v is None:
        return "None"
    if isinstance(v, bool):
        return "True" if v else "False"
    if isinstance(v, (int, float, str)):
        return str(v)
    if isinstance(v, list):
        if not v:
            return ""
        if all(not isinstance(x, (list, dict)) for x in v):
            return "\t".join(to_text(x) for x in v)
        return "\n".join(to_text(x) for x in v)
    if isinstance(v, dict):
        lines = []
        for k, x in v.items():
            if isinstance(x, list) and x and all(not isinstance(y, (list, dict)) for y in x):
                lines.append(k.upper() + "\t" + "\t".join(to_text(y) for y in x))
            elif isinstance(x, (list, dict)):
                t = to_text(x)
                if t:
                    lines.append(t)
            else:
                lines.append(to_text(x))
        return "\n".join(lines)
    return str(v)


def main():
    service, op, opts, order = parse(sys.argv[1:])
    if LOG:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(" ".join(sys.argv[1:]) + "\n")
    validate_ids(opts)
    data, tried = load(service, op, opts, order)
    if data is None:
        sys.stderr.write(f"fake-aws: fixture がありません: {service} {op} (tried: {', '.join(tried)})\n")
        sys.exit(254)
    if isinstance(data, dict) and "__error__" in data:
        sys.stderr.write(data["__error__"] + "\n")
        sys.exit(254)
    if "--query" in opts:
        data = jmespath.search(opts["--query"], data)
    if opts.get("--output") == "text":
        text = to_text(data)
        if text != "":
            print(text)
    else:
        print(json.dumps(data, indent=4, ensure_ascii=False, default=str))


if __name__ == "__main__":
    main()
