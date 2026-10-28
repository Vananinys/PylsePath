"""Fail before publication if a staged source contains a high-confidence secret.
Only names/line numbers are printed, never matched values.
"""
import base64
import json
import re
import subprocess
import sys

paths = subprocess.check_output(['git', 'ls-files', '-z'], text=True).split('\0')
patterns = [r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
            r'gh[pousr]_[A-Za-z0-9_]{30,}', r'github_pat_[A-Za-z0-9_]{30,}',
            r'sb_secret_[A-Za-z0-9_-]{15,}',
            r'(?i)(?:storePassword|keyPassword)\s*[=:]\s*["\']?(?!YOUR_|REPLACE|<|\$|releaseKeys)[A-Za-z0-9!@#%^&*]{8,}']
findings = []
for path in filter(None, paths):
    content = subprocess.check_output(['git', 'show', ':' + path])
    if b'\0' in content:
        continue
    text = content.decode('utf-8-sig', errors='replace')
    for number, line in enumerate(text.splitlines(), 1):
        if any(re.search(pattern, line) for pattern in patterns):
            findings.append((path, number, 'credential pattern'))
        for token in re.findall(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', line):
            try:
                payload = token.split('.')[1]
                claims = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
                if claims.get('role') == 'service_role':
                    findings.append((path, number, 'privileged JWT'))
            except (ValueError, TypeError):
                pass
for finding in findings:
    print('%s:%d: %s' % finding)
print('Scanned %d indexed files; findings: %d' % (len(list(filter(None, paths))), len(findings)))
sys.exit(bool(findings))
