"""Score PHPStan output (levels 0-10) against the spike's ground truth on the pre-fix tree 2314b75.

A ground-truth item counts as detected at a level only when a finding sits on one of its lines
AND has an identifier that actually describes the defect (a "missing return type" note on the
same line does not count). Detections whose message is only about `mixed` are marked generic:
they are true, but indistinguishable from the hundreds of other `mixed` findings at that level.

    python3 -I score.py <dir with phpstan-l0.json .. phpstan-l10.json>
"""
import collections
import json
import sys

OUT = sys.argv[1]
# id: (journal entry, description, relevant PHPStan identifiers, [(file, line), ...])
G = {
    'G01': ('5.2', 'property read on json_decode() null (Slack)', {'property.nonObject'},
            [('features/slack/lib.php', l) for l in (42, 77, 126)]),
    'G02': ('5.3', 'setUp() without : void', {'method.childReturnType'},
            [('tests/unit/CurlClient_Test.php', 8), ('tests/unit/JiraClient_Test.php', 13)]),
    'G03': ('5.4', 'test file name != class name', set(),
            [('tests/unit/Contact_Test.php', 5), ('tests/unit/CurlClient_Test.php', 6), ('tests/unit/JiraClient_Test.php', 7)]),
    'G04': ('5.5', 'implode() reversed args (TypeError)', {'argument.type'},
            [('features/jira/lib.php', 223), ('features/jira/lib.php', 225)]),
    'G05': ('5.6', 'non-static data provider', set(), [('tests/unit/JiraClient_Test.php', 62)]),
    'G06': ('5.6', '@dataProvider doc-comment metadata', set(), [('tests/unit/JiraClient_Test.php', 72)]),
    'G07': ('5.6', 'returnValue() deprecated', {'method.deprecated'}, [('tests/unit/JiraClient_Test.php', 43)]),
    'G08': ('5.6', 'createMock() extra arg', {'arguments.count'}, [('tests/unit/JiraClient_Test.php', 15)]),
    'G09': ('5.6', 'dynamic properties on test classes', {'property.notFound'},
            [('tests/unit/JiraClient_Test.php', 15), ('tests/unit/JiraClient_Test.php', 16), ('tests/unit/CurlClient_Test.php', 9)]),
    'G10': ('5.7', 'JiraClient dynamic properties', {'property.notFound'},
            [('features/jira/lib.php', l) for l in range(180, 191)]),
    'G11': ('5.8', 'Calendar / Uploader_Webdav dynamic properties', {'property.notFound'},
            [('features/calendar/lib.php', l) for l in range(8, 21)] + [('features/upload/lib/webdav.php', 38)]),
    'G12': ('5.9', 'implicitly nullable parameter', {'parameter.implicitlyNullable'}, [('phplib/CurlClient.php', 5)]),
    'G13': ('5.10', 'optional before required parameter', {'parameter.requiredAfterOptional'}, [('phplib/Persistence.php', 230)]),
    'G14': ('5.10', 'trigger_error(E_USER_ERROR)', set(), [('phplib/Persistence.php', 251)]),
    'G15': ('5.11', '${var} interpolation', set(), [('features/anniversary/views/anniversary-mail.php', 29)]),
    'G16': ('5.12', 'removed mcrypt constants in app', {'constant.notFound'}, [('htdocs/index.php', 28), ('htdocs/index.php', 29)]),
    'G17': ('5.13', 'fetch() false used as array (unknown id -> 500)', {'offsetAccess.nonOffsetAccessible'},
            [('phplib/Persistence.php', 168), ('phplib/Postmortem.php', 85)]),
    'G18': ('5.14', 'missing id: undefined key / false autoviv', {'offsetAccess.nonOffsetAccessible', 'argument.type'},
            [('phplib/Postmortem.php', 142), ('features/history/routes.php', 10), ('phplib/Postmortem.php', 624)]),
    'G19': ('5.16', 'null passed to string params (7 sites)', {'argument.type'},
            [('htdocs/index.php', 134), ('features/anniversary/routes.php', 11), ('features/anniversary/routes.php', 38),
             ('features/anniversary/routes.php', 90), ('features/search/routes.php', 5), ('phplib/Postmortem.php', 47),
             ('phplib/Postmortem.php', 559)]),
    'G20': ('5.18', 'undefined variable $img (forum-link route)', {'variable.undefined'}, [('features/links/routes.php', 38)]),
}
site = {}
for gid, (_, _, _, sites) in G.items():
    for s in sites:
        site.setdefault(s, set()).add(gid)

first = {}          # gid -> (level, n_precise, n_generic) at the first level it is detected
best = {}           # gid -> (level, n_precise, n_generic) at the level with most sites covered
rows = []
for L in range(11):
    d = json.load(open(f'{OUT}/phpstan-l{L}.json'))
    total = 0
    found = collections.defaultdict(lambda: {'precise': set(), 'generic': set()})
    for f, v in d['files'].items():
        rel = f.replace('/target/', '')
        for m in v['messages']:
            total += 1
            for gid in site.get((rel, m['line']), ()):
                if m.get('identifier') in G[gid][2]:
                    kind = 'generic' if ('on mixed' in m['message'] or 'mixed given' in m['message']) else 'precise'
                    found[gid][kind].add((rel, m['line']))
    rows.append((L, total, sorted(found)))
    for gid, k in found.items():
        p = len(k['precise']); g = len(k['generic'] - k['precise'])
        first.setdefault(gid, (L, p, g))
        if gid not in best or p + g > sum(best[gid][1:]):
            best[gid] = (L, p, g)

print('PHPStan level | findings | ground-truth items detected (of 20)')
for L, total, gids in rows:
    print(f'  {L:>2} | {total:>5} | {len(gids):>2}  {" ".join(gids)}')
print()
print('item | entry | description | first detected: level (precise+generic sites) | widest: level (precise+generic)')
for gid, (entry, desc, _, sites) in G.items():
    n = 'all' if gid in ('G10', 'G11') else len(sites)
    f0 = first.get(gid); b0 = best.get(gid)
    a_ = f'L{f0[0]} ({f0[1]}+{f0[2]} of {n})' if f0 else '-'
    b_ = f'L{b0[0]} ({b0[1]}+{b0[2]} of {n})' if b0 and b0 != f0 else ''
    print(f'{gid} | {entry} | {desc} | {a_} | {b_}')
