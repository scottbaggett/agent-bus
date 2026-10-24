#!/usr/bin/env python3
"""Behavior checks for opt-in queue delivery and its failure boundaries."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'bin/agent-bus'
spec = importlib.util.spec_from_file_location('queue_adapter', ROOT / 'lib/codex_queue.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='agent-bus-queue-')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.thread = str(uuid.uuid4())
        self.fake = self.home / 'codex with spaces'
        self.calls = self.home / 'calls.jsonl'
        self.fake.write_text('''#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:] == ['queue', '--help']:
    sys.exit(int(os.environ.get('FAKE_HELP_EXIT', '0')))
with open(os.environ['FAKE_CALLS'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
print('accepted')
sys.exit(int(os.environ.get('FAKE_QUEUE_EXIT', '0')))
''')
        self.fake.chmod(0o755)
        self.env = {k:v for k,v in os.environ.items() if not k.startswith('AGENT_BUS_') and k not in (
            'CLAUDECODE','CLAUDE_CODE_SESSION_ID','CLAUDE_CODE_MESSAGING_SOCKET',
            'CODEX_THREAD_ID','OPENCODE','OPENCODE_SESSION_ID')}
        self.env.update(AGENT_BUS_HOME=str(self.home / 'bus'), AGENT_BUS_NO_AUTO_GC='1',
                        AGENT_BUS_CODEX_BIN=str(self.fake), FAKE_CALLS=str(self.calls),
                        AGENT_BUS_REPO_ID='testrepo', AGENT_BUS_WT='testwt')

    def cmd(self, *args, tool='codex', session=None, extra=None, check=True, input=None):
        env = self.env | {'AGENT_BUS_TOOL': tool, 'AGENT_BUS_SESSION': session or self.thread}
        env.update(extra or {})
        return subprocess.run([str(BIN), *args], cwd=self.home, env=env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check, input=input)

    def seat(self):
        rows = [json.loads(p.read_text()) for p in (self.home / 'bus/seats').glob('codex_*.json')]
        rows = [r for r in rows if r['wt'] == self.env['AGENT_BUS_WT']]
        return next((r for r in rows if r['session'] == self.thread), rows[0])

    def state(self):
        return self.home / 'bus/state' / (self.seat()['addr'].replace('/', '_') + '.json')

    def enable(self):
        self.cmd('codex', 'enable')
        return self.seat()['addr']

    def post(self, target, body='peer-content-should-stay-on-bus', **kw):
        return self.cmd('post', '--to', target, '--state', 'question', '-m', body,
                        tool='claude', session='sender', **kw)

    def rows(self, kind):
        return [r for r in map(json.loads, (self.home / 'bus/ledger.jsonl').read_text().splitlines()) if r['kind']==kind]

    def requests(self):
        return [json.loads(x) for x in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_auto_identity_and_host_precedence(self):
        env = dict(AGENT_BUS_TOOL='', AGENT_BUS_SESSION='', CODEX_THREAD_ID=self.thread)
        self.cmd('heartbeat', extra=env)
        self.assertEqual(self.seat()['session'], self.thread)
        for tool, marker in [('claude', {'CLAUDECODE':'1','CLAUDE_CODE_SESSION_ID':'cc'}),
                             ('opencode', {'OPENCODE_SESSION_ID':'oc'})]:
            self.cmd('heartbeat', extra=env | marker)
            rows = list((self.home/'bus/seats').glob(tool+'_*.json'))
            self.assertEqual(len(rows), 1)
            self.assertNotEqual(json.loads(rows[0].read_text())['session'], self.thread)

    def test_opt_in_fixed_notice_and_no_read_ack(self):
        self.cmd('heartbeat')
        self.post(self.seat()['addr'])
        self.assertEqual(self.requests(), [])
        target = self.enable()
        self.post(target, 'arbitrary peer instructions $(touch should-not-exist)')
        self.assertEqual(self.requests(), [['queue','--thread',self.thread,'--message',adapter.NOTICE]])
        self.assertEqual(self.rows('delivery')[-1]['status'], 'queued')
        state = json.loads(self.state().read_text())
        self.assertEqual(state.get('read', []), [])
        self.assertEqual(state['wakes'], 1)
        self.assertEqual(self.rows('delivery')[-1]['msg'], self.rows('msg')[-1]['id'])
        self.assertFalse((self.home/'should-not-exist').exists())

    def test_routing_broadcast_self_stale_disable_and_no_push(self):
        target = self.enable()
        for scope in ['@here','@repo','@all','codex/other.1234']:
            self.post(scope)
        self.cmd('post','--to',target,'-m','own')
        self.post(target, extra={'AGENT_BUS_NO_PUSH':'1'})
        self.assertEqual(self.requests(), [])
        self.post('codex/testwt')
        self.assertEqual(len(self.requests()), 1)
        seatfile = next((self.home/'bus/seats').glob('codex_*.json'))
        seat = json.loads(seatfile.read_text()); seat['epoch'] = 0
        seatfile.write_text(json.dumps(seat))
        self.post(target)
        self.assertEqual(len(self.requests()), 1)
        self.cmd('codex','disable')
        self.post(target)
        self.assertEqual(len(self.requests()), 1)
        self.assertEqual(self.seat()['codex_queue'], '')

    def test_budget_and_close_reset(self):
        target = self.enable()
        for _ in range(4): self.post(target)
        self.assertEqual(len(self.requests()), 3)
        self.assertEqual(self.rows('delivery')[-1]['status'], 'budget_exhausted')
        self.assertEqual(json.loads(self.cmd('codex','status').stdout)['mode'],'budget_exhausted')
        original = self.rows('msg')[0]['id']
        self.cmd('post','--to','claude/sender','--re',original,'--close','done','--state','done','-m','reply',
                 extra={'AGENT_BUS_NO_PUSH':'1'})
        self.assertEqual(json.loads(self.state().read_text())['wakes'], 0)
        self.post(target)
        self.assertEqual(len(self.requests()), 4)

    def test_pm_routing_deduplicates_thread_and_read_ack_is_explicit(self):
        target = self.enable()
        self.cmd('role','pm')
        # The same loaded chat may register in two directories; one post must
        # not enqueue two notices to that same thread.
        self.cmd('codex','enable', extra={'AGENT_BUS_WT':'second'})
        self.cmd('role','pm','--lane','testlane',extra={'AGENT_BUS_WT':'second'})
        self.cmd('lane','testlane',tool='claude',session='sender')
        self.post('@pm')
        self.assertEqual(len(self.requests()), 1)
        packet = self.rows('msg')[0]['id']
        self.assertEqual(self.rows('delivery')[0]['thread'], self.thread)
        self.cmd('read')
        self.assertIn(packet, json.loads(self.state().read_text())['read'])
        shown = self.cmd('show',packet).stdout
        rows = [json.loads(line) for line in shown.splitlines() if line.startswith('{')]
        self.assertEqual(sum(row['kind']=='delivery' for row in rows), 1)

    def test_failure_durable_and_no_retry(self):
        target = self.enable()
        self.post(target, extra={'FAKE_QUEUE_EXIT':'7'})
        self.assertEqual(len(self.rows('msg')), 1)
        self.assertEqual(self.rows('delivery')[0]['status'], 'failed')
        self.assertEqual(self.rows('delivery')[0]['exit_code'], 7)
        self.assertEqual(json.loads(self.state().read_text()).get('read',[]), [])
        same = adapter.submit(str(self.fake.resolve()), self.thread, str(self.state()), self.rows('msg')[0]['id'], '3')
        self.assertEqual(same['status'], 'already_attempted')
        self.assertEqual(len(self.requests()), 1)

    def test_enable_rejects_unsupported_cli_and_invalid_thread(self):
        failed = self.cmd('codex','enable',extra={'FAKE_HELP_EXIT':'2'},check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(self.requests(), [])
        self.assertNotEqual(self.cmd('codex','enable',session='local',check=False).returncode, 0)
        self.assertNotEqual(self.cmd('codex','enable',tool='claude',check=False).returncode, 0)

    def test_missing_binary_does_not_lose_packet(self):
        target = self.enable(); self.fake.unlink()
        self.post(target)
        self.assertEqual(len(self.rows('msg')), 1)
        self.assertEqual(self.rows('delivery')[0]['status'], 'unavailable')
        self.assertEqual(json.loads(self.state().read_text()).get('read',[]), [])

    def test_inherited_claude_socket_is_not_registered_for_codex(self):
        self.cmd('heartbeat', extra={'CLAUDE_CODE_MESSAGING_SOCKET':'/tmp/not-codex'})
        self.assertEqual(self.seat()['socket'], '')

    def test_queue_timeout_and_simultaneous_reservations(self):
        status, code, _ = adapter.run(['/bin/sleep','10'], 0.05)
        self.assertEqual((status,code), ('uncertain', None))
        self.enable()
        outcomes=[]
        def reserve(n):
            outcomes.append(adapter.reserve(self.state(),str(n),3,str(self.fake.resolve())))
        threads=[threading.Thread(target=reserve,args=(i,)) for i in range(8)]
        for thread in threads: thread.start()
        for thread in threads: thread.join()
        self.assertEqual(outcomes.count(None), 3)
        self.assertEqual(outcomes.count('budget_exhausted'), 5)
        self.assertEqual(json.loads(self.state().read_text())['wakes'], 3)


    def hook(self, name, *, cwd=None, session=None, extra=None):
        self.env['AGENT_BUS_WT'] = self.home.name
        self.env.pop('AGENT_BUS_REPO_ID', None)
        payload = {'hook_event_name':name, 'session_id':session or self.thread,
                   'cwd':str(cwd or self.home)}
        env = {'CODEX_INTERNAL_ORIGINATOR_OVERRIDE':'Codex Desktop',
               'CODEX_APP_RUNTIME_CLI_PATH':str(self.fake)}
        env.update(extra or {})
        return self.cmd('codex-hook', input=json.dumps(payload), extra=env)

    def test_lifecycle_registers_payload_identity_without_reading_messages(self):
        actual=str(uuid.uuid4())
        result=self.hook('SessionStart',session=actual)
        self.assertEqual(self.seat()['session'],actual)
        self.assertTrue(self.seat()['codex_queue'])
        self.assertGreater(self.seat()['last_hook'],0)
        self.assertEqual(json.loads(result.stdout)['hookSpecificOutput']['hookEventName'],'SessionStart')
        self.assertEqual(json.loads(self.state().read_text()).get('read',[]),[])
        self.assertEqual(self.requests(),[])
        state=json.loads(self.cmd('codex','status',session=actual).stdout)
        self.assertEqual(state['mode'],'queue_ready')

    def test_lifecycle_pause_survives_events_and_manual_offboard(self):
        self.hook('SessionStart')
        self.cmd('codex','disable')
        for event in ['UserPromptSubmit','Stop','SessionStart']:
            self.hook(event)
            self.assertEqual(self.seat()['codex_queue'],'')
        self.assertEqual(json.loads(self.cmd('codex','status').stdout)['mode'],'disabled')
        self.cmd('codex','enable')
        self.cmd('offboard')
        self.assertEqual(list((self.home/'bus/seats').glob('codex_*.json')),[])
        self.hook('Stop')
        self.assertEqual(self.seat()['codex_queue'],'')

    def test_lifecycle_end_cleans_thread_seats_roles_claims_and_allows_resume(self):
        self.hook('SessionStart')
        self.cmd('role','pm')
        self.cmd('claim',str(self.home/'claimed.txt'))
        second=self.home/'second'; second.mkdir()
        self.hook('SessionStart',cwd=second)
        foreign=str(uuid.uuid4())
        self.hook('SessionStart',session=foreign)
        self.hook('SessionEnd')
        seats=[json.loads(p.read_text()) for p in (self.home/'bus/seats').glob('codex_*.json')]
        self.assertEqual([s['session'] for s in seats],[foreign])
        self.assertEqual(list((self.home/'bus/claims').glob('*.json')),[])
        self.assertEqual(list((self.home/'bus/state/roles').glob('*.pm')),[])
        self.hook('SessionStart')
        self.assertEqual(json.loads(self.cmd('codex','status').stdout)['mode'],'queue_ready')

    def test_hook_rejects_bad_inputs_and_does_not_auto_enable_cli(self):
        for payload in ['broken',json.dumps({'hook_event_name':'SessionStart','session_id':'bad','cwd':str(self.home)}),
                        json.dumps({'hook_event_name':'SessionStart','session_id':self.thread,'cwd':'/missing'})]:
            result=self.cmd('codex-hook',input=payload)
            self.assertEqual(result.returncode,0)
        self.assertEqual(list((self.home/'bus/seats').glob('*.json')),[])
        self.hook('SubagentStart')
        self.assertEqual(list((self.home/'bus/seats').glob('*.json')),[])
        self.hook('SessionStart',extra={'CODEX_INTERNAL_ORIGINATOR_OVERRIDE':'codex_cli'})
        self.assertEqual(self.seat()['codex_queue'],'')

    def test_lifecycle_idle_registration_survives_ttl_and_gc_until_end(self):
        self.hook('SessionStart')
        target=self.seat()['addr']
        self.cmd('role','pm')
        path=next((self.home/'bus/seats').glob('codex_*.json'))
        state=json.loads(path.read_text()); state['epoch']=1
        path.write_text(json.dumps(state))
        self.cmd('gc',tool='shell',session='gc-observer')
        self.assertTrue(path.exists())
        self.assertTrue(list((self.home/'bus/state/roles').glob('*.pm')))
        self.post(target)
        self.assertEqual(len(self.requests()),1)
        self.hook('SessionEnd')
        self.assertFalse(path.exists())
        self.post(target)
        self.assertEqual(len(self.requests()),1)

    def test_codex_installer_preserves_other_hooks_and_is_reversible(self):
        cfg=self.home/'codex settings.json'
        original={'custom':{'keep':True}, 'hooks':{'SessionStart':[{'hooks':[
            {'type':'command','command':'keep-existing-hook'}]}]}}
        cfg.write_text(json.dumps(original))
        self.hook('SessionStart')
        env=self.env | {'AGENT_BUS_CODEX_SETTINGS':str(cfg)}
        def install(*args):
            subprocess.run([str(ROOT/'install-hooks.sh'),'--codex',*args],env=env,cwd=self.home,
                           stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
        install()
        first=json.loads(cfg.read_text()); install()
        self.assertEqual(first,json.loads(cfg.read_text()))
        self.assertEqual(first['custom'],original['custom'])
        self.assertEqual(first['hooks']['SessionStart'][0],original['hooks']['SessionStart'][0])
        self.assertEqual(len(first['hooks']['SessionStart']),2)
        for name in ['UserPromptSubmit','Stop','SessionEnd']:
            self.assertEqual(len(first['hooks'][name]),1)
        self.assertEqual(first['hooks']['SessionEnd'][0]['hooks'][0]['timeout'],3)
        # Execute the generated hook command: path quoting and stdin payload
        # must really reach the adapter, not just appear in a config snapshot.
        command=first['hooks']['SessionStart'][1]['hooks'][0]['command']
        payload={'hook_event_name':'SessionStart','session_id':self.thread,'cwd':str(self.home)}
        subprocess.run(['/bin/bash','-c',command],env=env,cwd=self.home,input=json.dumps(payload),
                       text=True,stdout=subprocess.PIPE,check=True)
        install('--uninstall')
        self.assertEqual(json.loads(cfg.read_text()),original)
        self.assertEqual(json.loads(self.cmd('codex','status').stdout)['mode'],'disabled')
        self.assertEqual(json.loads(Path(str(cfg)+'.agent-bus.bak').read_text()),original)


if __name__ == '__main__':
    unittest.main()
