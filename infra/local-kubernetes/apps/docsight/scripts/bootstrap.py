import os
from app.config import ConfigManager
from app.storage import SnapshotStorage
from app.tz import utc_now
from werkzeug.security import generate_password_hash

config = ConfigManager('/data')
config.save({'modem_type': 'sagemcom', 'disabled_modules': ','.join('docsight.' + name for name in (
    'backup', 'bnetz', 'bqm', 'connection_monitor', 'de_tkg_compensation',
    'mqtt', 'reports', 'smokeping', 'speedtest', 'weather',
))})
token = os.environ['DOCSIGHT_SCRAPE_TOKEN']
if not token.startswith('dsk_') or len(token) < 48:
    raise ValueError('A strong dsk_ scrape credential must be provisioned through Secret Manager')
storage = SnapshotStorage('/data/docsis_history.db', max_days=7)
current = storage.validate_api_token(token)
if current is not None and current['scope'] != 'metrics':
    raise ValueError('The provisioned scrape credential must not be a general API token')
if current is None:
    with storage._write() as conn:
        conn.execute("UPDATE api_tokens SET revoked=1 WHERE name='managed-prometheus' AND scope='metrics'")
        conn.execute('INSERT INTO api_tokens (name, token_hash, token_prefix, created_at, scope) '
                     'VALUES (?, ?, ?, ?, ?)',
                     ('managed-prometheus', generate_password_hash(token), token[:8], utc_now(), 'metrics'))
