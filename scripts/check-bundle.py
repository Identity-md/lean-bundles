"""Reads one bundle as the IMD worker's reader does (packages/daemon/src/task/fetch.ts, extractTar, worker 0.1.45) and
says why the worker would refuse it, or nothing. Fed the archive's tar stream on stdin (zstd -dc <file> | python3 -I
scripts/check-bundle.py <compressed bytes>), it writes nothing to disk. The released worker bundles its reader into its
command, so it cannot be called on its own; these are its rules, one by one:

- a member's name, `./` and trailing slashes dropped, is never empty, absolute, holds no backslash or NUL, and has no
  `..` or empty part: `./` alone, the archive's own root, is refused;
- the worker's own records (`.imd-bytes`, `.imd-complete`) are never a top-level name;
- only plain files, folders, symbolic links and hard links: no device, pipe or other kind;
- nothing is written through a link, and nothing takes the place of a member of another kind;
- a symbolic link is relative, stays inside the root, and leads to a member the archive holds;
- a hard link names a plain file written before it;
- at most 200,000 members, and at most min(48 GiB, max(1 GiB, 16 times the archive's size), the 24 GiB cache) unpacked.
"""
import posixpath
import re
import sys
import tarfile

MAX_MEMBERS = 200_000
GIB = 1024 ** 3
OWN_RECORDS = {".imd-bytes", ".imd-complete"}


def member_path(raw):
    path = re.sub(r"^(\./)+", "", raw)
    path = re.sub(r"/+$", "", path)
    if path == "" or path.startswith("/") or "\0" in path or "\\" in path:
        return None
    parts = path.split("/")
    if any(part in ("..", "") for part in parts):
        return None
    return "/".join(part for part in parts if part != ".") or None


def main():
    compressed = int(sys.argv[1])
    limit = min(48 * GIB, max(GIB, compressed * 16), 24 * GIB)
    kinds = {}
    sizes = {}
    links = {}
    written = 0
    count = 0
    problems = []

    def refuse(reason):
        problems.append(reason)
        return len(problems) >= 10

    with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as archive:
        for member in archive:
            count += 1
            if count > MAX_MEMBERS:
                refuse(f"more than {MAX_MEMBERS} members")
                break
            path = member_path(member.name)
            if path is None:
                if refuse(f"names {member.name!r}, outside its own root"):
                    break
                continue
            if path.split("/")[0].lower() in OWN_RECORDS:
                if refuse(f"names {path}, where the worker keeps its own record"):
                    break
                continue
            parents = path.split("/")[:-1]
            if any(links.get("/".join(parents[: i + 1])) is not None for i in range(len(parents))):
                if refuse(f"{path} would be written through a link"):
                    break
                continue
            kind = "dir" if member.isdir() else "file" if member.isreg() else "symlink" if member.issym() else "hardlink" if member.islnk() else None
            if kind is None:
                if refuse(f"{path} is of a kind ({member.type!r}) no prebuilt file holds"):
                    break
                continue
            there = kinds.get(path)
            if there is not None and not (there == kind == "dir") and not (there == "file" and kind in ("file", "hardlink")):
                if refuse(f"{path} would take the place of a {there}"):
                    break
                continue
            if kind == "file":
                written += -(-member.size // 512) * 512
                sizes[path] = member.size
            elif kind == "symlink":
                target = member.linkname
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
                if not target or target.startswith("/") or resolved == ".." or resolved.startswith("../"):
                    if refuse(f"{path} links outside the archive ({target})"):
                        break
                    continue
                links[path] = resolved
            elif kind == "hardlink":
                source = member_path(member.linkname)
                if source is None or kinds.get(source) != "file":
                    if refuse(f"{path} links to {member.linkname}, which is not a file the archive holds"):
                        break
                    continue
                written += sizes[source]
                sizes[path] = sizes[source]
            kinds[path] = "file" if kind == "hardlink" else kind
            if written > limit:
                refuse(f"unpacks to more than {limit} bytes")
                break

    # Every link must lead to something the archive holds, through any number of other links.
    for path, resolved in links.items():
        seen = set()
        while resolved in links and resolved not in seen:
            seen.add(resolved)
            resolved = links[resolved]
        if resolved != "." and resolved not in kinds:
            if refuse(f"{path} leads nowhere ({resolved})"):
                break

    if problems:
        for problem in problems:
            print(f"::error::the IMD worker's reader would refuse this archive: {problem}")
        sys.exit(1)
    print(f"{count} members, {written} bytes unpacked (limit {limit}), {len(links)} links: the worker's reader takes it")


main()
