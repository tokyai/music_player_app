#!/usr/bin/env python3
"""Generate the Sherpa homophone resources used by the AI assistant."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import tempfile
import urllib.request
from pathlib import Path

UPSTREAM_LEXICON_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
    "hr-files/lexicon.txt"
)
UPSTREAM_LEXICON_SHA256 = (
    "978900e511bc481b8630cb6e4a573c12566fa092c366d5396e2c3823dec9dcb9"
)

# These rules are deliberately limited to distinctive music entities and
# multi-syllable player commands. Short general words are excluded because a
# context-free homophone rule could otherwise alter valid conversation text.
RULES: tuple[tuple[str, str], ...] = (
    ("zhou1jie2lun2", "周杰伦"),
    ("lin2jun4jie2", "林俊杰"),
    ("chen2yi4xun4", "陈奕迅"),
    ("xue1zhi1qian1", "薛之谦"),
    ("deng4zi3qi2", "邓紫棋"),
    ("mao2bu4yi4", "毛不易"),
    ("wang1su1long2", "汪苏泷"),
    ("zhang1bi4chen2", "张碧晨"),
    ("zhang1shao2han2", "张韶涵"),
    ("feng4huang2chuan2qi2", "凤凰传奇"),
    ("wu3yue4tian1", "五月天"),
    ("sun1yan4zi1", "孙燕姿"),
    ("liu2de2hua2", "刘德华"),
    ("zhang1xue2you3", "张学友"),
    ("li3rong2hao4", "李荣浩"),
    ("hua2chen2yu3", "华晨宇"),
    ("hua4chen2yu3", "华晨宇"),
    ("dan1yi1chun2", "单依纯"),
    ("shan1yi1chun2", "单依纯"),
    ("shan4yi1chun2", "单依纯"),
    ("ku4gou3yin1yue4", "酷狗音乐"),
    ("wang3yi4yun2yin1yue4", "网易云音乐"),
    ("ku4zai3yin1yue4", "库仔音乐"),
    ("qing1hua1ci2", "青花瓷"),
    ("gao4bai2qi4qiu2", "告白气球"),
    ("gu1yong3zhe3", "孤勇者"),
    ("hai3kuo4tian1kong1", "海阔天空"),
    ("bo1fang4yin1yue4", "播放音乐"),
    ("bo1fang4ge1qu3", "播放歌曲"),
    ("zan4ting2bo1fang4", "暂停播放"),
    ("ji4xu4bo1fang4", "继续播放"),
    ("shang4yi1shou3", "上一首"),
    ("xia4yi1shou3", "下一首"),
    ("sui2ji1bo1fang4", "随机播放"),
    ("shun4xu4bo1fang4", "顺序播放"),
    ("dan1qu3xun2huan2", "单曲循环"),
    ("lie4biao3xun2huan2", "列表循环"),
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _obtain_upstream_lexicon(path: Path | None) -> tuple[Path, tempfile.TemporaryDirectory[str] | None]:
    temporary: tempfile.TemporaryDirectory[str] | None = None
    if path is None:
        temporary = tempfile.TemporaryDirectory(prefix="sherpa-hr-")
        path = Path(temporary.name) / "lexicon.txt"
        urllib.request.urlretrieve(UPSTREAM_LEXICON_URL, path)
    if _sha256(path) != UPSTREAM_LEXICON_SHA256:
        temporary and temporary.cleanup()
        raise ValueError("Upstream lexicon SHA-256 does not match")
    return path, temporary


def _write_full_lexicon(source: Path, output: Path) -> None:
    # Keep the verified upstream bytes intact so the bundled dictionary stays
    # complete and its provenance can be checked with the same SHA-256.
    shutil.copyfile(source, output)


def _write_rule_fst(output: Path) -> None:
    try:
        import pynini
        from pynini import cdrewrite
        from pynini.lib import utf8
    except ImportError as error:
        raise SystemExit(
            "Pynini is required: python -m pip install --only-binary :all: pynini"
        ) from error

    sigma = utf8.VALID_UTF8_CHAR.star
    replacements = pynini.union(
        *(pynini.cross(pronunciation, text) for pronunciation, text in RULES)
    ).optimize()
    rule = cdrewrite(replacements, "", "", sigma).optimize()
    rule.write(str(output))

    for pronunciation, expected in RULES:
        actual = pynini.compose(pronunciation, rule).string()
        if actual != expected:
            raise RuntimeError(
                f"Rule validation failed for {pronunciation}: {actual!r}"
            )
    unchanged = "pu3tong1wen2ben3"
    if pynini.compose(unchanged, rule).string() != unchanged:
        raise RuntimeError("Non-matching text must pass through unchanged")


def main() -> None:
    project_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream-lexicon", type=Path)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=project_root / "assets/models/sherpa-onnx-homophone-replacer-zh",
    )
    args = parser.parse_args()

    source, temporary = _obtain_upstream_lexicon(args.upstream_lexicon)
    try:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        _write_full_lexicon(source, args.output_dir / "lexicon.txt")
        _write_rule_fst(args.output_dir / "replace.fst")
    finally:
        temporary and temporary.cleanup()

    print(f"Generated homophone resources in {args.output_dir}")


if __name__ == "__main__":
    main()
