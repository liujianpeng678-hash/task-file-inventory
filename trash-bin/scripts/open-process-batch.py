"""建立一个带初始标记的过程文件批次。"""

import argparse
import json
from pathlib import Path, PureWindowsPath


def batch_name(value):
    p = PureWindowsPath(value)
    if (
        not value.strip()
        or value.endswith((".", " "))
        or len(p.parts) != 1
        or value in (".", "..")
        or p.drive
        or p.is_reserved()
        or any(char in value for char in '<>:"/\\\\|?*')
    ):
        raise argparse.ArgumentTypeError("批次须为合法的单一目录名")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True, help="既有项目或工具垃圾堆目录")
    parser.add_argument("--kind", choices=("任务类", "工具类"), required=True)
    parser.add_argument("--owner", required=True, help="任务或工具名")
    parser.add_argument("--batch", required=True, type=batch_name)
    parser.add_argument("--purpose", required=True)
    args = parser.parse_args()

    root = args.root.resolve(strict=True)
    if not root.is_dir() or not any(part.casefold() == ".task-trash" for part in root.parts):
        parser.error("根目录须位于既有 .task-trash 目录内")
    path = root / args.batch
    if path.resolve() != path:
        parser.error("批次目录被重定向")
    identity = {"归属类型": args.kind, "归属": args.owner, "批次": args.batch}
    mark = path / "过程标记.json"
    if path.exists():
        current = json.loads(mark.read_text(encoding="utf-8"))
        if any(current.get(key) != value for key, value in identity.items()):
            parser.error("已存在批次的归属不一致")
    else:
        path.mkdir()
        current = {**identity, "用途": args.purpose, "目录": str(path), "状态": "处理中", "依据": ""}
        with mark.open("x", encoding="utf-8") as output:
            json.dump(current, output, ensure_ascii=False, indent=2)
    print(json.dumps({"目录": str(path), "标记": str(mark), "状态": current["状态"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
