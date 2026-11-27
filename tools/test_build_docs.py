"""Tests for tools/build-docs.py: links are rewritten for the published site, and anything broken fails the build."""
import importlib.util
import sys
from pathlib import Path

import pytest

pytest.importorskip("markdown")

SPEC = importlib.util.spec_from_file_location("build_docs", Path(__file__).with_name("build-docs.py"))
bd = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bd)


@pytest.fixture()
def tree(tmp_path, monkeypatch):
    """A miniature repository: docs/, one file outside docs/, and an image."""
    (tmp_path / "docs" / "images").mkdir(parents=True)
    (tmp_path / "installer").mkdir()
    (tmp_path / "installer" / "install-template.sh").write_text("#!/bin/bash\n")
    (tmp_path / "docs" / "images" / "pic.jpg").write_bytes(b"jpg")
    monkeypatch.setattr(bd, "ROOT", tmp_path)
    monkeypatch.setattr(bd, "DOCS", tmp_path / "docs")
    monkeypatch.setattr(bd, "ABOUT", [("alpha", "Alpha", "First."), ("beta", "Beta", "Second.")])
    return tmp_path


def build(tree, tmp_path, capsys):
    out = tmp_path / "out"
    monkeypatch_argv = ["build-docs.py", "--out", str(out)]
    old = sys.argv
    sys.argv = monkeypatch_argv
    try:
        rc = bd.main()
    finally:
        sys.argv = old
    return rc, out, capsys.readouterr().err


def write(tree, name, text):
    (tree / "docs" / name).write_text(text, encoding="utf-8")


def test_pages_links_images_and_index(tree, tmp_path, capsys):
    write(tree, "alpha.md", "# Alpha page\n\nSee [beta](beta.md#second-part) and [the installer](../installer/install-template.sh) "
          "and [the folder](../installer/).\n\n![a picture](images/pic.jpg)\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n## Second part\n\n```\nsome code\n```\n")
    write(tree, "beta.md", "# Beta\n\n## Second part\n\nBack to [alpha](alpha.md).\n")
    rc, out, err = build(tree, tmp_path, capsys)
    assert rc == 0, err
    a = (out / "alpha.html").read_text(encoding="utf-8")
    assert 'href="beta.html#second-part"' in a
    assert f'href="{bd.REPO}/blob/main/installer/install-template.sh"' in a
    assert f'href="{bd.REPO}/tree/main/installer"' in a                       # a directory links to /tree/
    assert 'src="images/pic.jpg"' in a and (out / "images" / "pic.jpg").exists()
    assert '<div class="tablewrap"><table>' in a                              # tables scroll inside their own box
    assert "<title>Alpha page" in a and 'href="../"' in a and 'href="../docs/"' in a
    idx = (out / "index.html").read_text(encoding="utf-8")
    assert 'href="alpha.html"' in idx and "First." in idx and 'href="beta.html"' in idx


def test_heading_anchors_match_github(tree, tmp_path, capsys):
    write(tree, "alpha.md", "# Putting a Bobcat 300 into recovery mode\n")
    write(tree, "beta.md", "# Beta\n")
    rc, out, err = build(tree, tmp_path, capsys)
    assert rc == 0
    assert 'id="putting-a-bobcat-300-into-recovery-mode"' in (out / "alpha.html").read_text(encoding="utf-8")


@pytest.mark.parametrize("bad", ["[x](missing.md)", "[x](../nope/file.sh)", "![x](images/absent.jpg)", "[x](../../outside.md)"])
def test_a_broken_link_fails_the_build(tree, tmp_path, capsys, bad):
    write(tree, "alpha.md", f"# Alpha\n\n{bad}\n")
    write(tree, "beta.md", "# Beta\n")
    rc, out, err = build(tree, tmp_path, capsys)
    assert rc == 1 and "alpha.md" in err


def test_unlisted_and_missing_documents_fail(tree, tmp_path, capsys):
    write(tree, "alpha.md", "# Alpha\n")
    write(tree, "beta.md", "# Beta\n")
    write(tree, "gamma.md", "# Gamma\n")                                        # exists but is not in ABOUT
    rc, out, err = build(tree, tmp_path, capsys)
    assert rc == 1 and "gamma.md is not listed" in err


def test_the_real_docs_build_without_broken_links(tmp_path, capsys):
    real = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(real)
    old = sys.argv
    sys.argv = ["build-docs.py", "--out", str(tmp_path / "site-docs")]
    try:
        rc = real.main()
    finally:
        sys.argv = old
    err = capsys.readouterr().err
    assert rc == 0, err
    assert (tmp_path / "site-docs" / "recovery-mode.html").exists()
