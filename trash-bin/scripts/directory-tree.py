"""只读生成整目录清扫的身份和元数据指纹；不搬移、不删除文件。"""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def inspect(root):
    root = Path(os.path.abspath(root))
    for parent in (root, *root.parents):
        if parent.exists() and parent.lstat().st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            raise ValueError('目录或祖先含链接/占位符，拒绝整体搬移')
    if not root.is_dir():
        raise ValueError('目录不存在')
    if any((p / '.git').exists() for p in root.parents):
        raise ValueError('目录属于Git仓库，拒绝整体搬移')
    if os.environ.get('GIT_DIR') or os.environ.get('GIT_WORK_TREE'):
        raise ValueError('检测到Git环境，拒绝整体搬移')
    display_root = root
    # 垃圾堆批次路径比原路径更长；Windows遍历和stat均使用扩展路径。
    if os.name == 'nt' and not str(root).startswith('\\\\?\\'):
        root = Path('\\\\?\\' + str(root))
    h = hashlib.sha256()
    count = dirs = total = 0
    for base, names, files in os.walk(root, followlinks=False):
        for name in sorted(names + files):
            p = Path(base) / name
            if name.lower() in {'.git', '.codex', '.agents', 'agents.md', 'agents.override.md'} or name.lower().startswith('.env'):
                raise ValueError('目录内含受保护配置或Git：' + str(p))
            s = p.lstat()
            if s.st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                raise ValueError('目录内含链接/占位符：' + str(p))
            directory = stat.S_ISDIR(s.st_mode)
            entry = [str(p.relative_to(root)), directory, s.st_ino, s.st_size if not directory else 0,
                     s.st_mtime_ns, s.st_file_attributes]
            h.update(json.dumps(entry, ensure_ascii=False, separators=(',', ':')).encode('utf-8'))
            h.update(b'\n')
            if directory:
                dirs += 1
            else:
                count += 1
                total += s.st_size
        names.sort()
    s = root.stat()
    return {'path': str(display_root), 'inode': s.st_ino, 'device': s.st_dev,
            'tree_sha256': h.hexdigest(), 'files': count, 'directories': dirs,
            'logical_bytes': total,
            'fingerprint_kind': 'relative paths, file identities, lengths, mtimes, attributes; not file content hash'}


if __name__ == '__main__':
    try:
        print(json.dumps(inspect(sys.argv[1]), ensure_ascii=True))
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
