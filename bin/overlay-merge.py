#!/usr/bin/env python3
"""Merge N overlayfs layers into a single directory, properly handling whiteouts."""

import os
import sys
import shutil
import stat


def is_whiteout(path):
    """Check if path is an overlayfs whiteout (char device 0/0)."""
    try:
        st = os.lstat(path)
        if stat.S_ISCHR(st.st_mode) and st.st_rdev == 0:
            return True
    except OSError:
        pass
    return False


def is_opaque_dir(path):
    """Check if directory is opaque (contains .wh.__dir_opaque)."""
    return os.path.isfile(os.path.join(path, ".wh.__dir_opaque"))


def _relpath(rel, name):
    """Relative path within the output, with no leading './' (rel == '.' -> name)."""
    return name if rel == "." else os.path.join(rel, name)


def merge_layers(layers, output):
    """
    Merge overlayfs layers into output directory.
    layers: list of paths, lowest priority first, highest last.
    """
    deleted = set()

    for layer in layers:
        if not os.path.isdir(layer):
            continue

        for root, dirs, files in os.walk(layer, followlinks=False):
            rel = os.path.relpath(root, layer)

            # Opaque directory: suppress lower-layer content NOT provided by this layer
            if is_opaque_dir(root):
                out_dir = os.path.join(output, rel) if rel != "." else output
                if os.path.isdir(out_dir):
                    present = set(files) | set(dirs)
                    for item in os.listdir(out_dir):
                        if item not in present:
                            deleted.add(_relpath(rel, item))

            for name in files:
                src = os.path.join(root, name)
                rel_path = os.path.join(rel, name) if rel != "." else name

                # Skip opaque marker
                if name == ".wh.__dir_opaque":
                    continue

                # Whiteout: mark target for deletion
                if is_whiteout(src):
                    target = name[4:] if name.startswith(".wh.") else name
                    deleted.add(_relpath(rel, target))
                    continue

                # A higher layer re-adding a file a lower layer whited out must
                # "un-delete" it (delete-then-recreate support).
                deleted.discard(rel_path)

                if rel_path in deleted:
                    continue

                dst = os.path.join(output, rel_path)
                os.makedirs(os.path.dirname(dst), exist_ok=True)

                # Remove anything already there
                if os.path.lexists(dst):
                    if os.path.isdir(dst) and not os.path.islink(dst):
                        shutil.rmtree(dst)
                    else:
                        os.remove(dst)

                # Copy (preserve symlinks)
                if os.path.islink(src):
                    os.symlink(os.readlink(src), dst)
                else:
                    shutil.copy2(src, dst)

            # Ensure directories exist (even if empty)
            for name in dirs:
                rel_path = os.path.join(rel, name) if rel != "." else name
                if rel_path not in deleted:
                    os.makedirs(os.path.join(output, rel_path), exist_ok=True)

    # Final cleanup: remove all whiteout targets (children before parents)
    for path in sorted(deleted, key=lambda p: p.count(os.sep), reverse=True):
        full = os.path.join(output, path)
        if os.path.islink(full):
            os.remove(full)
        elif os.path.isdir(full):
            shutil.rmtree(full, ignore_errors=True)
        elif os.path.isfile(full):
            os.remove(full)


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <output_dir> <layer1> [layer2 ...]")
        print("Layers: lowest priority first, highest priority last")
        sys.exit(1)

    output = sys.argv[1]
    layers = sys.argv[2:]

    os.makedirs(output, exist_ok=True)
    merge_layers(layers, output)
    print(f"Merged {len(layers)} layers into {output}")


if __name__ == "__main__":
    main()
