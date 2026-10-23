from pathlib import Path

_top_tool = str(Path(__file__).resolve().parents[2] / "tool")
if _top_tool not in __path__:
    __path__.insert(0, _top_tool)
