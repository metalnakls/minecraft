#!/usr/bin/env python3
"""The settings snapshot must not copy database records, credentials or paths."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).with_name('prepare.py'))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory).resolve()
    database, output = root/'fixture.db', root/'shared.json'
    record = {'jvmArguments': '-XX:+UseZGC', 'xms': 1024, 'xmx': 8192,
              'credential': 'PRIVATE', 'javaPath': '/Users/source/java', 'environmentVariables': 'PRIVATE=value'}
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE game_versions (working_path TEXT, game_name TEXT, data_json TEXT)')
        connection.execute('INSERT INTO game_versions VALUES (?,?,?)', (str(root), 'Fabric 26.3', json.dumps(record)))
    prepare.write_shared_launch_settings(database, root, output)
    result = json.loads(output.read_text())
    assert result == {'schema': 1, 'jvmArguments': '-XX:+UseZGC', 'xms': 1024, 'xmx': 8192}
    assert 'PRIVATE' not in output.read_text() and '/Users/source' not in output.read_text()
    record['jvmArguments'] += ' -javaagent:/Users/source/agent.jar'
    with sqlite3.connect(database) as connection:
        connection.execute('UPDATE game_versions SET data_json=?', (json.dumps(record),))
    try:
        prepare.write_shared_launch_settings(database, root, output)
        raise AssertionError('Unapproved launch arguments were accepted')
    except ValueError:
        pass
    print('PASS portable settings allowlist; credentials, paths and custom agents excluded.')
