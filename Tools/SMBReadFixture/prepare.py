from pathlib import Path
root = Path(__file__).parent / "music"
(root / "folder").mkdir(parents=True, exist_ok=True)
(root / "folder" / "音楽 & #.bin").write_bytes(bytes(i % 251 for i in range(8193)))
(root / "empty.bin").write_bytes(b"")
