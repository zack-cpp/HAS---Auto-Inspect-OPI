from __future__ import annotations

from pathlib import Path

from counter_inspect import cli


def _use_kiosk_directory(monkeypatch, directory: Path) -> None:
    monkeypatch.setattr(cli, "KIOSK_DIR", directory)
    monkeypatch.setattr(cli, "KIOSK_URL_PATH", directory / "url")
    monkeypatch.setattr(cli, "KIOSK_RESTART_REQUEST_PATH", directory / "restart-request")
    monkeypatch.setattr(cli, "KIOSK_RESTART_READY_PATH", directory / "restart-via-systemd")


def test_kiosk_show_reads_existing_url(tmp_path, monkeypatch, capsys):
    kiosk_dir = tmp_path / "kiosk"
    kiosk_dir.mkdir()
    (kiosk_dir / "url").write_text("https://kiosk.example/app\n", encoding="utf-8")
    _use_kiosk_directory(monkeypatch, kiosk_dir)

    assert cli.main(["kiosk", "show"]) == 0
    assert capsys.readouterr().out == "https://kiosk.example/app\n"


def test_kiosk_set_updates_only_url_without_implicit_restart(tmp_path, monkeypatch, capsys):
    kiosk_dir = tmp_path / "kiosk"
    kiosk_dir.mkdir()
    unrelated = kiosk_dir / "operator-note"
    unrelated.write_text("preserve me", encoding="utf-8")
    _use_kiosk_directory(monkeypatch, kiosk_dir)

    assert cli.main(["kiosk", "set", "http://192.168.100.38/dashboard"]) == 0

    assert (kiosk_dir / "url").read_text(encoding="utf-8") == "http://192.168.100.38/dashboard\n"
    assert unrelated.read_text(encoding="utf-8") == "preserve me"
    assert not (kiosk_dir / "restart-request").exists()
    assert "counterctl kiosk restart" in capsys.readouterr().out


def test_kiosk_set_can_request_restart(tmp_path, monkeypatch, capsys):
    kiosk_dir = tmp_path / "kiosk"
    kiosk_dir.mkdir()
    (kiosk_dir / "restart-via-systemd").touch()
    _use_kiosk_directory(monkeypatch, kiosk_dir)

    assert cli.main(["kiosk", "set", "https://kiosk.example", "--restart"]) == 0

    assert (kiosk_dir / "url").read_text(encoding="utf-8") == "https://kiosk.example\n"
    assert (kiosk_dir / "restart-request").read_text(encoding="utf-8") == "restart\n"
    assert "Docker application services remain running" in capsys.readouterr().out


def test_kiosk_restart_rejects_invalid_existing_url(tmp_path, monkeypatch, capsys):
    kiosk_dir = tmp_path / "kiosk"
    kiosk_dir.mkdir()
    (kiosk_dir / "url").write_text("javascript:alert(1)\n", encoding="utf-8")
    _use_kiosk_directory(monkeypatch, kiosk_dir)

    assert cli.main(["kiosk", "restart"]) == 2
    assert not (kiosk_dir / "restart-request").exists()
    assert "absolute http:// or https:// URL" in capsys.readouterr().err


def test_kiosk_restart_requires_host_restart_support(tmp_path, monkeypatch, capsys):
    kiosk_dir = tmp_path / "kiosk"
    kiosk_dir.mkdir()
    (kiosk_dir / "url").write_text("https://kiosk.example\n", encoding="utf-8")
    _use_kiosk_directory(monkeypatch, kiosk_dir)

    assert cli.main(["kiosk", "restart"]) == 2
    assert not (kiosk_dir / "restart-request").exists()
    assert "restart support is not installed" in capsys.readouterr().err


def test_kiosk_set_rejects_whitespace_without_changing_url(tmp_path, monkeypatch, capsys):
    kiosk_dir = tmp_path / "kiosk"
    kiosk_dir.mkdir()
    url_path = kiosk_dir / "url"
    url_path.write_text("https://old.example\n", encoding="utf-8")
    _use_kiosk_directory(monkeypatch, kiosk_dir)

    assert cli.main(["kiosk", "set", "https://bad.example/a path"]) == 2
    assert url_path.read_text(encoding="utf-8") == "https://old.example\n"
    assert "whitespace" in capsys.readouterr().err


def test_kiosk_set_rejects_malformed_url_without_traceback(tmp_path, monkeypatch, capsys):
    kiosk_dir = tmp_path / "kiosk"
    kiosk_dir.mkdir()
    _use_kiosk_directory(monkeypatch, kiosk_dir)

    assert cli.main(["kiosk", "set", "http://[invalid"]) == 2
    assert not (kiosk_dir / "url").exists()
    assert "kiosk URL is invalid" in capsys.readouterr().err
