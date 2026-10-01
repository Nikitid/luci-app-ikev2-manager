#!/usr/bin/env python3
"""Transition regressions from the installed-runtime audit; offline only."""
import json
import os
from pathlib import Path
import select
import signal
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def function(file, name):
    source = (ROOT / file).read_text()
    start = source.index(name + '() ')
    closing = ')' if source[start + len(name) + 3] == '(' else '}'
    end = source.index('\n' + closing + '\n', start) + 3
    return source[start:end] + '\n'

def run(source, env=None, success=True):
    p = subprocess.run(['sh', '-c', source], env=env, capture_output=True, text=True, timeout=15)
    assert (p.returncode == 0) == success, (p.returncode, p.stdout, p.stderr)
    return p.stdout

with tempfile.TemporaryDirectory() as folder:
    work = Path(folder)
    env = dict(os.environ, WORK=folder)
    actions = '. ' + shlex.quote(str(ROOT / 'ikev2-manager-runtime/lib/actions.sh')) + '\n'
    # Suspend the first owner after mkdir. A second owner and a stale-lock
    # inspector must both respect the publication gate, without timing guesses.
    for mode in ('pid', 'action'):
        lock = work / (mode + '.lock')
        ready_r, ready_w = os.pipe()
        resume_r, resume_w = os.pipe()
        acquire = 'pid_lock_acquire "$lock"' if mode == 'pid' else 'acquire_action_lock test one'
        busy = 'pid_lock_busy "$lock"' if mode == 'pid' else 'action_lock_busy'
        release = 'pid_lock_release "$lock"' if mode == 'pid' else 'release_action_lock'
        setup = actions + 'stat() { echo 1; }; date() { case "$1" in -r) echo 1;; *) command date "$@";; esac; }\n' + f'lock={shlex.quote(str(lock))}\naction_lock_dir="$lock"\naction_lock_status="$lock.status"\n'
        owner_code = setup + f'''
mkdir() {{
    command mkdir "$@" || return
    printf ready >&{ready_w}
    read -r resume <&{resume_r}
}}
{acquire} || exit 1
printf held >&{ready_w}
read -r resume <&{resume_r}
{release}
'''
        owner = subprocess.Popen(['sh', '-c', owner_code], pass_fds=(ready_w, resume_r), env=env, start_new_session=True)
        os.close(ready_w)
        os.close(resume_r)
        def receive(expected):
            assert select.select([ready_r], [], [], 10)[0], 'owner failed to reach interleaving barrier'
            assert os.read(ready_r, len(expected)) == expected
        try:
            receive(b'ready')
            run(setup + 'IKEV2_ACTION_LOCK_WAIT_SECONDS=1\n' + acquire, env, False)
            run(setup + busy, env)
            assert lock.is_dir()
            os.write(resume_w, b'continue\n')
            receive(b'held')
            # An unrelated process cannot release the actual owner's lock.
            run(setup + release, env)
            assert lock.is_dir()
            os.write(resume_w, b'continue\n')
            assert owner.wait(timeout=10) == 0
            assert not lock.exists()
        finally:
            os.killpg(owner.pid, signal.SIGKILL) if owner.poll() is None else None
            owner.wait()
            os.close(ready_r)
            os.close(resume_w)
        # The supported router has no stat applet. A crash before publishing
        # a PID must still become recoverable after the legacy grace period.
        lock.mkdir()
        run(setup + 'stat() { return 127; }\n' + acquire + ' && ' + release, env)
        assert not lock.exists()
        # Legacy stale owners remain recoverable after an upgrade.
        lock.mkdir()
        if mode == 'pid':
            (lock / 'pid').write_text('99999999\n')
        else:
            Path(str(lock) + '.status').write_text('pid=99999999\n')
        run(setup + acquire + ' && ' + release, env)
        assert not lock.exists()
    print('audit: publication race, foreign release and stale recovery OK')

    # Every mutation must preserve at least one terminal default, including a
    # legacy metric-zero guard and a rejected netlink update.
    bindir = work / 'bin'
    bindir.mkdir()
    ip = bindir / 'ip'
    ip.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
p=Path(os.environ['WORK'])/'routes.json'
s=json.loads(p.read_text()); a=sys.argv[1:]
if 'show' in a:
    for metric in s['guards']:
        print('unreachable default' + ((' metric '+str(metric)) if metric else ''))
elif 'replace' in a:
    if s.get('fail'): sys.exit(1)
    s['guards']=sorted(set(s['guards']+[32767]))
elif 'flush' in a:
    assert a[-3:] == ['unreachable','metric','0'], a
    s['guards']=[m for m in s['guards'] if m != 0]
else: raise AssertionError(a)
if 'show' not in a:
    assert s['guards'], 'terminal default disappeared during mutation'
    s['mutations']+=1
    p.write_text(json.dumps(s))
''')
    ip.chmod(0o755)
    env['PATH'] = str(bindir) + os.pathsep + os.environ['PATH']
    routes = work / 'routes.json'
    guard = function('ikev2-manager-runtime/lib/routing.sh', 'ensure_failclosed_default')
    for family in (4, 6):
        for initial, fail in [([32767], False), ([0], False), ([0], True), ([], True)]:
            routes.write_text(json.dumps(dict(guards=initial, fail=fail, mutations=0)))
            run(guard + f'ensure_failclosed_default {family} 123', env, not fail)
            result = json.loads(routes.read_text())
            if initial == [32767]: assert result['mutations'] == 0
            if not fail: assert 32767 in result['guards']
            if fail: assert result['guards'] == initial
    print('audit: continuous fail-closed guard and netlink error propagation OK')

    # Missing any mandatory inbound guard must fail a runtime check.
    policy = function('ikev2-manager-runtime/ikev2-user-policy.sh', 'check_runtime')
    nft = bindir / 'nft'
    nft.write_text('''#!/bin/sh
case "$*" in
 *"chain inet test input") [ "$BROKEN" != input ] || exit 1; echo 'type filter hook input; ip saddr @inbound_pool drop';;
 *"chain inet test forward") [ "$BROKEN" != forward ] || exit 1; echo 'type filter hook forward; jump inbound_policy';;
 *"chain inet test inbound_policy") [ "$BROKEN" != drop ] || exit 0; echo 'ip daddr @inbound_pool drop';;
 *"set inet test "*) [ "$BROKEN" != set ] || exit 1;;
 *) exit 1;;
esac
''')
    nft.chmod(0o755)
    # A runtime that kept every chain and set but stopped tracking the live
    # sessions is the shape the wedged watcher left behind, so it counts as a
    # missing guard too.
    session_state = work / 'inbound-session-state'
    session_state.write_text('')
    env['SESSION_STATE'] = str(session_state)
    setup = ('uci() { case "$*" in *custom_config) echo 0;; *) echo 1;; esac; }; '
             'runtime_owned() { return 0; }; table=test; nft_bin=nft; '
             'runtime_unchanged() { [ "$BROKEN" != table ]; }; '
             'valid_ipv4() { case "$1" in *.*.*.*) return 0;; *) return 1;; esac; }; '
             'session_state="$SESSION_STATE"; '
             'collect_sessions() { if [ "$BROKEN" = sessions ]; then '
             'printf "alice\\t10.20.30.10\\n" >"$1"; else : >"$1"; fi; }\n')
    for broken in ('none', 'input', 'forward', 'drop', 'set', 'table', 'sessions'):
        run(setup + policy + 'check_runtime', dict(env, BROKEN=broken), broken == 'none')
    print('audit: inbound input/forward/default-drop/set/table/session verification OK')

    # A probe success requires a query response, and both bootstrap and DoH
    # must bind to the tunnel. A server address in nslookup output is no answer.
    domain = 'ikev2-manager-runtime/ikev2-domain-router.sh'
    routing = 'ikev2-manager-runtime/lib/routing.sh'
    probe = "dns_probe_names='openwrt.org cloudflare.com yandex.ru'\n" + \
        ''.join(function(routing, name) for name in ('dns_probe_lookup', 'dns_probe_answers')) + \
        ''.join(function(domain, name) for name in
                ('valid_dns_name', 'parse_tunnel_doh', 'bounded_nslookup', 'tunnel_dns_query'))
    worker = bindir / 'sing-box'
    worker.write_text('''#!/usr/bin/env python3
import json,os,signal,sys
from pathlib import Path
args=sys.argv
cfg=Path(args[args.index('-c')+1])
s=json.loads(cfg.read_text())
root=Path(os.environ['WORK'])
(root/'probe-captured.json').write_text(json.dumps(s))
(root/'worker-pid').write_text(str(os.getpid()))
(root/'worker-dir').write_text(str(cfg.parent))
with open(root/'ready', 'w') as pipe: pipe.write('ready\\n')
signal.pause()
''')
    worker.chmod(0o755)
    lookup = bindir / 'nslookup'
    lookup.write_text('''#!/bin/sh
[ "$1" = openwrt.org ] && [ "$2" = 127.0.0.44 ] || exit 3
case "$ANSWER" in
 good) printf 'Server: 127.0.0.44\nAddress: 127.0.0.44#53\nName: openwrt.org\nAddress: 203.0.113.20\n';;
 server-only) printf 'Server: 127.0.0.44\nAddress: 127.0.0.44#53\n';;
 error) printf '** server cannot find openwrt.org: NXDOMAIN\n'; exit 1;;
 empty) printf 'Name: openwrt.org\n';;
esac
''')
    lookup.chmod(0o755)
    os.mkfifo(work / 'ready')
    setup = f'''ucode_bin=ucode; runtime_lib_dir={ROOT}/ikev2-manager-runtime/lib
listener_calls=0
listener_ready() {{
    listener_calls=$((listener_calls + 1))
    [ "$listener_calls" != 1 ] || return 1
    read -r ready <"$WORK/ready"
}}
'''
    env['IKEV2_SING_BOX'] = str(worker)
    for answer in ('good', 'server-only', 'error', 'empty'):
        run(probe + setup + 'tunnel_dns_query https://dns.example.net:444/dns-query 192.0.2.53:53',
            dict(env, ANSWER=answer), answer == 'good')
        cfg = json.loads((work / 'probe-captured.json').read_text())
        servers = cfg['dns']['servers']
        assert all(s['bind_interface'] == 'ipsec-out' for s in servers)
        assert servers[0]['server'] == '192.0.2.53' and servers[0]['server_port'] == 53
        assert servers[1]['tls']['server_name'] == 'dns.example.net'
        assert servers[1]['server_port'] == 444 and servers[1]['path'] == '/dns-query'
        assert servers[1]['domain_resolver']['server'] == servers[0]['tag']
        assert cfg['dns']['disable_cache'] is True
        assert cfg['route']['default_domain_resolver'] == 'probe'
        assert cfg['route']['rules'][0]['action'] == 'hijack-dns'
        assert not Path((work / 'worker-dir').read_text()).exists(), 'probe left private files'
        try:
            os.kill(int((work / 'worker-pid').read_text()), 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError('probe left running worker')
    print('audit: real-query contract, tunnel-bound bootstrap and worker cleanup OK')

    # A vulnerable enabled server is reported (security_ok=0 and a warning),
    # but no longer fails the whole report: with no fixed package in the feed
    # that kept the overview red for good.
    # The system helper's source is the script plus the libraries it sources.
    system = ''.join(path.read_text() for path in
                     [ROOT / 'ikev2-manager-runtime/ikev2-manager-system.sh'] +
                     sorted((ROOT / 'ikev2-manager-runtime/lib').glob('system-*.sh')))
    a = system.index('\tif pkg_version_at_least strongswan 6.0.7; then', system.index('doctor()'))
    b = system.index('\tif [ "$(getv globals configured)"', a)
    diagnostic = system[a:b]
    for modern, enabled, repair, expected in [(0,1,0,1), (0,1,1,1), (1,1,0,1), (0,0,0,1)]:
        setup = f'''ok=1; strongswan_version=test; IKEV2_DOCTOR_ALLOW_RUNTIME_REPAIR={repair}
pkg_version_at_least() {{ [ {modern} = 1 ]; }}
pkg_available_version() {{ echo 6.0.3-r2; }}
pkg_version_string_at_least() {{ return 1; }}
getv() {{ echo {enabled}; }}
'''
        result = run(setup + diagnostic + f'[ "$ok" = {expected} ]', env)
        if not modern and enabled: assert 'security_ok=0' in result
    health = (ROOT / 'ikev2-manager-runtime/ikev2-health.sh').read_text()
    a = health.index('\t\tstate=up\n')
    b = health.index('\t\tprintf', a)
    for failures, routing, expected in [(0,'ok','up'), (1,'ok','degraded'), (0,'degraded','degraded')]:
        run(f'probe_failures={failures}; routing_policy_state={routing}\n' + health[a:b] +
            f'[ "$state" = {expected} ]', env)
    print('audit: vulnerable server and failed data probe cannot report healthy OK')

    # Targeted proxy retirement uses source CIDRs, retains other clients, and
    # keeps the API credential out of process arguments.
    closer = ('. ' + shlex.quote(str(ROOT / 'ikev2-manager-runtime/lib/controller.sh')) + '\n' +
              function('luci-ikev2-domains/ikev2-devices.sh', 'close_device_connections'))
    jf = bindir / 'jsonfilter'
    jf.write_text('''#!/usr/bin/env python3
import json,sys
args=sys.argv[1:]
if '-i' in args:
    if args[args.index('-i')+1]=='config': obj={'experimental':{'clash_api':{'secret':'a'*64}}}
    else: obj=json.load(open(args[args.index('-i')+1]))
else: obj=json.loads(args[args.index('-s')+1])
key=args[-1]
if '-t' in args: print('array' if isinstance(obj.get('connections'),list) else 'null')
elif key=='@.experimental.clash_api.secret': print(obj['experimental']['clash_api']['secret'])
elif key=='@.connections[*]':
    for c in obj['connections']: print(json.dumps(c))
elif key=='@.id': print(obj['id'])
elif key=='@.metadata.sourceIP': print(obj['metadata']['sourceIP'])
else: sys.exit(1)
''')
    jf.chmod(0o755)
    curl = bindir / 'curl'
    curl.write_text('''#!/usr/bin/env python3
import json,os,stat,sys
from pathlib import Path
args=sys.argv[1:]; root=Path(os.environ['WORK'])
assert not any('Bearer' in a for a in args)
config=Path(args[args.index('--config')+1])
assert stat.S_IMODE(config.stat().st_mode)==0o600
if os.environ.get('API_FAIL')=='1': sys.exit(22)
if '-X' in args:
    with (root/'closed').open('a') as f: f.write(args[-1].split('/')[-1]+'\\n')
else: print(json.dumps({'connections':[
 {'id':'11111111-1111-1111-1111-111111111111','metadata':{'sourceIP':'192.0.2.4'}},
 {'id':'22222222-2222-2222-2222-222222222222','metadata':{'sourceIP':'192.0.2.5'}},
 {'id':'33333333-3333-3333-3333-333333333333','metadata':{'sourceIP':'198.51.100.5'}}]}))
''')
    curl.chmod(0o755)
    setup = '''APP_CONFIG=test; IKEV2_DOMAIN_CONFIG=config
uci() { case "$*" in *engine) echo fakeip;; *) echo 0;; esac; }
'''
    for address, count in [('192.0.2.4',1), ('192.0.2.0/24',2), ('203.0.113.4',0)]:
        (work/'closed').write_text('')
        run(closer + setup + f'close_device_connections {address}', env)
        closed=(work/'closed').read_text().splitlines()
        assert len(closed)==count and not any(c.startswith('3333') for c in closed)
    run(closer + setup + 'close_device_connections 192.0.2.4', dict(env, API_FAIL='1'), False)
    print('audit: targeted proxy CIDR cleanup, credential handling and API errors OK')
